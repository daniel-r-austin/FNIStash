-----------------------------------------------------------------------------
--
-- Module      :  Main
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

module Main (
    main
) where


import FNIStash.Logic.Backend
import FNIStash.UI.Frontend
import FNIStash.Comm.Messages


import Filesystem
import Filesystem.Path.CurrentOS

main = do
    setWorkingDirectory "C:\\Users\\Dan\\My Code\\FNIStash" -- only for testing
    messages <- newChan
    (appRoot, guiRoot) <- launchBackend messages
    serve Config
        { jiPort = 10001
        , jiRun = runJi
        , jiWorker = frontend messages
        , jiInitHTML = Just "GUI.html"
        , jiStatic = encodeString guiRoot
        }


