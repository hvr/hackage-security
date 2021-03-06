-- | An implementation of Repository that talks to repositories over HTTP.
--
-- This implementation is itself parameterized over a 'HttpClient', so that it
-- it not tied to a specific library; for instance, 'HttpClient' can be
-- implemented with the @HTTP@ library, the @http-client@ libary, or others.
--
-- It would also be possible to give _other_ Repository implementations that
-- talk to repositories over HTTP, if you want to make other design decisions
-- than we did here, in particular:
--
-- * We attempt to do incremental downloads of the index when possible.
-- * We reuse the "Repository.Local"  to deal with the local cache.
-- * We download @timestamp.json@ and @snapshot.json@ together. This is
--   implemented here because:
--   - One level down (HttpClient) we have no access to the local cache
--   - One level up (Repository API) would require _all_ Repositories to
--     implement this optimization.
module Hackage.Security.Client.Repository.Remote (
    -- * Top-level API
    withRepository
  , RepoOpts(..)
  , defaultRepoOpts
     -- * File sizes
  , FileSize(..)
  , fileSizeWithinBounds
  ) where

import Control.Concurrent
import Control.Exception
import Control.Monad.Cont
import Control.Monad.Except
import Data.List (nub)
import Network.URI hiding (uriPath, path)
import System.IO
import qualified Data.ByteString      as BS
import qualified Data.ByteString.Lazy as BS.L

import Hackage.Security.Client.Formats
import Hackage.Security.Client.Repository
import Hackage.Security.Client.Repository.Cache (Cache)
import Hackage.Security.Client.Repository.HttpLib
import Hackage.Security.Trusted
import Hackage.Security.TUF
import Hackage.Security.Util.Checked
import Hackage.Security.Util.IO
import Hackage.Security.Util.Path
import Hackage.Security.Util.Some
import qualified Hackage.Security.Client.Repository.Cache as Cache

{-------------------------------------------------------------------------------
  Server capabilities
-------------------------------------------------------------------------------}

-- | Server capabilities
--
-- As the library interacts with the server and receives replies, we may
-- discover more information about the server's capabilities; for instance,
-- we may discover that it supports incremental downloads.
newtype ServerCapabilities = SC (MVar ServerCapabilities_)

-- | Internal type recording the various server capabilities we support
data ServerCapabilities_ = ServerCapabilities {
      -- | Does the server support range requests?
      serverAcceptRangesBytes :: Bool
    }

newServerCapabilities :: IO ServerCapabilities
newServerCapabilities = SC <$> newMVar ServerCapabilities {
      serverAcceptRangesBytes      = False
    }

updateServerCapabilities :: ServerCapabilities -> [HttpResponseHeader] -> IO ()
updateServerCapabilities (SC mv) responseHeaders = modifyMVar_ mv $ \caps ->
    return $ caps {
        serverAcceptRangesBytes = serverAcceptRangesBytes caps
          || HttpResponseAcceptRangesBytes `elem` responseHeaders
      }

checkServerCapability :: MonadIO m
                      => ServerCapabilities -> (ServerCapabilities_ -> a) -> m a
checkServerCapability (SC mv) f = liftIO $ withMVar mv $ return . f

{-------------------------------------------------------------------------------
  File size
-------------------------------------------------------------------------------}

data FileSize =
    -- | For most files we download we know the exact size beforehand
    -- (because this information comes from the snapshot or delegated info)
    FileSizeExact Int

    -- | For some files we might not know the size beforehand, but we might
    -- be able to provide an upper bound (timestamp, root info)
  | FileSizeBound Int

