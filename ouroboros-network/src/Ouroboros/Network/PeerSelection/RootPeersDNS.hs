{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}

module Ouroboros.Network.PeerSelection.RootPeersDNS (
    -- * DNS based provider for local root peers
    localRootPeersProvider,
    DomainAddress (..),
    TraceLocalRootPeers(..),

    -- * DNS based provider for public root peers
    publicRootPeersProvider,
    TracePublicRootPeers(..),

    -- * DNS type re-exports
    DNS.ResolvConf,
    DNS.Domain,
    DNS.TTL,
    IPv4,
  ) where

import           Data.Word (Word32)
import           Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Set as Set
import           Data.Set (Set)
import qualified Data.Map.Strict as Map
import           Data.Map.Strict (Map)

import           Control.Exception (Exception (..), IOException)
import           Control.Monad (when, unless)
import           Control.Monad.Class.MonadAsync
-- TODO: use `MonadSTM.Strict`
import           Control.Monad.Class.MonadSTM
import           Control.Monad.Class.MonadTime
import           Control.Monad.Class.MonadTimer
import           Control.Monad.Class.MonadThrow
import           Control.Tracer (Tracer(..), contramap, traceWith)

import           Data.Time (UTCTime)
import           System.Directory (getModificationTime)

import           Data.IP (IPv4)
import qualified Data.IP as IP
import           Network.DNS (DNSError)
import qualified Network.DNS as DNS
import qualified Network.Socket as Socket

import           Ouroboros.Network.PeerSelection.Types


-- | A product of a 'DNS.Domain' and 'Socket.PortNumber'.  After resolving the
-- domain we will use the 'Socket.PortNumber' to form 'Socket.SockAddr'.
--
data DomainAddress = DomainAddress {
    daDomain     :: !DNS.Domain,
    daPortNumber :: !Socket.PortNumber
  }
  deriving (Show, Eq, Ord)


-----------------------------------------------
-- Resource
--

-- | Evolving resource; We use it to reinitialise the dns library if the
-- `/etc/resolv.conf` file was modified.
--
data Resource err a = Resource {
    withResource :: IO (Either err a, Resource err a)
  }

-- | Like 'withResource' but retries untill success.
--
withResource' :: Tracer IO err
              -> NonEmpty DiffTime
              -- ^ delays between each re-try
              -> Resource err a
              -> IO (a, Resource err a)
