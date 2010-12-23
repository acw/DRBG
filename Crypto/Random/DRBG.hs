{-# LANGUAGE EmptyDataDecls, FlexibleInstances, TypeSynonymInstances, BangPatterns #-}
{-|
 Maintainer: Thomas.DuBuisson@gmail.com
 Stability: beta
 Portability: portable 

This module is the convenience interface for the DRBG (NIST standardized
number-theoretically secure random number generator).  Everything is setup
for using the "crypto-api" 'CryptoRandomGen' type class.  For example,
to seed a new generator with the system secure random ('System.Crypto.Random')
and generate some bytes (stepping the generator along the way) one would do:

@
    gen <- newGenIO :: IO HashDRBG
    let Right (randomBytes, newGen) = genBytes 1024 gen
@

Selecting the underlying hash algorithm is supporting using *DRBGWith types:

@
    gen <- newGenIO :: IO (HmacDRBGWith SHA224)
@

Composition of generators is supported using two trivial compositions, 'GenXor'
and 'GenAutoReseed'.  Additional compositions can be built by instanciating
a 'CryptoRandomGen' as desired.

@
    gen <- newGenIO :: IO (GenBuffered (GenAutoReseed (GenXor AesCntDRBG (HashDRBGWith SHA384)) HmacDRBG))
@

 
 -}

module Crypto.Random.DRBG
	( HmacDRBG, HashDRBG
	, HmacDRBGWith, HashDRBGWith
	, GenXor
	, GenAutoReseed
	, GenBuffered
	, module Crypto.Random
	) where

import qualified Crypto.Random.DRBG.HMAC as M
import qualified Crypto.Random.DRBG.Hash as H
import Crypto.Classes
import Crypto.Random
import Crypto.Hash.SHA512 (SHA512)
import Crypto.Hash.SHA384 (SHA384)
import Crypto.Hash.SHA256 (SHA256)
import Crypto.Hash.SHA224 (SHA224)
import Crypto.Hash.SHA1 (SHA1)
import System.Crypto.Random
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as L
import Data.Tagged
import Data.Bits (xor)
import Control.Parallel
import Control.Monad (liftM)
import Control.Monad.Error () -- Either instance
import System.IO.Unsafe (unsafeInterleaveIO)

instance H.SeedLength SHA512 where
	seedlen = Tagged 888

instance H.SeedLength SHA384 where
	seedlen = Tagged  888

instance H.SeedLength SHA256 where
	seedlen = Tagged 440

instance H.SeedLength SHA224 where
	seedlen = Tagged 440

instance H.SeedLength SHA1 where
	seedlen = Tagged 440

-- |The HMAC DRBG state (of kind * -> *) allowing selection
-- of the underlying hash algorithm (SHA1, SHA224 ... SHA512)
type HmacDRBGWith = M.State

-- |The Hash DRBG state (of kind * -> *) allowing selection
-- of the underlying hash algorithm.
type HashDRBGWith = H.State

-- |An alias for an HMAC DRBG generator using SHA512.
type HmacDRBG = M.State SHA512

-- |An Alias for a Hash DRBG generator using SHA512.
type HashDRBG = H.State SHA512

newGenAutoReseed :: (CryptoRandomGen a, CryptoRandomGen b) => B.ByteString -> Int -> Either GenError (GenAutoReseed a b)
newGenAutoReseed bs rsInterval=
	let (b1,b2) = B.splitAt (genSeedLength `for` fromRight g1) bs
	    g1 = newGen b1
	    g2 = newGen b2
	    fromRight (Right x) = x
	in case (g1, g2) of
		(Right a, Right b) -> Right $ GenAutoReseed a b rsInterval 0
		(Left e, _) -> Left e
		(_, Left e) -> Left e

instance CryptoRandomGen HmacDRBG where
	newGen bs =
		let res = M.instantiate bs B.empty B.empty
		in if B.length bs < genSeedLength `for` res
			then Left NotEnoughEntropy
			else Right res
	genSeedLength = Tagged (512 `div` 8)
	genBytes req g =
		let res = M.generate g (req * 8) B.empty
		in case res of
			Nothing -> Left NeedReseed
			Just (r,s) -> Right (r, s)
	genBytesWithEntropy req ai g =
		let res = M.generate g (req * 8) ai
		in case res of
			Nothing -> Left NeedReseed
			Just (r,s) -> Right (r, s)
	reseed ent g =
		let res = M.reseed g ent B.empty
		in if B.length ent < genSeedLength `for` res
			then Left NotEnoughEntropy
			else Right res

instance CryptoRandomGen HashDRBG where
	newGen bs =
		let res = H.instantiate bs B.empty B.empty
		in if B.length bs < genSeedLength `for` res
			then Left NotEnoughEntropy
			else Right res
	genSeedLength = Tagged $ 512 `div` 8
	genBytes req g = 
		let res = H.generate g (req * 8) B.empty
		in case res of
			Nothing -> Left NeedReseed
			Just (r,s) -> Right (r, s)
	genBytesWithEntropy req ai g =
		let res = H.generate g (req * 8) ai
		in case res of
			Nothing -> Left NeedReseed
			Just (r,s) -> Right (r, s)
	reseed ent g =
		let res = H.reseed g ent B.empty
		in if B.length ent < genSeedLength `for` res
			then Left NotEnoughEntropy
			else Right res

helper1 :: Tagged (GenAutoReseed a b) Int -> a
helper1 = const undefined

helper2 :: Tagged (GenAutoReseed a b) Int -> b
helper2 = const undefined

-- |@g :: GenAutoReseed a b@ is a generator of type a that gets
-- automatically reseeded by generator b upon every 32kB generated.
--
-- @reseed g ent@ will reseed both the component generators by
-- breaking ent up into two parts determined by the genSeedLength of each generator.
--
-- @genBytes@ will generate the requested bytes with generator @a@ and reseed @a@
-- using generator @b@ if there has been 32KB of generated data since the last reseed.
-- Note a request for > 32KB of data will be filled in one request to generator @a@ before
-- @a@ is reseeded by @b@.
--
-- @genBytesWithEntropy@ will push the entropy into generator @a@, leaving generator
-- @b@ unchanged unless the count hits 32KB, in which case it is reseeds @a@ 
-- (for a second time) using @b@ as in normal operation via @genBytes@.
data GenAutoReseed a b = GenAutoReseed !a !b !Int !Int

instance (CryptoRandomGen a, CryptoRandomGen b) => CryptoRandomGen (GenAutoReseed a b) where
	{-# SPECIALIZE instance CryptoRandomGen (GenAutoReseed HmacDRBG HmacDRBG) #-}
	{-# SPECIALIZE instance CryptoRandomGen (GenAutoReseed HashDRBG HashDRBG) #-}
	{-# SPECIALIZE instance CryptoRandomGen (GenAutoReseed HashDRBG HmacDRBG) #-}
	{-# SPECIALIZE instance CryptoRandomGen (GenAutoReseed HmacDRBG HashDRBG) #-}
	newGen bs = newGenAutoReseed bs (2^15)
	genSeedLength =
		let a = helper1 res
		    b = helper2 res
		    res = Tagged $ genSeedLength `for` a + genSeedLength `for` b
		in res
	genBytes req (GenAutoReseed a b rs cnt) = do
		(res, aNew) <- genBytes req a
		gNew <- if (cnt + req) > rs
			  then do (ent,b') <- genBytes (genSeedLength `for` a) b
				  a'  <- reseed ent aNew
				  return (GenAutoReseed a' b' rs 0)
			  else return $ GenAutoReseed aNew b rs (cnt + req)
		return (res, gNew)
	genBytesWithEntropy req entropy (GenAutoReseed a b rs cnt) = do
		(res, aNew) <- genBytesWithEntropy req entropy a
		gNew <- if (cnt + req) > rs
			  then do (ent,b') <- genBytes (genSeedLength `for` a) b
				  a'  <- reseed ent aNew
				  return (GenAutoReseed a' b' rs 0)
			  else return $ GenAutoReseed aNew b rs (cnt + req)
		return (res, gNew)
	reseed ent gen@(GenAutoReseed a b rs _) 
	  | genSeedLength `for` gen > B.length ent = Left NotEnoughEntropy
	  | otherwise = do
		let (e1,e2) = B.splitAt (genSeedLength `for` a) ent
		a' <- reseed e1 a
		b' <- if B.length e2 /= 0
			then reseed e2 b
			else return b
		return $ GenAutoReseed a' b' rs 0

-- |@g :: GenXor a b@ generates bytes with sub-generators a and b 
-- and exclusive-or's the outputs to produce the resulting bytes.
data GenXor a b = GenXor !a !b

helperXor1 :: Tagged (GenXor a b) c -> a
helperXor1 = const undefined
helperXor2 :: Tagged (GenXor a b) c -> b
helperXor2 = const undefined

instance (CryptoRandomGen a, CryptoRandomGen b) => CryptoRandomGen (GenXor a b) where
	{-# SPECIALIZE instance CryptoRandomGen (GenXor HmacDRBG HmacDRBG) #-}
	{-# SPECIALIZE instance CryptoRandomGen (GenXor HashDRBG HmacDRBG) #-}
	{-# SPECIALIZE instance CryptoRandomGen (GenXor HmacDRBG HashDRBG) #-}
	{-# SPECIALIZE instance CryptoRandomGen (GenXor HashDRBG HashDRBG) #-}
	newGen bs = do
		let g1 = newGen b1
		    g2 = newGen b2
		    (b1,b2) = B.splitAt (genSeedLength `for` fromRight g1) bs
		    fromRight (Right x) = x
		a <- g1
		b <- g2
		return (GenXor a b)
	genSeedLength =
		let a = helperXor1 res
		    b = helperXor2 res
		    res = Tagged $ (genSeedLength `for` a) + (genSeedLength `for` b)
		in res
	genBytes req (GenXor a b) = do
		(r1, a') <- genBytes req a
		(r2, b') <- genBytes req b
		return (zwp' r1 r2, GenXor a' b')
	genBytesWithEntropy req ent (GenXor a b) = do
		(r1, a') <- genBytesWithEntropy req ent a
		(r2, b') <- genBytesWithEntropy req ent b
		return (zwp' r1 r2, GenXor a' b')
	reseed ent (GenXor a b) = do
		let (b1, b2) = B.splitAt (genSeedLength `for` a) ent
		a' <- reseed b1 a
		b' <- reseed b2 b
		return (GenXor a' b')

-- |@g :: GenBuffered a@ is a generator of type @a@ that attempts to
-- maintain a buffer of random values size >= 1MB and <= 5MB at any time.
data GenBuffered g = GenBuffered Int Int (Either (GenError, g) (B.ByteString, g)) {-# UNPACK #-} !B.ByteString

proxyToGenBuffered :: Proxy g -> Proxy (Either GenError (GenBuffered g))
proxyToGenBuffered = const Proxy

bufferMinDef = 2^20
bufferMaxDef = 2^22

newGenBuffered :: (CryptoRandomGen g) => Int -> Int -> B.ByteString -> Either GenError (GenBuffered g)
newGenBuffered min max bs = do
        g <- newGen bs
        (rs,g') <- genBytes min g
        let new = wrapErr (genBytes min g') g'
        (let !_ = rs in ()) `par` return (GenBuffered min max new rs)

newGenBufferedIO :: CryptoRandomGen g => Int -> Int -> IO (GenBuffered g)
newGenBufferedIO min max = do
        g <- newGenIO
        let !(Right !gBuf) = do
                (rs,g') <- genBytes min g
                let new = wrapErr (genBytes min g') g'
                (let !_ = rs in ()) `par` return (GenBuffered min max new rs)
        return gBuf

instance (CryptoRandomGen g) => CryptoRandomGen (GenBuffered g) where
	{-# SPECIALIZE instance CryptoRandomGen (GenBuffered HmacDRBG) #-}
	{-# SPECIALIZE instance CryptoRandomGen (GenBuffered HashDRBG) #-}
        newGen = newGenBuffered bufferMinDef bufferMaxDef
        newGenIO = newGenBufferedIO bufferMinDef bufferMaxDef
	genSeedLength =
		let a = help res
		    res = Tagged $ genSeedLength `for` a
		in res
	  where
	  help :: Tagged (GenBuffered g) c -> g
	  help = const undefined
        genBytes req gb@(GenBuffered min max g bs)
                | remSize >= min =  Right (B.take req bs, GenBuffered min max g (B.drop req bs))
                | B.length bs < min =
                        case g of
                                Left (err,_)  -> Left err
                                Right g   -> Left (GenErrorOther "Buffering generator failed to buffer properly - unknown reason")
                | req > B.length bs = Left RequestedTooManyBytes
                | remSize < min =
                        case g of
                                Left (err,_) -> Left err
                                Right (rnd, gen) ->
                                        let new | B.length rnd > 0 = wrapErr (genBytes (max - (remSize + B.length rnd)) gen) gen
                                                | otherwise = Right (B.empty,gen)
                                            (rs,rem) = B.splitAt req bs
                                        in (eval new) `par` Right (rs, GenBuffered min max new (B.append rem rnd))
                | otherwise = Left $ GenErrorOther "Buffering generator hit an impossible case.  Please inform the Haskell crypto-api maintainer"
          where
          remSize = B.length bs - req
        genBytesWithEntropy req ent g = reseed ent g >>= \gen -> genBytes req gen
        reseed ent (GenBuffered min max g bs) = do
                let (rs, g') =
                      case g of
                        Left (_,g') -> (B.empty, g')
                        Right (rs, g') -> (rs, g')
                g'' <- reseed ent g'
                let new = wrapErr (genBytes (min-B.length bs') g'') g''
                    bs' = B.take max (B.append bs rs)
                return (GenBuffered min max new bs')


wrapErr :: Either x y -> g -> Either (x,g) y
wrapErr (Left x) g = Left (x,g)
wrapErr (Right r) _ = Right r

-- |Force evaluation for use by GenBuffered.
eval :: Either x (B.ByteString, g) -> Either x (B.ByteString, g)
eval (Left x) = Left x
eval (Right (g,bs)) = bs `seq` (g `seq` (Right (g, bs)))

-- |zipWith xor + Pack
-- As a result of rewrite rules, this should automatically be optimized (at compile time) 
-- to use the bytestring libraries 'zipWith'' function.
zwp' a = B.pack . B.zipWith xor a
