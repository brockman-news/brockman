{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase #-}

module Brockman.Types where

import Control.Concurrent.MVar
import Control.Lens
import Data.Aeson hiding ((.=))
import Data.Aeson.Encode.Pretty (encodePretty)
import Data.Aeson.Types
import Data.ByteString (ByteString)
import qualified Data.ByteString.Lazy as BL
import Data.CaseInsensitive
import Data.Char (isLower, toLower)
import Data.Map (Map, lookup)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text.Encoding (decodeUtf8, encodeUtf8)
import Data.Typeable (Typeable)
import GHC.Generics (Generic)
import qualified Network.IRC.Conduit as IRC
import System.Directory (getHomeDirectory)
import System.FilePath ((</>))

class Decode a where decode :: ByteString -> a

class Encode a where encode :: a -> ByteString

type URL = Text

newtype Nick = Nick {unNick :: IRC.NickName (CI Text)} deriving (Eq, Ord)

instance Show Nick where show = show . unNick

instance FromJSON Nick where parseJSON = fmap (Nick . mk) . parseJSON

instance ToJSON Nick where toJSON = toJSON . foldedCase . unNick

instance ToJSONKey Nick where toJSONKey = toJSONKeyText (foldedCase . unNick)

instance FromJSONKey Nick where fromJSONKey = FromJSONKeyText (Nick . mk)

instance Decode Nick where decode = Nick . mk . decodeUtf8

instance Encode Nick where encode = encodeUtf8 . foldedCase . unNick

newtype Channel = Channel {unChannel :: IRC.ChannelName (CI Text)} deriving (Eq, Ord)

instance Show Channel where show = show . unChannel

instance FromJSON Channel where parseJSON = fmap (Channel . mk) . parseJSON

instance ToJSON Channel where toJSON = toJSON . foldedCase . unChannel

instance Decode Channel where decode = Channel . mk . decodeUtf8

instance Encode Channel where encode = encodeUtf8 . foldedCase . unChannel

configBotsL :: Lens' BrockmanConfig (Map Nick BotConfig)
configBotsL = lens configBots (\config bots -> config {configBots = bots})

configControllerL :: Lens' BrockmanConfig (Maybe ControllerConfig)
configControllerL = lens configController (\config controller -> config {configController = controller})

controllerExtraChannelsL :: Lens' ControllerConfig (Maybe [Channel])
controllerExtraChannelsL = lens controllerExtraChannels (\controller channels -> controller {controllerExtraChannels = channels})

botFeedL :: Lens' BotConfig URL
botFeedL = lens botFeed (\bot feed -> bot {botFeed = feed})

botDelayL :: Lens' BotConfig (Maybe Integer)
botDelayL = lens botDelay (\bot delay -> bot {botDelay = delay})

botExtraChannelsL :: Lens' BotConfig (Maybe [Channel])
botExtraChannelsL = lens botExtraChannels (\bot channels -> bot {botExtraChannels = channels})

botChannels :: Nick -> BrockmanConfig -> [Channel]
botChannels nick config = (configChannel config :) $ fromMaybe [] $ botExtraChannels =<< Data.Map.lookup nick (configBots config)

data BrockmanConfig = BrockmanConfig
  { configBots :: Map Nick BotConfig,
    configChannel :: Channel,
    configUseTls :: Maybe Bool,
    configIrc :: IrcConfig,
    configShortener :: Maybe URL,
    configController :: Maybe ControllerConfig,
    configStatePath :: Maybe FilePath,
    configPastebin :: Maybe URL,
    configDefaultDelay :: Maybe Integer,
    configMaxStartDelay :: Maybe Integer
  }
  deriving (Generic, Show, Typeable)

data ControllerConfig = ControllerConfig
  { controllerNick :: Nick,
    controllerExtraChannels :: Maybe [Channel]
  }
  deriving (Generic, Show, Typeable)

data IrcConfig = IrcConfig
  { ircHost :: URL,
    ircPort :: Maybe Int
  }
  deriving (Generic, Show, Typeable)

data BotConfig = BotConfig
  { botFeed :: URL,
    botExtraChannels :: Maybe [Channel],
    botDelay :: Maybe Integer
  }
  deriving (Generic, Show, Typeable)

statePath :: BrockmanConfig -> IO FilePath
statePath = maybe defaultStatePath pure . configStatePath
  where
    defaultStatePath = (</> "brockman.json") <$> getHomeDirectory

update :: MVar BrockmanConfig -> (BrockmanConfig -> BrockmanConfig) -> IO ()
update stateMVar function = modifyMVar_ stateMVar $ \state ->
  let state' = function state
   in state' <$ dump state'
  where
    dump config = do
      path <- statePath config
      BL.writeFile path $ encodePretty config

myOptions :: Options
myOptions =
  defaultOptions
    { fieldLabelModifier = uncapitalize . dropWhile isLower,
      omitNothingFields = True
    }
  where
    uncapitalize =
      \case
        [] -> []
        (x : xs) -> toLower x : xs

instance FromJSON BrockmanConfig where
  parseJSON = genericParseJSON myOptions

instance FromJSON BotConfig where
  parseJSON = genericParseJSON myOptions

instance FromJSON IrcConfig where
  parseJSON = genericParseJSON myOptions

instance FromJSON ControllerConfig where
  parseJSON = genericParseJSON myOptions

instance ToJSON BrockmanConfig where
  toJSON = genericToJSON myOptions

instance ToJSON BotConfig where
  toJSON = genericToJSON myOptions

instance ToJSON IrcConfig where
  toJSON = genericToJSON myOptions

instance ToJSON ControllerConfig where
  toJSON = genericToJSON myOptions
