{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ViewPatterns #-}

module Brockman.Bot.Controller where

import Brockman.Bot
import Brockman.Bot.Reporter (reporterThread)
import Brockman.Types
import Brockman.Util
import Control.Concurrent (forkIO)
import Control.Concurrent.Chan
import Control.Concurrent.MVar
import Control.Lens
import Control.Monad
import Control.Monad.IO.Class (liftIO)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.Conduit
import qualified Data.Map.Strict as M
import Data.Maybe
import qualified Data.Text as T
import qualified Network.IRC.Conduit as IRC
import Safe (readMay)

data ControllerCommand
  = Info Channel Nick
  | Pinged (IRC.ServerName ByteString)
  | SetUrl Nick URL
  | Add Nick URL (Maybe Channel)
  | Tick Nick (Maybe Integer)
  | Invite Channel
  | Kick Channel
  | Help Channel
  | Subscribe Channel {- subscriber -} Nick {- bot -}
  | Unsubscribe Channel {- subscriber -} Nick {- bot -}
  | Dump Channel
  | MOTD
  deriving (Show)

controllerThread :: MVar BrockmanConfig -> IO ()
controllerThread configMVar = do
  initialConfig <- readMVar configMVar
  mapM_ (forkIO . eloop . reporterThread configMVar) $ M.keys $ configBots initialConfig
  case configController initialConfig of
    Nothing -> pure ()
    Just initialControllerConfig@ControllerConfig {controllerNick} ->
      let initialControllerChannels = configChannel initialConfig : fromMaybe [] (controllerExtraChannels initialControllerConfig)
          listen chan =
            forever $
              await >>= \case
                Just (Right (IRC.Event _ _ (IRC.Invite channel _))) -> liftIO $ writeChan chan $ Invite $ decode channel
                Just (Right (IRC.Event _ _ (IRC.Kick channel nick _))) | decode nick == controllerNick -> liftIO $ writeChan chan $ Kick $ decode channel
                Just (Right (IRC.Event _ _ (IRC.Ping s _))) -> liftIO $ writeChan chan (Pinged s)
                Just (Right (IRC.Event _ (IRC.User user) (IRC.Privmsg _ (Right message)))) ->
                  liftIO $ case bsWords message of
                    ["subscribe", decode -> nick] -> writeChan chan $ Subscribe (decode user) nick
                    ["unsubscribe", decode -> nick] -> writeChan chan $ Unsubscribe (decode user) nick
                    ["help"] -> writeChan chan $ Help $ decode user
                    ["info", decode -> nick] -> writeChan chan $ Info (decode user) nick
                    ["dump"] -> writeChan chan $ Dump $ decode user
                    _ -> pure ()
                Just (Right (IRC.Event _ (IRC.Channel channel _) (IRC.Privmsg _ (Right message)))) ->
                  liftIO $ case bsWords <$> B.stripPrefix (encode controllerNick <> ":") message of
                    Just ["dump"] -> writeChan chan $ Dump $ decode channel
                    Just ["help"] -> writeChan chan $ Help $ decode channel
                    Just ["info", decode -> nick] -> writeChan chan $ Info (decode channel) nick
                    Just ["set-url", decode -> nick, decodeUtf8 -> url] -> writeChan chan $ SetUrl nick url
                    Just ["add", decode -> nick, decodeUtf8 -> url]
                      | "http" `T.isPrefixOf` url && isValidIrcNick nick ->
                        writeChan chan $
                          Add nick url $
                            if decode channel == configChannel initialConfig then Nothing else Just $ decode channel
                    Just ["tick", decode -> nick, decodeUtf8 -> tickString] ->
                      writeChan chan $ Tick nick $ readMay $ T.unpack tickString
                    Just _ -> writeChan chan $ Help $ decode channel
                    _ -> pure ()
                -- 376 is RPL_ENDOFMOTD
                Just (Right (IRC.Event _ _ (IRC.Numeric 376 _))) ->
                  liftIO $ writeChan chan MOTD
                _ -> pure ()
          speak chan = do
            handshake controllerNick initialControllerChannels
            forever $ do
              config@BrockmanConfig {configBots, configController, configChannel} <- liftIO (readMVar configMVar)
              case configController of
                Nothing -> pure ()
                Just controller -> do
                  let controllerChannels = configChannel : fromMaybe [] (controllerExtraChannels controller)
                  command <- liftIO (readChan chan)
                  notice controllerNick (show command)
                  case command of
                    Help channel -> do
                      broadcast
                        [channel]
                        [ "help — send this helpful message",
                          "info NICK — display a bot's settings",
                          "set-url NICK FEED_URL — change a bot's feed url",
                          "tick NICK SECONDS — change a bot's tick speed",
                          "add NICK FEED_URL — add a new bot to all channels I am in",
                          "dump — upload the current config/state somewhere you can see it",
                          "/msg " <> decodeUtf8 (encode controllerNick) <> " subscribe NICK — subscribe to private messages from a bot",
                          "/msg NICK die — tell a bot to commit suicice",
                          "/msg " <> decodeUtf8 (encode controllerNick) <> " unsubscribe NICK — unsubscribe to private messages from a bot",
                          "/invite NICK — invite a bot from your channel",
                          "/kick NICK — remove a bot from your channel",
                          "/invite " <> decodeUtf8 (encode controllerNick) <> " — invite the controller to your channel",
                          "/kick " <> decodeUtf8 (encode controllerNick) <> " — kick the controller from your channel"
                        ]
                    Tick nick tick -> do
                      liftIO $ update configMVar $ configBotsL . at nick . mapped . botDelayL .~ tick
                      notice nick ("change tick speed to " <> show tick)
                      channelsForNick <- botChannels nick <$> liftIO (readMVar configMVar)
                      broadcastNotice channelsForNick $ T.pack (show nick) <> " @ " <> T.pack (maybe "auto" ((<> " seconds") . show) tick)
                    Add nick url extraChannel ->
                      case M.lookup nick configBots of
                        Just BotConfig {botFeed} -> broadcast [fromMaybe configChannel extraChannel] [T.pack (show nick) <> " is already serving " <> botFeed]
                        Nothing -> do
                          liftIO $ update configMVar $ configBotsL . at nick ?~ BotConfig {botFeed = url, botDelay = Nothing, botExtraChannels = (: []) <$> extraChannel}
                          _ <- liftIO $ forkIO $ eloop $ reporterThread configMVar nick
                          pure ()
                    SetUrl nick url -> do
                      liftIO $ update configMVar $ configBotsL . at nick . mapped . botFeedL .~ url
                      notice nick $ "set url to " <> T.unpack url
                      channelsForNick <- botChannels nick <$> liftIO (readMVar configMVar)
                      broadcastNotice channelsForNick $ T.pack (show nick) <> " -> " <> url
                    Pinged serverName -> do
                      debug controllerNick ("pong " <> show serverName)
                      yield $ IRC.Pong serverName
                    Kick channel -> do
                      liftIO $ update configMVar $ configControllerL . mapped . controllerExtraChannelsL %~ delete channel
                      notice controllerNick $ "kicked from " <> show channel
                    Invite channel -> do
                      liftIO $ update configMVar $ configControllerL . mapped . controllerExtraChannelsL %~ insert channel
                      notice controllerNick $ "invited to " <> show channel
                      yield $ IRC.Join $ encode channel
                    Subscribe user nick -> do
                      liftIO $ update configMVar $ configBotsL . at nick . mapped . botExtraChannelsL %~ insert user
                      notice nick $ show user <> " has subscribed"
                      broadcast [user] ["subscribed to " <> T.pack (show nick)]
                    Unsubscribe user nick -> do
                      liftIO $ update configMVar $ configBotsL . at nick . mapped . botExtraChannelsL %~ delete user
                      notice nick $ show user <> " has unsubscribed"
                      broadcast [user] ["unsubscribed from " <> T.pack (show nick)]
                    Dump channel ->
                      broadcast [channel] . (: []) =<< case configPastebin config of
                        Just endpoint -> liftIO $ pasteJson endpoint config
                        Nothing -> pure "No pastebin set"
                    Info channel nick -> do
                      broadcast [channel] $
                        pure $
                          case M.lookup nick configBots of
                            Just BotConfig {botFeed, botExtraChannels, botDelay} -> do
                              T.unwords $ [botFeed, T.pack (show (configChannel : fromMaybe [] botExtraChannels))] ++ maybeToList (T.pack . show <$> botDelay)
                            _
                              | nick == controllerNick -> T.pack (show controllerChannels)
                              | otherwise ->
                                case M.keys $ M.filter (\BotConfig {botExtraChannels} -> decode (encode nick) `elem` fromMaybe [] botExtraChannels) configBots of
                                  [] -> T.pack (show nick) <> " is neither bot nor subscriber"
                                  subscriptions -> T.pack (show nick) <> " has subscribed to " <> T.pack (show subscriptions)
                    MOTD -> do
                      notice controllerNick ("handshake, joining " <> show initialControllerChannels)
                      mapM_ (yield . IRC.Join . encode) initialControllerChannels
       in withIrcConnection initialConfig listen speak
