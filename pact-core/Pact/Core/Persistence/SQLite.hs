-- |
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}

module Pact.Core.Persistence.SQLite (
  withSqlitePactDb
                                    ) where

import Control.Monad.Trans.Control (MonadBaseControl)
import Control.Exception.Lifted (bracket)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.IORef (newIORef, IORef, readIORef, atomicModifyIORef', writeIORef, modifyIORef')
import Data.Text (Text)
import Control.Lens (view)
import qualified Database.SQLite3 as SQL
import qualified Database.SQLite3.Direct as Direct
import Data.ByteString (ByteString)
import qualified Data.Map.Strict as Map

import Pact.Core.Guards (renderKeySetName, parseAnyKeysetName)
import Pact.Core.Names (renderModuleName, DefPactId(..), NamespaceName(..), TableName(..), RowKey(..), parseRenderedModuleName
                       , renderDefPactId, renderNamespaceName)
import Pact.Core.Persistence (PactDb(..), Domain(..),
                              Purity(PImpure)
                             ,WriteType(..)
                             ,toUserTable
                             ,ExecutionMode(..), TxId(..)
                             , RowData(..), TxLog(..)
                             )
import qualified Pact.Core.Persistence as P
import Control.Exception (throwIO)
-- import Pact.Core.Repl.Utils (ReplEvalM)
import Pact.Core.Serialise

withSqlitePactDb
  :: (MonadIO m, MonadBaseControl IO m)
  => PactSerialise b i
  -> Text
  -> (PactDb b i -> m a)
  -> m a
withSqlitePactDb serial connectionString act =
  bracket connect cleanup (\db -> liftIO (initializePactDb serial db) >>= act)
  where
    connect = liftIO $ SQL.open connectionString
    cleanup db = liftIO $ SQL.close db

createSysTables :: SQL.Database -> IO ()
createSysTables db = do
  SQL.exec db (cStmt "SYS:KEYSETS")
  SQL.exec db (cStmt "SYS:MODULES")
  SQL.exec db (cStmt "SYS:PACTS")
  SQL.exec db (cStmt "SYS:NAMESPACES")
  where
    cStmt tbl = "CREATE TABLE IF NOT EXISTS \"" <> tbl <> "\" \
                \ (txid UNSIGNED BIG INT, \
                \  rowkey TEXT, \
                \  rowdata BLOB, \
                \  UNIQUE (txid, rowkey))"

-- | Create all tables that should exist in a fresh pact db,
--   or ensure that they are already created.
initializePactDb :: PactSerialise b i -> SQL.Database  -> IO (PactDb b i)
initializePactDb serial db = do
  createSysTables db
  txId <- newIORef (TxId 0)
  txLog <- newIORef []
  pure $ PactDb
    { _pdbPurity = PImpure
    , _pdbRead = read' serial db
    , _pdbWrite = write' serial db txId txLog
    , _pdbKeys = readKeys db
    , _pdbCreateUserTable = createUserTable db txLog
    , _pdbBeginTx = beginTx txId db txLog
    , _pdbCommitTx = commitTx txId db txLog
    , _pdbRollbackTx = rollbackTx db txLog
    , _pdbTxIds = listTxIds db
    , _pdbGetTxLog = getTxLog serial db txId txLog
    }

getTxLog :: PactSerialise b i -> SQL.Database -> IORef TxId -> IORef [TxLog ByteString] -> TableName -> TxId -> IO [TxLog RowData]
getTxLog serial db currTxId txLog tab txId = do
  currTxId' <- readIORef currTxId
  if currTxId' == txId
    then do
    txLog' <- readIORef txLog
    let
      userTabLogs = filter (\tl -> _tableName tab == _txDomain tl) txLog'
      env :: Maybe [TxLog RowData] = traverse (traverse (fmap (view document) . _decodeRowData serial)) userTabLogs
    case env of
      Nothing -> fail "undexpected decoding error"
      Just xs -> pure xs
    else withStmt db ("SELECT rowkey,rowdata FROM \"" <> toUserTable tab <> "\" WHERE txid = ?") $ \stmt -> do
                         let TxId i = txId
                         SQL.bind stmt [SQL.SQLInteger $ fromIntegral i]
                         txLogBS <- collect stmt []
                         case traverse (traverse (fmap (view document) . _decodeRowData serial)) txLogBS of
                           Nothing -> fail "unexpected decoding error"
                           Just txl -> pure txl
  where
    collect stmt acc = SQL.step stmt >>= \case
        SQL.Done -> pure acc
        SQL.Row -> do
          [SQL.SQLText key, SQL.SQLBlob value] <- SQL.columns stmt
          collect stmt (TxLog (toUserTable tab) key value:acc)
        
