{-# LANGUAGE RankNTypes, ExistentialQuantification #-}
{-# LANGUAGE TypeApplications, FlexibleContexts #-}
{-# LANGUAGE BangPatterns, MagicHash, ScopedTypeVariables #-}
{-# LANGUAGE GADTs #-}
module Debug.Dyepack (dye, checkDyed, Dyed(..)) where

import qualified GHC.Generics as GHC
import Generics.SOP
import Generics.SOP.GGP
import GHC.Exts
import System.Mem.Weak
import System.Mem

-- TODO: come up with a better name for Part
data Part = forall a. Part String (Weak a)

-- | Represents an object who's contents on the heap have been "dyed".
-- The dyed contents have weak pointers, which can then be used to check if they
-- are being retained.
newtype Dyed a = Dyed [Part]

-- | Create a new 'Dyed' that can be then used with 'checkDyed'. 'dye' will
-- make a 'Weak' pointer to each field in your type which can be used to
-- check if any part of the data type is leaking at a later part of the
-- program.
dye :: forall a . (GHC.Generic a
                  , GFrom a
                  , SListI (GCode a)
                  , GDatatypeInfo a ) => a -> IO (Dyed a)
dye !x = do
  let parts :: [IO Part]
      parts = hcollapse $ hzipWith go cinfo (unSOP $ gfrom x)

      cinfo = constructorInfo info
      info = gdatatypeInfo (Proxy @a)
  Dyed <$> sequence parts
  where go :: ConstructorInfo xs -> NP I xs -> K [IO Part] xs
        go (Constructor n) x = K (hcollapse $ hmap (doOne n) x)
        go (Infix n _ prec) x = K (hcollapse $ hmap (doOne n) x)
        go (Record n fi) x = K (goProd fi x)

        doOne d !(I !y) = K (Part d <$> mkWeakPtr y Nothing)

        goProd :: All Top xs => NP FieldInfo xs -> NP I xs -> [IO Part]
        goProd fi x = hcollapse $ hzipWith (\(FieldInfo l) y -> doOne l y) fi x


-- | Check if any part of 'Dyed' is being retained. The callback is triggered when
-- the object is retained.
checkDyed :: Dyed a -> (forall x . String -> x -> IO ()) -> IO ()
checkDyed (Dyed parts) k = do
  performGC
  mapM_ checkPart parts
  where
    checkPart (Part s wp) = do
      res <- deRefWeak wp
      case res of
        Just x -> k s x
        Nothing -> pure ()
