{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeOperators #-}

-- |
-- Module: Chainweb.Pact.Service.Types
-- Copyright: Copyright © 2018 Kadena LLC.
-- License: See LICENSE file
-- Maintainer: Mark Nichols <mark@kadena.io>
-- Stability: experimental
--
-- Types module for Pact execution HTTP API

module Chainweb.Pact.Service.Types where

import Control.Concurrent.STM.TQueue
import Control.Concurrent.STM.TVar
import Control.Lens
import Control.Monad.Trans.Reader

import Data.Aeson
import Data.Hashable
import qualified Data.HashTable.IO as H
import qualified Data.HashTable.ST.Basic as H
import Data.Int
import Data.String.Conv (toS)

import Safe
import Servant

--TODO: How to get rid of the redundant import warning on this?
import Chainweb.BlockHeader (BlockHeader)
import Chainweb.Pact.Types

type PactAPI = "new" :> ReqBody '[JSON] BlockHeader :> Post '[JSON] RequestId
          :<|> "validate" :> ReqBody '[JSON] BlockHeader :> Post '[JSON] RequestId
          :<|> "poll" :> ReqBody '[JSON] RequestId :> Post '[JSON] (Either String Transactions)
data RequestIdEnv
  = RequestIdEnv { _rieReqIdVar :: TVar RequestId
                 , _rieReqQ :: TVar (TQueue RequestMsg)
                 , _rieRespQ :: TVar (TQueue ResponseMsg)
                 , _rieResponseMap :: H.IOHashTable H.HashTable RequestId Transactions }

type PactAppM = ReaderT RequestIdEnv Handler

pactAPI :: Proxy PactAPI
pactAPI = Proxy

newtype RequestId = RequestId { _getInt64 :: Int64 }
    deriving (Enum, Eq, Hashable, Read, Show, FromJSON, ToJSON)

instance FromHttpApiData RequestId where
    parseUrlPiece t =
        let e = readEitherSafe (toS t)
        in bimap toS RequestId e

data RequestType = ValidateBlock | NewBlock deriving (Show)

data RequestMsg = RequestMsg
    { _reqRequestType :: RequestType
    , _reqRequestId   :: RequestId
    , _reqBlockHeader :: BlockHeader
    } deriving (Show)

data ResponseMsg = ResponseMsg
    { _respRequestType :: RequestType
    , _respRequestId   :: RequestId
    , _respPayload :: Transactions
    } deriving (Show)

makeLenses ''RequestIdEnv