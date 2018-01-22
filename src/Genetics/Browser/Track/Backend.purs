module Genetics.Browser.Track.Backend where

import Prelude

import Color (Color, black, white)
import Color.Scheme.Clrs (aqua, blue, fuchsia, green, lime, maroon, navy, olive, orange, purple, red, teal, yellow)
import Control.Monad.Aff (Aff)
import Control.Monad.Eff.Exception (error)
import Control.Monad.Error.Class (throwError)
import Control.Monad.Reader (class MonadReader, ask)
import Data.Argonaut (Json, _Array, _Number, _Object, _String)
import Data.Array ((..))
import Data.Array as Array
import Data.Bifunctor (bimap)
import Data.Filterable (class Filterable, filterMap)
import Data.Foldable (class Foldable, fold, foldMap, foldl, length, maximum)
import Data.FunctorWithIndex (mapWithIndex)
import Data.Int as Int
import Data.Lens ((^.), (^?))
import Data.Lens.Index (ix)
import Data.List (List)
import Data.List as List
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(Just, Nothing), fromMaybe)
import Data.Monoid (class Monoid, mempty)
import Data.Newtype (unwrap)
import Data.Profunctor.Strong (fanout)
import Data.Record as Record
import Data.Symbol (SProxy(..))
import Data.Traversable (traverse)
import Data.Tuple (Tuple(Tuple), snd, uncurry)
import Data.Unfoldable (class Unfoldable, none)
import Genetics.Browser.Types (Bp(Bp), ChrId(ChrId), Point)
import Genetics.Browser.Types.Coordinates (BrowserPoint, CoordInterval, CoordSys(CoordSys), Interval, Normalized(Normalized), _BrowserIntervals, _CoordSys, _Index, _Interval, intervalToScreen, nPointToFrame, normPoint, viewIntervals)
import Genetics.Browser.View (Pixels)
import Graphics.Drawing (Drawing, circle, fillColor, filled, lineWidth, outlineColor, outlined, rectangle, scale, translate)
import Graphics.Drawing as Drawing
import Graphics.Drawing.Font (font, sansSerif)
import Network.HTTP.Affjax as Affjax
import Type.Prelude (class RowLacks)
import Unsafe.Coerce (unsafeCoerce)

type BrowserView = Interval BrowserPoint


intersection :: forall k a b.
                Ord k
             => Map k a
             -> Map k b
             -> Map k a
intersection a b = Map.filterKeys (flip Map.member b) a

zipMaps :: forall k a b.
           Ord k
        => Map k a
        -> Map k b
        -> Map k (Tuple a b)
zipMaps a b =
  let kas = Array.unzip $ Map.toAscUnfoldable $ a `intersection` b
      kbs = Array.unzip $ Map.toAscUnfoldable $ b `intersection` a
      kabs = uncurry Array.zip $ map (Array.zip (snd kas)) kbs
  in Map.fromFoldable kabs


zipMapsWith :: forall k a b c.
               Ord k
            => (a -> b -> c)
            -> Map k a
            -> Map k b
            -> Map k c
zipMapsWith f a b = uncurry f <$> zipMaps a b


type ChrCtx r = Map ChrId (Record r)

-- type Dimensions x = x -> BrowserView -> { x :: Pixels, width :: Pixels }

type ToPixels feature = feature -> BrowserView -> Interval Pixels

type Draw feature = feature -> Interval Pixels -> Drawing


geneGlyph :: forall r a.
            Color
         -> { min :: BrowserPoint  -- TODO should be `Bp` which gets transformed to `BrowserPoint`s
            , max :: BrowserPoint | r }
         -> (BrowserPoint -> Pixels)
         ->
geneGlyph color {min, max} scaler =
  let width = scaler (max - min)
      rect = rectangle 0.0 0.0 width 10.0
      out = outlined (outlineColor color) rect
      fill = filled (fillColor color) rect
  in out <> fill


placeWide :: forall a r.
             { chrSize :: a -> Maybe Bp
             , min     :: a -> Bp
             , max     :: a -> Bp
             | r }
          -> a
          -> Maybe (Interval (Normalized Number))
placeWide {min, max} get a = do
  size <- get.chrSize a
  let l = unwrap $ (get.min a) / size
      r = unwrap $ (get.min a) / size
  pure $ Normalized <$> Pair l r


type PureRenderer a = a -> Maybe { drawing :: Drawing
                                 , point   :: Normalized Point
                                 }

