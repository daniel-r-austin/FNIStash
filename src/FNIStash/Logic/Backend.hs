-----------------------------------------------------------------------------
--
-- Module      :  FNIStash.Logic.Backend
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
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE RecordWildCards #-}

module FNIStash.Logic.Backend
    ( ensurePaths
    , backend
    , Paths(..)
) where

import FNIStash.Logic.Initialize
import FNIStash.Comm.Messages
import FNIStash.File.Crypto
import FNIStash.File.SharedStash
import FNIStash.Logic.DB
import FNIStash.Logic.Env
import FNIStash.File.Variables
import FNIStash.File.General

import Filesystem.Path
import Filesystem.Path as F
import Filesystem.Path.CurrentOS
import Filesystem
import qualified Filesystem as F
import Control.Monad.Trans
import Control.Monad
import Data.Monoid
import Control.Exception
import Control.Applicative
import Data.Either
import Data.List.Split
import Data.Binary.Put
import Data.Maybe
import Data.Time
import Text.Printf
import System.Random
import qualified Data.List as L
import qualified Data.Map as M
import qualified Data.Set as S
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BSL

import Debug.Trace


-- Gets/makes the necessary application paths
ensurePaths maybeName = do
    -- Ensure we have an app path for both backend and GUI to access
    appRoot <- ensureAppRoot maybeName
    guiRoot <- ensureHtml appRoot
    (importDir, exportDir, backupDir, failedDir) <- ensureSubPaths appRoot
    return $ Paths appRoot guiRoot importDir exportDir backupDir failedDir

-- Prep exception handling
sendErrIO :: Messages -> (String -> BMessage) -> IOException -> IO ()
sendErrIO msg c exc = traceShow exc $ writeBMessage msg $ c ("IO: " ++ show exc)
sendErrDB msg c exc = traceShow exc $ writeBMessage msg $ c ("DB: " ++ show exc)

handleIOExc c msg = handle   (sendErrIO msg c)
handleDBExc c msg = handleDB (sendErrDB msg c)

catchAs msg c = handleIOExc c msg . handleDBExc c msg

-- The real meat of the program
backend msg paths@Paths{..} mvar = catchAs msg (Initializing . InitError) $ do
    env <- initialize msg paths mvar

    -- Try to read the shared stash file
    (mSharedStashCrypted, file, dir) <- sharedStashPath env

    case mSharedStashCrypted of
        Nothing -> writeBMessage msg $ Initializing $ InitError $
            "Could not find " ++ file ++ " under the directory " ++ dir ++
            ". Verify Backend.conf is defined correctly for your installation."
        Just sharedStashCrypted -> do
            -- Descramble the scrambled shared stash file.  Just reads the test file for now. Needs to
            -- eventually read the file defined by cfg
            cryptoFile <- readCryptoFile sharedStashCrypted
            let ssData = fileGameData cryptoFile
                fileVers = fileVersion cryptoFile
                sharedStashResult = parseSharedStash env ssData
            case sharedStashResult of
                Left (error,_) -> writeBMessage msg $ Initializing $ InitError $ "Error reading shared stash: " ++ error
                Right sharedStash -> do
                    writeBMessage msg $ Initializing BackupsStart
                    makeBackups paths env (decodeString sharedStashCrypted)
                    writeBMessage msg $ Initializing ImportsStart
                    processImports env msg importDir fileVers
                    writeBMessage msg $ Initializing RegisterStart
                    dumpRegistrations paths env msg fileVers sharedStash
                    dumpItemLocs msg env
                    writeBMessage msg $ Initializing ArchiveDataStart
                    dumpArchive env msg
                    writeBMessage msg $ Initializing ReportStart
                    dumpItemReport env msg
                    writeBMessage msg $ Initializing Complete
                    msgList <- liftIO $ onlyFMessages msg
                    catchAs msg (Notice . Error) $
                        handleMessages env (decodeString sharedStashCrypted) msg cryptoFile paths msgList

-- copy the shared stash and DB files to a backups directory, dated with the time
makeBackups Paths{..} (dbPath->dbPath) stashFile = do
    backupsExists <- isDirectory backupsDir
    when (not backupsExists) $ createDirectory True backupsDir
    let backupLimit = 10
    zonedTime <- getZonedTime
    let t = zonedTimeToLocalTime zonedTime
        (y, m, d) = toGregorian $ localDay t
        (hr, min) = (todHour.localTimeOfDay $ t, todMin.localTimeOfDay $ t)
        newDirName = L.intercalate "-" $ show y : map (printf "%02d") [m, d, hr, min]
        newDirectory = backupsDir </> (decodeString newDirName)
    oldDirectories <- getSubDirectoriesSorted (encodeString backupsDir)
    
    when (length oldDirectories >= backupLimit && notElem newDirName oldDirectories) $
        removeTree . decodeString $ head oldDirectories -- remove older directories
    createDirectory True newDirectory
    let dbBackupPath = decodeString $ (encodeString dbPath) <> "_bak"
    dbBackupExists <- isFile dbBackupPath
    when dbBackupExists $ copyFile dbBackupPath (newDirectory </> filename dbBackupPath)
                      >> removeFile dbBackupPath
    copyFile stashFile (newDirectory </> filename stashFile)