withResource' tracer delays0 = go delays0
  where
    dropHead :: NonEmpty a -> NonEmpty a
    dropHead as@(_ :| [])  = as
    dropHead (_ :| a : as) = a :| as

    go !delays resource = do
      er <- withResource resource
      case er of
        (Left err, resource') -> do
          traceWith tracer err
          threadDelay (NonEmpty.head delays)
          withResource' tracer (dropHead delays) resource'
        (Right r, resource') ->
          pure (r, resource')


constantResource :: a -> Resource err a
constantResource a = Resource (pure (Right a, constantResource a))

data DNSorIOError
    = DNSError !DNSError
    | IOError  !IOException
  deriving Show

instance Exception DNSorIOError where


-- | Strict version of 'Maybe' adjusted to the needs ot
-- 'asyncResolverResource'.
--
data TimedResolver
    = TimedResolver !DNS.Resolver !UTCTime
    | NoResolver

-- |
--
-- TODO: it could be useful for `publicRootPeersProvider`.
--
resolverResource :: DNS.ResolvConf -> IO (Resource DNSorIOError DNS.Resolver)
resolverResource resolvConf = do
    rs <- DNS.makeResolvSeed resolvConf
    case DNS.resolvInfo resolvConf of
      DNS.RCFilePath filePath ->
        pure $ go filePath NoResolver

      _ -> DNS.withResolver rs (pure . constantResource)

  where
    handlers :: FilePath
             -> TimedResolver
             -> [Handler IO
                  ( Either DNSorIOError DNS.Resolver
                  , Resource DNSorIOError DNS.Resolver)]
    handlers filePath tr =
      [ Handler $
          \(err :: IOException) ->
            pure (Left (IOError err), go filePath tr)
      , Handler $
          \(err :: DNS.DNSError) ->
              pure (Left (DNSError err), go filePath tr)
      ]

    go :: FilePath
       -> TimedResolver
       -> Resource DNSorIOError DNS.Resolver
    go filePath tr@NoResolver = Resource $
      do
        modTime <- getModificationTime filePath
        rs <- DNS.makeResolvSeed resolvConf
        DNS.withResolver rs
          (\resolver ->
            pure (Right resolver, go filePath (TimedResolver resolver modTime)))
      `catches` handlers filePath tr

    go filePath tr@(TimedResolver resolver modTime) = Resource $
      do
        modTime' <- getModificationTime filePath
        if modTime' <= modTime
          then pure (Right resolver, go filePath (TimedResolver resolver modTime))
          else do
            rs <- DNS.makeResolvSeed resolvConf
            DNS.withResolver rs
              (\resolver' ->
                pure (Right resolver', go filePath (TimedResolver resolver' modTime')))
      `catches` handlers filePath tr


-- | `Resource` which passes the 'DNS.Resolver' through a 'TVar'.  Better than
-- 'resolverResource' when using in multiple threads.
--
asyncResolverResource :: DNS.ResolvConf -> IO (Resource DNSorIOError DNS.Resolver)
asyncResolverResource resolvConf =
    case DNS.resolvInfo resolvConf of
      DNS.RCFilePath filePath -> do
        resourceVar <- newTVarM NoResolver
        pure $ go filePath resourceVar
      _ -> do
        rs <- DNS.makeResolvSeed resolvConf
        DNS.withResolver rs (pure . constantResource)
  where
    handlers :: FilePath -> TVar IO TimedResolver
             -> [Handler IO
                  ( Either DNSorIOError DNS.Resolver
                  , Resource DNSorIOError DNS.Resolver)]
    handlers filePath resourceVar =
      [ Handler $
          \(err :: IOException) ->
            pure (Left (IOError err), go filePath resourceVar)
      , Handler $
          \(err :: DNS.DNSError) ->
            pure (Left (DNSError err), go filePath resourceVar)
      ]

    go :: FilePath -> TVar IO TimedResolver
       -> Resource DNSorIOError DNS.Resolver
    go filePath resourceVar = Resource $ do
      r <- atomically (readTVar resourceVar)
      case r of
        NoResolver ->
          do
            modTime <- getModificationTime filePath
            rs <- DNS.makeResolvSeed resolvConf
            DNS.withResolver rs $ \resolver -> do
              atomically (writeTVar resourceVar (TimedResolver resolver modTime))
              pure (Right resolver, go filePath resourceVar)
          `catches` handlers filePath resourceVar

        TimedResolver resolver modTime ->
          do
            modTime' <- getModificationTime filePath
            if modTime' <= modTime
                then pure (Right resolver, go filePath resourceVar)
                else do
                  rs <- DNS.makeResolvSeed resolvConf
                  DNS.withResolver rs $ \resolver' -> do
                    atomically (writeTVar resourceVar (TimedResolver resolver' modTime'))
                    pure (Right resolver', go filePath resourceVar)
          `catches` handlers filePath resourceVar


-----------------------------------------------
-- local root peer set provider based on DNS
--

data TraceLocalRootPeers =
       TraceLocalRootDomains [(DomainAddress, PeerAdvertise)]
     | TraceLocalRootWaiting DomainAddress DiffTime
     | TraceLocalRootResult  DomainAddress [(IPv4, DNS.TTL)]
     | TraceLocalRootFailure DomainAddress DNSorIOError
       --TODO: classify DNS errors, config error vs transitory
  deriving Show


-- |
--
-- This action typically runs indefinitely, but can terminate successfully in
-- corner cases where there is nothing to do.
--
localRootPeersProvider :: Tracer IO TraceLocalRootPeers
                       -> DNS.ResolvConf
                       -> TVar IO (Map DomainAddress (Map Socket.SockAddr PeerAdvertise))
                       -> [(DomainAddress, PeerAdvertise)]
                       -> IO ()
localRootPeersProvider tracer resolvConf rootPeersVar domains = do
    traceWith tracer (TraceLocalRootDomains domains)
    unless (null domains) $ do
      rr <- asyncResolverResource resolvConf
      withAsyncAll (map (monitorDomain rr) domains) $ \asyncs ->
        waitAny asyncs >> return ()
  where
    monitorDomain :: Resource DNSorIOError DNS.Resolver -> (DomainAddress, PeerAdvertise) -> IO ()
    monitorDomain rr0 (domain@DomainAddress {daDomain, daPortNumber}, advertisePeer) =
        go rr0 0
      where
        go :: Resource DNSorIOError DNS.Resolver -> DiffTime -> IO ()
        go !rr !ttl = do
          when (ttl > 0) $ do
            traceWith tracer (TraceLocalRootWaiting domain ttl)
            threadDelay ttl

          (resolver, rrNext) <-
            withResource' (TraceLocalRootFailure domain `contramap` tracer)
                          (1 :| [3, 6, 9, 12])
                          rr
          reply <- lookupAWithTTL resolver daDomain
          case reply of
            Left  err -> do
              traceWith tracer (TraceLocalRootFailure domain (DNSError err))
              go rrNext (ttlForDnsError err ttl)

            Right results -> do
              traceWith tracer (TraceLocalRootResult domain results)
              atomically $ do
                rootPeers <- readTVar rootPeersVar
                let resultsMap :: Map Socket.SockAddr PeerAdvertise
                    resultsMap = Map.fromList [ ( Socket.SockAddrInet
                                                    daPortNumber
                                                    (IP.toHostAddress addr)
                                                , advertisePeer)
                                              | (addr, _ttl) <- results ]
                    rootPeers' :: Map DomainAddress (Map Socket.SockAddr PeerAdvertise)
                    rootPeers' = Map.insert domain resultsMap rootPeers

                -- Only overwrite if it changed:
                when (Map.lookup domain rootPeers /= Just resultsMap) $
                  writeTVar rootPeersVar rootPeers'

              go rrNext (ttlForResults (map snd results))


---------------------------------------------
-- Public root peer set provider using DNS
--

data TracePublicRootPeers =
       TracePublicRootDomains [DomainAddress]
     | TracePublicRootResult  DNS.Domain [(IPv4, DNS.TTL)]
     | TracePublicRootFailure DNS.Domain DNS.DNSError
       --TODO: classify DNS errors, config error vs transitory
  deriving Show

-- |
--
publicRootPeersProvider :: Tracer IO TracePublicRootPeers
                        -> DNS.ResolvConf
                        -> [DomainAddress]
                        -> ((Int -> IO (Set Socket.SockAddr, DiffTime)) -> IO a)
                        -> IO a
publicRootPeersProvider tracer resolvConf domains action = do
    traceWith tracer (TracePublicRootDomains domains)
    rr <- resolverResource resolvConf
    resourceVar <- newTVarM rr
    action (requestPublicRootPeers resourceVar)
  where
    requestPublicRootPeers :: TVar IO (Resource DNSorIOError DNS.Resolver)
                           -> Int -> IO (Set Socket.SockAddr, DiffTime)
    requestPublicRootPeers resourceVar _numRequested = do
        rr <- atomically $ readTVar resourceVar
        (er, rr') <- withResource rr
        atomically $ writeTVar resourceVar rr'
        case er of
          Left (DNSError err) -> throwM err
          Left (IOError  err) -> throwM err
          Right resolver -> do
            let lookups =
                  [ lookupAWithTTL resolver daDomain
                  |  DomainAddress {daDomain} <- domains ]
            -- The timeouts here are handled by the 'lookupAWithTTL'. They're
            -- configured via the DNS.ResolvConf resolvTimeout field and defaults
            -- to 3 sec.
            results <- withAsyncAll lookups (atomically . mapM waitSTM)
            sequence_
              [ traceWith tracer $ case result of
                  Left  dnserr -> TracePublicRootFailure daDomain dnserr
                  Right ipttls -> TracePublicRootResult  daDomain ipttls
              | (DomainAddress {daDomain}, result) <- zip domains results ]
            let successes = [ (Socket.SockAddrInet daPortNumber (IP.toHostAddress ip), ipttl)
                            | (Right ipttls, DomainAddress {daPortNumber}) <- (zip results domains)
                            , (ip, ipttl) <- ipttls
                            ]
                !ips      = Set.fromList  (map fst successes)
                !ttl      = ttlForResults (map snd successes)
            -- If all the lookups failed we'll return an empty set with a minimum
            -- TTL, and the governor will invoke its exponential backoff.
            return (ips, ttl)


---------------------------------------------
-- Shared utils
--

-- | Like 'DNS.lookupA' but also return the TTL for the results.
--
lookupAWithTTL :: DNS.Resolver
               -> DNS.Domain
               -> IO (Either DNS.DNSError [(IPv4, DNS.TTL)])
lookupAWithTTL resolver domain = do
    reply <- DNS.lookupRaw resolver domain DNS.A
    case reply of
      Left  err -> return (Left err)
      Right ans -> return (DNS.fromDNSMessage ans selectA)
      --TODO: we can get the SOA TTL on NXDOMAIN here if we want to
  where
    selectA DNS.DNSMessage { DNS.answer } =
      [ (addr, ttl)
      | DNS.ResourceRecord {
          DNS.rdata = DNS.RD_A addr,
          DNS.rrttl = ttl
        } <- answer
      ]

-- | Policy for TTL for positive results
ttlForResults :: [DNS.TTL] -> DiffTime

-- This case says we have a successful reply but there is no answer.
-- This covers for example non-existent TLDs since there is no authority
-- to say that they should not exist.
ttlForResults []   = ttlForDnsError DNS.NameError 0
ttlForResults ttls = clipTTLBelow
                   . clipTTLAbove
                   . (fromIntegral :: Word32 -> DiffTime)
                   $ maximum ttls

-- | Policy for TTL for negative results
-- Cache negative response for 3hrs
-- Otherwise, use exponential backoff, up to a limit
ttlForDnsError :: DNS.DNSError -> DiffTime -> DiffTime
ttlForDnsError DNS.NameError _ = 10800
ttlForDnsError _           ttl = clipTTLAbove (ttl * 2 + 5)

-- | Limit insane TTL choices.
clipTTLAbove, clipTTLBelow :: DiffTime -> DiffTime
clipTTLBelow = max 60     -- between 1min
clipTTLAbove = min 86400  -- and 24hrs

withAsyncAll :: [IO a] -> ([Async IO a] -> IO b) -> IO b
withAsyncAll xs0 action = go [] xs0
  where
    go as []     = action as
    go as (x:xs) = withAsync x (\a -> go (a:as) xs)


---------------------------------------------
-- Examples
--
{-
exampleLocal :: [DomainAddress] -> IO ()
exampleLocal domains = do
      rootPeersVar <- newTVarM Map.empty
      withAsync (observer rootPeersVar Map.empty) $ \_ ->
        provider rootPeersVar
  where
    provider rootPeersVar =
      localRootPeersProvider
        (showTracing stdoutTracer)
        DNS.defaultResolvConf
        rootPeersVar
        (map (\d -> (d, DoAdvertisePeer)) domains)

    observer :: (Eq a, Show a) => TVar IO a -> a -> IO ()
    observer var fingerprint = do
      x <- atomically $ do
        x <- readTVar var
        check (x /= fingerprint)
        return x
      traceWith (showTracing stdoutTracer) x
      observer var x

examplePublic :: [DomainAddress] -> IO ()
examplePublic domains = do
    publicRootPeersProvider
      (showTracing stdoutTracer)
      DNS.defaultResolvConf
      domains $ \requestPublicRootPeers ->
        forever $ do
          (ips, ttl) <- requestPublicRootPeers 42
          traceWith (showTracing stdoutTracer) (ips, ttl)
          threadDelay ttl
-}