type GWASFeature r = { score :: Number
                     , pos :: Bp
                     , chrId :: ChrId | r }

gwasDraw :: forall a. Color -> a -> Drawing
gwasDraw color =
  let r = 2.2
      c = circle 0.0 0.0 r
      out = outlined (outlineColor color) c
      fill = filled (fillColor color) c
  in const $ out <> fill


gwasPlace :: forall a r.
             { min :: Number, max :: Number | r }
          -> { chrSize :: a -> Maybe Bp
             , pos     :: a -> Bp
             , score   :: a -> Number }
          -> a
          -> Maybe (Normalized Point)
gwasPlace {min, max} get a = do
  size <- get.chrSize a
  let x = unwrap $ (get.pos a) / size
      y = (get.score a - min) / (max - min)
  normPoint {x, y}


gwasRenderer :: forall r rf.
                { min :: Number, max :: Number | r }
             -> Array (GWASFeature rf)
             -> { drawing :: Drawing
                , points :: Array (Normalized Point) }
gwasRenderer vs gwas = { drawing, points }
  where get = { chrSize: \a -> Map.lookup a.chrId mouseChrs
              , pos: _.pos, score: _.score }
        drawing = gwasDraw red unit
        points = filterMap (gwasPlace vs get) gwas

mkGwasRenderer :: forall m rf rctx.
                  MonadReader (ChrCtx (size :: Bp, color :: Color | rctx)) m
               => {min :: Number, max :: Number, sig :: Number}
               -> m (PureRenderer (GWASFeature rf))
mkGwasRenderer {min, max} = do
  ctx <- ask
  let renderer f = do
        size <- _.size <$> Map.lookup f.chrId ctx
        color <- _.color <$> Map.lookup f.chrId ctx
        let r = 2.2
            x = unwrap $ f.pos / size
            y = (f.score - min) / (max - min)
            c = circle x y r
            out = outlined (outlineColor color) c
            fill = filled (fillColor color) c
            drawing = out <> fill

        point <- normPoint {x, y}
        pure { drawing, point }
  pure renderer


mkAnnotRenderer :: forall m rf rctx.
                   MonadReader (ChrCtx (size :: Bp | rctx)) m
                => m (PureRenderer (Annot rf))
mkAnnotRenderer = do
  ctx <- ask
  let font' = font sansSerif 12 mempty
  let renderer f = do
        size <- _.size <$> Map.lookup f.chrId ctx

        let rad = 5.0
            x = unwrap $ f.pos / size
            y = 0.0
            c = circle x y rad
            out  = outlined (outlineColor maroon <> lineWidth 3.0) c
            fill = filled   (fillColor red) c
            -- the canvas is flipped so y-axis increases upward, need to flip the text too
            text' = scale 1.0 (-1.0)
                    $ Drawing.text font' (x+7.5) (y+2.5) (fillColor black) f.name
            drawing = out <> fill <> text'

        point <- normPoint {x, y}
        pure { drawing, point }

  pure renderer


pureRender :: forall f a.
              Filterable f
           => PureRenderer a
           -> f a
           -> f { drawing :: Drawing, point :: Normalized Point }
pureRender r as = filterMap r as


drawPureInterval :: forall f r .
                    Foldable f
                 => { height :: Pixels | r }
                 -> { width :: Pixels, offset :: Pixels }
                 -> f { drawing :: Drawing, point :: Normalized Point }
                 -> Drawing
drawPureInterval {height} {width, offset} = foldMap render'
  where render' {drawing, point} =
          let {x,y} = nPointToFrame width height $ point
          in translate (x + offset) y drawing




drawFrames :: forall i a.
              Ord i
           => CoordSys i BrowserPoint
           -> { width :: Pixels, height :: Pixels }
           -> Map i (Array { drawing :: _, point :: _ })
           -> Interval BrowserPoint
           -> Drawing
drawFrames cs@(CoordSys s) canvasBox drawings =
  let f :: Interval _  -> CoordInterval i _ -> { width :: _, offset :: _ }
      f iv c = (intervalToScreen canvasBox iv) (c^._Interval)

      g :: CoordInterval i _ -> Array { drawing :: _, point :: _ }
      g c = fromMaybe [] $ Map.lookup (c^._Index) drawings

      toDraw :: Interval BrowserPoint -> Array (Tuple _ (Array _))
      toDraw iv = (\x -> Tuple (f iv x) (g x)) <$> (viewIntervals cs iv)

      drawIvs :: Array (Tuple _ (Array _)) -> Drawing
      drawIvs = foldMap (uncurry $ drawPureInterval canvasBox)

      drawIvs' :: Array (Tuple _ (Array _)) -> Array Drawing
      drawIvs' = map (uncurry $ drawPureInterval canvasBox)

  in \bView -> translate 0.0 canvasBox.height
                $ scale 1.0 (-1.0)
                $ drawIvs (toDraw bView)