readKeys :: forall k v b i. SQL.Database -> Domain k v b i -> IO [k]
readKeys db = \case
  DKeySets -> withStmt db "SELECT rowkey FROM \"SYS:KEYSETS\" ORDER BY txid DESC" $ \stmt -> do
    parsedKS <- fmap parseAnyKeysetName <$> collect stmt []
    case sequence parsedKS of
      Left _ -> fail "unexpected decoding"
      Right v -> pure v
  DModules -> withStmt db "SELECT rowkey FROM \"SYS:MODULES\" ORDER BY txid DESC" $ \stmt -> fmap parseRenderedModuleName <$> collect stmt [] >>= \mns -> case sequence mns of
    Nothing -> fail "unexpected decoding"
    Just mns' -> pure mns'
  DDefPacts -> withStmt db "SELECT rowkey FROM \"SYS:PACTS\" ORDER BY txid DESC" $ \stmt -> fmap DefPactId <$> collect stmt []
  DNamespaces -> withStmt db "SELECT rowkey FROM \"SYS:NAMESPACES\" ORDER BY txid DESC" $ \stmt -> fmap NamespaceName <$> collect stmt []
  DUserTables tbl -> withStmt db ("SELECT rowkey FROM \"" <> toUserTable tbl <> "\" ORDER BY txid DESC") $ \stmt -> fmap RowKey <$> collect stmt []
  where
    collect stmt acc = SQL.step stmt >>= \case
        SQL.Done -> pure acc
        SQL.Row -> do
          [SQL.SQLText value] <- SQL.columns stmt
          collect stmt (value:acc)


listTxIds :: SQL.Database -> TableName -> TxId -> IO [TxId]
listTxIds db tbl (TxId minTxId) = withStmt db ("SELECT txid FROM \"" <> toUserTable tbl <> "\" WHERE txid >= ? ORDER BY txid ASC") $ \stmt -> do
  SQL.bind stmt [SQL.SQLInteger $ fromIntegral minTxId]
  collect stmt []
  where
    collect stmt acc = SQL.step stmt >>= \case
        SQL.Done -> pure acc
        SQL.Row -> do
          [SQL.SQLInteger value] <- SQL.columns stmt
          -- Here we convert the Int64 received from SQLite into Word64
          -- using `fromIntegral`. It is assumed that recorded txids
          -- in the database will never be negative integers.
          collect stmt (TxId (fromIntegral value):acc)

commitTx :: IORef TxId -> SQL.Database -> IORef [TxLog ByteString] -> IO [TxLog ByteString]
commitTx txid db txLog = do
  _ <- atomicModifyIORef' txid (\old@(TxId n) -> (TxId (succ n), old))
  SQL.exec db "COMMIT TRANSACTION"
  readIORef txLog

beginTx :: IORef TxId -> SQL.Database -> IORef [TxLog ByteString] -> ExecutionMode -> IO (Maybe TxId)
beginTx txid db txLog em = do
    SQL.exec db "BEGIN TRANSACTION"
    writeIORef txLog []
    case em of
      Transactional -> Just <$> readIORef txid
      Local -> pure Nothing

rollbackTx :: SQL.Database -> IORef [TxLog ByteString] -> IO ()
rollbackTx db txLog = do
  SQL.exec db "ROLLBACK TRANSACTION"
  writeIORef txLog []

