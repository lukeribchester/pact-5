{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE PartialTypeSignatures #-}
{-# LANGUAGE ScopedTypeVariables #-}


-- |
-- Module      :  Pact.Core.IR.Typecheck
-- Copyright   :  (C) 2022 Kadena
-- License     :  BSD-style (see the file LICENSE)
-- Maintainer  :  Jose Cardona <jose@kadena.io>
--
-- Pact core minimal repl
--


module Main where

import Control.Lens
import Control.Monad.Catch
import Control.Monad.Except
import Control.Monad.Trans(lift)
import System.Console.Haskeline
import Data.IORef
import Data.Foldable(traverse_)

import Data.Default
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Data.Set as Set

import Pact.Core.Persistence
import Pact.Core.Pretty
import Pact.Core.Builtin
import Pact.Core.Names
import Pact.Core.Interpreter

import Pact.Core.Compile
import Pact.Core.Repl.Compile
import Pact.Core.Repl.Utils
import Pact.Core.Environment
import Pact.Core.PactValue
import Pact.Core.Hash
import Pact.Core.Capabilities
import Pact.Core.Imports

main :: IO ()
main = do
  pdb <- mockPactDb
  g <- newIORef mempty
  evalLog <- newIORef Nothing
  let ee = EvalEnv mempty pdb (EnvData mempty) (Hash "default") def Transactional mempty
      es = EvalState (CapState [] mempty mempty mempty)  [] [] mempty
  ref <- newIORef (ReplState mempty pdb es ee g evalLog (SourceCode mempty) Nothing)
  runReplT ref (runInputT replSettings loop) >>= \case
    Left err -> do
      putStrLn "Exited repl session with error:"
      putStrLn $ T.unpack $ replError (ReplSource "(interactive)" "") err
    _ -> pure ()
  where
  replSettings = Settings (replCompletion rawBuiltinNames) (Just ".pc-history") True
  displayOutput = \case
    RCompileValue cv -> case cv of
      LoadedModule mn -> outputStrLn $ show $
        "loaded module" <+> pretty mn
      LoadedInterface mn -> outputStrLn $ show $
        "Loaded interface" <+> pretty mn
      InterpretValue iv -> case iv of
        IPV v _ -> outputStrLn (show (pretty v))
        IPTable (TableName tn) -> outputStrLn $ "table{" <> T.unpack tn <> "}"
        IPClosure -> outputStrLn "<<closure>>"
      LoadedImports i ->
        outputStrLn $ "loaded imports from" <> show (pretty (_impModuleName i))
    RLoadedDefun mn ->
      outputStrLn $ show $
        "loaded defun" <+> pretty mn
    RLoadedDefConst mn ->
      outputStrLn $ show $
        "loaded defconst" <+> pretty mn
    -- InterpretValue v _ -> outputStrLn (show (pretty v))
    -- InterpretLog t -> outputStrLn (T.unpack t)
  catch' ma = catchAll ma (\e -> outputStrLn (show e) *> loop)
  loop = do
    minput <- fmap T.pack <$> getInputLine "pact>"
    case minput of
      Nothing -> outputStrLn "goodbye"
      Just input | T.null input -> loop
      Just input -> case parseReplAction (T.strip input) of
        Nothing -> do
          outputStrLn "Error: Expected command [:load, :type, :syntax, :debug] or expression"
          loop
        Just ra -> case ra of
          RASetFlag flag -> do
            lift (replFlags %= Set.insert flag)
            outputStrLn $ unwords ["set debug flag for", prettyReplFlag flag]
            loop
          RADebugAll -> do
            lift (replFlags .= Set.fromList [minBound .. maxBound])
            outputStrLn $ unwords ["set all debug flags"]
            loop
          RADebugNone -> do
            lift (replFlags .= Set.empty)
            outputStrLn $ unwords ["Remove all debug flags"]
            loop
          RAExecuteExpr src -> catch' $ do
            eout <- lift (tryError (interpretReplProgram (SourceCode (T.encodeUtf8 src))))
            case eout of
              Right out -> traverse_ displayOutput out
              Left err -> do
                SourceCode currSrc <- lift (use replCurrSource)
                let srcText = T.decodeUtf8 currSrc
                let rs = ReplSource "(interactive)" srcText
                outputStrLn (T.unpack (replError rs err))
            loop
