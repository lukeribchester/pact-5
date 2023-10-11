{-# LANGUAGE DeriveTraversable #-}


module Pact.Core.Capabilities
 ( DefCapMeta(..)
 , DefManagedMeta(..)
 , CapForm(..)
 , capFormName
 ) where

import Control.Lens

import Pact.Core.Pretty

data DefManagedMeta name
  = DefManagedMeta
  { _dmManagedArgIx :: Int
  , _dmManagerFn :: name
  } deriving (Show, Functor, Foldable, Traversable)

data DefCapMeta name
  = DefEvent
  | DefManaged (Maybe (DefManagedMeta name))
  deriving (Show, Functor, Foldable, Traversable)

data CapForm name e
  = WithCapability name [e] e
  | RequireCapability name [e]
  | ComposeCapability name [e]
  | InstallCapability name [e]
  | EmitEvent name [e]
  | CreateUserGuard name [e]
  deriving (Show, Functor, Foldable, Traversable)

capFormName :: Lens (CapForm name e) (CapForm name' e) name name'
capFormName f = \case
  WithCapability name es e -> (\fq -> WithCapability fq es e) <$> f name
  RequireCapability name es -> (`RequireCapability` es) <$> f name
  ComposeCapability name es -> (`ComposeCapability` es) <$> f name
  InstallCapability name es -> (`InstallCapability` es) <$> f name
  EmitEvent name es -> (`EmitEvent` es) <$> f name
  CreateUserGuard name es -> (`CreateUserGuard` es) <$> f name

instance (Pretty name, Pretty e) => Pretty (CapForm name e) where
  pretty = \case
    WithCapability name es e ->
      parens ("with-capability" <+> parens (pretty name <+> hsep (pretty <$> es)) <+> pretty e)
    RequireCapability name es ->
      parens ("require-capability" <+> parens (pretty name <+> hsep (pretty <$> es)))
    ComposeCapability name es ->
      parens ("compose-capability" <+> parens (pretty name <+> hsep (pretty <$> es)))
    InstallCapability name es ->
      parens ("install-capability" <+> parens (pretty name <+> hsep (pretty <$> es)))
    EmitEvent name es ->
      parens ("emit-event" <+> parens (pretty name <+> hsep (pretty <$> es)))
    CreateUserGuard name es ->
      parens ("create-user-guard" <+> parens (pretty name <+> hsep (pretty <$> es)))
