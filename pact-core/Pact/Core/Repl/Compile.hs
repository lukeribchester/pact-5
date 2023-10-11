{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE PartialTypeSignatures #-}
{-# LANGUAGE TypeApplications #-}


module Pact.Core.Repl.Compile
 ( ReplCompileValue(..)
--  , interpretExpr
--  , compileProgram
 , interpretReplProgram
 ) where

import Control.Lens
import Control.Monad
import Control.Monad.Except
import Control.Monad.IO.Class(liftIO)
import Data.Text(Text)
import Data.Proxy
import Data.Default
import qualified Data.Map.Strict as M
-- import qualified Data.Set as Set
import qualified Data.ByteString as B
import qualified Data.Text as T

-- import Pact.Core.Info
import Pact.Core.Persistence
import Pact.Core.Builtin
import Pact.Core.Names
import Pact.Core.Repl.Utils
import Pact.Core.IR.Desugar
import Pact.Core.Errors
import Pact.Core.IR.Term
import Pact.Core.Compile
import Pact.Core.Interpreter
import Pact.Core.Environment


import Pact.Core.IR.Eval.Runtime
import Pact.Core.Repl.Runtime
import Pact.Core.Repl.Runtime.ReplBuiltin

import qualified Pact.Core.Syntax.ParseTree as Lisp
import qualified Pact.Core.Syntax.Lexer as Lisp
import qualified Pact.Core.Syntax.Parser as Lisp

-- Small internal debugging function for playing with file loading within
-- this module
data ReplCompileValue
  = RCompileValue (CompileValue ReplRawBuiltin)
  | RLoadedDefun Text
  | RLoadedDefConst Text
  deriving Show

loadFile :: FilePath -> ReplM ReplRawBuiltin [ReplCompileValue]
loadFile loc = do
  source <- SourceCode <$> liftIO (B.readFile loc)
  replCurrSource .= source
  interpretReplProgram source

interpretReplProgram
  :: SourceCode
  -> ReplM ReplRawBuiltin [ReplCompileValue]
interpretReplProgram sc@(SourceCode source) = do
  pactdb <- use replPactDb
  lexx <- liftEither (Lisp.lexer source)
  debugIfFlagSet ReplDebugLexer lexx
  parsed <- liftEither $ Lisp.parseReplProgram lexx
  concat <$> traverse (pipe pactdb) parsed
  where
  debugIfLispExpr = \case
    Lisp.RTLTerm t -> debugIfFlagSet ReplDebugParser t
    _ -> pure ()
  debugIfIRExpr flag = \case
    RTLTerm t -> debugIfFlagSet flag t
    _ -> pure ()
  pipe pactdb = \case
    Lisp.RTL rtl ->
      pure <$> pipe' pactdb rtl
    Lisp.RTLReplSpecial rsf -> case rsf of
      Lisp.ReplLoad txt b _ -> do
        oldSrc <- use replCurrSource
        oldEs <- use evalState
        when b $ evalState .= def
        out <- loadFile (T.unpack txt)
        evalState .= oldEs
        replCurrSource .= oldSrc
        pure out
  pipe' pactdb tl = do
    debugIfLispExpr tl
    lastLoaded <- use loaded
    ds <- runDesugarReplTopLevel (Proxy @ReplRawBuiltin) pactdb lastLoaded tl
    debugIfIRExpr ReplDebugDesugar (_dsOut ds)
    loaded .= _dsLoaded ds
    interpret ds
  interpret (DesugarOutput tl _ deps) = do
    pdb <- use replPactDb
    lo <- use loaded
    ee <- use replEvalEnv
    case tl of
      RTLTopLevel tt -> do
        let interp = Interpreter interpreter
        RCompileValue <$> interpretTopLevel pdb interp (DesugarOutput tt lo deps)
        where
        -- interpreter :: EvalTerm (ReplBuiltin RawBuiltin) SpanInfo -> ReplM ReplRawBuiltin InterpretValue
        interpreter te = do
          let i = view termInfo te
          evalGas <- use replGas
          evalLog <- use replEvalLog
          es <- use replEvalState
          -- todo: cache?
          -- mhashes <- uses (loaded . loModules) (fmap (view mdModuleHash))
          let rEnv = ReplEvalEnv evalGas evalLog replBuiltinEnv
              rState = ReplEvalState ee es sc
          (out, st) <- liftIO (runReplCEK rEnv rState te)
          evalState .= view reState st
          replEvalEnv .= view reEnv st
          liftEither out >>= \case
            VError txt ->
              throwError (PEExecutionError (EvalError txt) i)
            EvalValue v -> do
              loaded .= view (reState . esLoaded) st
              (replEvalState . esPactExec) .= view (reState . esPactExec) st
              case v of
                VClosure{} -> do
                  pure IPClosure
                VTable tv -> pure (IPTable (_tvName tv))
                VPactValue pv -> do
                  pure (IPV pv (view termInfo te))
      RTLDefun df -> do
        let fqn = FullyQualifiedName replModuleName (_dfunName df) replModuleHash
        loaded . loAllLoaded %= M.insert fqn (Dfun df)
        pure $ RLoadedDefun $ _dfunName df
      RTLDefConst dc -> do
        let fqn = FullyQualifiedName replModuleName (_dcName dc) replModuleHash
        loaded . loAllLoaded %= M.insert fqn (DConst dc)
        pure $ RLoadedDefConst $ _dcName dc
