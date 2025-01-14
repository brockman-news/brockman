{-# LANGUAGE TypeApplications #-}

module Brockman.Util where

import Brockman.Types (Encode (encode), Nick)
import Control.Concurrent (killThread, myThreadId, threadDelay)
import Control.Exception (SomeException, handle)
import Control.Lens
import Control.Monad.IO.Class (MonadIO (..), liftIO)
import Data.Aeson (ToJSON (toJSON))
import Data.Aeson.Encode.Pretty (encodePretty)
import Data.ByteString (ByteString)
import Data.ByteString.Char8 (all, uncons)
import Data.ByteString.Lazy (toStrict)
import Data.Char (isAsciiLower, isAsciiUpper)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text, unpack)
import qualified Data.Text as T (words)
import Data.Text.Encoding (decodeUtf8With, encodeUtf8)
import Network.Wreq (post, responseBody)
import System.Log.Logger

eloop :: IO a -> IO a
eloop x =
  handle @SomeException
    ( \ex -> do
        warningM "brockman" (show ex)
        sleepSeconds 10
        x
    )
    x

sleepSeconds :: Integer -> IO ()
sleepSeconds n = threadDelay $ fromInteger (n * (^) @Integer @Integer 10 6)

optionally :: (Applicative f) => (a -> f ()) -> Maybe a -> f ()
optionally = maybe (pure ())

notice :: (MonadIO m) => Nick -> String -> m ()
notice nick message =
  liftIO $ noticeM "brockman" ("[" <> show nick <> "] " <> message)

debug :: (MonadIO m) => Nick -> String -> m ()
debug nick message =
  liftIO $ debugM "brockman" ("[" <> show nick <> "] " <> message)

warning :: (MonadIO m) => Nick -> String -> m ()
warning nick message =
  liftIO $ warningM "brockman" ("[" <> show nick <> "] " <> message)

error' :: (MonadIO m) => Nick -> String -> m ()
error' nick message =
  liftIO $ errorM "brockman" ("[" <> show nick <> "] " <> message)

suicide :: IO ()
suicide = killThread =<< myThreadId

decodeUtf8 :: ByteString -> Text
decodeUtf8 = decodeUtf8With $ \_error _ -> Just '?'

insert :: (Ord a) => a -> Maybe (Set a) -> Maybe (Set a)
insert value list =
  Just $ case list of
    Nothing -> Set.singleton value
    Just values -> Set.insert value values

delete :: (Ord a) => a -> Maybe (Set a) -> Maybe (Set a)
delete value list =
  case Set.delete value <$> list of
    Just xs
      | Set.null xs -> Nothing
      | otherwise -> Just xs
    Nothing -> Nothing

bsWords :: ByteString -> [ByteString]
bsWords = map encodeUtf8 . T.words . decodeUtf8

-- as defined in https://tools.ietf.org/html/rfc1459#page-9
isValidIrcNick :: Nick -> Bool
isValidIrcNick nick =
  case Data.ByteString.Char8.uncons $ encode nick of
    Nothing -> False
    Just (first, rest) -> isLetter first && Data.ByteString.Char8.all (\c -> isLetter c || isNumber c || isSpecial c) rest
  where
    isLetter c = isAsciiLower c || isAsciiUpper c
    isNumber c = c `elem` ("0123456789" :: String)
    isSpecial c = c `elem` ("-[]\\`^{}_|" :: String) -- '_' and '|' are not in the RFC, but they work

pasteJson :: (ToJSON a) => Text -> a -> IO Text
pasteJson endpoint value = do
  response <- post (Data.Text.unpack endpoint) . encodePretty $ toJSON value
  return $ decodeUtf8 $ Data.ByteString.Lazy.toStrict $ response ^. responseBody
