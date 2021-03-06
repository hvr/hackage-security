-- | HttpLib bridge to the in-memory repository
module TestSuite.HttpMem (
    httpMem
  ) where

-- stdlib
import Network.URI (URI)
import qualified Data.ByteString.Lazy as BS.L

-- hackage-security
import Hackage.Security.Client
import Hackage.Security.Client.Repository.HttpLib
import Hackage.Security.Util.Checked
import Hackage.Security.Util.Path

-- TestSuite
import TestSuite.InMemRepo

httpMem :: InMemRepo -> HttpLib
httpMem inMemRepo = HttpLib {
      httpGet      = get      inMemRepo
    , httpGetRange = getRange inMemRepo
    }

{-------------------------------------------------------------------------------
  Individual methods
-------------------------------------------------------------------------------}

-- | Download a file
--
-- Since we don't (yet?) make any attempt to simulate a cache, we ignore
-- caching headers.
get :: forall a. Throws SomeRemoteError
    => InMemRepo
    -> [HttpRequestHeader]
    -> URI
    -> ([HttpResponseHeader] -> BodyReader -> IO a)
    -> IO a
get InMemRepo{..} requestHeaders uri callback = do
    let repoPath = castRoot $ uriPath uri
    inMemRepoGetPath repoPath $ \tempPath -> do
      br <- bodyReaderFromBS =<< readLazyByteString tempPath

      -- We pretend that we used content compression (the HttpLib spec
      -- explicitly states that it is the responsibility of the HttpLib
      -- implementation to decode compressed content), and indicate that we can
      -- use range requests
      let responseHeaders = concat [
              [ HttpResponseAcceptRangesBytes ]
            , [ HttpResponseContentCompression
              | HttpRequestContentCompression <- requestHeaders
              ]
            ]
      callback responseHeaders br

-- | Download a byte range
--
-- Range is starting and (exclusive) end offset in bytes.
--
-- We ignore requests for compression; different servers deal with compression
-- for byte range requests differently; in particular, Apache returns the range
-- of the _compressed_ file, which is pretty useless for our purposes. For now
-- we ignore this issue completely here.
getRange :: forall a. Throws SomeRemoteError
         => InMemRepo
         -> [HttpRequestHeader]
         -> URI
         -> (Int, Int)
         -> ([HttpResponseHeader] -> BodyReader -> IO a)
         -> IO a
getRange InMemRepo{..} _requestHeaders uri (fr, to) callback = do
    let repoPath = castRoot $ uriPath uri
    inMemRepoGetPath repoPath $ \tempPath -> do
      br <- bodyReaderFromBS . substr =<< readLazyByteString tempPath

      let responseHeaders = concat [
              [ HttpResponseAcceptRangesBytes ]
            ]
      callback responseHeaders br
  where
    substr :: BS.L.ByteString -> BS.L.ByteString
    substr = BS.L.take (fromIntegral (to - fr)) . BS.L.drop (fromIntegral fr)
