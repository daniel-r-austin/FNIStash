-----------------------------------------------------------------------------
--
-- Module      :  FNIStash.File.Variables
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

module FNIStash.File.Variables where

import Data.Endian
import Data.Word

-- This file defines values for different VariableID's that are useful

type VarID = Word32

-- Variables that are particularly useful.
vUNIT_GUID = swapEndian 0x06aad3ed::VarID
vEFFECTLIST = swapEndian 0x15ca47c3::VarID
vEFFECT = swapEndian 0x351c420e::VarID
vGOODDES = swapEndian 0xda18d35a::VarID
vGOODDESOT = swapEndian 0xdfa0624c::VarID
vBADDES = swapEndian 0xf2183300::VarID
vBADDESOT = swapEndian 0xb4cf63cc::VarID
vNAME = swapEndian 0xe50d6600::VarID
vDISPLAYPRECISION = swapEndian 0xcceda5e5::VarID
vSLOTNAME = swapEndian 0x6e07669b::VarID
vSLOT = swapEndian 0xb4b96800::VarID
vSLOTS = swapEndian 0xd336170f::VarID
vUNIQUEID = swapEndian 0xdf973b17::VarID
vICON = swapEndian 0xae856500::VarID
vBASEFILE = swapEndian 0xc52772e2::VarID
