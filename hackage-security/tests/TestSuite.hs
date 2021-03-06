module Main (main) where

-- stdlib
import Control.Exception
import Control.Monad
import Data.Maybe (fromJust)
import Data.Time
import Network.URI (URI, parseURI)
import Test.Tasty
import Test.Tasty.HUnit
import System.IO.Temp (withSystemTempDirectory)

-- hackage-security
import Hackage.Security.Client
import Hackage.Security.Client.Repository
import Hackage.Security.JSON (DeserializationError(..))
import Hackage.Security.Util.Checked
import Hackage.Security.Util.Path
import Hackage.Security.Util.Pretty
import Hackage.Security.Util.Some
import qualified Hackage.Security.Client.Repository.Remote as Remote
import qualified Hackage.Security.Client.Repository.Cache  as Cache

-- TestSuite
import TestSuite.HttpMem
import TestSuite.InMemCache
import TestSuite.InMemRepo
import TestSuite.InMemRepository
import TestSuite.PrivateKeys
import TestSuite.Util.StrictMVar

{-------------------------------------------------------------------------------
  TestSuite driver
-------------------------------------------------------------------------------}

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests = testGroup "hackage-security" [
      testGroup "InMem" [
          testCase "testInMemInitialHasForUpdates" testInMemInitialHasUpdates
        , testCase "testInMemNoUpdates"            testInMemNoUpdates
        , testCase "testInMemUpdatesAfterCron"     testInMemUpdatesAfterCron
        , testCase "testInMemKeyRollover"          testInMemKeyRollover
        , testCase "testInMemOutdatedTimestamp"    testInMemOutdatedTimestamp
        ]
    , testGroup "HttpMem" [
          testCase "testHttpMemInitialHasForUpdates" testHttpMemInitialHasUpdates
        , testCase "testHttpMemNoUpdates"            testHttpMemNoUpdates
        , testCase "testHttpMemUpdatesAfterCron"     testHttpMemUpdatesAfterCron
        , testCase "testHttpMemKeyRollover"          testHttpMemKeyRollover
        , testCase "testHttpMemOutdatedTimestamp"    testHttpMemOutdatedTimestamp
        ]
  ]

{-------------------------------------------------------------------------------
  In-memory tests

  These tests test the core TUF infrastructure, but any specific Repository
  implementation; instead, they use one specifically designed for testing
  (almost a Repository mock-up).
-------------------------------------------------------------------------------}

-- | Initial check for updates: empty cache
testInMemInitialHasUpdates :: Assertion
testInMemInitialHasUpdates = inMemTest $ \_inMemRepo logMsgs repo -> do
    withAssertLog "A" logMsgs [] $
      assertEqual "A.1" HasUpdates =<< checkForUpdates repo =<< checkExpiry

-- | Check that if we run updates again, with no changes on the server,
-- we get NoUpdates
testInMemNoUpdates :: Assertion
testInMemNoUpdates = inMemTest $ \_inMemRepo logMsgs repo -> do
    withAssertLog "A" logMsgs [] $ do
      assertEqual "A.1" HasUpdates =<< checkForUpdates repo =<< checkExpiry
    withAssertLog "B" logMsgs [] $ do
      assertEqual "B.2" NoUpdates  =<< checkForUpdates repo =<< checkExpiry

-- | Test that we have updates reported after the timestamp is resigned
testInMemUpdatesAfterCron :: Assertion
testInMemUpdatesAfterCron = inMemTest $ \inMemRepo logMsgs repo -> do
    withAssertLog "A" logMsgs [] $ do
      assertEqual "A.1" HasUpdates =<< checkForUpdates repo =<< checkExpiry
    withAssertLog "B" logMsgs [] $ do
      assertEqual "B.2" NoUpdates  =<< checkForUpdates repo =<< checkExpiry

    inMemRepoCron inMemRepo =<< getCurrentTime

    withAssertLog "C" logMsgs [] $ do
      assertEqual "C.1" HasUpdates =<< checkForUpdates repo =<< checkExpiry
    withAssertLog "D" logMsgs [] $ do
      assertEqual "D.2" NoUpdates  =<< checkForUpdates repo =<< checkExpiry

-- | Test what happens when the timestamp/snapshot keys rollover
testInMemKeyRollover :: Assertion
testInMemKeyRollover = inMemTest $ \inMemRepo logMsgs repo -> do
    withAssertLog "A" logMsgs [] $ do
      assertEqual "A.1" HasUpdates =<< checkForUpdates repo =<< checkExpiry
    withAssertLog "B" logMsgs [] $ do
      assertEqual "B.2" NoUpdates  =<< checkForUpdates repo =<< checkExpiry

    inMemRepoKeyRollover inMemRepo =<< getCurrentTime

    let msgs = [verificationError $ unknownKeyError timestampPath]
    withAssertLog "C" logMsgs msgs $ do
      assertEqual "C.1" HasUpdates =<< checkForUpdates repo =<< checkExpiry
    withAssertLog "D" logMsgs [] $ do
      assertEqual "D.1" NoUpdates =<< checkForUpdates repo =<< checkExpiry

