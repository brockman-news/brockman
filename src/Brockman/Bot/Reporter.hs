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
import Control.Concurrent.Chan
import Control.Concurrent.MVar
import qualified Control.Exception as E
import Control.Lens
import Control.Monad
import Control.Monad.IO.Class (MonadIO, liftIO)
import qualified Data.ByteString as BS (ByteString)
import qualified Data.ByteString.Lazy as BL (toStrict)
import qualified Data.Cache.LRU as LRU
import Data.Conduit
import Data.Foldable
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe, maybeToList)
import qualified Data.Set as Set
import qualified Data.Text as T (Text, intercalate, pack, unpack, unwords)
import Data.Time.Clock (getCurrentTime)
import Network.HTTP.Client (HttpException (HttpExceptionRequest), HttpExceptionContent (ConnectionFailure, StatusCodeException))
import qualified Network.IRC.Conduit as IRC
import Network.Socket (HostName)
import Network.Wreq (FormParam ((:=)), defaults, getWith, header, postWith, responseBody, responseStatus, statusCode, statusMessage)
import Safe (readMay)
import System.Log.Logger
import System.Random (randomRIO)
import System.Timeout (timeout)
import Text.Feed.Import (parseFeedSource)

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

reporterThread :: MVar BrockmanConfig -> Nick -> IO ()
reporterThread configMVar nick = do
  config@BrockmanConfig {configChannel, configDefaultDelay} <- readMVar configMVar
  withIrcConnection config listen $ \chan ->
    withCurrentBotConfig nick configMVar $ \BotConfig {botExtraChannels} -> do
      tickRef <- liftIO $ newIORef (fromMaybe defaultTick configDefaultDelay)
      void $ liftIO $ forkIO $ feedThread nick tickRef configMVar True Nothing chan
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

getFeed :: URL -> IO (Either T.Text (Integer, [FeedItem]))
getFeed url =
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
    Just (Right response) -> do
      now <- liftIO getCurrentTime
      let feed = parseFeedSource $ response ^. responseBody
          delta = feedEntryDelta now =<< feed
          feedItems = feedToItems feed
      return $ if null feedItems
        then Left "Feed is empty"
        else Right (fromMaybe defaultTick delta, feedItems)
  where
    options = defaults & header "Accept" .~ ["application/atom+xml", "application/rss+xml", "*/*"]
    second = 10 ^ (6 :: Int)

feedThread :: Nick -> IORef Integer -> MVar BrockmanConfig -> Bool -> Maybe LRU -> Chan ReporterMessage -> IO ()
feedThread nick tickRef configMVar isFirstTime lru chan =
  withCurrentBotConfig nick configMVar $ \BotConfig {botDelay, botFeed} -> do
    maxStartDelay <- configMaxStartDelay <$> readMVar configMVar
    notifyErrors <- configNotifyErrors <$> readMVar configMVar
    liftIO $
      when isFirstTime $ do
        randomDelay <- randomRIO (0, fromMaybe 60 maxStartDelay)
        debug nick $ "sleep " <> show randomDelay
        sleepSeconds randomDelay
    debug nick ("fetch " <> T.unpack botFeed)
    feedResult <- liftIO $ getFeed botFeed
    (newTick, newLRU) <- case feedResult of
      Left message -> do
        error' nick $ "exception: " <> T.unpack message
        when (fromMaybe True notifyErrors) $ writeChan chan $ Exception $ message <> " — " <> botFeed
        oldTick <- readIORef tickRef
        debug nick $ "exponential backoff: " <> show oldTick
        return
          ( oldTick * 2 -- exponential backoff
          , lru
          )
      Right (newTick, feedItems) -> do
        debug nick $ "got new tick: " <> show newTick
        let (lru', items) = deduplicate lru feedItems
        unless isFirstTime $ writeList2Chan chan $ map NewFeedItem items
        return (newTick, Just lru')
    tick <- scatterTick $ max 1 $ min 86400 $ fromMaybe newTick botDelay
    writeIORef tickRef tick
    debug nick $ "lrusize: " <> show (maybe 0 (fromMaybe 0 . LRU.maxSize) newLRU)
    notice nick $ "tick " <> show tick <> " seconds"
    liftIO $ sleepSeconds tick
    feedThread nick tickRef configMVar False newLRU chan
  where
    scatterTick x = (+) (x `div` 2) <$> randomRIO (0, x `div` 2)

shortenWith :: FeedItem -> HostName -> IO FeedItem
item `shortenWith` url = do
  debugM "brockman" ("Shortening " <> show item <> " with " <> show url)
  E.try (postWith defaults url ["uri" := itemLink item]) <&> \case
    Left (E.SomeException _) -> item
    Right response -> item {itemLink = decodeUtf8 $ BL.toStrict $ response ^. responseBody}
