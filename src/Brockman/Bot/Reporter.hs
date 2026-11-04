{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ViewPatterns #-}

module Brockman.Bot.Reporter where

import Brockman.Bot
import Brockman.Feed
import Brockman.Types
import Brockman.Util
import Data.IORef
import Control.Concurrent (forkIO)
import Control.Concurrent.QSem (QSem, newQSem, signalQSem, waitQSem)
import Data.Int (Int64)
import Control.Concurrent.Chan
import Control.Concurrent.MVar
import qualified Control.Exception as E
import Control.Lens
import Control.Monad
import Control.Monad.IO.Class (MonadIO, liftIO)
import qualified Data.ByteString as BS (ByteString)
import qualified Data.ByteString.Lazy as BL (length, toStrict)
import qualified Data.Cache.LRU as LRU
import Data.Conduit
import Data.Foldable
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe, maybeToList)
import qualified Data.Set as Set
import qualified Data.Text as T (Text, breakOnEnd, intercalate, length, null, pack, splitOn, takeWhile, toLower, unpack, unwords)
import Data.Time.Clock (getCurrentTime)
import Network.HTTP.Client (HttpException (HttpExceptionRequest), HttpExceptionContent (ConnectionFailure, StatusCodeException))
import Network.HTTP.Client.TLS (getGlobalManager)
import qualified Network.IRC.Conduit as IRC
import Network.Socket (HostName)
import Network.Wreq (FormParam ((:=)), defaults, getWith, header, manager, postWith, responseBody, responseStatus, statusCode, statusMessage)
import Safe (readMay)
import System.Log.Logger
import System.Random (randomRIO)
import System.Timeout (timeout)

defaultTick :: Integer
defaultTick = 300 -- seconds

data ReporterMessage
  = Exception T.Text
  | InfoRequested Channel
  | Invited Channel
  | Kicked Channel
  | Killed
  | MOTD
  | Messaged BS.ByteString T.Text
  | NewFeedItem FeedItem
  | Pinged (IRC.ServerName BS.ByteString)
  | SetUrl Channel URL
  | Subscribe Channel
  | Tick Channel (Maybe Integer)
  | Unsubscribe Channel
  deriving (Show)

-- return the current config or kill thread if the key is not present
withCurrentBotConfig :: (MonadIO m) => Nick -> MVar BrockmanConfig -> (BotConfig -> m ()) -> m ()
withCurrentBotConfig nick configMVar handler = do
  BrockmanConfig {configBots} <- liftIO $ readMVar configMVar
  maybe (liftIO suicide) handler $ M.lookup nick configBots

