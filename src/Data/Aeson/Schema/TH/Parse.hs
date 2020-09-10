{-|
Module      :  Data.Aeson.Schema.TH.Parse
Maintainer  :  Brandon Chinn <brandon@leapyear.io>
Stability   :  experimental
Portability :  portable

Definitions for parsing input text in QuasiQuoters.
-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE RecordWildCards #-}

module Data.Aeson.Schema.TH.Parse where

import Control.Monad (MonadPlus, void)
#if !MIN_VERSION_base(4,13,0)
import Control.Monad.Fail (MonadFail)
#endif
import Data.Functor (($>))
import Data.List (intercalate)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Void (Void)
import Text.Megaparsec hiding (sepBy1, sepEndBy1, some)
import qualified Text.Megaparsec as Megaparsec
import Text.Megaparsec.Char
import qualified Text.Megaparsec.Char.Lexer as L

type Parser = Parsec Void String

#if !MIN_VERSION_megaparsec(7,0,0)
errorBundlePretty :: (Ord t, ShowToken t, ShowErrorComponent e) => ParseError t e -> String
errorBundlePretty = parseErrorPretty
#endif

runParserFail :: MonadFail m => Parser a -> String -> m a
runParserFail parser s = either (fail . errorBundlePretty) return $ runParser parser s s

{- SchemaDef -}

data SchemaDef
  = SchemaDefType String
  | SchemaDefMaybe SchemaDef
  | SchemaDefTry SchemaDef
  | SchemaDefList SchemaDef
  | SchemaDefInclude String
  | SchemaDefObj (NonEmpty SchemaDefObjItem)
  | SchemaDefUnion (NonEmpty SchemaDef)
  deriving (Show)

data SchemaDefObjItem
  = SchemaDefObjPair (SchemaDefObjKey, SchemaDef)
  | SchemaDefObjExtend String
  deriving (Show)

data SchemaDefObjKey
  = SchemaDefObjKeyNormal String
  | SchemaDefObjKeyPhantom String
  deriving (Show)

parseSchemaDef :: MonadFail m => String -> m SchemaDef
parseSchemaDef = runParserFail $ do
  space
  def <- parseSchemaDefWithUnions
  space
  void eof
  return def
  where
    parseSchemaDefWithUnions =
      let parseSchemaUnion schemaDefs
            | length schemaDefs == 1 = NonEmpty.head schemaDefs
            | otherwise = SchemaDefUnion schemaDefs
      in fmap parseSchemaUnion $ parseSchemaDefWithoutUnions `sepBy1` lexeme "|"

    parseSchemaDefWithoutUnions = choice
      [ between (lexeme "{") (lexeme "}") $ SchemaDefObj <$> parseSchemaDefObjItems
      , between (lexeme "(") (lexeme ")") parseSchemaDefWithUnions
      , lexeme "Maybe" *> (SchemaDefMaybe <$> parseSchemaDefWithoutUnions)
      , lexeme "Try" *> (SchemaDefTry <$> parseSchemaDefWithoutUnions)
      , lexeme "List" *> (SchemaDefList <$> parseSchemaDefWithoutUnions)
      , SchemaDefType <$> identifier upperChar
      , SchemaDefInclude <$> parseSchemaReference
      ] <* space -- allow any trailing spaces

    parseSchemaDefObjItems = parseSchemaDefObjItem `sepEndBy1` lexeme ","
    parseSchemaDefObjItem = choice
      [ SchemaDefObjPair <$> parseSchemaDefPair
      , SchemaDefObjExtend <$> parseSchemaReference
      ] <* space -- allow any trailing spaces
    parseSchemaDefPair = do
      key <- choice
        [ SchemaDefObjKeyNormal <$> jsonKey
        , SchemaDefObjKeyPhantom <$> between (lexeme' "[") (lexeme' "]") jsonKey'
        ]
      lexeme ":"
      value <- parseSchemaDefWithUnions
      return (key, value)
    parseSchemaReference = char '#' *> namespacedIdentifier upperChar

{- GetterExp -}

data GetterExp = GetterExp
  { start     :: Maybe String
  , getterOps :: GetterOps
  } deriving (Show)

parseGetterExp :: MonadFail m => String -> m GetterExp
parseGetterExp = runParserFail $ do
  space
  start <- optional $ namespacedIdentifier lowerChar
  getterOps <- parseGetterOps
  space
  void eof
  return GetterExp{..}

{- UnwrapSchema -}

data UnwrapSchema = UnwrapSchema
  { startSchema :: String
  , getterOps   :: GetterOps
  } deriving (Show)

parseUnwrapSchema :: MonadFail m => String -> m UnwrapSchema
parseUnwrapSchema = runParserFail $ do
  space
  startSchema <- namespacedIdentifier upperChar
  getterOps <- parseGetterOps
  space
  void eof
  return UnwrapSchema{..}

{- GetterOps -}

type GetterOps = NonEmpty GetterOperation

parseGetterOps :: Parser GetterOps
parseGetterOps = some parseGetterOp

data GetterOperation
  = GetterKey String
  | GetterList (NonEmpty GetterOps)
  | GetterTuple (NonEmpty GetterOps)
  | GetterBang
  | GetterMapList
  | GetterMapMaybe
  | GetterBranch Int
  deriving (Show)

parseGetterOp :: Parser GetterOperation
parseGetterOp = choice
  [ lexeme "!" $> GetterBang
  , lexeme "[]" $> GetterMapList
  , lexeme "?" $> GetterMapMaybe
  , lexeme "@" *> (GetterBranch . read . NonEmpty.toList <$> some digitChar)
  , optional (lexeme ".") *> choice
      [ GetterKey <$> jsonKey
      , fmap GetterList $ between (lexeme "[") (lexeme "]") $ parseGetterOps `sepBy1` lexeme ","
      , fmap GetterTuple $ between (lexeme "(") (lexeme ")") $ parseGetterOps `sepBy1` lexeme ","
      ]
  ]

{- Parser primitives -}

-- | A Haskell identifier, with the given first character.
identifier :: Parser Char -> Parser String
identifier start = (:) <$> start <*> many (alphaNumChar <|> char '\'')

lexeme :: String -> Parser ()
lexeme = lexemeUsingLineComment $ L.skipLineComment "//"

-- | Same as 'lexeme', but without parsing comments.
lexeme' :: String -> Parser ()
lexeme' = lexemeUsingLineComment empty

lexemeUsingLineComment :: Parser () -> String -> Parser ()
lexemeUsingLineComment lineComment = void . L.lexeme (L.space space1 lineComment empty) . string

-- | Parses `identifier`, but if parentheses are provided, parses a namespaced identifier.
namespacedIdentifier :: Parser Char -> Parser String
namespacedIdentifier start = choice [lexeme "(" *> namespaced <* lexeme ")", ident]
  where
    ident = identifier start
    namespaced = intercalate "." <$> manyAndEnd (identifier upperChar <* lexeme ".") ident
    manyAndEnd p end = choice
      [ try $ p >>= \x -> (x:) <$> manyAndEnd p end
      , (:[]) <$> end
      ]

-- | An optionally quoted JSON key.
jsonKey :: Parser String
jsonKey = choice [char '"' *> jsonKey' <* char '"', jsonKey']

-- | A string that can be used as a JSON key.
jsonKey' :: Parser String
jsonKey' = fmap NonEmpty.toList $ some $ choice
  [ try $ char '\\' *> anySingle'
  , noneOf $ [' ', '\\', '"'] ++ schemaChars ++ getChars
  ]
  where
#if MIN_VERSION_megaparsec(7,0,0)
    anySingle' = anySingle
#else
    anySingle' = anyChar
#endif

    -- characters that cause ambiguity when parsing 'get' expressions
    getChars = "!?[](),.@"
    -- characters that should not indicate the start of a key when parsing 'schema' definitions
    schemaChars = ":{}#"

{- Parsing utilities -}

-- | Same as 'Megaparsec.some', except returns a 'NonEmpty'
some :: MonadPlus f => f a -> f (NonEmpty a)
some p = NonEmpty.fromList <$> Megaparsec.some p

-- | Same as 'Megaparsec.sepBy1', except returns a 'NonEmpty'
sepBy1 :: MonadPlus f => f a -> f sep -> f (NonEmpty a)
sepBy1 p sep = NonEmpty.fromList <$> Megaparsec.sepBy1 p sep

-- | Same as 'Megaparsec.sepEndBy1', except returns a 'NonEmpty'
sepEndBy1 :: MonadPlus f => f a -> f sep -> f (NonEmpty a)
sepEndBy1 p sep = NonEmpty.fromList <$> Megaparsec.sepEndBy1 p sep