-- | Test what happens when server has an outdated timestamp
-- (after a successful initial update)
testInMemOutdatedTimestamp :: Assertion
testInMemOutdatedTimestamp = inMemTest $ \_inMemRepo logMsgs repo -> do
    withAssertLog "A" logMsgs [] $ do
      assertEqual "A.1" HasUpdates =<< checkForUpdates repo =<< checkExpiry
    withAssertLog "B" logMsgs [] $ do
      assertEqual "B.2" NoUpdates  =<< checkForUpdates repo =<< checkExpiry

    now <- getCurrentTime
    let (FileExpires fourDaysLater) = expiresInDays now 4

    let msgs = replicate 5 (inHistory (Right (expired timestampPath)))
    catchVerificationLoop msgs $ do
      withAssertLog "C" logMsgs [] $ do
        assertEqual "C.1" HasUpdates =<< checkForUpdates repo fourDaysLater

{-------------------------------------------------------------------------------
  Same tests, but going through the "real" Remote repository and Cache, though
  still using an in-memory repository (with a HttpLib bridge)

  These are almost hte same as the in-memory tests, but the log messages we
  expect are slightly different because the Remote repository indicates what
  is is downloading, and why.
-------------------------------------------------------------------------------}

-- | Initial check for updates: empty cache
testHttpMemInitialHasUpdates :: Assertion
testHttpMemInitialHasUpdates = httpMemTest $ \_inMemRepo logMsgs repo -> do
    withAssertLog "A" logMsgs msgsInitialUpdate $
      assertEqual "A.1" HasUpdates =<< checkForUpdates repo =<< checkExpiry

-- | Check that if we run updates again, with no changes on the server,
-- we get NoUpdates
testHttpMemNoUpdates :: Assertion
testHttpMemNoUpdates = httpMemTest $ \_inMemRepo logMsgs repo -> do
    withAssertLog "A" logMsgs msgsInitialUpdate $ do
      assertEqual "A.1" HasUpdates =<< checkForUpdates repo =<< checkExpiry
    withAssertLog "B" logMsgs msgsNoUpdates $ do
      assertEqual "B.2" NoUpdates  =<< checkForUpdates repo =<< checkExpiry

-- | Test that we have updates reported after the timestamp is resigned
testHttpMemUpdatesAfterCron :: Assertion
testHttpMemUpdatesAfterCron = httpMemTest $ \inMemRepo logMsgs repo -> do
    withAssertLog "A" logMsgs msgsInitialUpdate $ do
      assertEqual "A.1" HasUpdates =<< checkForUpdates repo =<< checkExpiry
    withAssertLog "B" logMsgs msgsNoUpdates $ do
      assertEqual "B.2" NoUpdates  =<< checkForUpdates repo =<< checkExpiry

    inMemRepoCron inMemRepo =<< getCurrentTime

    withAssertLog "C" logMsgs msgsResigned $ do
      assertEqual "C.1" HasUpdates =<< checkForUpdates repo =<< checkExpiry
    withAssertLog "D" logMsgs msgsNoUpdates $ do
      assertEqual "D.2" NoUpdates  =<< checkForUpdates repo =<< checkExpiry

-- | Test what happens when the timestamp/snapshot keys rollover
testHttpMemKeyRollover :: Assertion
testHttpMemKeyRollover = httpMemTest $ \inMemRepo logMsgs repo -> do
    withAssertLog "A" logMsgs msgsInitialUpdate $ do
      assertEqual "A.1" HasUpdates =<< checkForUpdates repo =<< checkExpiry
    withAssertLog "B" logMsgs msgsNoUpdates $ do
      assertEqual "B.2" NoUpdates  =<< checkForUpdates repo =<< checkExpiry

    inMemRepoKeyRollover inMemRepo =<< getCurrentTime

    withAssertLog "C" logMsgs msgsKeyRollover $ do
      assertEqual "C.1" HasUpdates =<< checkForUpdates repo =<< checkExpiry
    withAssertLog "D" logMsgs msgsNoUpdates $ do
      assertEqual "D.1" NoUpdates =<< checkForUpdates repo =<< checkExpiry

