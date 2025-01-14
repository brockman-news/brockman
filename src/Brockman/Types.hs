{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase #-}

module Brockman.Types where

import Control.Applicative
import Control.Concurrent.MVar
import Control.Lens
import Data.Aeson hiding ((.=))
import Data.Aeson.Encode.Pretty (encodePretty)
import qualified Data.Aeson.Key
import Data.Aeson.KeyMap (keys)
import Data.Aeson.Types
import Data.ByteString (ByteString)
import qualified Data.ByteString.Lazy as BL
import Data.CaseInsensitive (CI, foldedCase, mk)
import Data.Char (isLower, toLower)
import Data.Data (Data, constrFields, toConstr)
import Data.List (intercalate)
import Data.Map.Strict (Map, lookup, union)
import Data.Maybe (fromMaybe)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import Data.Text.Encoding (decodeUtf8, encodeUtf8)
import Data.Typeable (Typeable)
import GHC.Generics (Generic, Rep)
import qualified Network.IRC.Conduit as IRC
import System.Directory (getHomeDirectory)
import System.FilePath ((</>))

class Decode a where decode :: ByteString -> a

class Encode a where encode :: a -> ByteString

type URL = Text

newtype Nick = Nick {unNick :: IRC.NickName (CI Text)} deriving (Data, Eq, Ord)

instance Show Nick where show = show . unNick

instance FromJSON Nick where parseJSON = fmap (Nick . mk) . parseJSON

instance ToJSON Nick where toJSON = toJSON . foldedCase . unNick

instance ToJSONKey Nick where toJSONKey = toJSONKeyText (foldedCase . unNick)

instance FromJSONKey Nick where fromJSONKey = FromJSONKeyText (Nick . mk)

instance Decode Nick where decode = Nick . mk . decodeUtf8

instance Encode Nick where encode = encodeUtf8 . foldedCase . unNick

newtype Channel = Channel {unChannel :: IRC.ChannelName (CI Text)} deriving (Data, Eq, Ord)

instance Show Channel where show = show . unChannel

instance FromJSON Channel where parseJSON = fmap (Channel . mk) . parseJSON

instance ToJSON Channel where toJSON = toJSON . foldedCase . unChannel

instance Decode Channel where decode = Channel . mk . decodeUtf8

instance Encode Channel where encode = encodeUtf8 . foldedCase . unChannel

configBotsL :: Lens' BrockmanConfig (Map Nick BotConfig)
configBotsL = lens configBots (\config bots -> config {configBots = bots})

configControllerL :: Lens' BrockmanConfig (Maybe ControllerConfig)
configControllerL = lens configController (\config controller -> config {configController = controller})

controllerExtraChannelsL :: Lens' ControllerConfig (Maybe (Set Channel))
controllerExtraChannelsL = lens controllerExtraChannels (\controller channels -> controller {controllerExtraChannels = channels})

botFeedL :: Lens' BotConfig URL
botFeedL = lens botFeed (\bot feed -> bot {botFeed = feed})

botDelayL :: Lens' BotConfig (Maybe Integer)
botDelayL = lens botDelay (\bot delay -> bot {botDelay = delay})

botExtraChannelsL :: Lens' BotConfig (Maybe (Set Channel))
botExtraChannelsL = lens botExtraChannels (\bot channels -> bot {botExtraChannels = channels})

botChannels :: Nick -> BrockmanConfig -> Set Channel
botChannels nick config = Set.insert (configChannel config) $ fromMaybe Set.empty $ botExtraChannels =<< Data.Map.Strict.lookup nick (configBots config)

mergeIrcConfig :: IrcConfig -> IrcConfig -> IrcConfig
mergeIrcConfig a b =
  IrcConfig
    { ircHost = ircHost b,
      ircPort = ircPort a <|> ircPort b,
      ircTls = ircTls a <|> ircTls b
    }

mergeControllerConfig :: Maybe ControllerConfig -> Maybe ControllerConfig -> Maybe ControllerConfig
mergeControllerConfig (Just a) (Just b) =
  Just
    ControllerConfig
      { controllerNick = controllerNick b,
        controllerExtraChannels = controllerExtraChannels a <> controllerExtraChannels b
      }
mergeControllerConfig (Just a) _ = Just a
mergeControllerConfig _ (Just b) = Just b
mergeControllerConfig _ _ = Nothing

mergeBrockmanConfig :: BrockmanConfig -> BrockmanConfig -> BrockmanConfig
mergeBrockmanConfig a b =
  BrockmanConfig
    { configBots = configBots a `union` configBots b,
      configChannel = configChannel b,
      configController = configController a `mergeControllerConfig` configController b,
      configIrc = configIrc a `mergeIrcConfig` configIrc b,
      configNoPrivmsg = configNoPrivmsg a <|> configNoPrivmsg b,
      configShortener = configShortener a <|> configShortener b,
      configStatePath = configStatePath a <|> configStatePath b,
      configPastebin = configPastebin a <|> configPastebin b,
      configDefaultDelay = configDefaultDelay a <|> configDefaultDelay b,
      configMaxStartDelay = configMaxStartDelay a <|> configMaxStartDelay b,
      configNotifyErrors = configNotifyErrors a <|> configNotifyErrors b,
      configShowEntryDate = configShowEntryDate a <|> configShowEntryDate b
    }

data BrockmanConfig = BrockmanConfig
  { configBots :: Map Nick BotConfig,
    configChannel :: Channel,
    configIrc :: IrcConfig,
    configShortener :: Maybe URL,
    configController :: Maybe ControllerConfig,
    configStatePath :: Maybe FilePath,
    configPastebin :: Maybe URL,
    configDefaultDelay :: Maybe Integer,
    configMaxStartDelay :: Maybe Integer,
    configNotifyErrors :: Maybe Bool,
    configNoPrivmsg :: Maybe Bool,
    configShowEntryDate :: Maybe Bool
  }
  deriving (Data, Generic, Show, Typeable)

data ControllerConfig = ControllerConfig
  { controllerNick :: Nick,
    controllerExtraChannels :: Maybe (Set Channel)
  }
  deriving (Data, Generic, Show, Typeable)

data IrcConfig = IrcConfig
  { ircHost :: URL,
    ircPort :: Maybe Int,
    ircTls :: Maybe Bool
  }
  deriving (Data, Generic, Show, Typeable)

data BotConfig = BotConfig
  { botFeed :: URL,
    botExtraChannels :: Maybe (Set Channel),
    botDelay :: Maybe Integer
  }
  deriving (Data, Generic, Show, Typeable)

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

parseStrictJSON :: (Data a, Generic a, GFromJSON Zero (Rep a)) => Value -> Parser a
parseStrictJSON jsonValue = checkExtraneousKeys myOptions jsonValue =<< genericParseJSON myOptions jsonValue
  where
    checkExtraneousKeys :: (Data a, MonadFail m) => Options -> Value -> a -> m a
    checkExtraneousKeys options value parsed =
      case value of
        Object o ->
          let objectKeys :: Set.Set String
              objectKeys = Set.fromList $ map Data.Aeson.Key.toString $ keys o
              recordFields = Set.fromList $ fmap (fieldLabelModifier options) $ constrFields $ toConstr parsed
              difference = Set.difference objectKeys recordFields
           in if Set.null difference
                then return parsed
                else fail $ "extraneous keys in input: " ++ intercalate ", " (Set.toList difference)
        _ -> fail $ "expected JSON object, got: " ++ show value

instance FromJSON BrockmanConfig where
  parseJSON = parseStrictJSON

instance FromJSON BotConfig where
  parseJSON = parseStrictJSON

instance FromJSON IrcConfig where
  parseJSON = parseStrictJSON

instance FromJSON ControllerConfig where
  parseJSON = parseStrictJSON

instance ToJSON BrockmanConfig where
  toJSON = genericToJSON myOptions

instance ToJSON BotConfig where
  toJSON = genericToJSON myOptions

instance ToJSON IrcConfig where
  toJSON = genericToJSON myOptions

instance ToJSON ControllerConfig where
  toJSON = genericToJSON myOptions
