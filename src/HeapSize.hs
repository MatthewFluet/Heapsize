{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE UnboxedTuples #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE GHCForeignImportPrim #-}
{-# LANGUAGE UnliftedFFITypes #-}

{- |
   Module      : HeapSize
   Copyright   : (c) Michail Pardalos
   License     : 3-Clause BSD-style
   Maintainer  : mpardalos@gmail.com

   Based on GHC.Datasize by Dennis Felsing
 -}
module HeapSize (
  recursiveSize,
  recursiveSizeNoGC,
  recursiveSizeNF,
  closureSize
  )
  where

import Control.DeepSeq (NFData, force)
import Control.Exception (evaluate)
import Data.Maybe (isNothing)

import GHC.Exts hiding (closureSize#)
import GHC.Arr
import GHC.Exts.Heap hiding (size)
import qualified Data.HashSet as H
import Data.IORef
import Data.Hashable

import Control.Monad

import System.Mem
import System.Mem.Weak

foreign import prim "aToWordzh" aToWord# :: Any -> Word#
foreign import prim "unpackClosurePtrs" unpackClosurePtrs# :: Any -> Array# b
foreign import prim "closureSize" closureSize# :: Any -> Int#

newtype GcDetector = GcDetector {gcSinceCreation :: IO Bool}

gcDetector :: IO GcDetector
gcDetector = do
  ref <- newIORef ()
  w <- mkWeakIORef ref (return ())
  return $ GcDetector $ isNothing <$> deRefWeak w

-- | Get the *non-recursive* size of an closure in words
closureSize :: a -> IO Int
closureSize x = return (I# (closureSize# (unsafeCoerce# x)))

getClosures :: a -> IO (Array Int Box)
getClosures x = case unpackClosurePtrs# (unsafeCoerce# x) of
    pointers ->
      let nelems = I# (sizeofArray# pointers)
      in pure (fmap Box $ Array 0 (nelems - 1) nelems pointers)

-- | Calculate the recursive size of GHC objects in Bytes. Note that the actual
--   size in memory is calculated, so shared values are only counted once.
--
--   Call with
--   @
--    recursiveSize $! 2
--   @
--   to force evaluation to WHNF before calculating the size.
--
--   Call with
--   @
--    recursiveSize $!! \"foobar\"
--   @
--   ($!! from Control.DeepSeq) to force full evaluation before calculating the
--   size.
--
--   A garbage collection is performed before the size is calculated, because
--   the garbage collector would make heap walks difficult.
--
--   This function works very quickly on small data structures, but can be slow
--   on large and complex ones. If speed is an issue it's probably possible to
--   get the exact size of a small portion of the data structure and then
--   estimate the total size from that.
--   Returns `Nothing` if the count is interrupted by a garbage collection
recursiveSize :: a -> IO (Maybe Int)
recursiveSize x = performGC >> recursiveSizeNoGC x

-- | Same as `recursiveSize` except without performing garbage collection first.
--   Useful if you want to measure the size of many objects in sequence. You can
--   call `performGC` once at first and then use this function to avoid multiple
--   unnecessary garbage collections.
--   Returns `Nothing` if the count is interrupted by a garbage collection
recursiveSizeNoGC :: a -> IO (Maybe Int)
recursiveSizeNoGC x = do
  state <- newIORef (0, H.empty)
  gcDetect <- gcDetector
  success <- go (gcSinceCreation gcDetect) state (asBox x)

  if success then Just . fst <$> readIORef state else return Nothing
  where
    go :: IO Bool -> IORef (Int, H.HashSet HashableBox) -> Box -> IO Bool
    go checkGC state b@(Box y) = do
      (_, closuresSeen) <- readIORef state

      !seen <- evaluate $ H.member (HashableBox b) closuresSeen

      gcHasRun <- checkGC

      if gcHasRun then return False else do
        when (not seen) $ do
          thisSize <- closureSize y
          next <- getClosures y
          modifyIORef state $ \(size, _) ->
            (size + thisSize, H.insert (HashableBox b) closuresSeen)

          mapM_ (go checkGC state) next
        return True

-- | Calculate the recursive size of GHC objects in Bytes after calling
-- Control.DeepSeq.force on the data structure to force it into Normal Form.
-- Using this function requires that the data structure has an `NFData`
-- typeclass instance.
-- Returns `Nothing` if the count is interrupted by a garbage collection
recursiveSizeNF :: NFData a => a -> IO (Maybe Int)
recursiveSizeNF = recursiveSize . force

newtype HashableBox = HashableBox Box
    deriving newtype Show

-- | Pointer Equality
instance Eq HashableBox where
    (HashableBox (Box a1)) == (HashableBox (Box a2)) =
        W# (aToWord# a1) == W# (aToWord# a2)

-- | Pointer hash
instance Hashable HashableBox where
    hashWithSalt n (HashableBox (Box a)) = hashWithSalt n (W# (aToWord# a))