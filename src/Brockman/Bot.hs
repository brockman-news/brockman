{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Brockman.Bot where

import Brockman.Types
import Brockman.Util (notice)
import Control.Concurrent.Chan
import Data.ByteString (ByteString)
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
withIrcConnection BrockmanConfig {configIrc} listen speak = do
  noticeM "" $ "Connecting to " <> T.unpack host <> ":" <> show port <> ", TLS " <> show tls
  chan <- newChan
  (if tls then IRC.ircTLSClient else IRC.ircClient)
    port
    (encodeUtf8 host)
    (pure ())
    (listen chan)
    (speak chan)
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