createUserTable :: SQL.Database -> IORef [TxLog ByteString] -> TableName -> IO ()
createUserTable db txLog tbl = do
  SQL.exec db stmt
  modifyIORef' txLog (TxLog "SYS:usertables" (_tableName tbl) mempty :)
  
  where
    stmt = "CREATE TABLE IF NOT EXISTS " <> tblName <> " \
           \ (txid UNSIGNED BIG INT, \
           \  rowkey TEXT, \
           \  rowdata BLOB, \
           \  UNIQUE (txid, rowkey))"
    tblName = "\"" <> toUserTable tbl <> "\""

write'
  :: forall k v b i.
     PactSerialise b i
  -> SQL.Database
  -> IORef TxId
  -> IORef [TxLog ByteString]
  -> WriteType
  -> Domain k v b i
  -> k
  -> v
  -> IO ()
write' serial db txId txLog wt domain k v =
  case domain of
    DUserTables tbl -> checkInsertOk tbl k >>= \case
      Nothing -> withStmt db ("INSERT INTO \"" <> toUserTable tbl <> "\" (txid, rowkey, rowdata) VALUES (?,?,?)") $ \stmt -> do
        let
          encoded = _encodeRowData serial v
          RowKey k' = k
        TxId i <- readIORef txId
        SQL.bind stmt [SQL.SQLInteger (fromIntegral i), SQL.SQLText k', SQL.SQLBlob encoded]
        SQL.stepNoCB stmt >>= \case
          SQL.Done -> modifyIORef' txLog (TxLog (_tableName tbl) k' encoded:)
          SQL.Row -> fail "invariant viaolation"

      Just old -> do
        let
          RowData old' = old
          RowData v' = v
          new = RowData (Map.union v' old')
        withStmt db ("INSERT OR REPLACE INTO \"" <> toUserTable tbl <> "\" (txid, rowkey, rowdata) VALUES (?,?,?)") $ \stmt -> do
          let
            encoded = _encodeRowData serial new
            RowKey k' = k
          TxId i <- readIORef txId
          SQL.bind stmt [SQL.SQLInteger (fromIntegral i), SQL.SQLText k', SQL.SQLBlob encoded]
          SQL.stepNoCB stmt >>= \case
            SQL.Done -> modifyIORef' txLog (TxLog (_tableName tbl) k' encoded:)
            SQL.Row -> fail "invariant viaolation"
      
    DKeySets -> withStmt db "INSERT OR REPLACE INTO \"SYS:kEYSETS\" (txid, rowkey, rowdata) VALUES (?,?,?)" $ \stmt -> do
      let encoded = _encodeKeySet serial v
      TxId i <- readIORef txId
      SQL.bind stmt [SQL.SQLInteger (fromIntegral i), SQL.SQLText (renderKeySetName k), SQL.SQLBlob encoded]
      SQL.stepNoCB stmt >>= \case
        SQL.Done -> modifyIORef' txLog (TxLog "SYS:KeySets" (renderKeySetName k) encoded:)
        SQL.Row -> fail "invariant violation"
        
    DModules -> withStmt db "INSERT OR REPLACE INTO \"SYS:MODULES\" (txid, rowkey, rowdata) VALUES (?,?,?)" $ \stmt -> do
      let encoded = _encodeModuleData serial v
      TxId i <- readIORef txId
      SQL.bind stmt [SQL.SQLInteger (fromIntegral i), SQL.SQLText (renderModuleName k), SQL.SQLBlob encoded]
      Direct.stepNoCB stmt >>= \case
        Left _err -> throwIO P.WriteException
        Right res
          | res == SQL.Done -> modifyIORef' txLog (TxLog "SYS:Modules" (renderModuleName k) encoded:)
          | otherwise -> fail "invariant violation"
    DDefPacts -> withStmt db "INSERT OR REPLACE INTO \"SYS:PACTS\" (txid, rowkey, rowdata) VALUES (?,?,?)" $ \stmt -> do
      let
        encoded = _encodeDefPactExec serial v
        DefPactId k' = k
      TxId i <- readIORef txId
