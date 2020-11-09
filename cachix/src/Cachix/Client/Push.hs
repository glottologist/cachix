{-# LANGUAGE DataKinds #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators #-}

{- This is a standalone module so it shouldn't depend on any CLI state like Env -}
module Cachix.Client.Push
  ( -- * Pushing a single path
    pushSingleStorePath,
    PushCache (..),
    PushSecret (..),
    PushStrategy (..),
    defaultWithXzipCompressor,
    defaultWithXzipCompressorWithLevel,
    findPushSecret,

    -- * Pushing a closure of store paths
    pushClosure,
    mapConcurrentlyBounded,
  )
where

import qualified Cachix.API as API
import Cachix.API.Error
import Cachix.API.Signing (fingerprint, passthroughHashSink, passthroughHashSinkB16, passthroughSizeSink)
import qualified Cachix.Client.Config as Config
import Cachix.Client.Exception (CachixException (..))
import Cachix.Client.Secrets
import Cachix.Client.Servant
import Cachix.Client.Store (Store)
import qualified Cachix.Client.Store as Store
import qualified Cachix.Types.ByteStringStreaming
import qualified Cachix.Types.NarInfoCreate as Api
import qualified Cachix.Types.NarInfoHash as NarInfoHash
import Control.Concurrent.Async (mapConcurrently)
import qualified Control.Concurrent.QSem as QSem
import Control.Exception.Safe (MonadMask, throwM)
import Control.Monad.Trans.Resource (ResourceT)
import Control.Retry (RetryPolicy, RetryStatus, exponentialBackoff, limitRetries, recoverAll)
import Crypto.Sign.Ed25519
import qualified Data.ByteString.Base64 as B64
import Data.Coerce (coerce)
import Data.Conduit
import Data.Conduit.Lzma (compress)
import Data.Conduit.Process hiding (env)
import Data.IORef
import qualified Data.Set as Set
import Data.String.Here
import qualified Data.Text as T
import Network.HTTP.Types (status401, status404)
import Protolude
import Servant.API
import Servant.Auth ()
import Servant.Auth.Client
import Servant.Client.Streaming
import Servant.Conduit ()
import System.Environment (lookupEnv)
import qualified System.Nix.Base32

data PushSecret
  = PushToken Token
  | PushSigningKey Token SigningKey

data PushCache
  = PushCache
      { pushCacheName :: Text,
        pushCacheSecret :: PushSecret
      }

data PushStrategy m r
  = PushStrategy
      { -- | Called when a path is already in the cache.
        onAlreadyPresent :: m r,
        onAttempt :: RetryStatus -> Int64 -> m (),
        on401 :: m r,
        onError :: ClientError -> m r,
        onDone :: m r,
        withXzipCompressor :: forall a. (ConduitM ByteString ByteString (ResourceT IO) () -> m a) -> m a,
        omitDeriver :: Bool
      }

defaultWithXzipCompressor :: forall m a. (ConduitM ByteString ByteString (ResourceT IO) () -> m a) -> m a
defaultWithXzipCompressor = ($ compress (Just 2))

defaultWithXzipCompressorWithLevel :: Int -> forall m a. (ConduitM ByteString ByteString (ResourceT IO) () -> m a) -> m a
defaultWithXzipCompressorWithLevel l = ($ compress (Just l))

pushSingleStorePath ::
  (MonadMask m, MonadIO m) =>
  -- | cachix base url, connection manager, see 'Cachix.Client.URI.defaultCachixBaseUrl', 'Servant.Client.mkClientEnv'
  ClientEnv ->
  Store ->
  -- | details for pushing to cache
  PushCache ->
  -- | how to report results, (some) errors, and do some things
  PushStrategy m r ->
  -- | store path
  Text ->
  -- | r is determined by the 'PushStrategy'
  m r
pushSingleStorePath clientEnv _store cache cb storePath = retryAll $ \retrystatus -> do
  let storeHash = fst $ splitStorePath $ toS storePath
      name = pushCacheName cache
  -- Check if narinfo already exists
  res <-
    liftIO $ (`runClientM` clientEnv) $
      API.narinfoHead
        cachixClient
        (getCacheAuthToken cache)
        name
        (NarInfoHash.NarInfoHash storeHash)
  case res of
    Right NoContent -> onAlreadyPresent cb -- we're done as store path is already in the cache
    Left err
      | isErr err status404 -> uploadStorePath clientEnv _store cache cb storePath retrystatus
      | isErr err status401 -> on401 cb
      | otherwise -> onError cb err

getCacheAuthToken :: PushCache -> Token
getCacheAuthToken cache = case pushCacheSecret cache of
  PushToken token -> token
  PushSigningKey token _ -> token

uploadStorePath ::
  (MonadMask m, MonadIO m) =>
  -- | cachix base url, connection manager, see 'Cachix.Client.URI.defaultCachixBaseUrl', 'Servant.Client.mkClientEnv'
  ClientEnv ->
  Store ->
  -- | details for pushing to cache
  PushCache ->
  -- | how to report results, (some) errors, and do some things
  PushStrategy m r ->
  -- | store path
  Text ->
  RetryStatus ->
  -- | r is determined by the 'PushStrategy'
  m r
uploadStorePath clientEnv store cache cb storePath retrystatus = do
  let (storeHash, storeSuffix) = splitStorePath $ toS storePath
      name = pushCacheName cache
  narSizeRef <- liftIO $ newIORef 0
  fileSizeRef <- liftIO $ newIORef 0
  narHashRef <- liftIO $ newIORef ("" :: ByteString)
  fileHashRef <- liftIO $ newIORef ("" :: ByteString)
  normalized <- liftIO $ Store.followLinksToStorePath store $ toS storePath
  pathinfo <- liftIO $ Store.queryPathInfo store normalized
  -- stream store path as xz compressed nar file
  let cmd = proc "nix-store" ["--dump", toS storePath]
      storePathSize :: Int64
      storePathSize = Store.validPathInfoNarSize pathinfo
  onAttempt cb retrystatus storePathSize
  (ClosedStream, stdoutStream, Inherited, cph) <- liftIO $ streamingProcess cmd
  withXzipCompressor cb $ \xzCompressor -> do
    let stream' =
          stdoutStream
            .| passthroughSizeSink narSizeRef
            .| passthroughHashSink narHashRef
            .| xzCompressor
            .| passthroughSizeSink fileSizeRef
            .| passthroughHashSinkB16 fileHashRef
    let subdomain =
          -- TODO: multipart
          if (fromIntegral storePathSize / (1024 * 1024) :: Double) > 100
            then "api"
            else toS name
        newClientEnv =
          clientEnv
            { baseUrl = (baseUrl clientEnv) {baseUrlHost = subdomain <> "." <> baseUrlHost (baseUrl clientEnv)}
            }
    (_ :: NoContent) <-
      liftIO
        $ (`withClientM` newClientEnv)
          (API.createNar cachixClient (getCacheAuthToken cache) name (mapOutput coerce stream'))
        $ escalate
          >=> \NoContent -> do
            exitcode <- waitForStreamingProcess cph
            when (exitcode /= ExitSuccess) $ throwM $ NarStreamingError exitcode $ show cmd
            return NoContent
    (_ :: NoContent) <- liftIO $ do
      narSize <- readIORef narSizeRef
      narHash <- ("sha256:" <>) . System.Nix.Base32.encode <$> readIORef narHashRef
      narHashNix <- Store.validPathInfoNarHash pathinfo
      when (narHash /= toS narHashNix) $ throwM $ NarHashMismatch "Nar hash mismatch between nix-store --dump and nix db"
      fileHash <- readIORef fileHashRef
      fileSize <- readIORef fileSizeRef
      deriver <-
        if omitDeriver cb
          then pure Store.unknownDeriver
          else toS <$> Store.validPathInfoDeriver pathinfo
      referencesPathSet <- Store.validPathInfoReferences pathinfo
      references <- sort <$> Store.traversePathSet (pure . toS) referencesPathSet
      let fp = fingerprint storePath narHash narSize references
          (sig, authToken) = case pushCacheSecret cache of
            PushToken token -> (Nothing, token)
            PushSigningKey token signKey -> (Just $ toS $ B64.encode $ unSignature $ dsign (signingSecretKey signKey) fp, token)
          nic =
            Api.NarInfoCreate
              { Api.cStoreHash = storeHash,
                Api.cStoreSuffix = storeSuffix,
                Api.cNarHash = narHash,
                Api.cNarSize = narSize,
                Api.cFileSize = fileSize,
                Api.cFileHash = toS fileHash,
                Api.cReferences = fmap (T.drop 11) references,
                Api.cDeriver =
                  if deriver == Store.unknownDeriver
                    then deriver
                    else T.drop 11 deriver,
                Api.cSig = sig
              }
      escalate $ Api.isNarInfoCreateValid nic
      -- Upload narinfo with signature
      escalate <=< (`runClientM` clientEnv) $
        API.createNarinfo
          cachixClient
          authToken
          name
          (NarInfoHash.NarInfoHash storeHash)
          nic
    onDone cb

-- Catches all exceptions except skipAsyncExceptions
retryAll :: (MonadIO m, MonadMask m) => (RetryStatus -> m a) -> m a
retryAll = recoverAll defaultRetryPolicy
  where
    defaultRetryPolicy :: RetryPolicy
    defaultRetryPolicy =
      exponentialBackoff 100000 <> limitRetries 3

-- | Push an entire closure
--
-- Note: 'onAlreadyPresent' will be called less often in the future.
pushClosure ::
  (MonadIO m, MonadMask m) =>
  -- | Traverse paths, responsible for bounding parallel processing of paths
  --
  -- For example: @'mapConcurrentlyBounded' 4@
  (forall a b. (a -> m b) -> [a] -> m [b]) ->
  -- | See 'pushSingleStorePath'
  ClientEnv ->
  Store ->
  PushCache ->
  (Text -> PushStrategy m r) ->
  -- | Initial store paths
  [Text] ->
  -- | Every @r@ per store path of the entire closure of store paths
  m [r]
pushClosure traversal clientEnv store pushCache pushStrategy inputStorePaths = do
  -- Get the transitive closure of dependencies
  paths <-
    liftIO $ do
      inputs <- Store.newEmptyPathSet
      for_ inputStorePaths $ \path -> do
        normalized <- Store.followLinksToStorePath store (encodeUtf8 path)
        Store.addToPathSet normalized inputs
      closure <- Store.computeFSClosure store Store.defaultClosureParams inputs
      Store.traversePathSet (pure . toSL) closure
  -- Check what store paths are missing
  missingHashesList <-
    retryAll $ \_ ->
      escalate
        =<< liftIO
          ( (`runClientM` clientEnv) $
              API.narinfoBulk
                cachixClient
                (getCacheAuthToken pushCache)
                (pushCacheName pushCache)
                (fst . splitStorePath <$> paths)
          )
  let missingHashes = Set.fromList missingHashesList
      missingPaths = filter (\path -> Set.member (fst (splitStorePath path)) missingHashes) paths
  traversal (\path -> retryAll $ \retrystatus -> uploadStorePath clientEnv store pushCache (pushStrategy path) path retrystatus) missingPaths

-- TODO: move to a separate module specific to cli

-- | Find auth token or signing key in the 'Config' or environment variable
findPushSecret ::
  Maybe Config.Config ->
  -- | Cache name
  Text ->
  -- | Secret key or exception
  IO PushSecret
findPushSecret config name = do
  maybeSigningKeyEnv <- toS <<$>> lookupEnv "CACHIX_SIGNING_KEY"
  maybeAuthToken <- Config.getAuthTokenMaybe config
  let maybeSigningKeyConfig = case config of
        Nothing -> Nothing
        Just cfg -> Config.secretKey <$> head (getBinaryCache cfg)
  case maybeSigningKeyEnv <|> maybeSigningKeyConfig of
    Just signingKey -> escalateAs FatalError $ PushSigningKey (fromMaybe (Token "") maybeAuthToken) <$> parseSigningKeyLenient signingKey
    Nothing -> case maybeAuthToken of
      Just authToken -> return $ PushToken authToken
      Nothing -> throwIO $ NoSigningKey msg
  where
    -- we reverse list of caches to prioritize keys added as last
    getBinaryCache c = filter (\bc -> Config.name bc == name) $ reverse $ Config.binaryCaches c
    msg :: Text
    msg =
      [iTrim|
Neither auth token nor signing key are present.

They are looked up via $CACHIX_AUTH_TOKEN and $CACHIX_SIGNING_KEY,
and if missing also looked up from ~/.config/cachix/cachix.dhall

Read https://mycache.cachix.org for instructions how to push to your binary cache.
    |]

mapConcurrentlyBounded :: Traversable t => Int -> (a -> IO b) -> t a -> IO (t b)
mapConcurrentlyBounded bound action items = do
  qs <- QSem.newQSem bound
  let wrapped x = bracket_ (QSem.waitQSem qs) (QSem.signalQSem qs) (action x)
  mapConcurrently wrapped items

-------------------
-- Private terms --
splitStorePath :: Text -> (Text, Text)
splitStorePath storePath =
  (T.take 32 (T.drop 11 storePath), T.drop 44 storePath)
