{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE ViewPatterns #-}

module Brockman.Bot.Controller where

import Brockman.Bot
import Brockman.Bot.Reporter (relayReporter, reporterThread)
import Brockman.Types
import Brockman.Util
import Control.Concurrent (forkIO, killThread)
import Control.Concurrent.Chan
import Control.Concurrent.MVar
import qualified Control.Exception as E
import Control.Lens
import Control.Monad
import Control.Monad.IO.Class (liftIO)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.Conduit
import Data.Foldable (toList)
import Data.IORef
import qualified Data.Map.Strict as M
import Data.Maybe
import qualified Data.Set as Set
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8)
import qualified Data.Text.IO as TIO
import qualified Network.IRC.Conduit as IRC
import Safe (readMay)
import System.Log.Logger

data ControllerCommand
  = Add Nick URL (Maybe Channel)
  | Dump Channel
  | Help Channel
  | Invite Channel
  | Kick Channel
  | MOTD
  | Pinged (IRC.ServerName ByteString)
  | -- relay mode: reporters have no connection of their own, so the controller handles their commands
    Opered
  | Relayed [IRC.IrcMessage]
  | Remove Channel Nick
  | Info Channel Nick
  | SetTick Channel Nick (Maybe Integer)
  | SetUrl Channel Nick URL
  | Subscribe Nick Nick
  | Unsubscribe Nick Nick
  | InviteBot Channel Nick
  | KickBot Channel Nick
  deriving (Show)

