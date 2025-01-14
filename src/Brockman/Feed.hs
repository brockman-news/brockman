{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module Brockman.Feed where

import Control.Applicative (Alternative (..))
import qualified Data.Cache.LRU as LRU
import Data.Fixed
import Data.Hashable (hash)
import Data.List
import Data.Maybe (fromMaybe, listToMaybe, mapMaybe)
import Data.Text (Text, intercalate, lines, pack, strip, unwords)
import Data.Time.Clock
import Data.Time.LocalTime (zonedTimeToUTC)
import Data.Time.RFC3339 (parseTimeRFC3339)
import Data.Time.RFC822 (parseTimeRFC822)
import Text.Atom.Feed (Entry (entryUpdated))
import qualified Text.Atom.Feed as Atom
import Text.Feed.Query (feedItems)
import qualified Text.Feed.Types as Feed (Feed (..), Item (..))
import Text.HTMLEntity (decode')
import Text.RSS.Syntax (RSSItem (rssItemPubDate))
import qualified Text.RSS.Syntax as RSS
import qualified Text.RSS1.Syntax as RSS1

type LRU = LRU.LRU Int ()

data FeedItem = FeedItem
  { itemTitle :: Text,
    itemDate :: Maybe RSS.DateString,
    itemLink :: Text
  }
  deriving (Show)

display :: Bool -> FeedItem -> Text
display showEntryDate item =
  let date = case (showEntryDate, itemDate item) of
        (True, Just entryDate) -> [entryDate]
        _ -> []
   in Data.Text.unwords $
        [strip $ itemLink item]
          ++ date
          ++ [decode' $ Data.Text.intercalate " | " $ Data.Text.lines $ strip $ itemTitle item]

feedEntryUtc :: Feed.Item -> Maybe UTCTime
feedEntryUtc item =
  zonedTimeToUTC
    <$> ( parseTime
            =<< case item of
              Feed.RSSItem rssItem -> rssItemPubDate rssItem
              Feed.AtomItem atomItem -> Just $ entryUpdated atomItem
              _ -> Nothing
        )
  where
    parseTime x = parseTimeRFC822 x <|> parseTimeRFC3339 x

averageDelta :: [UTCTime] -> Maybe Integer
averageDelta times = fmap (`div` pico) $ mean $ map (unFixed . nominalDiffTimeToSeconds) $ zipWith diffUTCTime times' (tail times')
  where
    pico = (^) @Integer @Integer 10 12
    times' = take 10 $ reverse $ nubBy sameMinute $ sort times
    sameMinute time1 time2 = abs (diffUTCTime time1 time2) < secondsToNominalDiffTime 60
    unFixed (MkFixed x) = x
    mean xs
      | null xs = Nothing
      | otherwise = Just $ round @Double $ fromIntegral (sum xs) / fromIntegral (length xs)

feedEntryDelta :: UTCTime -> Feed.Feed -> Maybe Integer
feedEntryDelta now = averageDelta . (:) now . mapMaybe feedEntryUtc . feedItems

feedToItems :: Maybe Feed.Feed -> [FeedItem]
feedToItems = maybe [] (mapMaybe fromItem . feedItems)
  where
    fromItem = \case
      Feed.AtomItem entry ->
        let title = pack $ Atom.txtToString $ Atom.entryTitle entry
            link = Atom.linkHref <$> listToMaybe (Atom.entryLinks entry)
            date = Atom.entryPublished entry
         in FeedItem title date <$> link
      Feed.RSSItem item ->
        let title = fromMaybe "untitled" (RSS.rssItemTitle item <|> RSS.rssItemDescription item)
            link = RSS.rssItemLink item
            date = RSS.rssItemPubDate item
         in FeedItem title date <$> link
      Feed.RSS1Item item ->
        Just $ FeedItem (RSS1.itemTitle item) Nothing (RSS1.itemLink item)
      _ -> Nothing

deduplicate :: Maybe LRU -> [FeedItem] -> (LRU, [FeedItem])
deduplicate maybeLRU items
  | Just lru <- maybeLRU,
    Just capacity <- LRU.maxSize lru,
    capacity >= genericLength items =
      insertItems lru items
  | otherwise = insertItems (LRU.newLRU (Just $ genericLength items * 2)) items
  where
    key = hash . itemLink
    insertItems lru items' = foldl' step (lru, []) items'
    step (lru, items') item =
      case LRU.lookup (key item) lru of
        (newLRU, Nothing) -> (LRU.insert (key item) () newLRU, item : items')
        (newLRU, Just ()) -> (newLRU, items')
