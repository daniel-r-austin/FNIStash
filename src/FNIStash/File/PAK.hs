-----------------------------------------------------------------------------
--
-- Module      :  FNIStash.Logic.File.App.PAK
-- Copyright   :
-- License     :  AllRightsReserved
--
-- Maintainer  :
-- Stability   :
-- Portability :
--
-- |
--
-----------------------------------------------------------------------------



-- functions for exploring and extracting raw data from PAK files

module FNIStash.File.PAK (
    readPAKMAN,
    readPAKFiles,
    lkupPAKFile,
    pakFileList
) where


import FNIStash.File.General

import Data.ByteString.Lazy as BS hiding (length)
import Data.Binary.Get
import qualified Data.Map.Lazy as M
import qualified Data.List as L
import Data.Word
import qualified Data.Text as T
import Control.Applicative
import Control.Monad (replicateM)
import System.FilePath
import Codec.Compression.Zlib
import Data.Char (toUpper)

----- Worker functions


readPAKMAN fileName = do
    content <- BS.readFile fileName
    return $ runGet getMANHeader content

pakFileList hdr =
    let f folder entry = forText2 (</>) (folderName folder) (entryName entry)
    in folderAndEntryToList f hdr

pakFileOffsets hdr =
    let f folder entry = entryOffset entry
    in folderAndEntryToList f hdr

folderAndEntryToList :: (MANFolder -> MANEntry -> a) -> MANHeader -> [a]
folderAndEntryToList f hdr =
    let folders = headerFolders hdr
    in L.concat $ flip L.map folders (\fol ->
        flip L.map (fileEntriesOnly $ folderEntries fol) (f fol))


readPAKFiles :: FilePath -> FilePath -> IO PAKFiles
readPAKFiles manFile pakFile = do
    man <- readPAKMAN manFile
    pak <- BS.readFile pakFile
    let fileList = pakFileList man
        offsetList = pakFileOffsets man
        fileOffsetList = L.zip fileList offsetList
        f offset = flip runGet pak ((getPAKEntry . fromIntegral) offset)
        mapList = L.zip fileList (L.map f offsetList) :: [(FilePath, PAKEntry)]
    return $ M.fromList mapList


lkupPAKFile :: PAKFiles -> FilePath -> Maybe BS.ByteString
lkupPAKFile pakFiles filePath =
    fmap (decompress . pakEncodedData) $ flip M.lookup pakFiles (L.map toUpper filePath)

forText f = f . T.unpack
forText2 f a b = f (T.unpack a) (T.unpack b)

fileEntriesOnly entries = L.filter ((Folder /=) . entryType) entries

-----  Data Declarations ------

type PAKFiles = M.Map FilePath PAKEntry

data MANEntry = MANEntry {
    entryCrc32 :: Word32,
    entryType :: PAKFileType,
    entryName :: T.Text,
    entryOffset :: Word32,
    entryDecodedSize :: Word32,
    entryUnknown1W32 :: Word32,
    entryUnknown2W32 :: Word32
    } deriving Eq

data MANFolder = MANFolder {
    folderName :: T.Text,
    folderEntries :: [MANEntry]
    } deriving Eq

data MANHeader = MANHeader {
    headerVersion :: Word16,
    headerName :: T.Text,
    headerUnknown1W32 :: Word32,
    headerFolders :: [MANFolder]
    } deriving Eq

data PAKFileType =
    DatTemplate | Layout | Mesh | Skeleton | Dds | Png | OggWav |
    Folder | Material | Raw | Imageset | Ttf | Font | Animation |
    Hie | Scheme | Looknfeel | Mpp | Unrecognized
    deriving (Show, Eq)

data PAKEntry = PAKEntry {
    pakHeader :: Word32,
    pakDecodedSize :: Word32,
    pakEncodedSize :: Word32,
    pakEncodedData :: BS.ByteString
    } deriving Eq

---- Gets -------

getMANEntry :: Get MANEntry
getMANEntry =
    MANEntry <$> getWord32le <*> getFileType <*> getTorchTextL
             <*> getWord32le <*> getWord32le <*> getWord32le <*> getWord32le

getMANFolder :: Get MANFolder
getMANFolder =
    MANFolder <$> getTorchTextL
              <*> (getWord32le >>= (flip replicateM getMANEntry) . fromIntegral)

getMANHeader :: Get MANHeader
getMANHeader =
    MANHeader <$> getWord16le
              <*> getTorchTextL
              <*> getWord32le
              <*> (getWord32le >>= (flip replicateM getMANFolder) . fromIntegral)
 
getFileType :: Get PAKFileType
getFileType = do
    typeID <- getWord8
    return $ case typeID of
        0x00 -> DatTemplate
        0x01 -> Layout
        0x02 -> Mesh
        0x03 -> Skeleton
        0x04 -> Dds
        0x05 -> Png
        0x06 -> OggWav
        0x07 -> Folder
        0x08 -> Material
        0x09 -> Raw
        0x0B -> Imageset
        0x0C -> Ttf
        0x0D -> Font
        0x10 -> Animation
        0x11 -> Hie
        0x13 -> Scheme
        0x14 -> Looknfeel
        0x15 -> Mpp
        _    -> Unrecognized

getPAKEntry :: Word32 -> Get PAKEntry
getPAKEntry offset = do
    (skip . fromIntegral) (offset-4)
    hdr <- getWord32le
    decSize <- getWord32le
    encSize <- getWord32le
    encData <- getLazyByteString $ fromIntegral encSize
    return $ PAKEntry hdr decSize encSize encData

----- Show Instances ----

instance Show MANEntry where
    show me = (show . entryType) me ++ " named " ++ (show . entryName) me ++ "\n"


instance Show MANFolder where
    show mf = "-- Contents folder " ++ (show . folderName) mf ++
              "(" ++ (show . length . folderEntries) mf ++ " entries)\n" ++
              (show . folderEntries) mf


instance Show MANHeader where
    show mh = "Hierarchy for " ++ (show . headerName) mh ++ "\n" ++
              (show . headerFolders) mh