-- | Test what happens when server has an outdated timestamp
-- (after a successful initial update)
testHttpMemOutdatedTimestamp :: Assertion
testHttpMemOutdatedTimestamp = httpMemTest $ \_inMemRepo logMsgs repo -> do
    withAssertLog "A" logMsgs msgsInitialUpdate $ do
      assertEqual "A.1" HasUpdates =<< checkForUpdates repo =<< checkExpiry
    withAssertLog "B" logMsgs msgsNoUpdates $ do
      assertEqual "B.2" NoUpdates  =<< checkForUpdates repo =<< checkExpiry

    now <- getCurrentTime
    let (FileExpires fourDaysLater) = expiresInDays now 4

    let msgs = replicate 5 (inHistory (Right (expired timestampPath)))
    catchVerificationLoop msgs $ do
      withAssertLog "C" logMsgs [] $ do
        assertEqual "C.1" HasUpdates =<< checkForUpdates repo fourDaysLater

{-------------------------------------------------------------------------------
  Log messages we expect when using the Remote repository
-------------------------------------------------------------------------------}

-- | The log messages we expect on the initial check for updates
msgsInitialUpdate :: [LogMessage -> Bool]
msgsInitialUpdate = [
      selectedMirror inMemURI
    , downloading isTimestamp
    , downloading isSnapshot
    , downloading isMirrors
    , noLocalCopy
    , downloading isIndex
    ]

-- | Log messages when we do a check for updates and there are no changes
msgsNoUpdates :: [LogMessage -> Bool]
msgsNoUpdates = [
      selectedMirror inMemURI
    , downloading isTimestamp
    ]

-- | Log messages we expect when the timestamp and snapshot have been resigned
msgsResigned :: [LogMessage -> Bool]
msgsResigned = [
      selectedMirror inMemURI
    , downloading isTimestamp
    , downloading isSnapshot
    ]

-- | Log messages we expect when the timestamp key has been rolled over
msgsKeyRollover :: [LogMessage -> Bool]
msgsKeyRollover = [
      selectedMirror inMemURI
    , downloading isTimestamp
    , verificationError $ unknownKeyError timestampPath
    , downloading isRoot
    , downloading isTimestamp
    , downloading isSnapshot
    -- Since we delete the timestamp and snapshot on a root info change,
    -- we will then conclude that we need to update the mirrors and the index.
    , downloading isMirrors
    , updating isIndex
    ]

{-------------------------------------------------------------------------------
  Classifying log messages
-------------------------------------------------------------------------------}

downloading :: (forall fs. RemoteFile fs -> Bool) -> LogMessage -> Bool
downloading isFile (LogDownloading (Some file)) = isFile file
downloading _ _ = False

noLocalCopy :: LogMessage -> Bool
noLocalCopy (LogCannotUpdate (Some (RemoteIndex _ _)) UpdateImpossibleNoLocalCopy) = True
noLocalCopy _ = False

