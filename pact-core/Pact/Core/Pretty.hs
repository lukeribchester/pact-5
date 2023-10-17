{-# LANGUAGE OverloadedStrings #-}

module Pact.Core.Pretty
( module Pretty
, renderCompactString
, renderCompactString'
, renderText
, renderText'
, commaSep
, commaSepNE
, commaBraces
, commaBrackets
, bracketsSep
, parensSep
, bracesSep
-- , prettyList
) where

import Data.Text(Text)
import Prettyprinter
import qualified Prettyprinter as Pretty
import Prettyprinter.Render.String
import Prettyprinter.Render.Text
import Data.List(intersperse)
import Data.List.NonEmpty(NonEmpty)

import qualified Data.List.NonEmpty as NE

renderCompactString :: Pretty a => a -> String
renderCompactString = renderString . layoutPretty defaultLayoutOptions . pretty

renderCompactString' :: Doc ann -> String
renderCompactString' = renderString . layoutPretty defaultLayoutOptions

renderText :: Pretty a => a -> Text
renderText = renderStrict . layoutPretty defaultLayoutOptions . pretty

renderText' :: Doc ann -> Text
renderText' = renderStrict . layoutPretty defaultLayoutOptions

commaSepNE :: Pretty a => NonEmpty a -> Doc ann
commaSepNE = commaSep . NE.toList

commaSep :: Pretty a => [a] -> Doc ann
commaSep = Pretty.hsep . intersperse "," . fmap pretty

commaBraces, commaBrackets, bracketsSep, parensSep, bracesSep :: [Doc ann] -> Doc ann
commaBraces   = encloseSep "{" "}" ","
commaBrackets = encloseSep "[" "]" ","
bracketsSep   = brackets . sep
parensSep     = parens   . sep
bracesSep     = braces   . sep

-- prettyList :: Pretty a => [a] -> Doc ann
-- prettyList = list . map pretty