controllerThread :: MVar BrockmanConfig -> IO ()
controllerThread configMVar = do
  initialConfig <- readMVar configMVar
  let relaySuffix = configRelaySuffix initialConfig
  -- relayed items wait here while the controller is (re)connecting
  relayChan <- newChan
  let startBot nick = void $ forkIO $ eloop $ case relaySuffix of
        Just _ -> relayReporter configMVar (writeChan relayChan) nick
        Nothing -> reporterThread configMVar nick
  when (isJust relaySuffix && isNothing (configController initialConfig)) $
    fail "relaySuffix needs a controller: it is the only connection relayed items can go out on"
  mapM_ startBot $ M.keys $ configBots initialConfig
  case configController initialConfig of
    Nothing -> pure ()
    Just initialControllerConfig@ControllerConfig {controllerNick} ->
      let initialControllerChannels = Set.insert (configChannel initialConfig) $ fromMaybe Set.empty (controllerExtraChannels initialControllerConfig)
          oper = ircOper (configIrc initialConfig)
          -- users may name a bot by its relayed nick
          botNick = decode . maybe id (\suffix name -> fromMaybe name (B.stripSuffix (encodeUtf8 suffix) name)) relaySuffix
          handleMessage :: Either Channel Nick -> Nick -> ByteString -> Maybe ControllerCommand
          handleMessage target sender message =
            let toChannel = either id (decode . encode)
                replyTo = toChannel target
             in case (bsWords message, relaySuffix) of
                  (["help"], _) -> Just $ Help replyTo
                  (["dump"], _) -> Just $ Dump replyTo
                  (["add", decode -> nick, decodeUtf8 -> url], _)
                    | "http" `T.isPrefixOf` url && isValidIrcNick nick ->
                        Just $ Add nick url $ case target of
                          Left channel
                            | channel == configChannel initialConfig -> Nothing
                            | otherwise -> Just channel
                          Right _ -> Nothing
                  (["remove", botNick -> bot], Just _) -> Just $ Remove replyTo bot
                  (["info", botNick -> bot], Just _) -> Just $ Info replyTo bot
                  (["tick", botNick -> bot, decodeUtf8 -> tick], Just _) -> Just $ SetTick replyTo bot $ readMay $ T.unpack tick
                  (["set-url", botNick -> bot, decodeUtf8 -> url], Just _)
                    | "http" `T.isPrefixOf` url -> Just $ SetUrl replyTo bot url
                  (["subscribe", botNick -> bot], Just _) -> Just $ Subscribe sender bot
                  (["unsubscribe", botNick -> bot], Just _) -> Just $ Unsubscribe sender bot
                  (["invite", botNick -> bot], Just _) | Left channel <- target -> Just $ InviteBot channel bot
                  (["kick", botNick -> bot], Just _) | Left channel <- target -> Just $ KickBot channel bot
                  _ -> Nothing

          listen chan =
            forever $
              await >>= \case
                -- relay mode: the server closed the connection, so end it (and with it the speaking side)
                -- for controllerThread's reconnect loop instead of spinning on EOF
                Nothing | isJust relaySuffix -> liftIO $ E.throwIO $ userError "IRC connection closed"
                Just (Right (IRC.Event _ _ (IRC.Invite channel _))) -> liftIO $ writeChan chan $ Invite $ decode channel
                Just (Right (IRC.Event _ _ (IRC.Kick channel nick _))) | decode nick == controllerNick -> liftIO $ writeChan chan $ Kick $ decode channel
                Just (Right (IRC.Event _ _ (IRC.Ping s _))) -> liftIO $ writeChan chan (Pinged s)
                Just (Right (IRC.Event _ (IRC.User (decode -> user)) (IRC.Privmsg _ (Right message)))) ->
                  liftIO $ maybe (pure ()) (writeChan chan) $ handleMessage (Right user) user message
                Just (Right (IRC.Event _ (IRC.Channel (decode -> channel) (decode -> user)) (IRC.Privmsg _ (Right message)))) ->
                  liftIO $ maybe (pure ()) (writeChan chan) $ handleMessage (Left channel) user =<< B.stripPrefix (encode controllerNick <> ":") message
                Just (Right (IRC.Event raw _ (IRC.Numeric n _)))
                  | n `elem` [376, 422] ->
                      -- RPL_ENDOFMOTD, ERR_NOMOTD: registration is complete either way
                      liftIO $ writeChan chan MOTD
                  | n == 381 ->
                      -- RPL_YOUREOPER
                      liftIO $ writeChan chan Opered
                  | n `elem` [464, 491] ->
                      -- ERR_PASSWDMISMATCH, ERR_NOOPERHOST
                      liftIO $ errorM "brockman" $ "OPER failed, relaying will be refused: " <> show raw
                Just (Right (IRC.Event raw _ (IRC.RawMsg _)))
                  | " FAIL " `B.isInfixOf` raw || "FAIL " `B.isPrefixOf` raw -> liftIO $ warningM "brockman" $ show raw
                _ -> pure ()

          -- forwards relayed items onto the current connection once it may relay; killed on disconnect
          startForwarding chan forwarder = liftIO $ do
            thread <- forkIO $ forever $ writeChan chan . Relayed =<< readChan relayChan
            writeIORef forwarder (Just thread)

          reply channel = broadcast (Set.singleton channel) . pure
          withBot channel bot handler = do
            BrockmanConfig {configBots} <- liftIO (readMVar configMVar)
            maybe (reply channel $ T.pack (show bot) <> " does not exist") handler $ M.lookup bot configBots
          updateBot bot = liftIO . update configMVar . (configBotsL . at bot . mapped %~)

          speak chan forwarder = do
            handshake controllerNick initialControllerChannels
            forever $ do
              config@BrockmanConfig {configController} <- liftIO (readMVar configMVar)
              case configController of
                Nothing -> pure ()
                Just _ -> do
                  command <- liftIO (readChan chan)
                  case command of
                    Relayed _ -> pure ()
                    _ -> notice controllerNick (show command)
                  case command of
                    Help channel -> do
                      broadcast (Set.singleton channel) $
                        [ "help — send this helpful message",
                          "add NICK FEED_URL — add a new bot to all channels I am in",
                          "dump — upload the current config/state somewhere you can see it"
                        ]
                          ++ case relaySuffix of
                            Just _ ->
                              [ "remove NICK — remove a bot",
                                "info NICK — display a bot's settings",
                                "tick NICK SECONDS — change a bot's tick speed (anything else: automatic)",
                                "set-url NICK FEED_URL — change a bot's feed url",
                                "subscribe NICK — subscribe to private messages from a bot",
                                "unsubscribe NICK — unsubscribe from private messages from a bot",
                                "invite NICK — (in a channel) post a bot's items here too",
                                "kick NICK — (in a channel) stop posting a bot's items here"
                              ]
                            Nothing ->
                              [ "/msg NICK die — tell a bot to commit suicice",
                                "/msg NICK info — display a bot's settings",
                                "/msg NICK tick SECONDS — change a bot's tick speed",
                                "/msg NICK set-url FEED_URL — change a bot's feed url",
                                "/msg NICK subscribe — subscribe to private messages from a bot",
                                "/msg NICK unsubscribe — unsubscribe to private messages from a bot",
                                "/invite NICK — invite a bot from your channel",
                                "/kick NICK — remove a bot from your channel"
                              ]
                          ++ [ "/invite " <> decodeUtf8 (encode controllerNick) <> " — invite the controller to your channel",
                               "/kick " <> decodeUtf8 (encode controllerNick) <> " — kick the controller from your channel"
                             ]
                    Add nick url extraChannel -> do
                      BrockmanConfig {configBots, configChannel} <- liftIO (readMVar configMVar)
                      case M.lookup nick configBots of
                        Just BotConfig {botFeed} -> broadcast (Set.singleton $ fromMaybe configChannel extraChannel) [T.pack (show nick) <> " is already serving " <> botFeed]
                        Nothing -> do
                          liftIO $ update configMVar $ configBotsL . at nick ?~ BotConfig {botFeed = url, botDelay = Nothing, botExtraChannels = Set.singleton <$> extraChannel}
                          liftIO $ startBot nick
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
                      when (isJust relaySuffix) $ case oper of
                        Just OperConfig {operName, operPasswordFile} ->
                          liftIO (E.try @E.IOException (TIO.readFile operPasswordFile)) >>= \case
                            Right password -> yield $ IRC.RawMsg $ "OPER " <> encodeUtf8 operName <> " " <> encodeUtf8 (T.strip password)
                            Left exception -> do
                              liftIO $ errorM "brockman" $ "cannot read OPER password, relaying without: " <> show exception
                              startForwarding chan forwarder
                        -- without OPER, relaying needs channel operator status (ergo: relaymsg.available-to-chanops)
                        Nothing -> startForwarding chan forwarder
                    Opered -> do
                      notice controllerNick "opered, relaying"
                      startForwarding chan forwarder
                    Relayed messages -> mapM_ yield messages
                    Remove channel bot -> withBot channel bot $ \_ -> do
                      liftIO $ update configMVar $ configBotsL . at bot .~ Nothing
                      reply channel $ "removed " <> T.pack (show bot)
                    Info channel bot -> withBot channel bot $ \BotConfig {botFeed, botDelay} ->
                      reply channel $
                        T.unwords
                          [ T.pack (show bot),
                            "serves <" <> botFeed <> ">",
                            "to " <> T.intercalate ", " (map (decodeUtf8 . encode) (toList (botChannels bot config))) <> ".",
                            "Tick: " <> maybe "automatic" ((<> "s") . T.pack . show) botDelay
                          ]
                    SetTick channel bot tick -> withBot channel bot $ \_ -> do
                      updateBot bot (botDelayL .~ tick)
                      reply channel $ T.pack (show bot) <> " @ " <> maybe "automatic" ((<> " seconds") . T.pack . show) tick
                    SetUrl channel bot url -> withBot channel bot $ \_ -> do
                      updateBot bot (botFeedL .~ url)
                      reply channel $ T.pack (show bot) <> " -> " <> url
                    Subscribe user bot -> withBot (userChannel user) bot $ \_ -> do
                      updateBot bot (botExtraChannelsL %~ insert (userChannel user))
                      reply (userChannel user) $ "subscribed to " <> T.pack (show bot)
                    Unsubscribe user bot -> withBot (userChannel user) bot $ \_ -> do
                      updateBot bot (botExtraChannelsL %~ delete (userChannel user))
                      reply (userChannel user) $ "unsubscribed from " <> T.pack (show bot)
                    InviteBot channel bot -> withBot channel bot $ \_ -> do
                      updateBot bot (botExtraChannelsL %~ insert channel)
                      reply channel $ T.pack (show bot) <> " now also posts here"
                    KickBot channel bot -> withBot channel bot $ \_ -> do
                      updateBot bot (botExtraChannelsL %~ delete channel)
                      reply channel $ T.pack (show bot) <> " no longer posts here"
          userChannel :: Nick -> Channel
          userChannel = decode . encode
       in case relaySuffix of
            Nothing -> withIrcConnection initialConfig listen (\chan -> liftIO (newIORef Nothing) >>= speak chan)
            -- the controller is the only connection: reconnect forever, keeping reporters and queued items
            Just _ -> forever $ do
              chan <- newChan
              forwarder <- newIORef Nothing
              result <- E.try @E.SomeException $ ircConnection initialConfig (listen chan) (speak chan forwarder)
              mapM_ killThread =<< readIORef forwarder
              warningM "brockman" $ "controller connection ended: " <> either show (const "closed") result
              sleepSeconds 10