drawData :: forall i c f a.
            Ord i
         => Foldable f
         => Filterable f
         => CoordSys i BrowserPoint
         -> { width :: Pixels, height :: Pixels }
         -> PureRenderer a
         -> Map i (f a)
         -> Interval BrowserPoint
         -> Drawing
drawData cs@(CoordSys s) canvasBox renderer dat =
  let drawings :: Map i (Array { drawing :: _, point :: _ })
      drawings = map (Array.fromFoldable <<< pureRender renderer) dat

      f :: Interval _  -> CoordInterval i _ -> { width :: _, offset :: _ }
      f iv c = (intervalToScreen canvasBox iv) (c^._Interval)

      g :: CoordInterval i _ -> Array { drawing :: _, point :: _ }
      g c = fromMaybe [] $ Map.lookup (c^._Index) drawings

      toDraw :: Interval BrowserPoint -> Array (Tuple _ (Array _))
      toDraw iv = (\x -> Tuple (f iv x) (g x)) <$> (viewIntervals cs iv)

      drawIvs :: Array (Tuple _ (Array _)) -> Drawing
      drawIvs = foldMap (uncurry $ drawPureInterval canvasBox)

      drawIvs' :: Array (Tuple _ (Array _)) -> Array Drawing
      drawIvs' = map (uncurry $ drawPureInterval canvasBox)

  in \bView -> translate 0.0 canvasBox.height
                $ scale 1.0 (-1.0)
                $ drawIvs (toDraw bView)


shiftRendererMinY :: forall rf.
                      RowLacks "minY" rf
                   => Number
                   -> { min :: Number, max :: Number, sig :: Number }
                   -> PureRenderer (Record rf)
                   -> PureRenderer (Record (minY :: Number | rf))