fileSizeWithinBounds :: Int -> FileSize -> Bool
fileSizeWithinBounds sz (FileSizeExact sz') = sz <= sz'
fileSizeWithinBounds sz (FileSizeBound sz') = sz <= sz'

{-------------------------------------------------------------------------------
  Top-level API
-------------------------------------------------------------------------------}

-- | Repository options with a reasonable default
--
-- Clients should use 'defaultRepositoryOpts' and override required settings.
data RepoOpts = RepoOpts {
      -- | Should we allow HTTP content compression?
      --
      -- Since content compression happens before signature verification, users
      -- who are concerned about potential exploits of the decompression
      -- algorithm may prefer to disallow content compression.
      repoAllowContentCompression :: Bool

      -- | Do we want to a copy of the compressed index?
      --
      -- This is important for mirroring clients only.
    , repoWantCompressedIndex :: Bool

      -- | Allow additional mirrors?
      --
      -- If this is set to True (default), in addition to the (out-of-band)
      -- specified mirrors we will also use mirrors reported by those
      -- out-of-band mirrors (that is, @mirrors.json@).
    , repoAllowAdditionalMirrors :: Bool
    }

-- | Default repository options
defaultRepoOpts :: RepoOpts
defaultRepoOpts = RepoOpts {
      repoAllowContentCompression = True
    , repoWantCompressedIndex     = False
    , repoAllowAdditionalMirrors  = True
    }

-- | Initialize the repository (and cleanup resources afterwards)
--
-- We allow to specify multiple mirrors to initialize the repository. These
-- are mirrors that can be found "out of band" (out of the scope of the TUF
-- protocol), for example in a @cabal.config@ file. The TUF protocol itself
-- will specify that any of these mirrors can serve a @mirrors.json@ file
-- that itself contains mirrors; we consider these as _additional_ mirrors
-- to the ones that are passed here.
--
-- NOTE: The list of mirrors should be non-empty (and should typically include
-- the primary server).
--
-- TODO: In the future we could allow finer control over precisely which
-- mirrors we use (which combination of the mirrors that are passed as arguments
-- here and the mirrors that we get from @mirrors.json@) as well as indicating
-- mirror preferences.
withRepository
  :: HttpLib                 -- ^ Implementation of the HTTP protocol
  -> [URI]                   -- ^ "Out of band" list of mirrors
  -> RepoOpts                -- ^ Repository options
  -> Cache                   -- ^ Location of local cache
  -> RepoLayout              -- ^ Repository layout
  -> (LogMessage -> IO ())   -- ^ Logger
  -> (Repository -> IO a)    -- ^ Callback
  -> IO a
withRepository httpLib
               outOfBandMirrors
               repoOpts
               cache
               repLayout
               logger
               callback
               = do
    selectedMirror <- newMVar Nothing
    caps <- newServerCapabilities
    let remoteConfig mirror = RemoteConfig {
                                  cfgLayout   = repLayout
                                , cfgHttpLib  = httpLib
                                , cfgBase     = mirror
                                , cfgCache    = cache
                                , cfgCaps     = caps
                                , cfgLogger   = logger
                                , cfgOpts     = repoOpts
                                }
    callback Repository {
        repWithRemote    = withRemote remoteConfig selectedMirror
      , repGetCached     = Cache.getCached     cache
      , repGetCachedRoot = Cache.getCachedRoot cache
      , repClearCache    = Cache.clearCache    cache
      , repGetFromIndex  = Cache.getFromIndex  cache (repoIndexLayout repLayout)
      , repWithMirror    = withMirror httpLib
                                      selectedMirror
                                      logger
                                      outOfBandMirrors
                                      repoOpts
      , repLog           = logger
      , repLayout        = repLayout
      , repDescription   = "Remote repository at " ++ show outOfBandMirrors
      }

{-------------------------------------------------------------------------------
  Implementations of the various methods of Repository
-------------------------------------------------------------------------------}

-- | We select a mirror in 'withMirror' (the implementation of 'repWithMirror').
-- Outside the scope of 'withMirror' no mirror is selected, and a call to
-- 'withRemote' will throw an exception. If this exception is ever thrown its
-- a bug: calls to 'withRemote' ('repWithRemote') should _always_ be in the
-- scope of 'repWithMirror'.
type SelectedMirror = MVar (Maybe URI)

-- | Get the selected mirror
--
-- Throws an exception if no mirror was selected (this would be a bug in the
-- client code).
--
-- NOTE: Cannot use 'withMVar' here, because the callback would be inside the
-- scope of the withMVar, and there might be further calls to 'withRemote' made
-- by the callback argument to 'withRemote', leading to deadlock.
getSelectedMirror :: SelectedMirror -> IO URI
getSelectedMirror selectedMirror = do
     mBaseURI <- readMVar selectedMirror
     case mBaseURI of
       Nothing      -> internalError "Internal error: no mirror selected"
       Just baseURI -> return baseURI

-- | Get a file from the server
withRemote :: (Throws VerificationError, Throws SomeRemoteError)
           => (URI -> RemoteConfig)
           -> SelectedMirror
           -> IsRetry
           -> RemoteFile fs
           -> (forall f. HasFormat fs f -> TempPath -> IO a)
           -> IO a
withRemote remoteConfig selectedMirror isRetry remoteFile callback = do
   baseURI <- getSelectedMirror selectedMirror
   withRemote' (remoteConfig baseURI) isRetry remoteFile callback

-- | Get a file from the server, assuming we have already picked a mirror
withRemote' :: (Throws VerificationError, Throws SomeRemoteError)
            => RemoteConfig
            -> IsRetry
            -> RemoteFile fs
            -> (forall f. HasFormat fs f -> TempPath -> IO a)
            -> IO a
withRemote' cfg isRetry remoteFile callback =
    getFile cfg isRetry remoteFile callback =<< pickDownloadMethod cfg remoteFile

-- | HTTP options
--
-- We want to make sure caches don't transform files in any way (as this will
-- mess things up with respect to hashes etc). Additionally, after a validation
-- error we want to make sure caches get files upstream in case the validation
-- error was because the cache updated files out of order.
httpRequestHeaders :: RemoteConfig
                   -> IsRetry
                   -> DownloadMethod fs
                   -> [HttpRequestHeader]
httpRequestHeaders RemoteConfig{..} isRetry method =
    case isRetry of
      FirstAttempt           -> defaultHeaders
      AfterVerificationError -> HttpRequestMaxAge0 : defaultHeaders
  where
    -- Headers we provide for _every_ attempt, first or not
    defaultHeaders :: [HttpRequestHeader]
    defaultHeaders = concat [
        [ HttpRequestNoTransform ]
      , [ HttpRequestContentCompression
        | repoAllowContentCompression cfgOpts && not (isRangeRequest method)
        ]
      ]

    -- If we are doing a range request, we must not request content compression:
    -- servers such as Apache interpret this range against the _compressed_
    -- stream, making it near useless for our purposes here.
    isRangeRequest :: DownloadMethod fs -> Bool
    isRangeRequest NeverUpdated{} = False
    isRangeRequest CannotUpdate{} = False
    isRangeRequest Update{}       = True

-- | Mirror selection
withMirror :: forall a.
              HttpLib                -- ^ HTTP client
           -> SelectedMirror         -- ^ MVar indicating currently mirror
           -> (LogMessage -> IO ())  -- ^ Logger
           -> [URI]                  -- ^ Out-of-band mirrors
           -> RepoOpts               -- ^ Repository options
           -> Maybe [Mirror]         -- ^ TUF mirrors
           -> IO a                   -- ^ Callback
           -> IO a
withMirror HttpLib{..}
           selectedMirror
           logger
           oobMirrors
           repoOpts
           tufMirrors
           callback
           =
    go orderedMirrors
  where
    go :: [URI] -> IO a
    -- Empty list of mirrors is a bug
    go [] = internalError "No mirrors configured"
    -- If we only have a single mirror left, let exceptions be thrown up
    go [m] = do
      logger $ LogSelectedMirror (show m)
      select m $ callback
    -- Otherwise, catch exceptions and if any were thrown, try with different
    -- mirror
    go (m:ms) = do
      logger $ LogSelectedMirror (show m)
      catchChecked (select m callback) $ \ex -> do
        logger $ LogMirrorFailed (show m) ex
        go ms

    -- TODO: We will want to make the construction of this list configurable.
    orderedMirrors :: [URI]
    orderedMirrors = nub $ concat [
        oobMirrors
      , if repoAllowAdditionalMirrors repoOpts
          then maybe [] (map mirrorUrlBase) tufMirrors
          else []
      ]

    select :: URI -> IO a -> IO a
    select uri =
      bracket_ (modifyMVar_ selectedMirror $ \_ -> return $ Just uri)
               (modifyMVar_ selectedMirror $ \_ -> return Nothing)

{-------------------------------------------------------------------------------
  Download methods
-------------------------------------------------------------------------------}

-- | Download method (downloading or updating)
data DownloadMethod fs =
    -- | Download this file (we never attempt to update this type of file)
    forall f. NeverUpdated {
        downloadFormat :: HasFormat fs f
      }

    -- | Download this file (we cannot update this file right now)
  | forall f. CannotUpdate {
        downloadFormat :: HasFormat fs f
      , downloadReason :: UpdateFailure
      }

    -- | Attempt an (incremental) update of this file
    --
    -- We record the trailer for the file; that is, the number of bytes
    -- (counted from the end of the file) that we should overwrite with
    -- the remote file.
  | forall f f'. Update {
        updateFormat   :: HasFormat fs f
      , updateInfo     :: Trusted FileInfo
      , updateLocal    :: AbsolutePath
      , updateTrailer  :: Integer
      , downloadFormat :: HasFormat fs f'    -- ^ In case an update fails
      }

