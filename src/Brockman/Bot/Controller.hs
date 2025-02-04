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
import qualified Data.Set as Set
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
  deriving (Show)

controllerThread :: MVar BrockmanConfig -> IO ()
controllerThread configMVar = do
  initialConfig <- readMVar configMVar
  mapM_ (forkIO . eloop . reporterThread configMVar) $ M.keys $ configBots initialConfig
  case configController initialConfig of
    Nothing -> pure ()
    Just initialControllerConfig@ControllerConfig {controllerNick} ->
      let initialControllerChannels = Set.insert (configChannel initialConfig) $ fromMaybe Set.empty (controllerExtraChannels initialControllerConfig)
          handleMessage :: Either Channel Nick -> ByteString -> Maybe ControllerCommand
          handleMessage target message =
            let toChannel = either id (decode . encode)
             in case bsWords message of
                  ["help"] -> Just $ Help $ toChannel target
                  ["dump"] -> Just $ Dump $ toChannel target
                  ["add", decode -> nick, decodeUtf8 -> url]
                    | "http" `T.isPrefixOf` url && isValidIrcNick nick ->
                        Just $ Add nick url $ case target of
                          Left channel
                            | channel == configChannel initialConfig -> Nothing
                            | otherwise -> Just channel
                          Right _ -> Nothing
                  _ -> Nothing

          listen chan =
            forever $
              await >>= \case
                Just (Right (IRC.Event _ _ (IRC.Invite channel _))) -> liftIO $ writeChan chan $ Invite $ decode channel
                Just (Right (IRC.Event _ _ (IRC.Kick channel nick _))) | decode nick == controllerNick -> liftIO $ writeChan chan $ Kick $ decode channel
                Just (Right (IRC.Event _ _ (IRC.Ping s _))) -> liftIO $ writeChan chan (Pinged s)
                Just (Right (IRC.Event _ (IRC.User (decode -> user)) (IRC.Privmsg _ (Right message)))) ->
                  liftIO $ maybe (pure ()) (writeChan chan) $ handleMessage (Right user) message
                Just (Right (IRC.Event _ (IRC.Channel (decode -> channel) _) (IRC.Privmsg _ (Right message)))) ->
                  liftIO $ maybe (pure ()) (writeChan chan) $ handleMessage (Left channel) =<< B.stripPrefix (encode controllerNick <> ":") message
                Just (Right (IRC.Event _ _ (IRC.Numeric 376 _))) ->
                  -- 376 is RPL_ENDOFMOTD
                  liftIO $ writeChan chan MOTD
                _ -> pure ()
          speak chan = do
            handshake controllerNick initialControllerChannels
            forever $ do
              config@BrockmanConfig {configController} <- liftIO (readMVar configMVar)
              case configController of
                Nothing -> pure ()
                Just _ -> do
                  command <- liftIO (readChan chan)
                  notice controllerNick (show command)
                  case command of
                    Help channel -> do
                      broadcast
                        (Set.singleton channel)
                        [ "help — send this helpful message",
                          "add NICK FEED_URL — add a new bot to all channels I am in",
                          "dump — upload the current config/state somewhere you can see it",
                          "/msg NICK die — tell a bot to commit suicice",
                          "/msg NICK info — display a bot's settings",
                          "/msg NICK tick SECONDS — change a bot's tick speed",
                          "/msg NICK set-url FEED_URL — change a bot's feed url",
                          "/msg NICK subscribe — subscribe to private messages from a bot",
                          "/msg NICK unsubscribe — unsubscribe to private messages from a bot",
                          "/invite NICK — invite a bot from your channel",
                          "/kick NICK — remove a bot from your channel",
                          "/invite " <> decodeUtf8 (encode controllerNick) <> " — invite the controller to your channel",
                          "/kick " <> decodeUtf8 (encode controllerNick) <> " — kick the controller from your channel"
                        ]
                    Add nick url extraChannel -> do
                      BrockmanConfig {configBots, configChannel} <- liftIO (readMVar configMVar)
                      case M.lookup nick configBots of
                        Just BotConfig {botFeed} -> broadcast (Set.singleton $ fromMaybe configChannel extraChannel) [T.pack (show nick) <> " is already serving " <> botFeed]
                        Nothing -> do
                          liftIO $ update configMVar $ configBotsL . at nick ?~ BotConfig {botFeed = url, botDelay = Nothing, botExtraChannels = Set.singleton <$> extraChannel}
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
                    Dump channel ->
                      broadcast (Set.singleton channel) . (: []) =<< case configPastebin config of
                        Just endpoint -> liftIO $ pasteJson endpoint config
                        Nothing -> pure "No pastebin set"
                    MOTD -> do
                      notice controllerNick ("handshake, joining " <> show initialControllerChannels)
                      mapM_ (yield . IRC.Join . encode) initialControllerChannels
       in withIrcConnection initialConfig listen speak
