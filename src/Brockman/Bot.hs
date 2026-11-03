{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Brockman.Bot where

import Brockman.Types
import Brockman.Util (decodeUtf8, notice)
import Control.Concurrent.Chan
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as B8
import Data.Conduit
import Data.Conduit.List (sourceList)
import Data.Foldable (toList)
import Data.Maybe
import Data.Set (Set)
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8)
import qualified Network.IRC.Conduit as IRC
import System.Log.Logger

withIrcConnection :: BrockmanConfig -> (Chan a -> ConduitM (Either ByteString IRC.IrcEvent) Void IO ()) -> (Chan a -> ConduitM () IRC.IrcMessage IO ()) -> IO ()
withIrcConnection config listen speak = do
  chan <- newChan
  ircConnection config (listen chan) (speak chan)

ircConnection :: BrockmanConfig -> ConduitM (Either ByteString IRC.IrcEvent) Void IO () -> ConduitM () IRC.IrcMessage IO () -> IO ()
ircConnection BrockmanConfig {configIrc} listen speak = do
  noticeM "" $ "Connecting to " <> T.unpack host <> ":" <> show port <> ", TLS " <> show tls
  (if tls then IRC.ircTLSClient else IRC.ircClient)
    port
    (encodeUtf8 host)
    (pure ())
    listen
    speak
  where
    port = fromMaybe 6667 $ ircPort configIrc
    host = ircHost configIrc
    tls = ircTls configIrc == Just True

handshake :: Nick -> Set Channel -> ConduitM () IRC.IrcMessage IO ()
handshake nick channels = do
  notice nick ("handshake, joining " <> show channels)
  yield $ IRC.Nick $ encode nick
  yield $ IRC.RawMsg $ "USER " <> encode nick <> " * 0 :" <> encode nick
  mapM_ (yield . IRC.Join . encode) (toList channels)

deafen :: Nick -> ConduitM () IRC.IrcMessage IO ()
deafen nick = yield $ IRC.Mode (encode nick) False [] ["+D"] -- deafen to PRIVMSGs in channels (query still works)

-- maybe join channels separated by comma

broadcastNotice :: (Monad m) => Set Channel -> T.Text -> ConduitT i (IRC.Message ByteString) m ()
broadcastNotice channels message =
  sourceList
    [ IRC.Notice (encode channel) $ Right $ encodeUtf8 message
      | channel <- toList channels
    ]

broadcast :: (Monad m) => Set Channel -> [T.Text] -> ConduitT i (IRC.Message ByteString) m ()
broadcast channels messages =
  sourceList
    [ IRC.Privmsg (encode channel) $ Right $ encodeIRCMessage message
      | channel <- toList channels,
        message <- messages
    ]

encodeIRCMessage :: T.Text -> ByteString
encodeIRCMessage = encodeUtf8 . T.map (\c -> if c `elem` ("\0\r\n" :: [Char]) then ' ' else c)

isChannelName :: Channel -> Bool
isChannelName channel = case B8.uncons (encode channel) of
  Just (c, _) -> c `elem` ("#&" :: [Char])
  Nothing -> False

relayNick :: T.Text -> Nick -> T.Text
relayNick suffix nick = decodeUtf8 (encode nick) <> suffix

-- RELAYMSG only reaches channels; subscribed users get a PRIVMSG prefixed with the relayed nick
relay :: T.Text -> Nick -> Set Channel -> T.Text -> [IRC.IrcMessage]
relay suffix nick targets message =
  [ IRC.RawMsg $
      if isChannelName target
        then fitLine ("RELAYMSG " <> encode target <> " " <> encodeUtf8 sender <> " :") message
        else fitLine ("PRIVMSG " <> encode target <> " :") ("<" <> sender <> "> " <> message)
    | target <- toList targets
  ]
  where
    sender = relayNick suffix nick

-- RELAYMSG cannot send NOTICEs, so the controller sends them itself, naming the bot
relayNotice :: T.Text -> Nick -> Set Channel -> T.Text -> [IRC.IrcMessage]
relayNotice suffix nick targets message =
  [ IRC.RawMsg $ fitLine ("NOTICE " <> encode target <> " :") ("[" <> relayNick suffix nick <> "] " <> message)
    | target <- toList targets
  ]

-- ergo rejects lines over 512 bytes (ERR_INPUTTOOLONG): cut the message at a character boundary,
-- leaving room for the prefix and CRLF
fitLine :: ByteString -> T.Text -> ByteString
fitLine prefix message = prefix <> encodeUtf8 (T.pack (takeBytes (510 - B8.length prefix) (T.unpack message)))
  where
    takeBytes n (c : cs)
      | size <= n = sanitize c : takeBytes (n - size) cs
      where
        size = B8.length (encodeUtf8 (T.singleton c))
    takeBytes _ _ = []
    sanitize c = if c `elem` ("\0\r\n" :: [Char]) then ' ' else c