reporterThread :: FetchLimits -> MVar BrockmanConfig -> Nick -> IO ()
reporterThread limits configMVar nick = do
  config@BrockmanConfig {configChannel, configDefaultDelay} <- readMVar configMVar
  withIrcConnection config listen $ \chan ->
    withCurrentBotConfig nick configMVar $ \BotConfig {botExtraChannels} -> do
      tickRef <- liftIO $ newIORef (fromMaybe defaultTick configDefaultDelay)
      void $ liftIO $ forkIO $ feedThread limits nick tickRef configMVar True Nothing (writeChan chan)
      let initialChannels = Set.insert configChannel (fromMaybe Set.empty botExtraChannels)
      handshake nick initialChannels
      deafen nick
      forever $ react tickRef config chan
  where
    react tickRef (BrockmanConfig{configShowEntryDate, configChannel, configShortener, configNoPrivmsg}) chan =
      withCurrentBotConfig nick configMVar $ \BotConfig {botFeed, botDelay, botExtraChannels} -> do
        let currentChannels = Set.insert configChannel (fromMaybe Set.empty botExtraChannels)
        command <- liftIO (readChan chan)
        debug nick $ show command
        case command of
          Pinged serverName -> do
            yield $ IRC.Pong serverName
          NewFeedItem item -> do
            item' <- liftIO $ maybe (pure item) (\url -> item `shortenWith` T.unpack url) configShortener
            let message = display (fromMaybe False configShowEntryDate) item'
            if fromMaybe False configNoPrivmsg
              then broadcastNotice currentChannels message
              else broadcast currentChannels [message]
          Exception message -> broadcastNotice currentChannels message
          Messaged _ _ -> return ()
          Subscribe user -> do
            liftIO $ update configMVar $ configBotsL . at nick . mapped . botExtraChannelsL %~ insert user
            notice nick $ show user <> " has subscribed"
            broadcast (Set.singleton user) ["subscribed to " <> T.pack (show nick)]
          Unsubscribe user -> do
            liftIO $ update configMVar $ configBotsL . at nick . mapped . botExtraChannelsL %~ delete user
            notice nick $ show user <> " has unsubscribed"
            broadcast (Set.singleton user) ["unsubscribed from " <> T.pack (show nick)]
          InfoRequested channel -> do
            theTick <- liftIO $ readIORef tickRef
            broadcast (Set.singleton channel) $
              pure $
                T.unwords $
                  [ "I serve the feed <" <> botFeed <> ">",
                    "to " <> T.intercalate ", " (map (decodeUtf8 . encode) (toList currentChannels)) <> ".",
                    "Refresh rate: " <> T.pack (show theTick) <> "s"
                  ]
                    ++ maybeToList (("configured " <>) . (<> "s") . T.pack . show <$> botDelay)
          Tick channel tick -> do
            liftIO $ update configMVar $ configBotsL . at nick . mapped . botDelayL .~ tick
            notice nick $ T.unpack (decodeUtf8 (encode channel)) <> " changed tick speed to " <> show tick
            broadcastNotice (Set.insert channel currentChannels) $ T.pack (show nick) <> " @ " <> T.pack (maybe "auto" ((<> " seconds") . show) tick) <> " (changed by " <> decodeUtf8 (encode channel) <> ")"
          SetUrl channel url -> do
            liftIO $ update configMVar $ configBotsL . at nick . mapped . botFeedL .~ url
            notice nick $ T.unpack (decodeUtf8 (encode channel)) <> " set url to " <> T.unpack url
            broadcastNotice (Set.insert channel currentChannels) $ T.pack (show nick) <> " -> " <> url <> " (changed by " <> decodeUtf8 (encode channel) <> ")"
          Killed -> do
            liftIO $ update configMVar $ configBotsL . at nick .~ Nothing
            notice nick "killed"
          Kicked channel -> do
            liftIO $ update configMVar $ configBotsL . at nick . mapped . botExtraChannelsL %~ delete channel
            notice nick $ "kicked from " <> show channel
          Invited channel -> do
            liftIO $ update configMVar $ configBotsL . at nick . mapped . botExtraChannelsL %~ insert channel
            notice nick $ "invited to " <> show channel
            yield $ IRC.Join $ encode channel
          MOTD -> do
            notice nick ("handshake, joining " <> show currentChannels)
            mapM_ (yield . IRC.Join . encode) currentChannels
    listen chan =
      forever $
        await >>= \case
          Just (Right (IRC.Event _ _ (IRC.Ping s _))) -> liftIO $ writeChan chan (Pinged s)
          Just (Right (IRC.Event _ _ (IRC.Invite channel _))) ->
            liftIO $ writeChan chan $ Invited $ decode channel
          Just (Right (IRC.Event _ _ (IRC.Kick channel nick' _)))
            | nick == decode nick' ->
                liftIO $ writeChan chan $ Kicked $ decode channel
          -- 376 is RPL_ENDOFMOTD
          Just (Right (IRC.Event _ _ (IRC.Numeric 376 _))) ->
            liftIO $ writeChan chan MOTD
          Just (Right (IRC.Event _ (IRC.User user) (IRC.Privmsg _ (Right message)))) ->
            liftIO $ writeChan chan $ case bsWords message of
              ["die"] -> Killed
              ["subscribe"] -> Subscribe (decode user)
              ["unsubscribe"] -> Unsubscribe (decode user)
              ["info"] -> InfoRequested (decode user)
              ["set-url", decodeUtf8 -> url] -> SetUrl (decode user) url
              ["tick", decodeUtf8 -> tickString] -> Tick (decode user) $ readMay $ T.unpack tickString
              _ -> Messaged user (decodeUtf8 message)
          _ -> pure ()

-- a reporter without its own IRC connection: items go out through the controller's connection
relayReporter :: FetchLimits -> MVar BrockmanConfig -> ([IRC.IrcMessage] -> IO ()) -> Nick -> IO ()
relayReporter limits configMVar send nick = do
  BrockmanConfig {configDefaultDelay} <- readMVar configMVar
  tickRef <- newIORef (fromMaybe defaultTick configDefaultDelay)
  feedThread limits nick tickRef configMVar True Nothing $ \message ->
    -- a removed bot stops here instead of posting its last items
    withCurrentBotConfig nick configMVar $ \_ -> do
      config@BrockmanConfig {configShowEntryDate, configShortener, configNoPrivmsg} <- readMVar configMVar
      let suffix = fromMaybe "" (configRelaySuffix config)
          channels = botChannels nick config
      case message of
        NewFeedItem item -> do
          item' <- maybe (pure item) (\url -> item `shortenWith` T.unpack url) configShortener
          let text = display (fromMaybe False configShowEntryDate) item'
          send $ (if fromMaybe False configNoPrivmsg then relayNotice else relay) suffix nick channels text
        Exception text -> send $ relayNotice suffix nick channels text
        _ -> pure ()

getFeed :: URL -> IO (Either T.Text (Integer, [FeedItem]))
getFeed url = do
  -- one shared connection manager: wreq's default builds a new one (and loads the CA store) per request
  httpManager <- getGlobalManager
  let options = defaults & manager .~ Right httpManager & header "Accept" .~ ["application/atom+xml", "application/rss+xml", "*/*"]
  timeout (100 * second) (E.try (getWith options (T.unpack url))) >>= \case
    Nothing ->
      return (Left "Timeout")
    Just (Left exception) ->
      let mircRed text = "\ETX4,99" <> text <> "\ETX" -- ref https://www.mirc.com/colors.html
          message = mircRed $ case exception of
            HttpExceptionRequest _ (StatusCodeException response _) ->
              T.unwords [T.pack $ show $ response ^. responseStatus . statusCode, decodeUtf8 $ response ^. responseStatus . statusMessage]
            HttpExceptionRequest _ (ConnectionFailure _) -> "Connection failure"
            HttpExceptionRequest _ exceptionContent -> T.pack $ show exceptionContent
            _ -> T.pack $ show exception
       in return $ Left message
    Just (Right response)
      | BL.length body > maxFeedBytes -> return $ Left "Feed too large"
      | otherwise -> do
          now <- liftIO getCurrentTime
          ParsedFeed {parsedItems, parsedTimes} <- parseFeed (BL.toStrict body)
          return $
            if null parsedItems
              then Left "Feed is empty"
              else Right (fromMaybe defaultTick (feedEntryDelta now parsedTimes), parsedItems)
      where
        body = response ^. responseBody
  where
    second = 10 ^ (6 :: Int)

-- the body is held in memory while it is parsed; the largest real feeds are ~20 MB
maxFeedBytes :: Int64
maxFeedBytes = 32 * 1024 * 1024

-- Fetches in flight: at most fetchConcurrency overall and domainConcurrency per domain group. Shared hosts throttle
-- a client fetching many of their sites at once (bearblog.dev answered 404 when ~2000 of its blogs started together).
data FetchLimits = FetchLimits
  { fetchSlots :: QSem,
    domainSlots :: MVar (M.Map T.Text QSem)
  }

domainConcurrency :: Int
domainConcurrency = 4

newFetchLimits :: Int -> IO FetchLimits
newFetchLimits concurrency = FetchLimits <$> newQSem (max 1 concurrency) <*> newMVar M.empty

withFetchSlot :: FetchLimits -> URL -> IO a -> IO a
withFetchSlot FetchLimits {fetchSlots, domainSlots} url action = do
  domain <- modifyMVar domainSlots $ \slots -> case M.lookup group slots of
    Just slot -> pure (slots, slot)
    Nothing -> do
      slot <- newQSem domainConcurrency
      pure (M.insert group slot slots, slot)
  -- the domain slot first, so fetches waiting for a busy domain do not hold global slots
  E.bracket_ (waitQSem domain) (signalQSem domain) $
    E.bracket_ (waitQSem fetchSlots) (signalQSem fetchSlots) action
  where
    group = domainGroup url

-- the registered domain of a feed URL, roughly: blog.example.com and x.bearblog.dev -> example.com, bearblog.dev;
-- one label more under country suffixes like co.uk
domainGroup :: URL -> T.Text
domainGroup url = T.intercalate "." (drop (length labels - keep) labels)
  where
    host = T.toLower $ T.takeWhile (`notElem` ("/:?#" :: [Char])) $ snd $ T.breakOnEnd "://" url
    labels = filter (not . T.null) (T.splitOn "." host)
    keep = case reverse labels of
      tld : second : _ : _ | T.length tld == 2, second `elem` ["co", "com", "org", "net", "ac", "gov", "edu", "ne", "or"] -> 3
      _ -> 2

feedThread :: FetchLimits -> Nick -> IORef Integer -> MVar BrockmanConfig -> Bool -> Maybe LRU -> (ReporterMessage -> IO ()) -> IO ()
feedThread limits nick tickRef configMVar isFirstTime lru emit =
  withCurrentBotConfig nick configMVar $ \BotConfig {botDelay, botFeed} -> do
    maxStartDelay <- configMaxStartDelay <$> readMVar configMVar
    notifyErrors <- configNotifyErrors <$> readMVar configMVar
    liftIO $
      when isFirstTime $ do
        randomDelay <- randomRIO (0, fromMaybe 60 maxStartDelay)
        debug nick $ "sleep " <> show randomDelay
        sleepSeconds randomDelay
    debug nick ("fetch " <> T.unpack botFeed)
    feedResult <- liftIO $ withFetchSlot limits botFeed $ getFeed botFeed
    (newTick, newLRU) <- case feedResult of
      Left message -> do
        error' nick $ "exception: " <> T.unpack message
        when (fromMaybe True notifyErrors) $ emit $ Exception $ message <> " — " <> botFeed
        oldTick <- readIORef tickRef
        debug nick $ "exponential backoff: " <> show oldTick
        return
          ( oldTick * 2 -- exponential backoff
          , lru
          )
      Right (newTick, feedItems) -> do
        debug nick $ "got new tick: " <> show newTick
        let (lru', items) = deduplicate lru feedItems
        unless isFirstTime $ mapM_ (emit . NewFeedItem) items
        return (newTick, Just lru')
    tick <- scatterTick $ max 1 $ min 86400 $ fromMaybe newTick botDelay
    writeIORef tickRef tick
    debug nick $ "lrusize: " <> show (maybe 0 (fromMaybe 0 . LRU.maxSize) newLRU)
    notice nick $ "tick " <> show tick <> " seconds"
    liftIO $ sleepSeconds tick
    feedThread limits nick tickRef configMVar False newLRU emit
  where
    scatterTick x = (+) (x `div` 2) <$> randomRIO (0, x `div` 2)

shortenWith :: FeedItem -> HostName -> IO FeedItem
item `shortenWith` url = do
  debugM "brockman" ("Shortening " <> show item <> " with " <> show url)
  E.try (postWith defaults url ["uri" := itemLink item]) <&> \case
    Left (E.SomeException _) -> item
    Right response -> item {itemLink = decodeUtf8 $ BL.toStrict $ response ^. responseBody}