dumpItemLocs messages env = do
    eitherConts <- allLocationContents env
    let itemErrors = lefts eitherConts
        goodLocItems  = rights eitherConts
        locMsg = LocationContents goodLocItems
    writeBMessage messages locMsg
    forM_ itemErrors $ \err -> writeBMessage messages $
        Notice $ Error $ err
    when (length itemErrors > 0) $ writeBMessage messages $
         Notice $ Error $ "Number items failed: " ++ (show.length) itemErrors


dumpArchive env msg = do
    allItems <- allItemSummaries env
    writeBMessage msg $ Initializing $ ArchiveData allItems

dumpRegistrations Paths{..} env messages fVers sharedStash = do
    let (badItems, goodItems) = partitionEithers sharedStash
    when (length badItems > 0) $ do
        forM_ badItems $ \(err, fromStrict -> bs) -> do
            writeBMessage messages $ Notice $ Error $ "--" ++ err
            roll <- getStdRandom (randomR (0,1000000000)) :: IO (Int)
            writeItemBSToFile env bs failedItemsDir (show roll)

        writeBMessage messages . Notice . Error $
           "Number of items failed to parse: " ++ (show $ length badItems) ++ ". Each error shown above.\
           \  Each failed item has been placed in the failed items folder.  Please report the bug \
           \ and attached the failed item file."
           
    RegisterSummary newItems updatedItems noChange <- registerStash env fVers Stashed goodItems
    let numNew = length newItems
        numUpd = length updatedItems
        numNoC = length noChange
    when (numNew > 0 ) $ writeBMessage messages . Notice . Info $ "Newly registered items: " ++ (show numNew)
    when (numUpd > 0) $ writeBMessage messages . Notice . Info $ "Updated items: " ++ (show numUpd)
    return ()
    -- writeBMessage messages $ Notice $ Info $ "No change items: " ++ (show numNoC)

processImports env@Env{..} messages importDir fVers = do
    importDirExists <- isDirectory importDir
    when importDirExists $ do
        -- read in each file
        files <- getRecursiveContents (encodeString importDir)
                    >>= return . filter (flip hasExtension "tl2i" . decodeString)
        (failedFileErrors, itemResults) <- fmap partitionEithers $ forM files $ \f -> BS.readFile f >>= \bs ->
            return $ runGetWithFail ("\""++f++"\"") (getItem env Nothing bs) bs
        RegisterSummary newItems updatedItems noChange <- registerStash env fVers Archived itemResults
        -- determine which files succeeded import and delete them (maybe)
        let failedFiles = filter (\f -> any (("\""++f++"\"") `L.isInfixOf`) $ map fst failedFileErrors) files
            successFiles = files L.\\ failedFiles
        forM_ successFiles (removeFile . decodeString)
        when (length files > 0) $ do
            writeBMessage messages $ Notice . Info $ "New registrations due to import: " ++ show (length newItems)
            writeBMessage messages $ Notice . Info $ "Updated registrations due to import: " ++ show (length updatedItems)
            writeBMessage messages $ Notice . Info $ "No change due to import: " ++ show (length noChange)
            when (length failedFiles > 0) $
                writeBMessage messages . Notice . Error $ "Failed imports (still in Import directory): " ++ show (length failedFiles)



-- Tries to register all non-registered items into the DB.  Retuns list of newly
-- registered items.
registerStash = register

