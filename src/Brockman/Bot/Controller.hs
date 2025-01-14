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

data ControllerCommand
  = Add Nick URL (Maybe Channel)
  | Dump Channel
  | Help Channel
  | Invite Channel
  | Kick Channel
  | MOTD
  | Pinged (IRC.ServerName ByteString)
  | Subscribe Channel {- subscriber -} Nick {- bot -}
  | Unsubscribe Channel {- subscriber -} Nick {- bot -}
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
                    ["dump"] -> writeChan chan $ Dump $ decode user
                    _ -> pure ()
                Just (Right (IRC.Event _ (IRC.Channel channel _) (IRC.Privmsg _ (Right message)))) ->
                  liftIO $ case bsWords <$> B.stripPrefix (encode controllerNick <> ":") message of
                    Just ["dump"] -> writeChan chan $ Dump $ decode channel
                    Just ["help"] -> writeChan chan $ Help $ decode channel
                    Just ["add", decode -> nick, decodeUtf8 -> url]
                      | "http" `T.isPrefixOf` url && isValidIrcNick nick ->
                        writeChan chan $
                          Add nick url $
                            if decode channel == configChannel initialConfig then Nothing else Just $ decode channel
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
                Just _ -> do
                  command <- liftIO (readChan chan)
                  notice controllerNick (show command)
                  case command of
                    Help channel -> do
                      broadcast
                        [channel]
                        [ "help — send this helpful message",
                          "add NICK FEED_URL — add a new bot to all channels I am in",
                          "dump — upload the current config/state somewhere you can see it",
                          "/msg " <> decodeUtf8 (encode controllerNick) <> " subscribe NICK — subscribe to private messages from a bot",
                          "/msg NICK die — tell a bot to commit suicice",
                          "/msg NICK info — display a bot's settings",
                          "/msg NICK tick SECONDS — change a bot's tick speed",
                          "/msg NICK set-url FEED_URL — change a bot's feed url",
                          "/msg " <> decodeUtf8 (encode controllerNick) <> " unsubscribe NICK — unsubscribe to private messages from a bot",
                          "/invite NICK — invite a bot from your channel",
                          "/kick NICK — remove a bot from your channel",
                          "/invite " <> decodeUtf8 (encode controllerNick) <> " — invite the controller to your channel",
                          "/kick " <> decodeUtf8 (encode controllerNick) <> " — kick the controller from your channel"
                        ]
                    Add nick url extraChannel ->
                      case M.lookup nick configBots of
                        Just BotConfig {botFeed} -> broadcast [fromMaybe configChannel extraChannel] [T.pack (show nick) <> " is already serving " <> botFeed]
                        Nothing -> do
                          liftIO $ update configMVar $ configBotsL . at nick ?~ BotConfig {botFeed = url, botDelay = Nothing, botExtraChannels = (: []) <$> extraChannel}
                          _ <- liftIO $ forkIO $ eloop $ reporterThread configMVar nick
                          pure ()
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
                    MOTD -> do
                      notice controllerNick ("handshake, joining " <> show initialControllerChannels)
                      mapM_ (yield . IRC.Join . encode) initialControllerChannels
       in withIrcConnection initialConfig listen speak
