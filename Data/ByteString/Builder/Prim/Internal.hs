{-# LANGUAGE ScopedTypeVariables, CPP #-}
#if __GLASGOW_HASKELL__ >= 703
{-# LANGUAGE Unsafe #-}
#endif
{-# OPTIONS_HADDOCK not-home #-}
-- |
-- Copyright   : 2010-2011 Simon Meier, 2010 Jasper van der Jeugt
-- License     : BSD3-style (see LICENSE)
--
-- Maintainer  : Simon Meier <iridcode@gmail.com>
-- Stability   : unstable, private
-- Portability : GHC
--
-- *Warning:* this module is internal. If you find that you need it please
-- contact the maintainers and explain what you are trying to do and discuss
-- what you would need in the public API. It is important that you do this as
-- the module may not be exposed at all in future releases.
--
-- The maintainers are glad to accept patches for further
-- standard encodings of standard Haskell values.
--
-- If you need to write your own builder primitives, then be aware that you are
-- writing code with /all safety belts off/; i.e.,
-- *this is the code that might make your application vulnerable to buffer-overflow attacks!*
-- The "Data.ByteString.Builder.Prim.Tests" module provides you with
-- utilities for testing your encodings thoroughly.
--
module Data.ByteString.Builder.Prim.Internal (
  -- * Fixed-size builder primitives
    Size
  , FixedPrim
  , fixedPrim
  , size
  , runF

  , emptyF
  , contramapF
  , pairF
  -- , liftIOF

  , storableToF

  -- * Bounded-size builder primitives
  , BoundedPrim
  , boundedPrim
  , sizeBound
  , runB

  , emptyB
  , contramapB
  , pairB
  , eitherB
  , condB

  -- , liftIOB

  , toB
  , liftFixedToBounded

  -- , withSizeFB
  -- , withSizeBB

  -- * Shared operators
  , (>$<)
  , (>*<)

  -- * Helpers
  , caseWordSize_32_64

  -- * Deprecated
  , boudedPrim
  ) where

import Foreign
import Prelude hiding (maxBound)

#include "MachDeps.h"

------------------------------------------------------------------------------
-- Supporting infrastructure
------------------------------------------------------------------------------

-- | Contravariant functors as in the @contravariant@ package.
class Contravariant f where
    contramap :: (b -> a) -> f a -> f b

infixl 4 >$<

-- | A fmap-like operator for builder primitives, both bounded and fixed size.
--
-- Builder primitives are contravariant so it's like the normal fmap, but
-- backwards (look at the type). (If it helps to remember, the operator symbol
-- is like (<$>) but backwards.)
--
-- We can use it for example to prepend and/or append fixed values to an
-- primitive.
--
-- > import Data.ByteString.Builder.Prim as P
-- >showEncoding ((\x -> ('\'', (x, '\''))) >$< fixed3) 'x' = "'x'"
-- >  where
-- >    fixed3 = P.char7 >*< P.char7 >*< P.char7
--
-- Note that the rather verbose syntax for composition stems from the
-- requirement to be able to compute the size / size bound at compile time.
--
(>$<) :: Contravariant f => (b -> a) -> f a -> f b
(>$<) = contramap


instance Contravariant FixedPrim where
    contramap = contramapF

instance Contravariant BoundedPrim where
    contramap = contramapB


-- | Type-constructors supporting lifting of type-products.
class Monoidal f where
    pair :: f a -> f b -> f (a, b)

instance Monoidal FixedPrim where
    pair = pairF

instance Monoidal BoundedPrim where
    pair = pairB

infixr 5 >*<

-- | A pairing/concatenation operator for builder primitives, both bounded and
-- fixed size.
--
-- For example,
--
-- > toLazyByteString (primFixed (char7 >*< char7) ('x','y')) = "xy"
--
-- We can combine multiple primitives using '>*<' multiple times.
--
-- > toLazyByteString (primFixed (char7 >*< char7 >*< char7) ('x',('y','z'))) = "xyz"
--
(>*<) :: Monoidal f => f a -> f b -> f (a, b)
(>*<) = pair


-- | The type used for sizes and sizeBounds of sizes.
type Size = Int


------------------------------------------------------------------------------
-- Fixed-size builder primitives
------------------------------------------------------------------------------

-- | A builder primitive that always results in a sequence of bytes of a
-- pre-determined, fixed size.
data FixedPrim a = FP {-# UNPACK #-} !Int (a -> Ptr Word8 -> IO ())

fixedPrim :: Int -> (a -> Ptr Word8 -> IO ()) -> FixedPrim a
fixedPrim = FP

-- | The size of the sequences of bytes generated by this 'FixedPrim'.
{-# INLINE CONLIKE size #-}
size :: FixedPrim a -> Int
size (FP l _) = l

{-# INLINE CONLIKE runF #-}
runF :: FixedPrim a -> a -> Ptr Word8 -> IO ()
runF (FP _ io) = io

-- | The 'FixedPrim' that always results in the zero-length sequence.
{-# INLINE CONLIKE emptyF #-}
emptyF :: FixedPrim a
emptyF = FP 0 (\_ _ -> return ())

-- | Encode a pair by encoding its first component and then its second component.
{-# INLINE CONLIKE pairF #-}
pairF :: FixedPrim a -> FixedPrim b -> FixedPrim (a, b)
pairF (FP l1 io1) (FP l2 io2) =
    FP (l1 + l2) (\(x1,x2) op -> io1 x1 op >> io2 x2 (op `plusPtr` l1))

-- | Change a primitives such that it first applies a function to the value
-- to be encoded.
--
-- Note that primitives are 'Contravariant'
-- <http://hackage.haskell.org/package/contravariant>. Hence, the following
-- laws hold.
--
-- >contramapF id = id
-- >contramapF f . contramapF g = contramapF (g . f)
{-# INLINE CONLIKE contramapF #-}
contramapF :: (b -> a) -> FixedPrim a -> FixedPrim b
contramapF f (FP l io) = FP l (io . f)

-- | Convert a 'FixedPrim' to a 'BoundedPrim'.
{-# INLINE CONLIKE toB #-}
toB :: FixedPrim a -> BoundedPrim a
toB (FP l io) = BP l (\x op -> io x op >> (return $! op `plusPtr` l))

-- | Lift a 'FixedPrim' to a 'BoundedPrim'.
{-# INLINE CONLIKE liftFixedToBounded #-}
liftFixedToBounded :: FixedPrim a -> BoundedPrim a
liftFixedToBounded = toB

{-# INLINE CONLIKE storableToF #-}
storableToF :: forall a. Storable a => FixedPrim a
-- Not all architectures are forgiving of unaligned accesses; whitelist ones
-- which are known not to trap (either to the kernel for emulation, or crash).
#if defined(i386_HOST_ARCH) || defined(x86_64_HOST_ARCH) \
    || ((defined(arm_HOST_ARCH) || defined(aarch64_HOST_ARCH)) \
        && defined(__ARM_FEATURE_UNALIGNED)) \
    || defined(powerpc_HOST_ARCH) || defined(powerpc64_HOST_ARCH) \
    || defined(powerpc64le_HOST_ARCH)
storableToF = FP (sizeOf (undefined :: a)) (\x op -> poke (castPtr op) x)
#else
storableToF = FP (sizeOf (undefined :: a)) $ \x op ->
    if ptrToWordPtr op `mod` fromIntegral (alignment (undefined :: a)) == 0 then poke (castPtr op) x
    else with x $ \tp -> copyBytes op (castPtr tp) (sizeOf (undefined :: a))
#endif

{-
{-# INLINE CONLIKE liftIOF #-}
liftIOF :: FixedPrim a -> FixedPrim (IO a)
liftIOF (FP l io) = FP l (\xWrapped op -> do x <- xWrapped; io x op)
-}

------------------------------------------------------------------------------
-- Bounded-size builder primitives
------------------------------------------------------------------------------

-- | A builder primitive that always results in sequence of bytes that is no longer
-- than a pre-determined bound.
data BoundedPrim a = BP {-# UNPACK #-} !Int (a -> Ptr Word8 -> IO (Ptr Word8))

-- | The bound on the size of sequences of bytes generated by this 'BoundedPrim'.
{-# INLINE CONLIKE sizeBound #-}
sizeBound :: BoundedPrim a -> Int
sizeBound (BP b _) = b

-- | @since 0.10.12.0
boundedPrim :: Int -> (a -> Ptr Word8 -> IO (Ptr Word8)) -> BoundedPrim a
boundedPrim = BP

{-# DEPRECATED boudedPrim "Use 'boundedPrim' instead" #-}
boudedPrim :: Int -> (a -> Ptr Word8 -> IO (Ptr Word8)) -> BoundedPrim a
boudedPrim = BP

{-# INLINE CONLIKE runB #-}
runB :: BoundedPrim a -> a -> Ptr Word8 -> IO (Ptr Word8)
runB (BP _ io) = io

-- | Change a 'BoundedPrim' such that it first applies a function to the
-- value to be encoded.
--
-- Note that 'BoundedPrim's are 'Contravariant'
-- <http://hackage.haskell.org/package/contravariant>. Hence, the following
-- laws hold.
--
-- >contramapB id = id
-- >contramapB f . contramapB g = contramapB (g . f)
{-# INLINE CONLIKE contramapB #-}
contramapB :: (b -> a) -> BoundedPrim a -> BoundedPrim b
contramapB f (BP b io) = BP b (io . f)

-- | The 'BoundedPrim' that always results in the zero-length sequence.
{-# INLINE CONLIKE emptyB #-}
emptyB :: BoundedPrim a
emptyB = BP 0 (\_ op -> return op)

-- | Encode a pair by encoding its first component and then its second component.
{-# INLINE CONLIKE pairB #-}
pairB :: BoundedPrim a -> BoundedPrim b -> BoundedPrim (a, b)
pairB (BP b1 io1) (BP b2 io2) =
    BP (b1 + b2) (\(x1,x2) op -> io1 x1 op >>= io2 x2)

-- | Encode an 'Either' value using the first 'BoundedPrim' for 'Left'
-- values and the second 'BoundedPrim' for 'Right' values.
--
-- Note that the functions 'eitherB', 'pairB', and 'contramapB' (written below
-- using '>$<') suffice to construct 'BoundedPrim's for all non-recursive
-- algebraic datatypes. For example,
--
-- @
--maybeB :: BoundedPrim () -> BoundedPrim a -> BoundedPrim (Maybe a)
--maybeB nothing just = 'maybe' (Left ()) Right '>$<' eitherB nothing just
-- @
{-# INLINE CONLIKE eitherB #-}
eitherB :: BoundedPrim a -> BoundedPrim b -> BoundedPrim (Either a b)
eitherB (BP b1 io1) (BP b2 io2) =
    BP (max b1 b2)
        (\x op -> case x of Left x1 -> io1 x1 op; Right x2 -> io2 x2 op)

-- | Conditionally select a 'BoundedPrim'.
-- For example, we can implement the ASCII primitive that drops characters with
-- Unicode codepoints above 127 as follows.
--
-- @
--charASCIIDrop = 'condB' (< \'\\128\') ('liftFixedToBounded' 'Data.ByteString.Builder.Prim.char7') 'emptyB'
-- @
{-# INLINE CONLIKE condB #-}
condB :: (a -> Bool) -> BoundedPrim a -> BoundedPrim a -> BoundedPrim a
condB p be1 be2 =
    contramapB (\x -> if p x then Left x else Right x) (eitherB be1 be2)

-- | Select an implementation depending on bitness.
-- Throw a compile time error if bitness is neither 32 nor 64.
{-# INLINE caseWordSize_32_64 #-}
caseWordSize_32_64
  :: a -- Value for 32-bit architecture
  -> a -- Value for 64-bit architecture
  -> a
#if WORD_SIZE_IN_BITS == 32
caseWordSize_32_64 = const
#endif
#if WORD_SIZE_IN_BITS == 64
caseWordSize_32_64 = const id
#endif
