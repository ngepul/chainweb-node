{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

-- |
-- Module: Chainweb.Miner.Core
-- Copyright: Copyright © 2018 - 2020 Kadena LLC.
-- License: MIT
-- Maintainer: Colin Woodbury <colin@kadena.io>
-- Stability: experimental

module Chainweb.Miner.Core
  ( HeaderBytes(..)
  , TargetBytes(..)
  , ChainBytes(..)
  , WorkBytes(..)
  , MiningResult(..)
  , usePowHash
  , mine
  , fastCheckTarget
  , injectNonce
  , callExternalMiner
  ) where

import qualified Control.Concurrent.Async as Async
import Control.Monad
import Control.Monad.Trans
import Control.Monad.Trans.Except

import Crypto.Hash.Algorithms (Blake2s_256)
import Crypto.Hash.IO

import qualified Data.ByteArray as BA
import qualified Data.ByteString.Base16 as B16
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Short as BS
import Data.Char (isSpace)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Proxy (Proxy(..))
import Data.Tuple.Strict (T2(..))
import Data.Word (Word64, Word8)

import Foreign.Marshal.Alloc (allocaBytes)
import Foreign.Ptr (Ptr, castPtr)
import Foreign.Storable (peekElemOff, pokeByteOff)

import Servant.API

import System.Exit
import System.IO (hClose)
import System.Path
import qualified System.Process as P

-- internal modules

import Chainweb.BlockHeader
import Chainweb.Cut.Create
import Chainweb.Difficulty
import Chainweb.Time hiding (second)
import Chainweb.Utils
import Chainweb.Version (ChainwebVersion(..))

---

-- | Encoding of @ChainId + HashTarget + BlockHeader@ to be consumed by a remote
-- Mining API.
--
newtype WorkBytes = WorkBytes { _workBytes :: B.ByteString }
    deriving newtype (MimeRender OctetStream, MimeUnrender OctetStream)

-- | The encoded form of a `BlockHeader`.
--
newtype HeaderBytes = HeaderBytes { _headerBytes :: B.ByteString }
    deriving stock (Eq, Show)
    deriving newtype (MimeRender OctetStream, MimeUnrender OctetStream)

-- | The encoded form of a `HashTarget`.
--
newtype TargetBytes = TargetBytes { _targetBytes :: B.ByteString }
    deriving stock (Eq, Show)

-- | The encoded form of a `ChainId`.
--
newtype ChainBytes = ChainBytes { _chainBytes :: B.ByteString }
    deriving stock (Eq, Show)
    deriving newtype (MimeRender OctetStream, MimeUnrender OctetStream)

-- | Select a hashing algorithm.
--
usePowHash :: ChainwebVersion -> (forall a. HashAlgorithm a => Proxy a -> f) -> f
usePowHash Test{} f = f $ Proxy @Blake2s_256
usePowHash TimedConsensus{} f = f $ Proxy @Blake2s_256
usePowHash PowConsensus{} f = f $ Proxy @Blake2s_256
usePowHash TimedCPM{} f = f $ Proxy @Blake2s_256
usePowHash FastTimedCPM{} f = f $ Proxy @Blake2s_256
usePowHash Development f = f $ Proxy @Blake2s_256
usePowHash Testnet04 f = f $ Proxy @Blake2s_256
usePowHash Mainnet01 f = f $ Proxy @Blake2s_256

-- | This Miner makes low-level assumptions about the chainweb protocol. It may
-- break if the protocol changes.
--
-- TODO: Check the chainweb version to make sure this function can handle the
-- respective version.
--
mine
  :: forall a
  . HashAlgorithm a
  => Nonce
  -> WorkHeader
  -> IO (T2 SolvedWork Word64)
mine orig@(Nonce o) work = do
    nonces <- newIORef 0
    BA.withByteArray tbytes $ \trgPtr -> do
        !ctx <- hashMutableInit @a
        new <- BA.copy hbytes $ \buf ->
            allocaBytes (powSize :: Int) $ \pow -> do

                -- inner mining loop
                --
                let go1 0 n = return (Just n)
                    go1 !i !n@(Nonce nv) = do
                        -- Compute POW hash for the nonce
                        injectNonce n buf
                        hash ctx buf pow

                        -- check whether the nonce meets the target
                        fastCheckTarget trgPtr (castPtr pow) >>= \case
                            True -> Nothing <$ writeIORef nonces (nv - o)
                            False -> go1 (i - 1) (Nonce $ nv + 1)

                -- outer loop
                -- Estimates how many iterations of the inner loop run in one second. It runs the inner loop
                -- that many times and injects an updated creation time in each cycle.
                let go0 :: Int -> Time Micros -> Nonce -> IO ()
                    go0 x t !n = do
                        injectTime t buf
                        go1 x n >>= \case
                            Nothing -> return ()
                            Just n' -> do
                                t' <- getCurrentTimeIntegral
                                let TimeSpan td = diff t' t
                                    x' = round @Double (int x * 1000000 / int td) -- target 1 second
                                go0 x' t' n'

                -- Start outer mining loop
                t <- getCurrentTimeIntegral
                go0 100000 t orig
        solved <- runGet decodeSolvedWork new
        T2 solved <$> readIORef nonces
  where
    tbytes = runPut $ encodeHashTarget (_workHeaderTarget work)
    hbytes = BS.fromShort $ _workHeaderBytes work

    bufSize :: Int
    !bufSize = B.length hbytes

    powSize :: Int
    !powSize = hashDigestSize @a undefined

    --  Compute POW hash
    hash :: MutableContext a -> Ptr Word8 -> Ptr Word8 -> IO ()
    hash ctx buf pow = do
        hashMutableReset ctx
        BA.withByteArray ctx $ \ctxPtr -> do
            hashInternalUpdate @a ctxPtr buf $ fromIntegral bufSize
            hashInternalFinalize ctxPtr $ castPtr pow
    {-# INLINE hash #-}

-- | `injectNonce` makes low-level assumptions about the byte layout of a
-- hashed `BlockHeader`. If that layout changes, this functions need to be
-- updated. The assumption allows us to iterate on new nonces quickly.
--
-- Recall: `Nonce` contains a `Word64`, and is thus 8 bytes long.
--
-- See also: https://github.com/kadena-io/chainweb-node/wiki/Block-Header-Binary-Encoding
--
injectNonce :: Nonce -> Ptr Word8 -> IO ()
injectNonce (Nonce n) buf = pokeByteOff buf 278 n
{-# INLINE injectNonce #-}

injectTime :: Time Micros -> Ptr Word8 -> IO ()
injectTime t buf = pokeByteOff buf 8 $ encodeTimeToWord64 t
{-# INLINE injectTime #-}

-- | `PowHashNat` interprets POW hashes as unsigned 256 bit integral numbers in
-- little endian encoding, hence we compare against the target from the end of
-- the bytes first, then move toward the front 8 bytes at a time.
fastCheckTarget :: Ptr Word64 -> Ptr Word64 -> IO Bool
fastCheckTarget !trgPtr !powPtr =
    fastCheckTargetN 3 trgPtr powPtr >>= \case
        LT -> return False
        GT -> return True
        EQ -> fastCheckTargetN 2 trgPtr powPtr >>= \case
            LT -> return False
            GT -> return True
            EQ -> fastCheckTargetN 1 trgPtr powPtr >>= \case
                LT -> return False
                GT -> return True
                EQ -> fastCheckTargetN 0 trgPtr powPtr >>= \case
                    LT -> return False
                    GT -> return True
                    EQ -> return True
{-# INLINE fastCheckTarget #-}

-- | Recall that `peekElemOff` acts like `drop` for the size of the type in
-- question. Here, this is `Word64`. Since our hash is treated as a `Word256`,
-- each @n@ knocks off a `Word64`'s worth of bytes, and there would be 4 such
-- sections (64 * 4 = 256).
--
-- This must never be called for @n >= 4@.
fastCheckTargetN :: Int -> Ptr Word64 -> Ptr Word64 -> IO Ordering
fastCheckTargetN n trgPtr powPtr = compare
    <$> peekElemOff trgPtr n
    <*> peekElemOff powPtr n
{-# INLINE fastCheckTargetN #-}

data MiningResult = MiningResult
  { _mrNonceBytes :: !B.ByteString
  , _mrNumNoncesTried :: !Word64
  , _mrEstimatedHashesPerSec :: !Word64
  , _mrStderr :: B.ByteString
  }

callExternalMiner
    :: Path Absolute            -- ^ miner path
    -> [String]                 -- ^ miner extra args
    -> Bool                     -- ^ save stderr?
    -> B.ByteString             -- ^ target hash
    -> B.ByteString             -- ^ block bytes
    -> IO (Either String MiningResult)
callExternalMiner minerPath0 minerArgs saveStderr target blockBytes = do
    minerPath <- toAbsoluteFilePath minerPath0
    let args = minerArgs ++ [targetHashStr]
    P.withCreateProcess (createProcess minerPath args) go
  where
    createProcess minerPath args =
        (P.proc minerPath args) {
            P.std_in = P.CreatePipe,
            P.std_out = P.CreatePipe,
            P.std_err = P.CreatePipe
            }
    targetHashStr = B.unpack $ B16.encode target
    go (Just hstdin) (Just hstdout) (Just hstderr) ph = do
        B.hPut hstdin blockBytes
        hClose hstdin
        Async.withAsync (B.hGetContents hstdout) $ \stdoutThread ->
          Async.withAsync (errThread hstderr) $ \stderrThread ->
          runExceptT $ do
            code <- liftIO $ P.waitForProcess ph
            (outbytes, errbytes) <- liftIO ((,) <$> Async.wait stdoutThread
                                                <*> Async.wait stderrThread)
            if (code /= ExitSuccess)
              then let msg = "Got error from miner. Stderr was: " ++ B.unpack errbytes
                   in throwE msg
              else do
                let parts = B.splitWith isSpace outbytes
                nonceB16 <- case parts of
                              [] -> throwE ("expected nonce from miner, got: "
                                            ++ B.unpack outbytes)
                              (a:_) -> return a
                let (numHashes, rate) =
                      case parts of
                        (_:a:b:_) -> (read (B.unpack a), read (B.unpack b))
                        _ -> (0, 0)

                -- reverse -- we want little-endian
                let nonceBytes = B.reverse $ fst $ B16.decode nonceB16
                when (B.length nonceBytes /= 8) $ throwE "process returned short nonce"
                return $ MiningResult nonceBytes numHashes rate errbytes
    go _ _ _ _ = fail "impossible: process is opened with CreatePipe in/out/err"

    slurp h = act
      where
        act = do
            b <- B.hGet h 4000
            if B.null b then return "stderr not saved" else act

    errThread = if saveStderr
                  then B.hGetContents
                  else slurp
