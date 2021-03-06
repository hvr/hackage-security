{-# LANGUAGE CPP #-}
-- | Abstracting over HTTP libraries
module Hackage.Security.Client.Repository.HttpLib (
    HttpLib(..)
  , HttpRequestHeader(..)
  , HttpResponseHeader(..)
  , ProxyConfig(..)
    -- ** Body reader
  , BodyReader
  , bodyReaderFromBS
  ) where

import Data.IORef
import Network.URI hiding (uriPath, path)
import qualified Data.ByteString      as BS
import qualified Data.ByteString.Lazy as BS.L

import Hackage.Security.Util.Checked
import Hackage.Security.Client.Repository (SomeRemoteError)

{-------------------------------------------------------------------------------
  Abstraction over HTTP clients (such as HTTP, http-conduit, etc.)
-------------------------------------------------------------------------------}

-- | Abstraction over HTTP clients
--
-- This avoids insisting on a particular implementation (such as the HTTP
-- package) and allows for other implementations (such as a conduit based one).
--
-- NOTE: Library-specific exceptions MUST be wrapped in 'SomeRemoteError'.
data HttpLib = HttpLib {
    -- | Download a file
    httpGet :: forall a. Throws SomeRemoteError
            => [HttpRequestHeader]
            -> URI
            -> ([HttpResponseHeader] -> BodyReader -> IO a)
            -> IO a

    -- | Download a byte range
    --
    -- Range is starting and (exclusive) end offset in bytes.
  , httpGetRange :: forall a. Throws SomeRemoteError
                 => [HttpRequestHeader]
                 -> URI
                 -> (Int, Int)
                 -> ([HttpResponseHeader] -> BodyReader -> IO a)
                 -> IO a
  }

-- | Additional request headers
--
-- Since different libraries represent headers differently, here we just
-- abstract over the few request headers that we might want to set
data HttpRequestHeader =
    -- | Set @Cache-Control: max-age=0@
    HttpRequestMaxAge0

    -- | Set @Cache-Control: no-transform@
  | HttpRequestNoTransform

    -- | Request transport compression (@Accept-Encoding: gzip@)
    --
    -- It is the responsibility of the 'HttpLib' to do compression
    -- (and report whether the original server reply was compressed or not).
    --
    -- NOTE: Clients should NOT allow for compression unless explicitly
    -- requested (since decompression happens before signature verification, it
    -- is a potential security concern).
  | HttpRequestContentCompression
  deriving (Eq, Ord, Show)

-- | Response headers
--
-- Since different libraries represent headers differently, here we just
-- abstract over the few response headers that we might want to know about.
data HttpResponseHeader =
    -- | Server accepts byte-range requests (@Accept-Ranges: bytes@)
    HttpResponseAcceptRangesBytes

    -- | Original server response was compressed
    -- (the 'HttpLib' however must do decompression)
  | HttpResponseContentCompression
  deriving (Eq, Ord, Show)

-- | Proxy configuration
--
-- Although actually setting the proxy is the purview of the initialization
-- function for individual 'HttpLib' implementations and therefore outside
-- the scope of this module, we offer this 'ProxyConfiguration' type here as a
-- way to uniformly configure proxies across all 'HttpLib's.
data ProxyConfig a =
    -- | Don't use a proxy
    ProxyConfigNone

    -- | Use this specific proxy
    --
    -- Individual HTTP backends use their own types for specifying proxies.
  | ProxyConfigUse a

    -- | Use automatic proxy settings
    --
    -- What precisely automatic means is 'HttpLib' specific, though
    -- typically it will involve looking at the @HTTP_PROXY@ environment
    -- variable or the (Windows) registry.
  | ProxyConfigAuto

{-------------------------------------------------------------------------------
  Body readers
-------------------------------------------------------------------------------}

-- | An @IO@ action that represents an incoming response body coming from the
-- server.
--
-- The action gets a single chunk of data from the response body, or an empty
-- bytestring if no more data is available.
--
-- This definition is copied from the @http-client@ package.
type BodyReader = IO BS.ByteString

-- | Construct a 'Body' reader from a lazy bytestring
--
-- This is appropriate if the lazy bytestring is constructed, say, by calling
-- 'hGetContents' on a network socket, and the chunks of the bytestring
-- correspond to the chunks as they are returned from the OS network layer.
--
-- If the lazy bytestring needs to be re-chunked this function is NOT suitable.
bodyReaderFromBS :: BS.L.ByteString -> IO BodyReader
bodyReaderFromBS lazyBS = do
    chunks <- newIORef $ BS.L.toChunks lazyBS
    -- NOTE: Lazy bytestrings invariant: no empty chunks
    let br = do bss <- readIORef chunks
                case bss of
                  []        -> return BS.empty
                  (bs:bss') -> writeIORef chunks bss' >> return bs
    return br
