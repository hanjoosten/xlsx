{-# LANGUAGE ConstraintKinds     #-}
{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE DerivingVia         #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StrictData          #-}
{-# LANGUAGE TemplateHaskell     #-}

-- | Writes excell files from a stream, which allows creation of
--   large excell files while remaining in constant memory.
module Codec.Xlsx.Writer.Stream
  ( writeXlsx
  , writeXlsxWithSharedStrings
  , WriteSettings(..)
  , defaultSettings
  , wsSheetView
  , wsZip
  , wsColumnProperties
  , wsRowProperties
  , wsStyles
  -- *** Shared strings
  , sharedStrings
  , sharedStringsStream
  ) where

import           Codec.Archive.Zip.Conduit.UnZip
import           Codec.Archive.Zip.Conduit.Zip
import           Codec.Xlsx.Parser.Internal              (n_)
import           Codec.Xlsx.Parser.Stream
import           Codec.Xlsx.Types                        (ColumnsProperties (..),
                                                          RowProperties (..),
                                                          Styles (..),
                                                          _AutomaticHeight,
                                                          _CustomHeight,
                                                          emptyStyles,
                                                          rowHeightLens)
import           Codec.Xlsx.Types.Cell
import           Codec.Xlsx.Types.Common
import           Codec.Xlsx.Types.Internal.Relationships (odr, pr)
import           Codec.Xlsx.Types.SheetViews
import           Codec.Xlsx.Writer.Internal              (nonEmptyElListSimple,
                                                          toAttrVal, toElement,
                                                          txtd, txti)
import           Codec.Xlsx.Writer.Internal.Stream
import           Conduit                                 (PrimMonad, yield,
                                                          (.|))
import qualified Conduit                                 as C
import           Control.Lens
import           Control.Monad.Catch
import           Control.Monad.Reader.Class
import           Control.Monad.State.Strict
import           Data.ByteString                         (ByteString)
import           Data.ByteString.Builder                 (Builder)
import           Data.Coerce
import           Data.Conduit                            (ConduitT)
import qualified Data.Conduit.List                       as CL
import           Data.Foldable                           (fold, traverse_)
import           Data.List
import           Data.Map.Strict                         (Map)
import qualified Data.Map.Strict                         as Map
import           Data.Maybe
import           Data.Text                               (Text)
import           Data.Time
import           Data.Word
import           Data.XML.Types
import           Text.Printf
import           Text.XML                                (toXMLElement)
import qualified Text.XML                                as TXML
import           Text.XML.Stream.Render
import           Text.XML.Unresolved                     (elementToEvents)
import qualified Data.Text as Text


mapFold :: MonadState SharedStringState m => SheetItem  -> m [(Text,Int)]
mapFold  row =
  traverse getSetNumber items
  where
    items :: [Text]
    items = row ^.. si_cell_row . traversed . cellValue . _Just . _CellText

-- | Process sheetItems into shared strings structure to be put into
--   'writeXlsxWithSharedStrings'
sharedStrings :: Monad m  => ConduitT SheetItem b m (Map Text Int)
sharedStrings = void sharedStringsStream .| CL.foldMap (uncurry Map.singleton)

-- | creates a unique number for every encountered string in the stream
--   This is used for creating a required structure in the xlsx format
--   called shared strings. Every string get's transformed into a number
--
--   exposed to allow further processing, we also know the map after processing
--   but I don't think conduit provides a way of getting that out.
--   use 'sharedStrings' to just get the map
sharedStringsStream :: Monad m  =>
  ConduitT SheetItem (Text, Int) m (Map Text Int)
sharedStringsStream = fmap (view string_map) $ C.execStateC initialSharedString $
  CL.mapFoldableM mapFold

-- note that currently we support only a single sheet.
data WriteSettings = MkWriteSettings
  { _wsSheetView        :: [SheetView]
  , _wsZip              :: ZipOptions
  , _wsColumnProperties :: [ColumnsProperties]
  , _wsRowProperties    :: Map Int RowProperties
  , _wsStyles           :: Styles
  }
instance Show  WriteSettings where
  -- ZipOptions lacks a show instance-}
  show (MkWriteSettings s _ y r _) = printf "MkWriteSettings{ _wsSheetView=%s, _wsColumnProperties=%s, _wsZip=defaultZipOptions, _wsRowProperties=%s }" (show s) (show y) (show r)
makeLenses ''WriteSettings

defaultSettings :: WriteSettings
defaultSettings = MkWriteSettings
  { _wsSheetView = []
  , _wsColumnProperties = []
  , _wsRowProperties = mempty
  , _wsStyles = emptyStyles
  , _wsZip = defaultZipOptions {
  zipOpt64 = False -- TODO renable
  -- There is a magick number in the zip archive package,
  -- https://hackage.haskell.org/package/zip-archive-0.4.1/docs/src/Codec.Archive.Zip.html#local-6989586621679055672
  -- if we enable 64bit the number doesn't align causing the test to fail.
  -- I'll make the test pass, and after that I'll make the
  }
  }


--   To validate the result is correct xml:
--
--   @
--   docker run -v $(pwd):/app/xlsx-validator/xlsx -it vindvaki/xlsx-validator xlsx-validator xlsx/yourfile.xlsx
--   @
--
--   TODO: package that program for nix and make a unit test out of it.
--   it's *really* usefull.
--
--   This will put the xlsx project root in the current working
--   directory of xlsx validator,
--   allowing you to run that program on the output from
--   streaming (which in this example was written to out/out.xlsx).
--   This gives a much more descriptive error reporting than excel.
-- | Transform a 'SheetItem' stream into a stream that creates the xlsx file format
--   (to be consumed by sinkfile for example)
--  This first runs 'sharedStrings' and then 'writeXlsxWithSharedStrings'.
--  If you want xlsx files this is the most obvious function to use.
--  the others are exposed in case you can cache the shared strings for example.
--
--  Note that the current concatination concatinates everything into a single sheet.
--  In other words there is no tab support yet.
writeXlsx :: MonadThrow m
    => PrimMonad m
    => WriteSettings -- ^ use 'defaultSettings'
    -> ConduitT () SheetItem m () -- ^ the conduit producing sheetitems
    -> ConduitT () ByteString m Word64 -- ^ result conduit producing xlsx files
writeXlsx settings sheetC = do
    sstrings  <- sheetC .| sharedStrings
    writeXlsxWithSharedStrings settings sstrings sheetC


-- TODO maybe should use bimap instead: https://hackage.haskell.org/package/bimap-0.4.0/docs/Data-Bimap.html
-- it guarantees uniqueness of both text and int
-- | This write excell file with a shared strings lookup table.
--   It appears that it is optional.
--   Failed lookups will result in valid xlsx.
--   There are several conditions on shared strings,
--
--      1. Every text to int is unique on both text and int.
--      2. Every Int should have a gap no greater then 1. [("xx", 3), ("yy", 4)] is okay, whereas [("xx", 3), ("yy", 5)] is not.
--      3. It's expected this starts from 0.
--
--   Use 'sharedStringsStream' to get a good shared strings table.
--   This is provided because the user may have a more efficient way of
--   constructing this table then the library can provide,
--   for example trough database operations.
writeXlsxWithSharedStrings :: MonadThrow m => PrimMonad m
    => WriteSettings
    -> Map Text Int -- ^ shared strings table
    -> ConduitT () SheetItem m ()
    -> ConduitT () ByteString m Word64
writeXlsxWithSharedStrings settings sstable items = do
  res  <- combinedFiles settings sstable items .| zipStream (settings ^. wsZip)
  -- yield (LBS.toStrict $ BS.toLazyByteString $ BS.word32LE 0x06054b50) -- insert magic number for fun.
  pure res

-- massive amount of boilerplate needed for excel to function
boilerplate :: forall m . PrimMonad m  => WriteSettings -> Map Text Int -> [(ZipEntry,  ZipData m)]
boilerplate settings sstable =
  [ (zipEntry "xl/sharedStrings.xml", ZipDataSource $ writeSst sstable .| eventsToBS)
  , (zipEntry "[Content_Types].xml", ZipDataSource $ writeContentTypes .| eventsToBS)
  , (zipEntry "xl/workbook.xml", ZipDataSource $ writeWorkbook .| eventsToBS)
  , (zipEntry "xl/styles.xml", ZipDataByteString $ coerce $ settings ^. wsStyles)
  , (zipEntry "xl/_rels/workbook.xml.rels", ZipDataSource $ writeWorkbookRels .| eventsToBS)
  , (zipEntry "_rels/.rels", ZipDataSource $ writeRootRels .| eventsToBS)
  ]

combinedFiles :: PrimMonad m
  => WriteSettings
  -> Map Text Int
  -> ConduitT () SheetItem m ()
  -> ConduitT () (ZipEntry, ZipData m) m ()
combinedFiles settings sstable items =
  C.yieldMany $
    boilerplate settings  sstable <>
    [(zipEntry "xl/worksheets/sheet1.xml", ZipDataSource $
       items .| C.runReaderC settings (writeWorkSheet sstable) .| eventsToBS )]

el :: Monad m => Name -> Monad m => forall i.  ConduitT i Event m () -> ConduitT i Event m ()
el x = tag x mempty

--   Clark notation a lot for xml namespaces:
--   <https://hackage.haskell.org/package/xml-types-0.3.8/docs/Data-XML-Types.html#t:Name>
override :: Monad m => Text -> Text -> forall i.  ConduitT i Event m ()
override content' part =
    tag "{http://schemas.openxmlformats.org/package/2006/content-types}Override"
      (attr "ContentType" content'
       <> attr "PartName" part) $ pure ()


-- | required by excell.
writeContentTypes :: Monad m => forall i.  ConduitT i Event m ()
writeContentTypes = doc "{http://schemas.openxmlformats.org/package/2006/content-types}Types" $ do
    override "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml" "/xl/workbook.xml"
    override "application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml" "/xl/sharedStrings.xml"
    override "application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml" "/xl/styles.xml"
    override "application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml" "/xl/worksheets/sheet1.xml"
    override "application/vnd.openxmlformats-package.relationships+xml" "/xl/_rels/workbook.xml.rels"
    override "application/vnd.openxmlformats-package.relationships+xml" "/_rels/.rels"

-- | required by excell.
writeWorkbook :: Monad m => forall i.  ConduitT i Event m ()
writeWorkbook = doc (n_ "workbook") $ do
    el (n_ "sheets") $ do
      tag (n_ "sheet")
        (attr "name" "Sheet1"
         <> attr "sheetId" "1" <>
         attr (odr "id") "rId3") $
        pure ()

doc :: Monad m => Name ->  forall i.  ConduitT i Event m () -> ConduitT i Event m ()
doc root docM = do
  yield EventBeginDocument
  el root docM
  yield EventEndDocument

relationship :: Monad m => Text -> Int -> Text ->  forall i.  ConduitT i Event m ()
relationship target id' type' =
  tag (pr "Relationship")
    (attr "Type" type'
      <> attr "Id" (Text.pack $ "rId" <> show id')
      <> attr "Target" target
    ) $ pure ()

writeWorkbookRels :: Monad m => forall i.  ConduitT i Event m ()
writeWorkbookRels = doc (pr "Relationships") $  do
  relationship "sharedStrings.xml" 1 "http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings"
  relationship "worksheets/sheet1.xml" 3 "http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet"
  relationship "styles.xml" 2 "http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles"

writeRootRels :: Monad m => forall i.  ConduitT i Event m ()
writeRootRels = doc (pr "Relationships") $  do
  relationship "xl/workbook.xml" 1 "http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument"
  -- relationship "docProps/core.xml" "rId2" "http://schemas.openxmlformats.org/officeDocument/2006/relationships/metadata/core-properties"
  -- relationship "docProps/app.xml" "rId3" "http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties"


zipEntry :: Text -> ZipEntry
zipEntry x = ZipEntry
  { zipEntryName = Left x
  , zipEntryTime = LocalTime (toEnum 0) midnight
  , zipEntrySize = Nothing
  , zipEntryExternalAttributes = Nothing
  }

eventsToBS :: PrimMonad m  => ConduitT Event ByteString m ()
eventsToBS = writeEvents .| C.builderToByteString

writeSst ::  Monad m  => Map Text Int  -> forall i.  ConduitT i Event m ()
writeSst sstable = doc (n_ "sst") $
    void $ traverse (el (n_ "si") .  el (n_ "t") . content . fst
                  ) $ sortBy (\(_, i) (_, y :: Int) -> compare i y) $ Map.toList sstable

writeEvents ::  PrimMonad m => ConduitT Event Builder m ()
writeEvents = renderBuilder (def {rsPretty=False})

sheetViews :: forall m . MonadReader WriteSettings m => forall i . ConduitT i Event m ()
sheetViews = el (n_ "sheetViews") $ do
  sheetView <- view wsSheetView
  let
      view' :: [Element]
      view' = setNameSpaceRec spreadSheetNS . toXMLElement .  toElement (n_ "sheetView") <$> sheetView
  -- tag (n_ "sheetView") (attr "topLeftCell" "D10" <> attr "tabSelected" "1") $ pure ()
  C.yieldMany $ elementToEvents =<< view'

spreadSheetNS :: Text
spreadSheetNS = fold $ nameNamespace $ n_ ""

setNameSpaceRec :: Text -> Element -> Element
setNameSpaceRec space xelm =
    xelm {elementName = ((elementName xelm ){nameNamespace =
                                    Just space })
      , elementNodes = elementNodes xelm <&> \case
                                    NodeElement x -> NodeElement (setNameSpaceRec space x)
                                    y -> y
    }

columns :: MonadReader WriteSettings m => ConduitT SheetItem Event m ()
columns = do
  colProps <- view wsColumnProperties
  let cols :: Maybe TXML.Element
      cols = nonEmptyElListSimple (n_ "cols") $ map (toElement (n_ "col")) colProps
  traverse_ (C.yieldMany . elementToEvents . toXMLElement) cols

writeWorkSheet :: MonadReader WriteSettings  m => Map Text Int  -> ConduitT SheetItem Event m ()
writeWorkSheet sstable = doc (n_ "worksheet") $ do
    sheetViews
    columns
    el (n_ "sheetData") $ C.awaitForever (mapRow sstable)

mapRow :: MonadReader WriteSettings m => Map Text Int -> SheetItem -> ConduitT SheetItem Event m ()
mapRow sstable sheetItem = do
  mRowProp <- preview $ wsRowProperties . ix rowIx . rowHeightLens . _Just . failing _CustomHeight _AutomaticHeight
  let rowAttr :: Attributes
      rowAttr = ixAttr <> fold (attr "ht" . txtd <$> mRowProp)
  tag (n_ "row") rowAttr $
    void $ itraverse (mapCell sstable rowIx) (sheetItem ^. si_cell_row)
  where
    rowIx = sheetItem ^. si_row_index
    ixAttr = attr "r" $ toAttrVal rowIx

mapCell :: Monad m => Map Text Int -> RowIndex -> ColIndex -> Cell -> ConduitT SheetItem Event m ()
mapCell sstable rix cix cell =
  tag (n_ "c") celAttr $
    el (n_ "v") $
      content $ renderCell sstable cell
  where
    celAttr  = attr "r" ref <>
      renderCellType sstable cell
      <> foldMap (attr "s" . txti) (cell ^. cellStyle)
    ref :: Text
    ref = coerce $ singleCellRef (rix, cix)

renderCellType :: Map Text Int -> Cell -> Attributes
renderCellType sstable cell =
  maybe mempty
  (attr "t" . renderType sstable)
  $ cell ^? cellValue . _Just

renderCell :: Map Text Int -> Cell -> Text
renderCell sstable cell =  renderValue sstable val
  where
    val :: CellValue
    val = fromMaybe (CellText mempty) $ cell ^? cellValue . _Just

renderValue :: Map Text Int -> CellValue -> Text
renderValue sstable = \case
  CellText x ->
    -- if we can't find it in the sst, print the string
    maybe x toAttrVal $ sstable ^? ix x
  CellDouble x -> toAttrVal x
  CellBool b -> toAttrVal b
  CellRich _ -> error "rich text is not supported yet"
  CellError err  -> toAttrVal err


renderType :: Map Text Int -> CellValue -> Text
renderType sstable = \case
  CellText x ->
    maybe "str" (const "s") $ sstable ^? ix x
  CellDouble _ -> "n"
  CellBool _ -> "b"
  CellRich _ -> "r"
  CellError _ -> "e"
