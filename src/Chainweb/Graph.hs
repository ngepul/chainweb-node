{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeInType #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE UndecidableSuperClasses #-}
{-# LANGUAGE UnicodeSyntax #-}

-- |
-- Module: Chainweb.Graph
-- Copyright: Copyright © 2018 Kadena LLC.
-- License: MIT
-- Maintainer: Lars Kuhtz <lars@kadena.io>
-- Stability: experimental
--
-- A chain graph is
--
-- * directed
-- * regular
-- * symmetric
-- * irreflexive
--
module Chainweb.Graph
(
-- * Exceptions
  ChainGraphException(..)

-- * Chain Graph

, ChainGraph
, toChainGraph
, validChainGraph
, adjacentChainIds

-- * Checks with a given chain graph

, isWebChain
, chainIds
, checkWebChainId
, checkAdjacentChainIds
) where

import Control.Monad
import Control.Monad.Catch

import qualified Data.HashSet as HS
import Data.Kind
import Data.Reflection

import GHC.Generics

-- internal imports

import Chainweb.Utils
import Chainweb.ChainId

import Data.DiGraph

-- -------------------------------------------------------------------------- --
-- Exceptions

-- | This exceptions are not about the properties of the graph itself
-- but about properties of enties (BlockHeader graph) that are constraint
-- by this graph. So, maybe we should move this and the respective checks
-- to the place where those enties are defined and rename these exceptions
-- accordingly. However, keeping it here remove code duplication.
--
data ChainGraphException ∷ Type where
    ChainNotInChainGraphException
        ∷ Expected (HS.HashSet ChainId)
        → Actual ChainId
        → ChainGraphException
    AdjacentChainMissmatch
        ∷ Expected (HS.HashSet ChainId)
        → Actual (HS.HashSet ChainId)
        → ChainGraphException
    ChainNotAdjacentException
        ∷ Expected ChainId
        → Actual (HS.HashSet ChainId)
        → ChainGraphException
    deriving (Show, Eq, Generic)

instance Exception ChainGraphException

-- -------------------------------------------------------------------------- --
-- Chainweb Graph

type ChainGraph = DiGraph ChainId

toChainGraph ∷ (a → ChainId) → DiGraph a → ChainGraph
toChainGraph = mapVertices
{-# INLINE toChainGraph #-}

validChainGraph ∷ DiGraph ChainId → Bool
validChainGraph g = isDiGraph g && isSymmetric g && isRegular g
{-# INLINE validChainGraph #-}

adjacentChainIds
    ∷ HasChainId p
    ⇒ ChainGraph
    → p
    → HS.HashSet ChainId
adjacentChainIds g cid = adjacents (_chainId cid) g
{-# INLINE adjacentChainIds #-}

-- -------------------------------------------------------------------------- --
-- Checks with a given Graphs

chainIds ∷ Given ChainGraph ⇒ HS.HashSet ChainId
chainIds = vertices given
{-# INLINE chainIds #-}

checkWebChainId ∷ MonadThrow m ⇒ Given ChainGraph ⇒ HasChainId p ⇒ p → m ()
checkWebChainId p = unless (isWebChain p)
    $ throwM $ ChainNotInChainGraphException
        (Expected (vertices given))
        (Actual (_chainId p))

isWebChain ∷ Given ChainGraph ⇒ HasChainId p ⇒ p → Bool
isWebChain p = isVertex (_chainId p) given
{-# INLINE isWebChain #-}

checkAdjacentChainIds
    ∷ MonadThrow m
    ⇒ Given ChainGraph
    ⇒ HasChainId cid
    ⇒ HasChainId adj
    ⇒ cid
    → Expected (HS.HashSet adj)
    → m (HS.HashSet adj)
checkAdjacentChainIds cid expectedAdj = do
    checkWebChainId cid
    void $ check AdjacentChainMissmatch
        (HS.map _chainId <$> expectedAdj)
        (Actual $ adjacents (_chainId cid) given)
    return (getExpected expectedAdj)

