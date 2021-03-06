module TestSuite.InMemRepository (
    newInMemRepository
  ) where

-- stdlib
import qualified Data.ByteString as BS

-- hackage-security
import Hackage.Security.Client
import Hackage.Security.Client.Formats
import Hackage.Security.Client.Repository
import Hackage.Security.Util.Checked

-- TestSuite
import TestSuite.InMemCache
import TestSuite.InMemRepo

newInMemRepository :: RepoLayout
                   -> InMemRepo
                   -> InMemCache
                   -> (LogMessage -> IO ())
                   -> Repository
newInMemRepository layout repo cache logger = Repository {
      repWithRemote    = withRemote    repo cache
    , repGetCached     = inMemCacheGet      cache
    , repGetCachedRoot = inMemCacheGetRoot  cache
    , repClearCache    = inMemCacheClear    cache
    , repGetFromIndex  = getFromIndex
    , repWithMirror    = withMirror
    , repLog           = logger
    , repLayout        = layout
    , repDescription   = "In memory repository"
    }

{-------------------------------------------------------------------------------
  Repository methods
-------------------------------------------------------------------------------}

-- | Get a file from the server
withRemote :: forall a fs.
              (Throws VerificationError, Throws SomeRemoteError)
           => InMemRepo
           -> InMemCache
           -> IsRetry
           -> RemoteFile fs
           -> (forall f. HasFormat fs f -> TempPath -> IO a)
           -> IO a
withRemote InMemRepo{..} InMemCache{..} _isRetry remoteFile callback =
    inMemRepoGet remoteFile $ \format tempPath -> do
      result <- callback format tempPath
      inMemCachePut tempPath (hasFormatGet format) (mustCache remoteFile)
      return result

-- | Get a file from the index
getFromIndex :: IndexFile -> IO (Maybe BS.ByteString)
getFromIndex = error "repGetFromIndex not implemented"

-- | Mirror selection
withMirror :: forall a. Maybe [Mirror] -> IO a -> IO a
withMirror Nothing   callback = callback
withMirror (Just []) callback = callback
withMirror _ _ = error "Mirror selection not implemented"
