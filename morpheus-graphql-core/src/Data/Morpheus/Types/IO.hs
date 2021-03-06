{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Data.Morpheus.Types.IO
  ( GQLRequest (..),
    GQLResponse (..),
    JSONResponse (..),
    renderResponse,
    MapAPI (..),
  )
where

import Data.Aeson
  ( (.:?),
    (.=),
    FromJSON (..),
    ToJSON (..),
    encode,
    object,
    pairs,
    withObject,
  )
import qualified Data.Aeson as Aeson
  ( Value (..),
  )
import Data.Aeson.Internal
  ( formatError,
    ifromJSON,
  )
import Data.Aeson.Parser
  ( eitherDecodeWith,
    jsonNoDup,
  )
import qualified Data.ByteString.Lazy.Char8 as LB
  ( ByteString,
    fromStrict,
    toStrict,
  )
import qualified Data.HashMap.Lazy as LH
import Data.Morpheus.Error.Utils (badRequestError)
import Data.Morpheus.Types.Internal.AST
  ( FieldName,
    GQLError (..),
    ValidValue,
  )
import Data.Morpheus.Types.Internal.Resolving.Core
  ( Failure (..),
    Result (..),
  )
import qualified Data.Text.Lazy as LT
  ( Text,
    fromStrict,
    toStrict,
  )
import Data.Text.Lazy.Encoding
  ( decodeUtf8,
    encodeUtf8,
  )
import Relude hiding
  ( decodeUtf8,
    encodeUtf8,
  )

decodeNoDup :: Failure String m => LB.ByteString -> m GQLRequest
decodeNoDup str = case eitherDecodeWith jsonNoDup ifromJSON str of
  Left (path, x) -> failure $ formatError path x
  Right value -> pure value

class MapAPI a b where
  mapAPI :: Applicative m => (GQLRequest -> m GQLResponse) -> a -> m b

instance MapAPI GQLRequest GQLResponse where
  mapAPI f = f

instance MapAPI LB.ByteString LB.ByteString where
  mapAPI api request = case decodeNoDup request of
    Left aesonError -> pure $ badRequestError aesonError
    Right req -> encode <$> api req

instance MapAPI LT.Text LT.Text where
  mapAPI api = fmap decodeUtf8 . mapAPI api . encodeUtf8

instance MapAPI ByteString ByteString where
  mapAPI api = fmap LB.toStrict . mapAPI api . LB.fromStrict

instance MapAPI Text Text where
  mapAPI api = fmap LT.toStrict . mapAPI api . LT.fromStrict

renderResponse :: Result e ValidValue -> GQLResponse
renderResponse (Failure errors) = Errors (sortOn locations errors)
renderResponse Success {result} = Data result

instance FromJSON a => FromJSON (JSONResponse a) where
  parseJSON = withObject "JSONResponse" objectParser
    where
      objectParser o = JSONResponse <$> o .:? "data" <*> o .:? "errors"

data JSONResponse a = JSONResponse
  { responseData :: Maybe a,
    responseErrors :: Maybe [GQLError]
  }
  deriving (Generic, Show, ToJSON)

-- | GraphQL HTTP Request Body
data GQLRequest = GQLRequest
  { operationName :: Maybe FieldName,
    query :: Text,
    variables :: Maybe Aeson.Value
  }
  deriving (Show, Generic, FromJSON, ToJSON)

-- | GraphQL Response
data GQLResponse
  = Data ValidValue
  | Errors [GQLError]
  deriving (Show, Generic)

instance FromJSON GQLResponse where
  parseJSON (Aeson.Object hm) = case LH.toList hm of
    [("data", value)] -> Data <$> parseJSON value
    [("errors", value)] -> Errors <$> parseJSON value
    _ -> fail "Invalid GraphQL Response"
  parseJSON _ = fail "Invalid GraphQL Response"

instance ToJSON GQLResponse where
  toJSON (Data gqlData) = object ["data" .= toJSON gqlData]
  toJSON (Errors errors) = object ["errors" .= toJSON errors]

  ----------------------------------------------------------
  toEncoding (Data _data) = pairs $ "data" .= _data
  toEncoding (Errors _errors) = pairs $ "errors" .= _errors