-- This is the main backend event queue
handleMessages env@Env{..} savePath m cryptoFile paths@Paths{..} (msg:rest) = do
    outMessages <- case msg of

        -- Move an item from one location to another
        Move fromToList -> do
            changeResults <- forM fromToList $ \(from, to) -> locationChange env from to
            let errorStrings = lefts changeResults
                contentUpdates = L.concat $ rights changeResults
                makeNotice erro = Notice . Error $ "Move error: " ++ erro
            return $ (map makeNotice errorStrings) ++ [LocationContents contentUpdates]

        -- Save all "Stashed" items to disk
        Save -> do
            sharedStash <- getSharedStashFromDb env
            let (saveErrors, newSaveFile) = buildSaveFile env cryptoFile sharedStash
                errorNotices = map (\e -> Notice . Error $ "Save error: " ++ e) saveErrors
                filePath = encodeString savePath
                saveNotice = if length errorNotices > 0
                             then []
                             else [Notice . Saved $ filePath]
            when (length errorNotices == 0) $ do-- only write out the file if there are no errors
                writeCryptoFile filePath newSaveFile
                commitDB env    -- also commit changes to DB
            return $ errorNotices ++ saveNotice

        -- Find items matching keywords
        Search keywordsString -> do
            matchStatuses <- keywordStatus env keywordsString
            return $ case matchStatuses of
                Right visibilityUpdates -> [Visibility visibilityUpdates]
                Left  queryError        -> [Notice . Error $ "Query parse error: " ++ queryError]

        -- Make a request for item data, associated with a particular element
        RequestItem elem loc -> do
            dbResult <- getItemFromDb env loc
            return $ case dbResult of
                Left requestErr -> [Notice . Error $ requestErr]
                Right mitem     -> [ResponseItem elem mitem]

        ExportDB -> do
            files <- getRecursiveContents (encodeString exportDir)
            if (length files > 0) then
                return [Notice . Error $ "Please empty Export directory before exporting: " ++ encodeString exportDir]
                else do
                    writeBMessage m $ Notice . Info $ "Exporting database to " ++ encodeString exportDir ++ "..."
                    (_, succs) <- exportDB env m paths
                    return $ [Notice . Info $ "Exported " ++ (show $ length succs) ++ " items to " ++ encodeString exportDir]

        DeleteItem (Archive id) -> do
            numDeletes <- deleteID env id
            when (numDeletes /= 1) $ writeBMessage m $
                Notice . Error $ "Problem deleting item ID " ++ show id ++". Deleted " ++ show numDeletes ++ " items."
            if  (numDeletes == 1) then do
                writeBMessage m $ Notice . Info $ "Item will be permanently deleted on save."
                return [RemoveItem (Archive id)]
                else return []
        DeleteItem _ -> return [Notice . Error $ "An attempt was made to delete an item without a proper item ID."]

            

    -- send GUI updates
    forM_ outMessages $ \msg -> writeBMessage m msg

    -- and then process next message
    handleMessages env savePath m cryptoFile paths rest


sharedStashToBS env ss = runPut (putSharedStash env ss)

buildSaveFile env c ss =
    let itemErrors = map fst $ lefts ss
        i = sharedStashToBS env ss
        newSaveFile = CryptoFile (fileVersion c) (fileDummy c) (0) (i) (0)
    in (itemErrors, newSaveFile)

exportDB env@Env{..} msg Paths{..} = do
    items <- allDBItems env
    let errors = lefts items
        succs = catMaybes . rights $ items
        numberedItems = zip [1..] succs
    when (length errors > 0) $ do
        forM_ errors $ \e -> writeBMessage msg $ Notice . Error $ "Database export parse error: " ++ e
        writeBMessage msg $ Notice . Error $ "Total database export parse errors: " ++ (show $ length errors)
    forM_ numberedItems $ \(i, item) -> writeItemBSToFile env (BSL.drop 4 $ runPut $ putItem env item) exportDir (show i)
    return (errors, succs)

writeItemBSToFile env dataBS dir filename =
     F.writeFile (dir </> (decodeString filename) <.> "tl2i") (toStrict dataBS)
    
dumpItemReport env mes = do
    guids <- allGUIDs env
    let report = buildReport env guids
    writeBMessage mes $ Initializing $ ReportData $ report

buildReport :: Env -> [GUID] -> ItemsReport
buildReport env@Env{..} (S.fromAscList -> guidSet) =
    let allPossibleGUIDs = M.keys allItems
        distinctFoundGUIDs = S.size guidSet
        mkItemReport guid =
            let i = lkupItemGUID guid
                trueName = i >>= vNAME
                n = i >>= searchAncestryFor env vDISPLAYNAME
                r = (i >>= searchAncestryFor env vRARITY >>= \k -> if k == 0 then Nothing else Just k)
                    <|> (trueName >>= lkupSpawnClass >>= nRARITY_ORIDE_NODE >>= vRARITY_OVERRIDE)
                l = i >>= searchAncestryFor env vLEVEL
                q = maybe NormalQ id (i >>= searchAncestryFor env vITEMUNITTYPE >>= return . uQuality)
                dropFlag = maybe True id (i >>= vDONTCREATE >>= return . not)
                creatable = case (r, dropFlag) of
                    (Just rar, f) -> f && q /= QuestQ && q /= LevelQ
                    _             -> False
            in ItemReport guid n r l creatable
        reportAllItems = map mkItemReport allPossibleGUIDs
        reportAllCreatables = filter reportCreatable reportAllItems
        itemsToFind = filter (\rep -> reportGUID rep `S.notMember` guidSet) reportAllCreatables
        percFound = 100 * fromIntegral (distinctFoundGUIDs) / fromIntegral (length reportAllCreatables)
    in ItemsReport
        (L.sortBy rarityDesc $ itemsToFind)
        percFound
        (S.size guidSet)
        (length reportAllCreatables)

rarityDesc a b
    | reportRarity a < reportRarity b  = GT
    | reportRarity a > reportRarity b  = LT
    | reportRarity a == reportRarity b = case reportName a `compare` reportName b of
        LT -> LT
        GT -> GT
        EQ -> reportLevel a `compare` reportLevel b