selectedMirror :: URI -> LogMessage -> Bool
selectedMirror mirror (LogSelectedMirror mirror') = mirror' == show mirror
selectedMirror _ _ = False

updating :: (forall fs. RemoteFile fs -> Bool) -> LogMessage -> Bool
updating isFile (LogUpdating (Some file)) = isFile file
updating _ _ = False

expired :: TargetPath -> VerificationError -> Bool
expired f (VerificationErrorExpired f') = f == f'
expired _ _ = False

unknownKeyError :: TargetPath -> VerificationError -> Bool
unknownKeyError f (VerificationErrorDeserialization f' (DeserializationErrorUnknownKey _keyId)) =
    f == f'
unknownKeyError _ _ = False

verificationError :: (VerificationError -> Bool) -> LogMessage -> Bool
verificationError isErr (LogVerificationError err) = isErr err
verificationError _ _ = False

inHistory :: Either RootUpdated (VerificationError -> Bool) -> HistoryMsg -> Bool
inHistory (Right isErr) (Right err) = isErr err
inHistory (Left _)      (Left _)    = True
inHistory _             _           = False

type HistoryMsg = Either RootUpdated VerificationError

catchVerificationLoop :: ([HistoryMsg -> Bool]) -> Assertion -> Assertion
catchVerificationLoop history = handleJust isLoop handler
  where
    isLoop :: VerificationError -> Maybe VerificationHistory
    isLoop (VerificationErrorLoop history') = Just history'
    isLoop _ = Nothing

    handler :: VerificationHistory -> Assertion
    handler history' =
      unless (length history == length history' && and (zipWith ($) history history')) $
        assertFailure $ "Unexpected verification history:"
                     ++ unlines (map pretty' history')

    pretty' :: HistoryMsg -> String
    pretty' (Left RootUpdated) = "root updated"
    pretty' (Right err)        = pretty err

{-------------------------------------------------------------------------------
  Classifying files
-------------------------------------------------------------------------------}

isRoot :: RemoteFile fs -> Bool
isRoot (RemoteRoot _) = True
isRoot _ = False

isIndex :: RemoteFile fs -> Bool
isIndex (RemoteIndex _ _) = True
isIndex _ = False

isMirrors :: RemoteFile fs -> Bool
isMirrors (RemoteMirrors _) = True
isMirrors _ = False

isSnapshot :: RemoteFile fs -> Bool
isSnapshot (RemoteSnapshot _) = True
isSnapshot _ = False

isTimestamp :: RemoteFile fs -> Bool
isTimestamp RemoteTimestamp = True
isTimestamp _ = False

timestampPath :: TargetPath
timestampPath = TargetPathRepo $ repoLayoutTimestamp hackageRepoLayout

{-------------------------------------------------------------------------------
  Auxiliary
-------------------------------------------------------------------------------}

-- | Check the contents of the log
assertLog :: String -> [LogMessage -> Bool] -> [LogMessage] -> Assertion
assertLog label = go
  where
    go :: [LogMessage -> Bool] -> [LogMessage] -> Assertion
    go []     []     = return ()
    go []     as     = unexpected as
    go (_:_)  []     = assertFailure $ label ++ ": expected log message"
    go (e:es) (a:as) = if e a then go es as else unexpected [a]

    unexpected :: [LogMessage] -> Assertion
    unexpected msgs = assertFailure $ label ++ ": "
                                   ++ "unexpected log messages:\n"
                                   ++ unlines (map pretty msgs)

-- | Run the actions and check its log messages
withAssertLog :: String
              -> MVar [LogMessage]
              -> [LogMessage -> Bool]
              -> Assertion -> Assertion
withAssertLog label mv expected action = do
    oldMsgs <- modifyMVar mv $ \old -> return ([], old)
    action
    newMsgs <- modifyMVar mv $ \new -> return (oldMsgs, new)
    assertLog label expected newMsgs

-- | Unit test using the in-memory repository/cache
inMemTest :: ( ( Throws SomeRemoteError
               , Throws VerificationError
               ) => InMemRepo -> MVar [LogMessage] -> Repository -> Assertion
             )
          -> Assertion
inMemTest test = uncheckClientErrors $ do
    now  <- getCurrentTime
    keys <- createPrivateKeys
    let root = initRoot now layout keys
    withSystemTempDirectory "hackage-security-test" $ \tempDir' -> do
      tempDir    <- makeAbsolute $ fromFilePath tempDir'
      inMemRepo  <- newInMemRepo  tempDir layout root now keys
      inMemCache <- newInMemCache tempDir layout
      logMsgs    <- newMVar []

      let logger msg = modifyMVar_ logMsgs $ \msgs -> return $ msgs ++ [msg]
          repository = newInMemRepository layout inMemRepo inMemCache logger

      bootstrap repository (map someKeyId (privateRoot keys)) (KeyThreshold 2)
      test inMemRepo logMsgs repository
  where
    layout :: RepoLayout
    layout = hackageRepoLayout

-- | Unit test using the Remote repository but with the in-mem repo
httpMemTest :: ( ( Throws SomeRemoteError
                 , Throws VerificationError
                 ) => InMemRepo -> MVar [LogMessage] -> Repository -> Assertion
               )
            -> Assertion
httpMemTest test = uncheckClientErrors $ do
    now  <- getCurrentTime
    keys <- createPrivateKeys
    let root = initRoot now layout keys
    withSystemTempDirectory "hackage-security-test" $ \tempDir' -> do
      tempDir    <- makeAbsolute $ fromFilePath tempDir'
      inMemRepo  <- newInMemRepo  tempDir layout root now keys
      logMsgs    <- newMVar []

      let logger msg = modifyMVar_ logMsgs $ \msgs -> return $ msgs ++ [msg]
          httpLib    = httpMem inMemRepo
          cache      = Cache.Cache {
                           cacheRoot   = tempDir </> fragment' "cache"
                         , cacheLayout = cabalCacheLayout
                         }

      Remote.withRepository httpLib
                            [inMemURI]
                            Remote.defaultRepoOpts
                            cache
                            hackageRepoLayout
                            logger
                            $ \repository -> do
        withAssertLog "bootstrap" logMsgs bootstrapMsgs $
          bootstrap repository (map someKeyId (privateRoot keys)) (KeyThreshold 2)
        test inMemRepo logMsgs repository
  where
    bootstrapMsgs :: [LogMessage -> Bool]
    bootstrapMsgs = [ selectedMirror inMemURI
                    , downloading isRoot
                    ]

    layout :: RepoLayout
    layout = hackageRepoLayout

-- | Base URI for the in-memory repository
--
-- This could really be anything at all
inMemURI :: URI
inMemURI = fromJust (parseURI "inmem://")

-- | Return @Just@ the current time
checkExpiry :: IO (Maybe UTCTime)
checkExpiry = Just `fmap` getCurrentTime
