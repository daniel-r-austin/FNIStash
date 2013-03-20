-----------------------------------------------------------------------------
--
-- Module      :  FNIStash.File.Location
-- Copyright   :  2013 Daniel Austin
-- License     :  AllRightsReserved
--
-- Maintainer  :  dan@fluffynukeit.com
-- Stability   :  Development
-- Portability :
--
-- |
--
-----------------------------------------------------------------------------

{-# LANGUAGE OverloadedStrings #-}

module FNIStash.File.Location (
    Location (..),
    getLocation
) where

import FNIStash.Logic.Env
import FNIStash.File.Variables
import FNIStash.File.DAT

import qualified Data.ByteString as BS
import Data.Binary.Strict.Get
import Data.Word

data Location = Location
    { locContainer :: String
    , locSlot :: String
    , locIndex :: Int
    }
    deriving (Eq, Ord, Show)


getLocation env = do
    locBytes <- getWord16le
    containerID <- getWord16le
    let l = lkupLocNodes env
        (Just container, slotType) = l locBytes containerID
        -- get the Container name
        Just containerName = lkupVar vNAME container >>= stringVar
        Just slotName = lkupVar vNAME slotType >>= stringVar
        Just slotID = lkupVar vUNIQUEID slotType >>= word32Var
        index = fromIntegral locBytes - slotID
    return $ Location containerName slotName $ fromIntegral index