pickDownloadMethod :: RemoteConfig
                   -> RemoteFile fs
                   -> IO (DownloadMethod fs)
pickDownloadMethod RemoteConfig{..} remoteFile = multipleExitPoints $ do
    -- We only have a choice for the index; everywhere else the repository only
    -- gives a single option. For the index we return a proof that the
    -- repository must at least have the compressed form available.
    (hasGz, formats) <- case remoteFile of
      RemoteTimestamp      -> exit $ NeverUpdated (HFZ FUn)
      (RemoteRoot _)       -> exit $ NeverUpdated (HFZ FUn)
      (RemoteSnapshot _)   -> exit $ NeverUpdated (HFZ FUn)
      (RemoteMirrors _)    -> exit $ NeverUpdated (HFZ FUn)
      (RemotePkgTarGz _ _) -> exit $ NeverUpdated (HFZ FGz)
      (RemoteIndex pf fs)  -> return (pf, fs)

    -- If the client wants the compressed index, we have no choice
    when (repoWantCompressedIndex cfgOpts) $
      exit $ CannotUpdate hasGz UpdateNotUsefulWantsCompressed

    -- Server must have uncompressed index available
    hasUn <- case formatsMember FUn formats of
      Nothing    -> exit $ CannotUpdate hasGz UpdateImpossibleOnlyCompressed
      Just hasUn -> return hasUn

    -- Server must support @Range@ with a byte-range
    rangeSupport <- checkServerCapability cfgCaps serverAcceptRangesBytes
    unless rangeSupport $ exit $ CannotUpdate hasGz UpdateImpossibleUnsupported

    -- We must already have a local file to be updated
    -- (if not we should try to download the initial file in compressed form)
    mCachedIndex <- lift $ Cache.getCachedIndex cfgCache
    cachedIndex  <- case mCachedIndex of
      Nothing -> exit $ CannotUpdate hasGz UpdateImpossibleNoLocalCopy
      Just fp -> return fp

    -- Index trailer
    --
    -- TODO: This hardcodes the trailer length as 1024. We should instead take
    -- advantage of the tarball index to find out where the trailer starts.
    let trailerLength = 1024

    -- File sizes
    localSize <- liftIO $ getFileSize cachedIndex
    let infoGz     = formatsLookup hasGz formats
        infoUn     = formatsLookup hasUn formats
        updateSize = fileLength' infoUn - fromIntegral localSize
    unless (updateSize < fileLength' infoGz) $
      exit $ CannotUpdate hasGz UpdateTooLarge

    -- If all these checks pass try to do an incremental update.
    return Update {
         updateFormat   = hasUn
       , updateInfo     = infoUn
       , updateLocal    = cachedIndex
       , updateTrailer  = trailerLength
       , downloadFormat = hasGz
       }

-- | Download the specified file using the given download method
getFile :: forall fs a. (Throws VerificationError, Throws SomeRemoteError)
        => RemoteConfig         -- ^ Internal configuration
        -> IsRetry              -- ^ Did a security check previously fail?
        -> RemoteFile fs        -- ^ File to get
        -> (forall f. HasFormat fs f -> TempPath -> IO a) -- ^ Callback
        -> DownloadMethod fs    -- ^ Selected format
        -> IO a
getFile cfg@RemoteConfig{..} isRetry remoteFile callback method =
    go method
  where
    go :: (Throws VerificationError, Throws SomeRemoteError)
       => DownloadMethod fs -> IO a
    go NeverUpdated{..} = do
        cfgLogger $ LogDownloading (Some remoteFile)
        download downloadFormat
    go CannotUpdate{..} = do
        cfgLogger $ LogCannotUpdate (Some remoteFile) downloadReason
        cfgLogger $ LogDownloading (Some remoteFile)
        download downloadFormat
    go Update{..} = do
        cfgLogger $ LogUpdating (Some remoteFile)
        -- Attempt to download the file incrementally.
        let updateFailed :: SomeException -> IO a
            updateFailed = go . CannotUpdate downloadFormat . UpdateFailed

            -- If verification of the file fails, and this is the first attempt,
            -- we let the exception be thrown up to the security layer, so that
            -- it will try again with instructions to the cache to fetch stuff
            -- upstream. Hopefully this will resolve the issue. However, if
            -- an incrementally updated file cannot be verified on the next
            -- attempt, we then try to download the whole file.
            handleVerificationError :: VerificationError -> IO a
            handleVerificationError ex =
              case isRetry of
                FirstAttempt -> throwChecked ex
                _otherwise   -> updateFailed $ SomeException ex

            handleHttpException :: SomeRemoteError -> IO a
            handleHttpException = updateFailed . SomeException

        handleChecked handleVerificationError $
          handleChecked handleHttpException $
            update updateFormat updateInfo updateLocal updateTrailer

    headers :: [HttpRequestHeader]
    headers = httpRequestHeaders cfg isRetry method

    -- Get any file from the server, without using incremental updates
    download :: Throws SomeRemoteError => HasFormat fs f -> IO a
    download format =
        withTempFile (Cache.cacheRoot cfgCache) (uriTemplate uri) $ \tempPath h -> do
          -- We are careful NOT to scope the remainder of the computation underneath
          -- the httpClientGet
          httpGet headers uri $ \responseHeaders bodyReader -> do
            updateServerCapabilities cfgCaps responseHeaders
            execBodyReader targetPath sz h bodyReader
          hClose h
          verifyAndCache format tempPath
      where
        targetPath = TargetPathRepo $ remoteRepoPath' cfgLayout remoteFile format
        uri = formatsLookup format $ remoteFileURI cfgLayout cfgBase remoteFile
        sz  = formatsLookup format $ remoteFileSize remoteFile

    -- Get a file incrementally
    --
    -- Sadly, this has some tar-specific functionality
    update :: HasFormat fs f      -- ^ Selected format
           -> Trusted FileInfo    -- ^ Expected info
           -> AbsolutePath        -- ^ Location of cached tar (after callback)
           -> Integer             -- ^ Trailer length
           -> IO a
    update format info cachedFile trailer = do
        currentSize <- getFileSize cachedFile
        let currentMinusTrailer = currentSize - trailer
            fileSz  = fileLength' info
            range   = (fromInteger currentMinusTrailer, fileSz)
            rangeSz = FileSizeExact (snd range - fst range)
        withTempFile (Cache.cacheRoot cfgCache) (uriTemplate uri) $ \tempPath h -> do
          BS.L.hPut h =<< readLazyByteString cachedFile
          hSeek h AbsoluteSeek currentMinusTrailer
          -- As in 'getFile', make sure we don't scope the remainder of the
          -- computation underneath the httpClientGetRange
          httpGetRange headers uri range $ \responseHeaders bodyReader -> do
            updateServerCapabilities cfgCaps responseHeaders
            execBodyReader targetPath rangeSz h bodyReader
          hClose h
          verifyAndCache format tempPath
      where
        targetPath = TargetPathRepo repoLayoutIndexTar
        uri = modifyUriPath cfgBase (`anchorRepoPathRemotely` repoLayoutIndexTar)
        RepoLayout{repoLayoutIndexTar} = cfgLayout

    -- | Verify the downloaded/updated file (by calling the callback) and
    -- cache it if the callback does not throw any exceptions
    verifyAndCache :: HasFormat fs f -> AbsolutePath -> IO a
    verifyAndCache format tempPath = do
        result <- callback format tempPath
        Cache.cacheRemoteFile cfgCache
                              tempPath
                              (hasFormatGet format)
                              (mustCache remoteFile)
        return result

    HttpLib{..} = cfgHttpLib

-- | Execute a body reader
--
-- NOTE: This intentially does NOT use the @with..@ pattern: we want to execute
-- the entire body reader (or cancel it) and write the results to a file and
-- then continue. We do NOT want to scope the remainder of the computation
-- as part of the same HTTP request.
--
-- TODO: Deal with minimum download rate.
execBodyReader :: Throws VerificationError
               => TargetPath  -- ^ File source (for error msgs only)
               -> FileSize    -- ^ Maximum file size
               -> Handle      -- ^ Handle to write data too
               -> BodyReader  -- ^ The action to give us blocks from the file
               -> IO ()
execBodyReader file mlen h br = go 0
  where
    go :: Int -> IO ()
    go sz = do
      unless (sz `fileSizeWithinBounds` mlen) $
        throwChecked $ VerificationErrorFileTooLarge file
      bs <- br
      if BS.null bs
        then return ()
        else BS.hPut h bs >> go (sz + BS.length bs)

{-------------------------------------------------------------------------------
  Information about remote files
-------------------------------------------------------------------------------}

remoteFileURI :: RepoLayout -> URI -> RemoteFile fs -> Formats fs URI
remoteFileURI repoLayout baseURI = fmap aux . remoteRepoPath repoLayout
  where
    aux :: RepoPath -> URI
    aux repoPath = modifyUriPath baseURI (`anchorRepoPathRemotely` repoPath)

-- | Extracting or estimating file sizes
remoteFileSize :: RemoteFile fs -> Formats fs FileSize
remoteFileSize (RemoteTimestamp) =
    FsUn $ FileSizeBound fileSizeBoundTimestamp
remoteFileSize (RemoteRoot mLen) =
    FsUn $ maybe (FileSizeBound fileSizeBoundRoot)
                 (FileSizeExact . fileLength')
                 mLen
remoteFileSize (RemoteSnapshot len) =
    FsUn $ FileSizeExact (fileLength' len)
remoteFileSize (RemoteMirrors len) =
    FsUn $ FileSizeExact (fileLength' len)
remoteFileSize (RemoteIndex _ lens) =
    fmap (FileSizeExact . fileLength') lens
remoteFileSize (RemotePkgTarGz _pkgId len) =
    FsGz $ FileSizeExact (fileLength' len)

-- | Bound on the size of the timestamp
--
-- This is intended as a permissive rather than tight bound.
--
-- The timestamp signed with a single key is 420 bytes; the signature makes up
-- just under 200 bytes of that. So even if the timestamp is signed with 10
-- keys it would still only be 2420 bytes. Doubling this amount, an upper bound
-- of 4kB should definitely be sufficient.
fileSizeBoundTimestamp :: Int
fileSizeBoundTimestamp = 4096

-- | Bound on the size of the root
--
-- This is intended as a permissive rather than tight bound.
--
-- The variable parts of the root metadata are
--
-- * Signatures, each of which are about 200 bytes
-- * A key environment (mapping from key IDs to public keys), each is of
--   which is also about 200 bytes
-- * Mirrors, root, snapshot, targets, and timestamp role specifications.
--   These contains key IDs, each of which is about 80 bytes.
--
-- A skeleton root metadata is about 580 bytes. Allowing for
--
-- * 100 signatures
-- * 100 mirror keys, 1000 root keys, 100 snapshot keys, 1000 target keys,
--   100 timestamp keys
-- * the corresponding 2300 entries in the key environment
--
-- We end up with a bound of about 665,000 bytes. Doubling this amount, an
-- upper bound of 2MB should definitely be sufficient.
fileSizeBoundRoot :: Int
fileSizeBoundRoot = 2 * 1024 * 2014

{-------------------------------------------------------------------------------
  Configuration
-------------------------------------------------------------------------------}

-- | Remote repository configuration
--
-- This is purely for internal convenience.
data RemoteConfig = RemoteConfig {
      cfgLayout   :: RepoLayout
    , cfgHttpLib  :: HttpLib
    , cfgBase     :: URI
    , cfgCache    :: Cache
    , cfgCaps     :: ServerCapabilities
    , cfgLogger   :: LogMessage -> IO ()
    , cfgOpts     :: RepoOpts
    }

{-------------------------------------------------------------------------------
  Auxiliary
-------------------------------------------------------------------------------}

-- | Template for the local file we use to download a URI to
uriTemplate :: URI -> String
uriTemplate = unFragment . takeFileName . uriPath

fileLength' :: Trusted FileInfo -> Int
fileLength' = fileLength . fileInfoLength . trusted

{-------------------------------------------------------------------------------
  Auxiliary: multiple exit points
-------------------------------------------------------------------------------}

-- | Multiple exit points
--
-- We can simulate the imperative code
--
-- > if (cond1)
-- >   return exp1;
-- > if (cond2)
-- >   return exp2;
-- > if (cond3)
-- >   return exp3;
-- > return exp4;
--
-- as
--
-- > choose $ do
-- >   when (cond1) $
-- >     exit exp1
-- >   when (cond) $
-- >     exit exp2
-- >   when (cond)
-- >     exit exp3
-- >   return exp4
multipleExitPoints :: Monad m => ExceptT a m a -> m a
multipleExitPoints = liftM aux . runExceptT
  where
    aux :: Either a a -> a
    aux (Left  a) = a
    aux (Right a) = a

-- | Function exit point (see 'multipleExitPoints')
exit :: Monad m => e -> ExceptT e m a
exit = throwError
