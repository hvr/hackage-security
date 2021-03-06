-- | Information about files
module Hackage.Security.TUF.FileInfo (
    FileInfo(..)
  , HashFn(..)
  , Hash(..)
    -- * Utility
  , fileInfo
  , computeFileInfo
  , knownFileInfoEqual
  ) where

import Prelude hiding (lookup)
import Data.Map (Map)
import qualified Crypto.Hash          as CH
import qualified Data.Map             as Map
import qualified Data.ByteString.Lazy as BS.L

import Hackage.Security.JSON
import Hackage.Security.TUF.Common
import Hackage.Security.Util.Path

{-------------------------------------------------------------------------------
  Datatypes
-------------------------------------------------------------------------------}

data HashFn = HashFnSHA256
  deriving (Show, Eq, Ord)

-- | File information
--
-- This intentionally does not have an 'Eq' instance; see 'knownFileInfoEqual'
-- and 'verifyFileInfo' instead.
--
-- NOTE: Throughout we compute file information always over the raw bytes.
-- For example, when @timestamp.json@ lists the hash of @snapshot.json@, this
-- hash is computed over the actual @snapshot.json@ file (as opposed to the
-- canonical form of the embedded JSON). This brings it in line with the hash
-- computed over target files, where that is the only choice available.
data FileInfo = FileInfo {
    fileInfoLength :: FileLength
  , fileInfoHashes :: Map HashFn Hash
  }
  deriving (Show)

{-------------------------------------------------------------------------------
  Utility
-------------------------------------------------------------------------------}

-- | Compute 'FileInfo'
--
-- TODO: Currently this will load the entire input bytestring into memory.
-- We need to make this incremental, by computing the length and all hashes
-- in a single traversal over the input.
fileInfo :: BS.L.ByteString -> FileInfo
fileInfo bs = FileInfo {
      fileInfoLength = FileLength . fromIntegral $ BS.L.length bs
    , fileInfoHashes = Map.fromList [
          (HashFnSHA256, Hash $ show (CH.hashlazy bs :: CH.Digest CH.SHA256))
        ]
    }

-- | Compute 'FileInfo'
computeFileInfo :: IsFileSystemRoot root => Path (Rooted root) -> IO FileInfo
computeFileInfo fp = fileInfo <$> readLazyByteString fp

-- | Compare known file info
--
-- This should be used only when the FileInfo is already known. If we want to
-- compare known FileInfo against a file on disk we should delay until we know
-- have confirmed that the file lengths don't match (see 'verifyFileInfo').
knownFileInfoEqual :: FileInfo -> FileInfo -> Bool
knownFileInfoEqual a b = (==) (fileInfoLength a, fileInfoHashes a)
                              (fileInfoLength b, fileInfoHashes b)

{-------------------------------------------------------------------------------
  JSON
-------------------------------------------------------------------------------}

instance Monad m => ToObjectKey m HashFn where
  toObjectKey HashFnSHA256 = return "sha256"

instance ReportSchemaErrors m => FromObjectKey m HashFn where
  fromObjectKey "sha256" = return HashFnSHA256
  fromObjectKey str      = expected "valid hash function" (Just str)

instance Monad m => ToJSON m FileInfo where
  toJSON FileInfo{..} = mkObject [
        ("length", toJSON fileInfoLength)
      , ("hashes", toJSON fileInfoHashes)
      ]

instance ReportSchemaErrors m => FromJSON m FileInfo where
  fromJSON enc = do
    fileInfoLength <- fromJSField enc "length"
    fileInfoHashes <- fromJSField enc "hashes"
    return FileInfo{..}
