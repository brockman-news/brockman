{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Brockman.Bot.Reporter where

import Brockman.Bot
import Brockman.Feed
import Brockman.Types
import Brockman.Util
import Control.Applicative (Alternative (..))
import Control.Concurrent (forkIO)
import Control.Concurrent.Chan
import Control.Concurrent.MVar
import qualified Control.Exception as E
import Control.Lens
import Control.Monad
import Control.Monad.IO.Class (MonadIO, liftIO)
import qualified Data.ByteString as BS (ByteString)
import qualified Data.ByteString.Lazy as BL (toStrict)
import Data.Conduit
import Data.LruCache.Internal (LruCache (lruCapacity))
import qualified Data.Map as M
import Data.Maybe (fromMaybe)
import qualified Data.Text as T (Text, pack, unpack, unwords, words)
import Data.Time.Clock (getCurrentTime)
import Network.HTTP.Client (HttpException (HttpExceptionRequest), HttpExceptionContent (ConnectionFailure, StatusCodeException))
import qualified Network.IRC.Conduit as IRC
import Network.Socket (HostName)
import Network.Wreq (FormParam ((:=)), defaults, getWith, header, postWith, responseBody, responseStatus, statusCode, statusMessage)
import System.Log.Logger
import System.Random (randomRIO)
import System.Timeout (timeout)
import Text.Feed.Import (parseFeedSource)

data ReporterMessage
  = Pinged (IRC.ServerName BS.ByteString)
  | Invited Channel
  | Kicked Channel
  | NewFeedItem FeedItem
  | Exception T.Text
  | MOTD
  deriving (Show)

-- return the current config or kill thread if the key is not present
withCurrentBotConfig :: MonadIO m => Nick -> MVar BrockmanConfig -> (BotConfig -> m ()) -> m ()
withCurrentBotConfig nick configMVar handler = do
  BrockmanConfig {configBots} <- liftIO $ readMVar configMVar
  maybe (liftIO suicide) handler $ M.lookup nick configBots

reporterThread :: MVar BrockmanConfig -> Nick -> IO ()
reporterThread configMVar nick = do
  config@BrockmanConfig {configChannel, configShortener} <- readMVar configMVar
  withIrcConnection config listen $ \chan -> do
    withCurrentBotConfig nick configMVar $ \initialBotConfig -> do
      handshake nick $ configChannel : fromMaybe [] (botExtraChannels initialBotConfig)
      deafen nick
      _ <- liftIO $ forkIO $ feedThread nick configMVar True Nothing chan
      forever $
        withCurrentBotConfig nick configMVar $ \_ -> do
          channels <- botChannels nick <$> liftIO (readMVar configMVar)
          command <- liftIO (readChan chan)
          debug nick $ show command
          case command of
            Pinged serverName -> do
              debug nick ("pong " <> show serverName)
              yield $ IRC.Pong serverName
            NewFeedItem item -> do
              item' <- liftIO $ maybe (pure item) (\url -> item `shortenWith` T.unpack url) configShortener
              debug nick ("sending " <> show (display item'))
              broadcast channels [display item']
            Exception message ->
              broadcastNotice channels message
            Kicked channel -> do
              liftIO $ update configMVar $ configBotsL . at nick . mapped . botExtraChannelsL %~ delete channel
              notice nick $ "kicked from " <> show channel
            Invited channel -> do
              liftIO $ update configMVar $ configBotsL . at nick . mapped . botExtraChannelsL %~ insert channel
              notice nick $ "invited to " <> show channel
              yield $ IRC.Join $ encode channel
            MOTD -> do
              notice nick ("handshake, joining " <> show channels)
              mapM_ (yield . IRC.Join . encode) channels
  where
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
          _ -> pure ()

getFeed :: URL -> IO (Maybe Integer, Either T.Text [FeedItem])
getFeed url =
  timeout (100 * second) (E.try (getWith options (T.unpack url))) >>= \case
    Nothing ->
      return (Nothing, Left "Timeout")
    Just (Left exception) ->
      let mircRed text = "\ETX4,99" <> text <> "\ETX" -- ref https://www.mirc.com/colors.html
          message = mircRed $
            T.unwords $
              T.words $ case exception of
                HttpExceptionRequest _ (StatusCodeException response _) ->
                  T.unwords [T.pack $ show $ response ^. responseStatus . statusCode, decodeUtf8 $ response ^. responseStatus . statusMessage]
                HttpExceptionRequest _ (ConnectionFailure _) -> "Connection failure"
                HttpExceptionRequest _ exceptionContent -> T.pack $ show exceptionContent
                _ -> T.pack $ show exception
       in return (Nothing, Left message)
    Just (Right response) -> do
      now <- liftIO getCurrentTime
      let feed = parseFeedSource $ response ^. responseBody
          delta = feedEntryDelta now =<< feed
          feedItems = feedToItems feed
      return (delta, Right feedItems)
  where
    options = defaults & header "Accept" .~ ["application/atom+xml", "application/rss+xml", "*/*"]
    second = 10 ^ (6 :: Int)

feedThread :: Nick -> MVar BrockmanConfig -> Bool -> Maybe LRU -> Chan ReporterMessage -> IO ()
feedThread nick configMVar isFirstTime lru chan =
  withCurrentBotConfig nick configMVar $ \BotConfig {botDelay, botFeed} -> do
    defaultDelay <- configDefaultDelay <$> readMVar configMVar
    maxStartDelay <- configMaxStartDelay <$> readMVar configMVar
    notifyErrors <- configNotifyErrors <$> readMVar configMVar
    liftIO $
      when isFirstTime $ do
        randomDelay <- randomRIO (0, fromMaybe 60 maxStartDelay)
        debug nick $ "sleep " <> show randomDelay
        sleepSeconds randomDelay
    debug nick ("fetch " <> T.unpack botFeed)
    (newTick, exceptionOrFeed) <- liftIO $ getFeed botFeed
    newLRU <- case exceptionOrFeed of
      Left message -> do
        error' nick $ "exception" <> T.unpack message
        when (fromMaybe True notifyErrors) $ writeChan chan $ Exception $ message <> " — " <> botFeed
        return lru
      Right feedItems -> do
        let (lru', items) = deduplicate lru feedItems
        when (null feedItems) $ do
          warning nick $ "Feed is empty: " <> T.unpack botFeed
          writeChan chan $ Exception $ "feed is empty: " <> botFeed
        unless isFirstTime $ writeList2Chan chan $ map NewFeedItem items
        return $ Just lru'
    tick <- scatterTick $ max 1 $ min 86400 $ fromMaybe fallbackDelay $ botDelay <|> newTick <|> defaultDelay
    debug nick $ "lrusize: " <> show (maybe 0 lruCapacity newLRU)
    notice nick $ "tick " <> show tick
    liftIO $ sleepSeconds tick
    feedThread nick configMVar False newLRU chan
  where
    fallbackDelay = 300
    scatterTick x = (+) (x `div` 2) <$> randomRIO (0, x `div` 2)

shortenWith :: FeedItem -> HostName -> IO FeedItem
item `shortenWith` url = do
  debugM "brockman" ("Shortening " <> show item <> " with " <> show url)
  E.try (postWith defaults url ["uri" := itemLink item]) <&> \case
    Left (E.SomeException _) -> item
    Right response -> item {itemLink = decodeUtf8 $ BL.toStrict $ response ^. responseBody}