--      putStrLn (show wt <> " / " <> show k <> " / " <> show v)
      SQL.bind stmt [SQL.SQLInteger (fromIntegral i), SQL.SQLText k', SQL.SQLBlob encoded]
      SQL.stepNoCB stmt >>= \case
        SQL.Done -> modifyIORef' txLog (TxLog "SYS:DEFPACTS" k' encoded:)
        SQL.Row -> fail "invariant violation"
    DNamespaces -> withStmt db "INSERT OR REPLACE INTO \"SYS:NAMESPACES\" (txid, rowkey, rowdata) VALUES (?,?,?)" $ \stmt -> do
      let
        encoded = _encodeNamespace serial v
        NamespaceName k' = k
      TxId i <- readIORef txId
--      putStrLn ("DNamespaces: " <> show i <> " / " <> show k')
      SQL.bind stmt [SQL.SQLInteger (fromIntegral i), SQL.SQLText k', SQL.SQLBlob encoded]
      Direct.stepNoCB stmt >>= \case
        Left _err -> undefined
        Right res
          | res == SQL.Done -> modifyIORef' txLog (TxLog "SYS:NAMESPACES" k' encoded:)
          | otherwise -> fail "invariant viaolation"
  --     DUserTables tbl -> do
        
        -- withStmt db ("INSERT INTO \"" <> toUserTable tbl <> "\" (txid, rowkey, rowdata) VALUES (?,?,?)") $ \stmt -> do
        -- let
        --   encoded = _encodeRowData serial v
        --   RowKey k' = k
        -- TxId i <- readIORef txId
        -- SQL.bind stmt [SQL.SQLInteger (fromIntegral i), SQL.SQLText k', SQL.SQLBlob encoded]
        -- SQL.stepNoCB stmt >>= \case
        --   SQL.Done -> modifyIORef' txLog (TxLog (toUserTable tbl) k' encoded:)
        --   SQL.Row -> fail "invariant viaolation"
  where
    checkInsertOk ::  TableName -> RowKey -> IO (Maybe RowData)
    checkInsertOk tbl rk = do
      curr <- read' serial db (DUserTables tbl) rk
      case (curr, wt) of
        (Nothing, Insert) -> return Nothing
        (Just _, Insert) -> throwIO P.WriteException -- error ("Insert: row found for key "<> show tbl <> " " <> show rk)
        (Nothing, Write) -> return Nothing
        (Just old, Write) -> return $ Just old
        (Just old, Update) -> return $ Just old
        (Nothing, Update) -> error "Update: no row found for key "
      

read' :: forall k v b i. PactSerialise b i -> SQL.Database -> Domain k v b i -> k -> IO (Maybe v)
read' serial db domain k = case domain of
  DKeySets -> withStmt db (selStmt "SYS:KEYSETS")
    (doRead (renderKeySetName k) (\v -> pure (view document <$> _decodeKeySet serial v)))

  DModules -> withStmt db (selStmt "SYS:MODULES")
    (doRead (renderModuleName k) (\v -> pure (view document <$> _decodeModuleData serial v)))

  DUserTables tbl ->  withStmt db (selStmt $ toUserTable tbl)
    (doRead (_rowKey k) (\v -> pure (view document <$> _decodeRowData serial v)))

  DDefPacts -> withStmt db (selStmt "SYS:PACTS")
    (doRead (renderDefPactId k) (\v -> pure (view document <$> _decodeDefPactExec serial v)))

  DNamespaces -> withStmt db (selStmt "SYS:NAMESPACES")
    (doRead (renderNamespaceName k) (\v -> pure (view document <$> _decodeNamespace serial v)))

  where
    selStmt tbl = "SELECT rowdata FROM \""<> tbl <> "\" WHERE rowkey = ? ORDER BY txid DESC LIMIT 1"
    doRead k' f stmt = do
      SQL.bind stmt [SQL.SQLText k']
      SQL.step stmt >>= \case
        SQL.Done -> pure Nothing
        SQL.Row -> do
          1 <- SQL.columnCount stmt
          [SQL.SQLBlob value] <- SQL.columns stmt
          SQL.Done <- SQL.step stmt
          f value


-- Utility functions
withStmt :: SQL.Database -> Text -> (SQL.Statement -> IO a) -> IO a
withStmt conn sql = bracket (SQL.prepare conn sql) SQL.finalize