shiftRendererMinY dist s render f = do
  {drawing, point} <- render (Record.delete (SProxy :: SProxy "minY") f)
  let {x,y} = unwrap point
      normY = (f.minY - s.min) / (s.max - s.min)
      y' = min (normY + dist) 0.95

  point' <- normPoint {x, y: y'}
  pure {drawing, point: point'}



groupToChrs :: forall a f rData.
               Monoid (f {chrId :: ChrId | rData})
            => Foldable f
            => Applicative f
            => f { chrId :: ChrId | rData }
            -> Map ChrId (f { chrId :: ChrId | rData })
groupToChrs = foldl (\chrs r@{chrId} -> Map.alter (add r) chrId chrs ) mempty
  where add x Nothing   = Just $ pure x
        add x (Just xs) = Just $ pure x <> xs


fetchJSON :: forall a.
             (Json -> Maybe a)
          -> String
          -> Aff _ (Array a)
fetchJSON p url = do
  json <- _.response <$> Affjax.get url

  case json ^? _Array of
    Nothing -> throwError $ error "Parse error: JSON is not an array"
    Just as -> case traverse p as of
      Nothing -> throwError $ error "Failed to parse JSON features"
      Just fs -> pure $ fs


gemmaJSONParse :: Json -> Maybe (GWASFeature ())
gemmaJSONParse j = do
  obj <- j ^? _Object
  chrId <- ChrId <$> obj ^? ix "chr" <<< _String
  pos   <- Bp    <$> obj ^? ix "ps"  <<< _Number
  score <-           obj ^? ix "af"  <<< _Number
  pure {pos, score, chrId}


fetchGemmaJSON :: String -> Aff _ (Array (GWASFeature ()))
fetchGemmaJSON = fetchJSON gemmaJSONParse


type GeneRow r = ( geneID :: String
                 , desc :: String
                 , start :: Bp
                 , end :: Bp
                 , name :: String
                 , chrId :: ChrId | r )

type Gene r = Record (GeneRow r)



geneJSONParse :: Json -> Maybe (Gene ())
geneJSONParse j = do
  obj    <- j ^? _Object
  geneID <- obj ^? ix "Gene stable ID" <<< _String
  desc   <- obj ^? ix "Gene description" <<< _String
  name   <- obj ^? ix "Gene name" <<< _String
  start  <- Bp    <$> obj ^? ix "Gene start (bp)"  <<< _Number
  end    <- Bp    <$> obj ^? ix "Gene end (bp)"  <<< _Number
  chrId  <- ChrId <$> obj ^? ix "ChrId" <<< _String
  pure {geneID, desc, name, start, end, chrId}


fetchGeneJSON :: String -> Aff _ (Array (Gene ()))
fetchGeneJSON = fetchJSON geneJSONParse


type AnnotRow r = ( geneID :: String
                  , desc :: String
                  , pos :: Bp
                  , name :: String
                  , chrId :: ChrId | r )

type Annot r = Record (AnnotRow r)


fetchAnnotJSON :: String -> Aff _ (Array (Annot ()))
fetchAnnotJSON str = map toAnnot <$> fetchJSON geneJSONParse str
  where toAnnot :: Gene () -> Annot ()
        toAnnot gene = { geneID: gene.geneID
                       , desc: gene.desc
                       , pos: gene.start
                       , name: gene.name
                       , chrId: gene.chrId }



bumpAnnots :: forall rAnnot rGWAS.
             RowLacks "minY" (AnnotRow rAnnot)
          => Bp
          -> Map ChrId (List (GWASFeature rGWAS))
          -> Map ChrId (List (Annot rAnnot))
          -> Map ChrId (List (Annot (minY :: Number | rAnnot)))
bumpAnnots radius = zipMapsWith (map <<< bumpAnnot)
  where maxScoreIn :: Bp -> Bp -> List (GWASFeature rGWAS) -> Number
        maxScoreIn l r gwas = fromMaybe 0.5 $ maximum
                              $ map (\g -> if g.pos >= l && g.pos <= r
                                           then g.score else 0.0) gwas
        bumpAnnot :: List (GWASFeature rGWAS) -> Annot rAnnot -> Annot (minY :: Number | rAnnot)
        bumpAnnot l g = let minY = maxScoreIn (g.pos - radius) (g.pos + radius) l
                       in Record.insert (SProxy :: SProxy "minY") minY g


getDataDemo :: { gwas :: String
               , annots :: String }
            -> Aff _ { gwas  :: Map ChrId (List (GWASFeature ()       ))
                     , annots :: Map ChrId (List (Annot (minY :: Number)))
                     }
getDataDemo urls = do
  gwas <- fetchGemmaJSON urls.gwas
  annots' <- fetchAnnotJSON urls.annots
  -- Divide data by chromosomes
  let gwasChr :: Map ChrId (List (GWASFeature ()))
      gwasChr = List.fromFoldable <$> groupToChrs gwas
  let annotsChr :: Map ChrId (List (Annot ()))
      annotsChr = List.fromFoldable <$> groupToChrs annots'
  let bumpedAnnots :: Map ChrId (List (Annot (minY :: Number)))
      bumpedAnnots = bumpAnnots (Bp 1000000.0) gwasChr annotsChr

  pure { gwas: gwasChr, annots: bumpedAnnots }



renderersDemo :: forall r.
                 { min :: Number, max :: Number, sig :: Number }
              -> { gwas  :: PureRenderer (GWASFeature ()       )
                 , annots :: PureRenderer (Annot (minY :: Number)) }
renderersDemo s = { gwas, annots }
  where colorsCtx = zipMapsWith (\r {color} -> Record.insert (SProxy :: SProxy "color") color r)
                      mouseChrCtx mouseColors
        gwas :: PureRenderer (GWASFeature ())
        gwas = mkGwasRenderer s colorsCtx

        annots :: PureRenderer (Annot (minY :: Number))
        annots = shiftRendererMinY 0.06 s $ mkAnnotRenderer mouseChrCtx


ruler :: forall r r1.
         { min :: Number, max :: Number, sig :: Number }
      -> Color
      -> { width :: Pixels, height :: Pixels }
      -> Drawing
ruler {min, max, sig} color f = outlined outline rulerDrawing
  where normY = (sig - min) / (max - min)
        y = f.height - (normY * f.height)
        outline = outlineColor color
        rulerDrawing = Drawing.path [{x: 0.0, y}, {x: f.width, y}]


chrLabels :: forall c.
             CoordSys ChrId c
          -> Map ChrId (Array { drawing :: _, point :: _ })
chrLabels cs = Map.fromFoldable results
  where mkLabel :: ChrId -> _
        mkLabel chr = { drawing: chrText chr, point: Normalized {x: 1.0, y: -0.1} }

        font' = font sansSerif 12 mempty

        chrText :: ChrId -> Drawing
        chrText chr = scale 1.0 (-1.0)
                    $ Drawing.text font' zero zero (fillColor black) (unwrap chr)

        results :: Array _
        results = map (\x -> Tuple (x^._Index) [mkLabel (x^._Index)]) $ cs^._BrowserIntervals

        results' :: Traversal' (CoordSys ChrId c) ChrId
        results' = _BrowserIntervals <<< traversed <<< _Index

        test :: forall r. Monoid r => Fold' r _ _
        test = results' <<< (to (fanout id mkLabel))

        output :: _
        output = Map.fromFoldable $ (foldMapOf test pure cs :: Array _)

        -- xxx :: Traversal' (CoordSys ChrId _) ChrId
        -- xxx = results' <<< _Index

        -- results2 :: _ -> Array _
        -- results2 = traverseOf results' pure

        -- results3 :: _ -> Array _
        -- results3 = foldMapOf results' pure

        -- results4 :: _
        -- results4 = foldMapOf results'
                     -- (fanout id chrText)


drawDemo :: forall f r.
            Foldable f
         => Filterable f
         => CoordSys _ _
         -> { min :: Number, max :: Number, sig :: Number }
         -> { width :: Pixels, height :: Pixels }
         -> { gwas   :: Map ChrId (f (GWASFeature ()))
            , annots :: Map ChrId (f (Annot (minY :: Number))) }
         -> Interval BrowserPoint
         -> Drawing
drawDemo cs s canvasBox {gwas, annots} =
  let renderers = renderersDemo s
      ruler' = ruler s red
      drawGwas   = drawData cs canvasBox renderers.gwas gwas
      drawAnnots = drawData cs canvasBox renderers.annots annots
  in \view -> (drawGwas view) <> (drawAnnots view) <> ruler' canvasBox



{-
TODO
there is currently no connection between the vertical scale's
position and the track. Need to take stuff like vertical
offset and padding into account; calculate once and use
in both places. However don't just use canvasheight - yoffset
or whatever; actually derive the top and bottom of the track.
-}

drawVScale :: forall r.
              Number
           -> Number
           -> { min :: Number, max :: Number, sig :: Number }
           -> Color
           -> Drawing
drawVScale width height vs col =
  -- should have some padding here too; hardcode for now
  let hPad = width  / 5.0
      vPad = height / 10.0
      x = width / 2.0

      y1 = 0.0
      y2 = height

      n = (_ * 0.1) <<< Int.toNumber <$> (0 .. 10)

      p = Drawing.path [{x, y:y1}, {x, y:y2}]

      bar w y = Drawing.path [{x:x-w, y}, {x, y}]

      ps = foldMap (\i -> bar
                          (if i == 0.0 || i == 1.0 then 8.0 else 3.0)
                          (y1 + i*(y2-y1))) n

      ft = font sansSerif 10 mempty
      mkT y = Drawing.text ft (x-12.0) y (fillColor black)

      topLabel = mkT (y1-(0.5*vPad)) $ show vs.max
      btmLabel = mkT (y2+vPad) $ show vs.min

  in outlined (outlineColor col <> lineWidth 2.0) (p <> ps)
  <> topLabel <> btmLabel


drawLegendItem :: Number
               -> { text :: String, icon :: Drawing }
               -> Drawing
drawLegendItem w {text, icon} =
  let ft = font sansSerif 12 mempty
      t = Drawing.text ft 12.0 0.0 (fillColor black) text
  in icon <> t


drawLegend :: Number
           -> Number
           -> Array { text :: String, icon :: Drawing }
           -> Drawing
drawLegend width height icons =
  let hPad = width  / 5.0
      vPad = height / 5.0
      n :: Int
      n = length icons
      x = hPad
      f :: Number -> { text :: String, icon :: Drawing } -> Drawing
      f y ic = translate x y $ drawLegendItem (width - 2.0*hPad) ic
      d = (height - 2.0*vPad) / (length icons)
      ds = mapWithIndex (\i ic -> f (vPad+(vPad*(Int.toNumber i))) ic) icons
  in fold ds



mkIcon :: Color -> String -> { text :: String, icon :: Drawing }
mkIcon c text =
  let sh = circle (-2.5) (-2.5) 5.0
      icon = outlined (outlineColor c <> lineWidth 2.0) sh <>
             filled (fillColor c) sh
  in {text, icon}


demoLegend :: Array {text :: String, icon :: Drawing}
demoLegend =
  [ mkIcon red "Red thing"
  , mkIcon blue "blue thing"
  , mkIcon purple "boop"
  ]


              -- the first 2 are used by all parts of the browser
demoBrowser :: forall f.
               Foldable f
            => Filterable f
            => CoordSys ChrId BrowserPoint
            -> { width :: Pixels, height :: Pixels }
            -> Pixels
            -- this by the vertical scale and the tracks
            -> { min :: Number, max :: Number, sig :: Number }
            -- these define the width of the non-track parts of the browser;
            -- the browser takes up the remaining space.
            -> { vScaleWidth :: Pixels
               , legendWidth :: Pixels }
            -- vScale only
            -> Color
            -- to be drawn in the legend on the RHS
            -> Array { text :: String, icon :: Drawing }
            -- finally, used by the main track
            -> { gwas :: Map ChrId (f (GWASFeature ()))
               , annots :: Map ChrId (f (Annot (minY :: Number))) }
            -> BrowserView
            -- the drawing produced contains all 3 parts.
            -> { track :: Drawing, overlay :: Drawing }
demoBrowser cs canvas vpadding vscale sizes vscaleColor legend {gwas, annots} =
  let height = canvas.height - 2.0 * vpadding
      width  = canvas.width

      trackCanvas = { width: canvas.width - sizes.vScaleWidth - sizes.legendWidth
                    , height }

      bg w' h' = filled (fillColor white) $ rectangle 0.0 0.0 w' h'

      -- TODO unify vertical offset by padding further; do it as late as possible

      vScale :: _ -> Drawing
      vScale _ = let w = sizes.vScaleWidth
                 in  translate zero vpadding
                   $ bg w height
                  <> drawVScale w height vscale vscaleColor

      track v = translate sizes.vScaleWidth vpadding
                  $ drawDemo cs vscale trackCanvas {gwas, annots} v


      chrs :: _ -> Drawing
      chrs v = translate zero vpadding
                 $ drawFrames cs trackCanvas (chrLabels cs) v

      legendD :: _ -> Drawing
      legendD _ = let w = sizes.legendWidth
                  in translate (canvas.width - w) vpadding
                    $ bg w height
                   <> drawLegend sizes.legendWidth canvas.height legend

  in \view -> { track: track view <> chrs view
              , overlay: vScale view <> legendD view }




mouseChrIds :: Array ChrId
mouseChrIds =
            [ (ChrId "1")
            , (ChrId "2")
            , (ChrId "3")
            , (ChrId "4")
            , (ChrId "5")
            , (ChrId "6")
            , (ChrId "7")
            , (ChrId "8")
            , (ChrId "9")
            , (ChrId "10")
            , (ChrId "11")
            , (ChrId "12")
            , (ChrId "13")
            , (ChrId "14")
            , (ChrId "15")
            , (ChrId "16")
            , (ChrId "17")
            , (ChrId "18")
            , (ChrId "19")
            , (ChrId "X")
            , (ChrId "Y")
            ]

mouseChrs :: Map ChrId Bp
mouseChrs = Map.fromFoldable $ Array.zip mouseChrIds $
            [ (Bp 195471971.0)
            , (Bp 182113224.0)
            , (Bp 160039680.0)
            , (Bp 156508116.0)
            , (Bp 151834684.0)
            , (Bp 149736546.0)
            , (Bp 145441459.0)
            , (Bp 129401213.0)
            , (Bp 124595110.0)
            , (Bp 130694993.0)
            , (Bp 122082543.0)
            , (Bp 120129022.0)
            , (Bp 120421639.0)
            , (Bp 124902244.0)
            , (Bp 104043685.0)
            , (Bp 98207768.0)
            , (Bp 94987271.0)
            , (Bp 90702639.0)
            , (Bp 61431566.0)
            , (Bp 17103129.0)
            , (Bp 9174469.0)
            ]


mouseColors :: ChrCtx (color :: Color)
mouseColors = Map.fromFoldable $ map (\x -> Tuple x {color: navy}) mouseChrIds

mouseColors' :: ChrCtx (color :: Color)
mouseColors' = Map.fromFoldable $ Array.zip mouseChrIds $ map (\x -> {color: x})
               [ navy, blue, aqua, teal, olive
               , green, lime, yellow, orange, red
               , maroon, fuchsia, purple, navy, blue
               , aqua, teal, olive, green, lime
               , yellow ]


mouseChrCtx :: ChrCtx (size :: Bp)
mouseChrCtx = map (\size -> { size }) mouseChrs
