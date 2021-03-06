{-# LANGUAGE CPP #-}
#if __GLASGOW_HASKELL__ >= 710
{-# LANGUAGE StaticPointers #-}
#endif
-- | Main entry point into the Hackage Security framework for clients
module Hackage.Security.Client (
    -- * Checking for updates
    checkForUpdates
  , HasUpdates(..)
    -- * Downloading targets
  , downloadPackage
  , getCabalFile
    -- * Bootstrapping
  , requiresBootstrap
  , bootstrap
    -- * Re-exports
  , module Hackage.Security.TUF
  , module Hackage.Security.Key
    -- ** We only a few bits from .Repository
    -- TODO: Maybe this is a sign that these should be in a different module?
  , Repository -- opaque
  , SomeRemoteError(..)
  , LogMessage(..)
    -- * Exceptions
  , uncheckClientErrors
  , VerificationError(..)
  , VerificationHistory
  , RootUpdated(..)
  , InvalidPackageException(..)
  , InvalidFileInIndex(..)
  , LocalFileCorrupted(..)
  ) where

import Prelude hiding (log)
import Control.Exception
import Control.Monad
import Control.Monad.IO.Class
import Control.Monad.Trans.Cont
import Data.Maybe (isNothing)
import Data.Time
import Data.Traversable (for)
import Data.Typeable (Typeable)
import qualified Data.ByteString      as BS
import qualified Data.ByteString.Lazy as BS.L

import Distribution.Package (PackageIdentifier)
import Distribution.Text (display)

import Hackage.Security.Client.Repository
import Hackage.Security.Client.Formats
import Hackage.Security.JSON
import Hackage.Security.Key
import Hackage.Security.Key.Env (KeyEnv)
import Hackage.Security.Trusted
import Hackage.Security.Trusted.TCB
import Hackage.Security.TUF
import Hackage.Security.Util.Checked
import Hackage.Security.Util.Pretty
import Hackage.Security.Util.Stack
import Hackage.Security.Util.Some
import qualified Hackage.Security.Key.Env   as KeyEnv

{-------------------------------------------------------------------------------
  Checking for updates
-------------------------------------------------------------------------------}

data HasUpdates = HasUpdates | NoUpdates
  deriving (Show, Eq, Ord)

-- | Generic logic for checking if there are updates
--
-- This implements the logic described in Section 5.1, "The client application",
-- of the TUF spec. It checks which of the server metadata has changed, and
-- downloads all changed metadata to the local cache. (Metadata here refers
-- both to the TUF security metadata as well as the Hackage packge index.)
--
-- You should pass @Nothing@ for the UTCTime _only_ under exceptional
-- circumstances (such as when the main server is down for longer than the
-- expiry dates used in the timestamp files on mirrors).
checkForUpdates :: (Throws VerificationError, Throws SomeRemoteError)
                => Repository
                -> Maybe UTCTime -- ^ To check expiry times against (if using)
                -> IO HasUpdates
checkForUpdates rep mNow =
    withMirror rep $ limitIterations []
  where
    -- More or less randomly chosen maximum iterations
    -- See <https://github.com/theupdateframework/tuf/issues/287>.
    maxNumIterations :: Int
    maxNumIterations = 5

    -- The spec stipulates that on a verification error we must download new
    -- root information and start over. However, in order to prevent DoS attacks
    -- we limit how often we go round this loop.
    -- See als <https://github.com/theupdateframework/tuf/issues/287>.
    limitIterations :: (Throws VerificationError, Throws SomeRemoteError)
                    => VerificationHistory -> IO HasUpdates
    limitIterations history | length history >= maxNumIterations =
        throwChecked $ VerificationErrorLoop (reverse history)
    limitIterations history = do
        -- Get all cached info
        --
        -- NOTE: Although we don't normally update any cached files until the
        -- whole verification process successfully completes, in case of a
        -- verification error, or in case of a regular update of the root info,
        -- we DO update the local files. Hence, we must re-read all local files
        -- on each iteration.
        cachedInfo <- getCachedInfo rep

        mHasUpdates <- tryChecked -- catch RootUpdated
                     $ tryChecked -- catch VerificationError
                     $ evalContT  -- clean up temp files
                     $ go isRetry cachedInfo
        case mHasUpdates of
          Left ex -> do
            -- NOTE: This call to updateRoot is not itself protected by an
            -- exception handler, and may therefore throw a VerificationError.
            -- This is intentional: if we get verification errors during the
            -- update process, _and_ we cannot update the main root info, then
            -- we cannot do anything.
            log rep $ LogVerificationError ex
            updateRoot rep mNow AfterVerificationError cachedInfo (Left ex)
            limitIterations (Right ex : history)
          Right (Left RootUpdated) -> do
            log rep $ LogRootUpdated
            limitIterations (Left RootUpdated : history)
          Right (Right hasUpdates) ->
            return hasUpdates
      where
        isRetry :: IsRetry
        isRetry = if null history then FirstAttempt else AfterVerificationError

    -- NOTE: We use the ContT monad transformer to make sure that none of the
    -- downloaded files will be cached until the entire check for updates check
    -- completes successfully.
    -- See also <https://github.com/theupdateframework/tuf/issues/283>.
    go :: Throws RootUpdated => IsRetry -> CachedInfo -> ContT r IO HasUpdates
    go isRetry cachedInfo@CachedInfo{..} = do
      -- Get the new timestamp
      newTS <- getRemoteFile' RemoteTimestamp
      let newInfoSS = static timestampInfoSnapshot <$$> newTS

      -- Check if the snapshot has changed
      if not (fileChanged cachedInfoSnapshot newInfoSS)
        then return NoUpdates
        else do
          -- Get the new snapshot
          newSS <- getRemoteFile' (RemoteSnapshot newInfoSS)
          let newInfoRoot    = static snapshotInfoRoot    <$$> newSS
              newInfoMirrors = static snapshotInfoMirrors <$$> newSS
              newInfoTarGz   = static snapshotInfoTarGz   <$$> newSS
              mNewInfoTar    = trustSeq (static snapshotInfoTar <$$> newSS)

          -- If root metadata changed, download and restart
          when (rootChanged cachedInfoRoot newInfoRoot) $ liftIO $ do
            updateRoot rep mNow isRetry cachedInfo (Right newInfoRoot)
            -- By throwing 'RootUpdated' as an exception we make sure that
            -- any files previously downloaded (to temporary locations)
            -- will not be cached.
            throwChecked RootUpdated

          -- If mirrors changed, download and verify
          when (fileChanged cachedInfoMirrors newInfoMirrors) $
            newMirrors =<< getRemoteFile' (RemoteMirrors newInfoMirrors)

          -- If index changed, download and verify
          when (fileChanged cachedInfoTarGz newInfoTarGz) $
            updateIndex newInfoTarGz mNewInfoTar

          return HasUpdates
      where
        getRemoteFile' :: ( VerifyRole a
                          , FromJSON ReadJSON_Keys_Layout (Signed a)
                          )
                       => RemoteFile (f :- ()) -> ContT r IO (Trusted a)
        getRemoteFile' = liftM fst . getRemoteFile rep cachedInfo isRetry mNow

        -- Update the index and check against the appropriate hash
        updateIndex :: Trusted FileInfo         -- info about @.tar.gz@
                    -> Maybe (Trusted FileInfo) -- info about @.tar@
                    -> ContT r IO ()
        updateIndex newInfoTarGz Nothing = do
          (targetPath, tempPath) <- getRemote' rep isRetry $
            RemoteIndex (HFZ FGz) (FsGz newInfoTarGz)
          verifyFileInfo' (Just newInfoTarGz) targetPath tempPath
        updateIndex newInfoTarGz (Just newInfoTar) = do
          (format, targetPath, tempPath) <- getRemote rep isRetry $
            RemoteIndex (HFS (HFZ FGz)) (FsUnGz newInfoTar newInfoTarGz)
          case format of
            Some FGz -> verifyFileInfo' (Just newInfoTarGz) targetPath tempPath
            Some FUn -> verifyFileInfo' (Just newInfoTar)   targetPath tempPath

    -- Unlike for other files, if we didn't have an old snapshot, consider the
    -- root info unchanged (otherwise we would loop indefinitely).
    -- See also <https://github.com/theupdateframework/tuf/issues/286>
    rootChanged :: Maybe (Trusted FileInfo) -> Trusted FileInfo -> Bool
    rootChanged Nothing    _   = False
    rootChanged (Just old) new = not (trustedFileInfoEqual old new)

    -- For any file other than the root we consider the file to have changed
    -- if we do not yet have a local snapshot to tell us the old info.
    fileChanged :: Maybe (Trusted FileInfo) -> Trusted FileInfo -> Bool
    fileChanged Nothing    _   = True
    fileChanged (Just old) new = not (trustedFileInfoEqual old new)

    -- We don't actually _do_ anything with the mirrors file until the next call
    -- to 'checkUpdates', because we want to use a single server for a single
    -- check-for-updates request. If validation was successful the repository
    -- will have cached the mirrors file and it will be available on the next
    -- request.
    newMirrors :: Trusted Mirrors -> ContT r IO ()
    newMirrors _ = return ()

-- | Update the root metadata
--
-- Note that the new root metadata is verified using the old root metadata,
-- and only then trusted.
--
-- We don't always have root file information available. If we notice during
-- the normal update process that the root information has changed then the
-- snapshot will give us the new file information; but if we need to update
-- the root information due to a verification error we do not.
--
-- We additionally delete the cached cached snapshot and timestamp. This is
-- necessary for two reasons:
--
-- 1. If during the normal update process we notice that the root info was
--    updated (because the hash of @root.json@ in the new snapshot is different
--    from the old snapshot) we download new root info and start over, without
--    (yet) downloading a (potential) new index. This means it is important that
--    we not overwrite our local cached snapshot, because if we did we would
--    then on the next iteration conclude there were no updates and we would
--    fail to notice that we should have updated the index. However, unless we
--    do something, this means that we would conclude on the next iteration once
--    again that the root info has changed (because the hash in the new shapshot
--    still doesn't match the hash in the cached snapshot), and we would loop
--    until we throw a 'VerificationErrorLoop' exception. By deleting the local
--    snapshot we basically reset the client to its initial state, and we will
--    not try to download the root info once again. The only downside of this is
--    that we will also re-download the index after every root info change.
--    However, this should be infrequent enough that this isn't an issue.
--    See also <https://github.com/theupdateframework/tuf/issues/285>.
--
-- 2. Additionally, deleting the local timestamp and snapshot protects against
--    an attack where an attacker has set the file version of the snapshot or
--    timestamp to MAX_INT, thereby making further updates impossible.
--    (Such an attack would require a timestamp/snapshot key compromise.)
--
-- However, we _ONLY_ do this when the root information has actually changed.
-- If we did this unconditionally it would mean that we delete the locally
-- cached timestamp whenever the version on the remote timestamp is invalid,
-- thereby rendering the file version on the timestamp and the snapshot useless.
-- See <https://github.com/theupdateframework/tuf/issues/283#issuecomment-115739521>
updateRoot :: (Throws VerificationError, Throws SomeRemoteError)
           => Repository
           -> Maybe UTCTime
           -> IsRetry
           -> CachedInfo
           -> Either VerificationError (Trusted FileInfo)
           -> IO ()
updateRoot rep mNow isRetry cachedInfo eFileInfo = do
    rootReallyChanged <- evalContT $ do
      (_newRoot :: Trusted Root, rootTempFile) <- getRemoteFile
        rep
        cachedInfo
        isRetry
        mNow
        (RemoteRoot (eitherToMaybe eFileInfo))

      -- NOTE: It is important that we do this check within the evalContT,
      -- because the temporary file will be deleted once we leave its scope.
      case eFileInfo of
        Right _ ->
          -- We are downloading the root info because the hash in the snapshot
          -- changed. In this case the root definitely changed.
          return True
        Left _e -> liftIO $ do
          -- We are downloading the root because of a verification error. In
          -- this case the root info may or may not have changed. In most cases
          -- it would suffice to compare the file version now; however, in the
          -- (exceptional) circumstance where the root info has changed but
          -- the file version has not, this would result in the same infinite
          -- loop described above. Hence, we must compare file hashes, and they
          -- must be computed on the raw file, not the parsed file.
          oldRootFile <- repGetCachedRoot rep
          oldRootInfo <- DeclareTrusted <$> computeFileInfo oldRootFile
          not <$> verifyFileInfo rootTempFile oldRootInfo

    when rootReallyChanged $ clearCache rep

{-------------------------------------------------------------------------------
  Convenience functions for downloading and parsing various files
-------------------------------------------------------------------------------}

data CachedInfo = CachedInfo {
    cachedRoot         :: Trusted Root
  , cachedKeyEnv       :: KeyEnv
  , cachedTimestamp    :: Maybe (Trusted Timestamp)
  , cachedSnapshot     :: Maybe (Trusted Snapshot)
  , cachedMirrors      :: Maybe (Trusted Mirrors)
  , cachedInfoSnapshot :: Maybe (Trusted FileInfo)
  , cachedInfoRoot     :: Maybe (Trusted FileInfo)
  , cachedInfoMirrors  :: Maybe (Trusted FileInfo)
  , cachedInfoTarGz    :: Maybe (Trusted FileInfo)
  }

cachedVersion :: CachedInfo -> RemoteFile fs -> Maybe FileVersion
cachedVersion CachedInfo{..} remoteFile =
    case mustCache remoteFile of
      CacheAs CachedTimestamp -> timestampVersion . trusted <$> cachedTimestamp
      CacheAs CachedSnapshot  -> snapshotVersion  . trusted <$> cachedSnapshot
      CacheAs CachedMirrors   -> mirrorsVersion   . trusted <$> cachedMirrors
      CacheAs CachedRoot      -> Just . rootVersion . trusted $ cachedRoot
      CacheIndex -> Nothing
      DontCache  -> Nothing

-- | Get all cached info (if any)
getCachedInfo :: (Applicative m, MonadIO m) => Repository -> m CachedInfo
getCachedInfo rep = do
    (cachedRoot, cachedKeyEnv) <- readLocalRoot rep
    cachedTimestamp <- readLocalFile rep cachedKeyEnv CachedTimestamp
    cachedSnapshot  <- readLocalFile rep cachedKeyEnv CachedSnapshot
    cachedMirrors   <- readLocalFile rep cachedKeyEnv CachedMirrors

    let cachedInfoSnapshot = fmap (static timestampInfoSnapshot <$$>) cachedTimestamp
        cachedInfoRoot     = fmap (static snapshotInfoRoot      <$$>) cachedSnapshot
        cachedInfoMirrors  = fmap (static snapshotInfoMirrors   <$$>) cachedSnapshot
        cachedInfoTarGz    = fmap (static snapshotInfoTarGz     <$$>) cachedSnapshot

    return CachedInfo{..}

readLocalRoot :: MonadIO m => Repository -> m (Trusted Root, KeyEnv)
readLocalRoot rep = do
    cachedPath <- liftIO $ repGetCachedRoot rep
    signedRoot <- throwErrorsUnchecked LocalFileCorrupted =<<
                    readJSON (repLayout rep) KeyEnv.empty cachedPath
    return (trustLocalFile signedRoot, rootKeys (signed signedRoot))

readLocalFile :: ( FromJSON ReadJSON_Keys_Layout (Signed a)
                 , MonadIO m, Applicative m
                 )
              => Repository -> KeyEnv -> CachedFile -> m (Maybe (Trusted a))
readLocalFile rep cachedKeyEnv file = do
    mCachedPath <- liftIO $ repGetCached rep file
    for mCachedPath $ \cachedPath -> do
      signed <- throwErrorsUnchecked LocalFileCorrupted =<<
                  readJSON (repLayout rep) cachedKeyEnv cachedPath
      return $ trustLocalFile signed

getRemoteFile :: ( Throws VerificationError
                 , Throws SomeRemoteError
                 , VerifyRole a
                 , FromJSON ReadJSON_Keys_Layout (Signed a)
                 )
              => Repository
              -> CachedInfo
              -> IsRetry
              -> Maybe UTCTime
              -> RemoteFile (f :- ())
              -> ContT r IO (Trusted a, TempPath)
getRemoteFile rep cachedInfo@CachedInfo{..} isRetry mNow file = do
    (targetPath, tempPath) <- getRemote' rep isRetry file
    verifyFileInfo' (remoteFileDefaultInfo file) targetPath tempPath
    signed   <- throwErrorsChecked (VerificationErrorDeserialization targetPath) =<<
                  readJSON (repLayout rep) cachedKeyEnv tempPath
    verified <- throwErrorsChecked id $ verifyRole
                  cachedRoot
                  targetPath
                  (cachedVersion cachedInfo file)
                  mNow
                  signed
    return (trustVerified verified, tempPath)

{-------------------------------------------------------------------------------
  Downloading target files
-------------------------------------------------------------------------------}

-- | Download a package
--
-- It is the responsibility of the callback to move the package from its
-- temporary location to a permanent location (if desired). The callback will
-- only be invoked once the chain of trust has been verified.
--
-- NOTE: Unlike the check for updates, downloading a package never triggers an
-- update of the root information (even if verification of the package fails).
downloadPackage :: ( Throws SomeRemoteError
                   , Throws VerificationError
                   , Throws InvalidPackageException
                   )
                => Repository -> PackageIdentifier -> (TempPath -> IO a) -> IO a
downloadPackage rep pkgId callback = withMirror rep $ evalContT $ do
    -- We need the cached root information in order to resolve key IDs and
    -- verify signatures. Note that whenever we read a JSON file, we verify
    -- signatures (even if we don't verify the keys); if this is a problem
    -- (for performance) we need to parameterize parseJSON.
    (_cachedRoot, keyEnv) <- readLocalRoot rep

    -- NOTE: The files inside the index as evaluated lazily.
    --
    -- 1. The index tarball contains delegated target.json files for both
    --    unsigned and signed packages. We need to verify the signatures of all
    --    signed metadata (that is: the metadata for signed packages).
    --
    -- 2. Since the tarball also contains the .cabal files, we should also
    --    verify the hashes of those .cabal files against the hashes recorded in
    --    signed metadata (there is no point comparing against hashes recorded
    --    in unsigned metadata because attackers could just change those).
    --
    -- Since we don't have author signing yet, we don't have any additional
    -- signed metadata and therefore we currently don't have to do anything
    -- here.
    --
    -- TODO: If we have explicit, author-signed, lists of versions for a package
    -- (as described in @README.md@), then evaluating these "middle-level"
    -- delegation files lazily opens us up to a rollback attack: if we've never
    -- downloaded the delegations for a package before, then we have nothing to
    -- compare the version number in the file that we downloaded against. One
    -- option is to always download and verify all these middle level files
    -- (strictly); other is to include the version number of all of these files
    -- in the snapshot. This is described in more detail in
    -- <https://github.com/theupdateframework/tuf/issues/282#issuecomment-102468421>.
    let trustIndex :: Signed a -> Trusted a
        trustIndex = trustLocalFile

    -- Get the metadata (from the previously updated index)
    --
    -- NOTE: Currently we hardcode the location of the package specific
    -- metadata. By rights we should read the global targets file and apply the
    -- delegation rules. Until we have author signing however this is
    -- unnecessary.
    targets :: Trusted Targets <- do
      let indexFile = IndexPkgMetadata pkgId
      mRaw <- getFromIndex rep indexFile
      case mRaw of
        Nothing -> liftIO $ throwChecked $ InvalidPackageException pkgId
        Just raw -> do
          signed <- throwErrorsUnchecked (InvalidFileInIndex indexFile) $
                      parseJSON_Keys_NoLayout keyEnv raw
          return $ trustIndex signed

    -- The path of the package, relative to the targets.json file
    let filePath :: TargetPath
        filePath = TargetPathRepo $ repoLayoutPkgTarGz (repLayout rep) pkgId

    let mTargetMetaData :: Maybe (Trusted FileInfo)
        mTargetMetaData = trustSeq
                        $ trustStatic (static targetsLookup)
             `trustApply` DeclareTrusted filePath
             `trustApply` targets
    targetMetaData :: Trusted FileInfo
      <- case mTargetMetaData of
           Nothing -> liftIO $
             throwChecked $ VerificationErrorUnknownTarget filePath
           Just nfo ->
             return nfo

    -- TODO: should we check if cached package available? (spec says no)
    tarGz <- do
      (targetPath, tempPath) <- getRemote' rep FirstAttempt $
        RemotePkgTarGz pkgId targetMetaData
      verifyFileInfo' (Just targetMetaData) targetPath tempPath
      return tempPath
    liftIO $ callback tarGz

-- | Get a cabal file from the index
--
-- This does currently not do any verification (bcause the cabal file comes
-- from the index, and the index itself is verified). Once we introduce author
-- signing this needs to be adapted.
--
-- Should be called only once a local index is available
-- (i.e., after 'checkForUpdates').
--
-- Throws an 'InvalidPackageException' if there is no cabal file for the
-- specified package in the index.
getCabalFile :: Throws InvalidPackageException
             => Repository -> PackageIdentifier -> IO BS.ByteString
getCabalFile rep pkgId = do
    mCabalFile <- repGetFromIndex rep (IndexPkgCabal pkgId)
    case mCabalFile of
      Just cabalFile -> return cabalFile
      Nothing        -> throwChecked $ InvalidPackageException pkgId

{-------------------------------------------------------------------------------
  Bootstrapping
-------------------------------------------------------------------------------}

-- | Check if we need to bootstrap (i.e., if we have root info)
requiresBootstrap :: Repository -> IO Bool
requiresBootstrap rep = isNothing <$> repGetCached rep CachedRoot

-- | Bootstrap the chain of trust
--
-- New clients might need to obtain a copy of the root metadata. This however
-- represents a chicken-and-egg problem: how can we verify the root metadata
-- we downloaded? The only possibility is to be provided with a set of an
-- out-of-band set of root keys and an appropriate threshold.
--
-- Clients who provide a threshold of 0 can do an initial "unsafe" update
-- of the root information, if they wish.
--
-- The downloaded root information will _only_ be verified against the
-- provided keys, and _not_ against previously downloaded root info (if any).
-- It is the responsibility of the client to call `bootstrap` only when this
-- is the desired behaviour.
bootstrap :: (Throws SomeRemoteError, Throws VerificationError)
          => Repository -> [KeyId] -> KeyThreshold -> IO ()
bootstrap rep trustedRootKeys keyThreshold = withMirror rep $ evalContT $ do
    _newRoot :: Trusted Root <- do
      (targetPath, tempPath) <- getRemote' rep FirstAttempt (RemoteRoot Nothing)
      signed   <- throwErrorsChecked (VerificationErrorDeserialization targetPath) =<<
                    readJSON (repLayout rep) KeyEnv.empty tempPath
      verified <- throwErrorsChecked id $ verifyFingerprints
                    trustedRootKeys
                    keyThreshold
                    targetPath
                    signed
      return $ trustVerified verified

    clearCache rep

{-------------------------------------------------------------------------------
  Wrapper around the Repository functions (to avoid callback hell)
-------------------------------------------------------------------------------}

getRemote :: forall fs r. (Throws SomeRemoteError, Throws VerificationError)
          => Repository
          -> IsRetry
          -> RemoteFile fs
          -> ContT r IO (Some Format, TargetPath, TempPath)
getRemote r isRetry file = ContT aux
  where
    aux :: ((Some Format, TargetPath, TempPath) -> IO r) -> IO r
    aux k = repWithRemote r isRetry file (wrapK k)

    wrapK :: ((Some Format, TargetPath, TempPath) -> IO r)
          -> (forall f. HasFormat fs f -> TempPath -> IO r)
    wrapK k format tempPath =
        k (Some (hasFormatGet format), targetPath, tempPath)
      where
        targetPath :: TargetPath
        targetPath = TargetPathRepo $ remoteRepoPath' (repLayout r) file format

-- | Variation on getRemote where we only expect one type of result
getRemote' :: forall f r. (Throws SomeRemoteError, Throws VerificationError)
           => Repository
           -> IsRetry
           -> RemoteFile (f :- ())
           -> ContT r IO (TargetPath, TempPath)
getRemote' r isRetry file = ignoreFormat <$> getRemote r isRetry file
  where
    ignoreFormat (_format, targetPath, tempPath) = (targetPath, tempPath)

clearCache :: MonadIO m => Repository -> m ()
clearCache r = liftIO $ repClearCache r

log :: MonadIO m => Repository -> LogMessage -> m ()
log r msg = liftIO $ repLog r msg

-- We translate to a lazy bytestring here for convenience
getFromIndex :: MonadIO m
             => Repository
             -> IndexFile
             -> m (Maybe BS.L.ByteString)
getFromIndex r file = liftIO $
    fmap tr <$> repGetFromIndex r file
  where
    tr :: BS.ByteString -> BS.L.ByteString
    tr = BS.L.fromChunks . (:[])

-- Tries to load the cached mirrors file
withMirror :: Repository -> IO a -> IO a
withMirror rep callback = do
    mMirrors <- repGetCached rep CachedMirrors
    mirrors  <- case mMirrors of
      Nothing -> return Nothing
      Just fp -> filterMirrors <$>
                   (throwErrorsUnchecked LocalFileCorrupted =<<
                     readJSON_NoKeys_NoLayout fp)
    repWithMirror rep mirrors $ callback
  where
    filterMirrors :: UninterpretedSignatures Mirrors -> Maybe [Mirror]
    filterMirrors = Just
                  . filter (canUseMirror . mirrorContent)
                  . mirrorsMirrors
                  . uninterpretedSigned

    -- Once we add support for partial mirrors, we wil need an additional
    -- argument to 'repWithMirror' (here, not in the Repository API itself)
    -- that tells us which files we will be requested from the mirror.
    -- We can then compare that against the specification of the partial mirror
    -- to see if all of those files are available from this mirror.
    canUseMirror :: MirrorContent -> Bool
    canUseMirror MirrorFull = True

{-------------------------------------------------------------------------------
  Exceptions
-------------------------------------------------------------------------------}

-- | Re-throw all exceptions thrown by the client API as unchecked exceptions
uncheckClientErrors :: ( ( Throws VerificationError
                         , Throws SomeRemoteError
                         , Throws InvalidPackageException
                         ) => IO a )
                     -> IO a
uncheckClientErrors act = handleChecked rethrowVerificationError
                        $ handleChecked rethrowSomeRemoteError
                        $ handleChecked rethrowInvalidPackageException
                        $ act
  where
     rethrowVerificationError :: VerificationError -> IO a
     rethrowVerificationError = throwIO

     rethrowSomeRemoteError :: SomeRemoteError -> IO a
     rethrowSomeRemoteError = throwIO

     rethrowInvalidPackageException :: InvalidPackageException -> IO a
     rethrowInvalidPackageException = throwIO

data InvalidPackageException = InvalidPackageException PackageIdentifier
  deriving (Typeable)

data LocalFileCorrupted = LocalFileCorrupted DeserializationError
  deriving (Typeable)

data InvalidFileInIndex = InvalidFileInIndex IndexFile DeserializationError
  deriving (Typeable)

#if MIN_VERSION_base(4,8,0)
deriving instance Show InvalidPackageException
deriving instance Show LocalFileCorrupted
deriving instance Show InvalidFileInIndex
instance Exception InvalidPackageException where displayException = pretty
instance Exception LocalFileCorrupted where displayException = pretty
instance Exception InvalidFileInIndex where displayException = pretty
#else
instance Show InvalidPackageException where show = pretty
instance Show LocalFileCorrupted where show = pretty
instance Show InvalidFileInIndex where show = pretty
instance Exception InvalidPackageException
instance Exception LocalFileCorrupted
instance Exception InvalidFileInIndex
#endif

instance Pretty InvalidPackageException where
  pretty (InvalidPackageException pkgId) = "Invalid package " ++ display pkgId

instance Pretty LocalFileCorrupted where
  pretty (LocalFileCorrupted err) = "Local file corrupted: " ++ pretty err

instance Pretty InvalidFileInIndex where
  pretty (InvalidFileInIndex file err) = "Invalid file " ++ pretty file
                                      ++ "in index: " ++ pretty err

{-------------------------------------------------------------------------------
  Auxiliary
-------------------------------------------------------------------------------}

-- | Local files are assumed trusted
--
-- There is no point tracking chain of trust for local files because that chain
-- would necessarily have to start at an implicitly trusted (though unverified)
-- file: the root metadata.
trustLocalFile :: Signed a -> Trusted a
trustLocalFile Signed{..} = DeclareTrusted signed

-- | Just a simple wrapper around 'verifyFileInfo'
--
-- Throws a VerificationError if verification failed.
verifyFileInfo' :: MonadIO m
                => Maybe (Trusted FileInfo)
                -> TargetPath  -- ^ For error messages
                -> TempPath    -- ^ File to verify
                -> m ()
verifyFileInfo' Nothing     _          _        = return ()
verifyFileInfo' (Just info) targetPath tempPath = liftIO $ do
    verified <- verifyFileInfo tempPath info
    unless verified $ throw $ VerificationErrorFileInfo targetPath

readJSON :: (MonadIO m, FromJSON ReadJSON_Keys_Layout a)
         => RepoLayout -> KeyEnv -> TempPath
         -> m (Either DeserializationError a)
readJSON repoLayout keyEnv fpath = liftIO $
    readJSON_Keys_Layout keyEnv repoLayout fpath

throwErrorsUnchecked :: ( MonadIO m
                        , Exception e'
                        )
                     => (e -> e') -> Either e a -> m a
throwErrorsUnchecked f (Left err) = liftIO $ throwUnchecked (f err)
throwErrorsUnchecked _ (Right a)  = return a

throwErrorsChecked :: ( Throws e'
                      , MonadIO m
                      , Exception e'
                      )
                   => (e -> e') -> Either e a -> m a
throwErrorsChecked f (Left err) = liftIO $ throwChecked (f err)
throwErrorsChecked _ (Right a)  = return a

eitherToMaybe :: Either a b -> Maybe b
eitherToMaybe (Left  _) = Nothing
eitherToMaybe (Right b) = Just b
