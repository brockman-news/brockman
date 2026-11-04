{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module Brockman.Feed where

import Control.Applicative (Alternative (..))
import Control.Exception qualified as E
import Data.ByteString (ByteString)
import Data.ByteString qualified as B
import Data.ByteString.Builder qualified as BB
import Data.ByteString.Char8 qualified as B8
import Data.ByteString.Lazy qualified as BL
import Data.Cache.LRU qualified as LRU
import Data.Char (chr, isDigit, isHexDigit)
import Data.Fixed
import Data.Hashable (hash)
import Data.IORef
import Data.List
import Data.Maybe (fromMaybe, isNothing, mapMaybe)
import Data.Text (Text, intercalate, lines, strip, unwords)
import Data.Text.Encoding (decodeUtf8With)
import Data.Text.Encoding.Error (lenientDecode)
import Data.Time.Clock
import Data.Time.LocalTime (zonedTimeToUTC)
import Data.Time.RFC3339 (parseTimeRFC3339)
import Data.Time.RFC822 (parseTimeRFC822)
import Numeric (readHex)
import Text.HTMLEntity (decode')
import Xeno.SAX qualified as Xeno
import Xeno.Types (XenoException (..))

type LRU = LRU.LRU Int ()

data FeedItem = FeedItem
  { itemTitle :: Text,
    itemDate :: Maybe Text,
    itemLink :: Text
  }
  deriving (Show)

-- all brockman needs from a feed: its items and the timestamps that set the polling interval
data ParsedFeed = ParsedFeed
  { parsedItems :: [FeedItem],
    parsedTimes :: [Text]
  }

display :: Bool -> FeedItem -> Text
display showEntryDate item =
  let date = case (showEntryDate, itemDate item) of
        (True, Just entryDate) -> [entryDate]
        _ -> []
   in Data.Text.unwords $
        [strip $ itemLink item]
          ++ date
          ++ [decode' $ Data.Text.intercalate " | " $ Data.Text.lines $ strip $ itemTitle item]

averageDelta :: [UTCTime] -> Maybe Integer
averageDelta times = case times' of
  [] -> Nothing
  _ : timesRest -> fmap (`div` pico) $ mean $ map (unFixed . nominalDiffTimeToSeconds) $ zipWith diffUTCTime times' timesRest
  where
    pico = (^) @Integer @Integer 10 12
    times' = take 10 $ reverse $ nubBy sameMinute $ sort times
    sameMinute time1 time2 = abs (diffUTCTime time1 time2) < secondsToNominalDiffTime 60
    unFixed (MkFixed x) = x
    mean xs
      | null xs = Nothing
      | otherwise = Just $ round @Double $ fromIntegral (sum xs) / fromIntegral (length xs)

feedEntryDelta :: UTCTime -> [Text] -> Maybe Integer
feedEntryDelta now = averageDelta . (:) now . mapMaybe (fmap zonedTimeToUTC . parseTime . strip)
  where
    parseTime x = parseTimeRFC822 x <|> parseTimeRFC3339 x

-- A single SAX pass (xeno) that keeps only what brockman uses: per item its title, link and dates.
-- Building a whole document (the feed/xml-conduit stack) cost up to ~150x the feed's size in memory.
-- Item rules are the ones brockman had with the feed library:
--   RSS 2.0  <item>:  title, else description, else "untitled"; <link> text; <pubDate> shown and used for the interval
--   RSS 1.0  <item>:  title and link required; no dates
--   Atom     <entry>: title; href of the first <link>; <published> shown, <updated> used for the interval
-- Malformed XML (unquoted attributes in embedded HTML and the like) does not stop the parse: it resumes at the next
-- tag after the error, so one bad spot costs at most the item it is in.
parseFeed :: ByteString -> IO ParsedFeed
parseFeed body = do
  state <- newIORef initialParse
  let on step = modifyIORef' state . step
      on2 step a b = modifyIORef' state (step a b)
      handlers =
        Xeno.Process
          { Xeno.openF = on openTag,
            Xeno.attrF = on2 attribute,
            Xeno.endOpenF = on (const endOpenTag),
            Xeno.textF = on (content . decodeEntities),
            Xeno.closeF = on closeTag,
            Xeno.cdataF = on content
          }
      run input =
        E.try (Xeno.process handlers input) >>= \case
          Left (XenoParseError index _)
            | Just next <- B8.elemIndex '<' (B.drop (index + 1) input) -> run (B.drop (index + 1 + next) input)
          _ -> pure ()
  run (Xeno.skipDoctype body)
  Parse {parseKind, parseEntries} <- readIORef state
  let entries = reverse parseEntries
      kind = fromMaybe Unknown parseKind
  pure
    ParsedFeed
      { parsedItems = mapMaybe (toItem kind) entries,
        parsedTimes = mapMaybe (timeOf kind) entries
      }
  where
    toItem kind Entry {entryTitle, entryLink, entryDescription, entryPubDate, entryPublished} = case kind of
      RSS -> FeedItem (fromMaybe "untitled" (entryTitle <|> entryDescription)) entryPubDate <$> entryLink
      RSS1 -> FeedItem <$> entryTitle <*> pure Nothing <*> entryLink
      Atom -> FeedItem (fromMaybe "" entryTitle) entryPublished <$> entryLink
      Unknown -> Nothing
    timeOf kind Entry {entryPubDate, entryUpdated} = case kind of
      RSS -> entryPubDate
      Atom -> entryUpdated
      _ -> Nothing

data Kind = Unknown | RSS | RSS1 | Atom
  deriving (Eq)

data Field = Title | Link | Description | PubDate | Published | Updated
  deriving (Eq)

data Entry = Entry
  { entryTitle, entryLink, entryDescription, entryPubDate, entryPublished, entryUpdated :: Maybe Text
  }

data Parse = Parse
  { parseDepth :: Int,
    -- set from the root element, once
    parseKind :: Maybe Kind,
    -- depth of the <item>/<entry> being read
    parseItemDepth :: Maybe Int,
    parseEntry :: Entry,
    -- field of the current entry being read: which, at what depth, its text so far (reversed)
    parseCapture :: Maybe (Field, Int, [ByteString]),
    -- an Atom <link> of the current entry is open and its href becomes the entry's link
    parseLinkTag :: Bool,
    parseEntries :: [Entry]
  }

initialParse :: Parse
initialParse = Parse 0 Nothing Nothing emptyEntry Nothing False []

emptyEntry :: Entry
emptyEntry = Entry Nothing Nothing Nothing Nothing Nothing Nothing

localName :: ByteString -> ByteString
localName name = maybe name (\i -> B.drop (i + 1) name) (B8.elemIndexEnd ':' name)

openTag :: ByteString -> Parse -> Parse
openTag name p = case parseKind p of
  Nothing -> p' {parseKind = Just (rootKind (localName name))}
  Just kind -> openIn kind
  where
    openIn kind
      | kind /= Unknown, localName name == itemName kind = case parseItemDepth p of
          Nothing -> p' {parseItemDepth = Just depth, parseEntry = emptyEntry, parseCapture = Nothing}
          -- the previous item's close tag was lost (see closeTag): finish it and start this one as its sibling
          Just itemDepth -> (finishItem itemDepth p) {parseDepth = itemDepth, parseItemDepth = Just itemDepth, parseEntry = emptyEntry}
      | Just itemDepth <- parseItemDepth p,
        depth == itemDepth + 1,
        isNothing (parseCapture p) =
          case fieldOf kind name of
            Just Link | kind == Atom -> p' {parseLinkTag = isNothing (entryLink (parseEntry p))}
            Just field | isNothing (getField field (parseEntry p)) -> p' {parseCapture = Just (field, depth, [])}
            _ -> p'
      | otherwise = p'
    depth = parseDepth p + 1
    p' = p {parseDepth = depth}
    rootKind = \case
      "rss" -> RSS
      "RDF" -> RSS1
      "feed" -> Atom
      _ -> Unknown

itemName :: Kind -> ByteString
itemName kind = if kind == Atom then "entry" else "item"

-- Atom elements are matched by local name (prefixes are rare there); RSS only unprefixed, so atom:link, dc:date
-- or media:title inside an RSS item are not mistaken for its own elements
fieldOf :: Kind -> ByteString -> Maybe Field
fieldOf kind name = case kind of
  Atom -> case localName name of
    "title" -> Just Title
    "link" -> Just Link
    "published" -> Just Published
    "updated" -> Just Updated
    _ -> Nothing
  RSS -> case name of
    "title" -> Just Title
    "link" -> Just Link
    "description" -> Just Description
    "pubDate" -> Just PubDate
    _ -> Nothing
  RSS1 -> case name of
    "title" -> Just Title
    "link" -> Just Link
    _ -> Nothing
  Unknown -> Nothing

getField :: Field -> Entry -> Maybe Text
getField field = case field of
  Title -> entryTitle
  Link -> entryLink
  Description -> entryDescription
  PubDate -> entryPubDate
  Published -> entryPublished
  Updated -> entryUpdated

setField :: Field -> Text -> Entry -> Entry
setField field value entry = case field of
  Title -> entry {entryTitle = Just value}
  Link -> entry {entryLink = Just value}
  Description -> entry {entryDescription = Just value}
  PubDate -> entry {entryPubDate = Just value}
  Published -> entry {entryPublished = Just value}
  Updated -> entry {entryUpdated = Just value}

attribute :: ByteString -> ByteString -> Parse -> Parse
attribute key value p
  | parseLinkTag p, key == "href" = p {parseEntry = setField Link (decodeText (decodeEntities value)) (parseEntry p), parseLinkTag = False}
  | otherwise = p

endOpenTag :: Parse -> Parse
endOpenTag p = p {parseLinkTag = False}

content :: ByteString -> Parse -> Parse
content text p = case parseCapture p of
  Just (field, depth, chunks) | parseDepth p >= depth -> p {parseCapture = Just (field, depth, text : chunks)}
  _ -> p

-- Items end only at their own close tag: xeno ends CDATA at the first "]]" without checking for ">", so code like
-- a[b[i]] inside a CDATA section turns the rest of it into unbalanced tags and the depth drifts. Ending items by name
-- confines that to one item's fields; the next item starts from a fresh depth.
closeTag :: ByteString -> Parse -> Parse
closeTag name p = case (parseItemDepth p, parseKind p) of
  (Just itemDepth, Just kind) | localName name == itemName kind -> finishItem itemDepth p
  _ -> case parseCapture p of
    Just (field, depth, chunks)
      | depth == parseDepth p || (fieldOf <$> parseKind p <*> pure name) == Just (Just field) ->
          p {parseCapture = Nothing, parseDepth = depth - 1, parseEntry = setField field (captured chunks) (parseEntry p)}
    _ -> p {parseDepth = max 0 (parseDepth p - 1)}

-- ends the current item at itemDepth, keeping a field still being read
finishItem :: Int -> Parse -> Parse
finishItem itemDepth p =
  p {parseItemDepth = Nothing, parseCapture = Nothing, parseDepth = itemDepth - 1, parseEntries = entry : parseEntries p}
  where
    entry = case parseCapture p of
      Just (field, _, chunks) -> setField field (captured chunks) (parseEntry p)
      Nothing -> parseEntry p

captured :: [ByteString] -> Text
captured = decodeText . B.concat . reverse

decodeText :: ByteString -> Text
decodeText = decodeUtf8With lenientDecode

-- the five XML entities and character references; anything else (e.g. HTML's &nbsp;) stays for display's HTML decoding
decodeEntities :: ByteString -> ByteString
decodeEntities text
  | isNothing (B8.elemIndex '&' text) = text
  | otherwise = BL.toStrict $ BB.toLazyByteString $ go text
  where
    go s = case B8.break (== '&') s of
      (before, rest)
        | B.null rest -> BB.byteString before
        | otherwise -> BB.byteString before <> entity (B.drop 1 rest)
    entity rest = case B8.elemIndex ';' (B.take 12 rest) of
      Just end | Just c <- reference (B.take end rest) -> BB.charUtf8 c <> go (B.drop (end + 1) rest)
      _ -> BB.char7 '&' <> go rest
    reference = \case
      "lt" -> Just '<'
      "gt" -> Just '>'
      "amp" -> Just '&'
      "quot" -> Just '"'
      "apos" -> Just '\''
      name -> case B8.uncons name of
        Just ('#', number) -> case B8.uncons number of
          Just (x, hex) | x `elem` ("xX" :: [Char]), B8.all isHexDigit hex -> case readHex (B8.unpack hex) of
            [(n, "")] -> codePoint n
            _ -> Nothing
          _ | B8.all isDigit number, Just (n, rest) <- B8.readInt number, B.null rest -> codePoint n
          _ -> Nothing
        _ -> Nothing
    codePoint n
      | n > 0, n <= 0x10FFFF, n < 0xD800 || n > 0xDFFF = Just (chr n)
      | otherwise = Nothing

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
