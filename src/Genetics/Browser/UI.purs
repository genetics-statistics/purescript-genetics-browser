module Genetics.Browser.UI where

import Prelude

import Control.Monad.Error.Class (throwError)
import Data.Array as Array
import Data.Bifunctor (bimap)
import Data.BigInt (BigInt)
import Data.BigInt as BigInt
import Data.Either (Either(Right, Left))
import Data.Filterable (filterMap)
import Data.Foldable (foldMap, length, sum)
import Data.Generic.Rep (class Generic)
import Data.Generic.Rep.Show (genericShow)
import Data.Int as Int
import Data.Lens ((^.))
import Data.Lens.Iso.Newtype (_Newtype)
import Data.Map as Map
import Data.Maybe (Maybe(..), fromJust, fromMaybe)
import Data.Newtype (unwrap, wrap)
import Data.Pair (Pair(..))
import Data.Pair as Pair
import Data.Symbol (SProxy(SProxy))
import Data.Traversable (for_, traverse_)
import Data.Tuple (Tuple(Tuple))
import Data.Variant (Variant, case_, inj)
import Data.Variant as V
import Effect (Effect)
import Effect.Aff (Aff, Fiber, Milliseconds, forkAff, killFiber, launchAff, launchAff_)
import Effect.Aff.AVar (AVar)
import Effect.Aff.AVar as AVar
import Effect.Class (liftEffect)
import Effect.Class.Console (log)
import Effect.Exception (error, throw)
import Effect.Ref (Ref)
import Effect.Ref as Ref
import Foreign (Foreign, MultipleErrors, renderForeignError)
import Genetics.Browser (HexColor, Peak, pixelSegments)
import Genetics.Browser.Bed (getGenes)
import Genetics.Browser.Canvas (BrowserContainer, TrackContainer, _Container, addTrack, animateTrack, browserContainer, dragScroll, getDimensions, getTrack, setElementStyle, setTrackContainerSize, trackClickHandler, wheelZoom, withLoadingIndicator)
import Genetics.Browser.Coordinates (CoordSys, CoordSysView(..), _Segments, _TotalSize, coordSys, normalizeView, pairsOverlap, scaleToScreen, viewScale)
import Genetics.Browser.Demo (Annotation, AnnotationField, SNP, addChrLayers, addGWASLayers, addGeneLayers, annotationsForScale, filterSig, getAnnotations, getSNPs, showAnnotationField)
import Genetics.Browser.Layer (Component(Center), trackSlots)
import Genetics.Browser.Track (class TrackRecord, makeContainers, makeTrack)
import Genetics.Browser.Types (ChrId(ChrId), _NegLog10, _prec)
import Genetics.Browser.UI.View (Animation(..), UpdateView(..), updateViewFold)
import Genetics.Browser.UI.View as View
import Global.Unsafe (unsafeStringify)
import Graphics.Canvas as Canvas
import Graphics.Drawing (Point)
import Math as Math
import Partial.Unsafe (unsafePartial)
import Prim.RowList (class RowToList)
import Record as Record
import Simple.JSON (read)
import Unsafe.Coerce (unsafeCoerce)
import Web.DOM (Element)
import Web.DOM.Document (createElement, documentElement) as DOM
import Web.DOM.Document (toParentNode)
import Web.DOM.Element (setId)
import Web.DOM.Element as Element
import Web.DOM.Node (appendChild)
import Web.DOM.ParentNode (querySelector) as DOM
import Web.HTML (window) as DOM
import Web.HTML.HTMLDocument (toDocument) as DOM
import Web.HTML.Window (document) as DOM
import Web.UIEvent.KeyboardEvent (KeyboardEvent)
import Web.UIEvent.KeyboardEvent (key) as DOM


foreign import windowInnerSize :: Effect Canvas.Dimensions

-- | Set an event to fire on the given button id
foreign import buttonEvent :: String
                           -> Effect Unit
                           -> Effect Unit

foreign import keydownEvent :: Element
                            -> (KeyboardEvent -> Effect Unit)
                            -> Effect Unit

-- | Set callback to run after the window has resized (see UI.js for
-- | time waited), providing it with the new window size.
foreign import resizeEvent :: ({ width  :: Number
                               , height :: Number } -> Effect Unit)
                           -> Effect Unit



-- | The value returned by the function that initializes the genome browser;
-- | provides an interface to the running track instance.
type TrackInterface a
  = { getView          :: Effect CoordSysView
    , container        :: TrackContainer
    , lastHotspots     :: Aff (Number -> Point -> Array a)
    , queueCommand     :: Variant UICmdR -> Aff Unit
    , queueUpdateView  :: UpdateView -> Effect Unit
    }


-- | Creates the track using the provided initial data, returning
-- | a TrackInterface for reading state & sending commands to it
initializeTrack :: ∀ c r rl a.
                   RowToList r rl
                => TrackRecord rl r a
                => CoordSys c BigInt
                -> Record r
                -> CoordSysView
                -> TrackContainer
                -> Aff (TrackInterface a)
initializeTrack cSys renderFuns initView bc = do

  renderFiberVar <- AVar.empty

  trackView <- liftEffect $ Ref.new initView
  bcVar <- AVar.new bc

  uiCmdVar <- AVar.empty
  lastHotspotsVar <- AVar.empty

  track <- makeTrack renderFuns bc

  let getView = Ref.read trackView
      queueCommand = flip AVar.put uiCmdVar

    -- hardcoded timeout for now
  queueUpdateView <- liftEffect $ uiViewUpdate cSys { trackContainer: bc } (wrap 30.0) {view: trackView, uiCmd: uiCmdVar}


  let mainLoop = do
        uiCmd <- AVar.take uiCmdVar
        case_ # V.on _render (\_ -> pure unit)
              # V.on _docResize (\ {width} -> do
                      {height} <- _.size <$> getDimensions bc
                      setTrackContainerSize {width, height} bc
                      queueCommand $ inj _render unit
                      mainLoop)
              $ uiCmd

        -- if there's a rendering fiber running, we kill it
        traverse_ (killFiber (error "Resetting renderer"))
          =<< AVar.tryTake renderFiberVar

        csView <- liftEffect $ getView

        currentDims <- getDimensions bc

        let trackDims = _.center $ trackSlots currentDims
            currentScale = viewScale trackDims.size csView
            pxView = scaleToScreen currentScale <$> (unwrap csView)

        -- fork a new renderFiber
        renderFiber <- forkAff
                       $ track.render pxView csView

        AVar.put renderFiber renderFiberVar

        mainLoop

  _ <- forkAff mainLoop

  queueCommand $ inj _render unit

  pure { getView
       , container: bc
       , lastHotspots: track.hotspots
       , queueCommand
       , queueUpdateView }



queueCmd :: ∀ a. AVar a -> a -> Effect Unit
queueCmd av cmd = launchAff_ $ AVar.put cmd av


uiViewUpdate :: ∀ c r.
                CoordSys c BigInt
             -> { trackContainer :: TrackContainer }
             -> Milliseconds
             -> { view  :: Ref CoordSysView
                , uiCmd :: AVar (Variant UICmdR) | r }
             -> Effect (UpdateView -> Effect Unit)
uiViewUpdate cs { trackContainer } timeout {view, uiCmd} = do

  position <- Ref.read view

  trackDims <- _.center <<< trackSlots <$> getDimensions trackContainer

  let width = trackDims.size.width

      step :: UpdateView -> CoordSysView -> CoordSysView
      step uv = normalizeView cs (BigInt.fromInt 200000)
                 <<< updateViewFold uv

      pixelClamps :: CoordSysView -> { left :: Number, right :: Number }
      pixelClamps csv@(CoordSysView (Pair l r)) =
        let vs     = viewScale trackDims.size csv
            left   = scaleToScreen vs l
            right  = scaleToScreen vs ((cs ^. _TotalSize) - r)
        in { left, right }

      toPixels :: CoordSysView -> Number -> Number
      toPixels csv x = let { left, right } = pixelClamps csv
                           x' = width * x
                       in if x' < zero then max (-left) x'
                                       else min (right) x'

      toZoomRange :: CoordSysView -> Number -> Pair Number
      toZoomRange (CoordSysView (Pair l r)) x =
        let dx = (x - 1.0) / 2.0
            l' = if l <= zero then 0.0
                              else (-dx)
            r' = if r >= (cs ^. _TotalSize) then 1.0
                                            else 1.0 + dx
        in Pair l' r'

      animate :: UpdateView -> CoordSysView -> View.Animation
      animate uv csv = case uv of
        ScrollView x -> Scrolling (toPixels csv x)
        ZoomView   x -> Zooming   (toZoomRange csv x)
        ModView _    -> Jump


      callback :: Either CoordSysView View.Animation -> Effect Unit
      callback = case _ of
        Right a -> animateTrack trackContainer a
        Left  v -> do
          Ref.write v view
          launchAff_ $ AVar.put (inj _render unit) uiCmd


      initial :: { position :: _, velocity :: UpdateView }
      initial = { position, velocity: mempty }

      timeouts :: _
      timeouts = { step: wrap 10.0
                 , done: wrap 200.0 }


  View.animateDelta { step, animate } callback initial timeouts



btnUI :: { scrollMod :: Number, zoomMod :: Number }
      -> (UpdateView -> Effect Unit)
      -> Effect Unit
btnUI mods cb = do
  buttonEvent "scrollLeft"  $ cb $ ScrollView     (-mods.scrollMod)
  buttonEvent "scrollRight" $ cb $ ScrollView       mods.scrollMod
  buttonEvent "zoomOut"     $ cb $ ZoomView $ 1.0 + mods.zoomMod
  buttonEvent "zoomIn"      $ cb $ ZoomView $ 1.0 - mods.zoomMod


keyUI :: ∀ r.
         Element
      -> { scrollMod :: Number | r }
      -> (UpdateView -> Effect Unit)
      -> Effect Unit
keyUI el mods cb = keydownEvent el f
  where f ke = case DOM.key ke of
          "ArrowLeft"  -> cb $ ScrollView (-mods.scrollMod)
          "ArrowRight" -> cb $ ScrollView   mods.scrollMod
          _ -> pure unit


type UICmdR = ( render :: Unit
              , docResize :: { width :: Number, height :: Number } )

_render = SProxy :: SProxy "render"
_docResize = SProxy :: SProxy "docResize"


debugView :: ∀ a.
             TrackInterface a
          -> Effect { get :: String -> Effect Unit
                    , set :: { l :: Number, r :: Number } -> Effect Unit }
debugView s = unsafePartial do
  let get name = launchAff_ do
         view <- liftEffect $ s.getView
         liftEffect do
           log $ "CoordSysView: " <> show (map BigInt.toString $ unwrap view)
           setWindow name $ (\(Pair l r) -> {l,r}) $ unwrap view

  let set lr = s.queueUpdateView
               $ ModView $ const ((fromJust <<< BigInt.fromNumber) <$> Pair lr.l lr.r)

  pure {get, set}



printSNPInfo :: ∀ r. Array (SNP r) -> Effect Unit
printSNPInfo fs = do
  let n = length fs :: Int
      m = 5
  log $ "showing " <> show m <> " out of " <> show n <> " clicked glyphs"
  for_ (Array.take m fs) (log <<< unsafeCoerce)


wrapWith :: String -> String -> String
wrapWith tag x =
  "<"<> tag <>">" <> x <> "</"<> tag <>">"

snpHTML :: ∀ r.
           SNP r
        -> String
snpHTML {position, feature} = wrapWith "div" contents
  where contents = foldMap (wrapWith "p")
            [ "SNP: "    <> feature.name
            , "Chr: "    <> show feature.chrId
            , "Pos: "    <> show (Pair.fst position)
            , "-log10: " <> feature.score ^. _NegLog10 <<< _Newtype <<< _prec 4
            ]


peakHTML :: ∀ a b c.
            (a -> String)
         -> Peak b c a
         -> String
peakHTML disp peak =
  case Array.uncons peak.elements of
    Nothing               -> ""
    Just {head, tail: []} -> disp head
    Just {head, tail}     ->
      wrapWith "div" $ wrapWith "p"
        $ show (length tail + 1) <> " annotations"


annoPeakHTML :: ∀ a b.
                Peak a b (Annotation ())
             -> String
annoPeakHTML peak =
  case Array.uncons peak.elements of
    Nothing               -> ""
    Just {head, tail: []} -> annotationHTMLAll head
    Just {head, tail}     -> wrapWith "div"
                             ( wrapWith "p" "Annotations:"
                             <> foldMap annotationHTMLShort peak.elements)


-- | Given a function to transform the data in the annotation's "rest" field
-- | to text (or Nothing if the field should not be displayed), produce a
-- | function that generates HTML from annotations
annotationHTML :: (AnnotationField -> Maybe String)
                -> Annotation () -> String
annotationHTML disp {feature} = wrapWith "div" contents
  where url = fromMaybe "No URL"
              $ map (\a -> "URL: <a target='_blank' href='"
                           <> a <> "'>" <> a <> "</a>") feature.url

        name = fromMaybe ("Annotated SNP: " <> feature.name)
                         (("Gene: " <> _) <$> feature.gene)

        showOther fv = fv.field <> ": " <> (unsafeCoerce fv.value)

        contents = foldMap (wrapWith "p")
          $ [ name
            , url
            ] <> (filterMap disp
                  $ Array.fromFoldable feature.rest)

-- | Shows all data in "rest" using the default showAnnotationField (which uses unsafeCoerce)
annotationHTMLAll :: Annotation () -> String
annotationHTMLAll =
  annotationHTML (pure <<< showAnnotationField)


annotationHTMLDefault :: Annotation () -> String
annotationHTMLDefault = annotationHTML \x -> pure case x of
  {field: "p_lrt", value} ->
     "p_lrt: " <> (unsafeCoerce value) ^. _NegLog10 <<< _Newtype <<< _prec 4
  fv -> showAnnotationField fv

annotationHTMLShort :: Annotation () -> String
annotationHTMLShort {feature} = wrapWith "p" anchor
  where
        name' = fromMaybe (feature.name)
                          (feature.gene)

        showOther fv = fv.field <> ": " <> (unsafeCoerce fv.value)

        anchor = case feature.url of
          Nothing  -> name'
          Just url -> "<a target='_blank' href='" <> url <> "'>" <> name' <> "</a>"



foreign import initDebugDiv :: Number -> Effect Unit
foreign import setDebugDivVisibility :: String -> Effect Unit
foreign import setDebugDivPoint :: Point -> Effect Unit


foreign import setElementContents :: Element -> String -> Effect Unit

data InfoBoxF
  = IBoxShow
  | IBoxHide
  | IBoxSetY Int
  | IBoxSetX Int
  | IBoxSetContents String

derive instance genericInfoBoxF :: Generic InfoBoxF _

instance showInfoBoxF :: Show InfoBoxF where
  show = genericShow

updateInfoBox :: Element -> InfoBoxF -> Effect Unit
updateInfoBox el cmd =
  case cmd of
    IBoxShow ->
      setElementStyle el "visibility" "visible"
    IBoxHide ->
      setElementStyle el "visibility" "hidden"
    (IBoxSetX x)    ->
      setElementStyle el "left" $ show x <> "px"
    (IBoxSetY y)    ->
      setElementStyle el "top"  $ show y <> "px"
    (IBoxSetContents html) ->
      setElementContents el html

infoBoxId :: String
infoBoxId = "infoBox"

initInfoBox :: Effect (InfoBoxF -> Effect Unit)
initInfoBox = do
  doc <- map DOM.toDocument
           $ DOM.document =<< DOM.window
  el <- DOM.createElement "div" doc

  setId infoBoxId el

  DOM.documentElement doc >>= case _ of
    Nothing -> throw "Couldn't find document body!"
    Just docBody -> void $ appendChild (Element.toNode el) (Element.toNode docBody)

  pure $ updateInfoBox el


runBrowser :: BrowserConfig { gwas :: _
                            , gene :: _ }
           -> BrowserContainer
           -> Effect (Fiber Unit)
runBrowser config bc = launchAff $ do

  let cSys :: CoordSys ChrId BigInt
      cSys = coordSys mouseChrSizes
      initialView = fromMaybe (wrap $ Pair zero (cSys^._TotalSize)) do
        v <- config.initialChrs
        (Pair l _) <- Map.lookup (wrap v.left) $ cSys^._Segments
        (Pair _ r) <- Map.lookup (wrap v.right) $ cSys^._Segments
        pure $ wrap $ Pair l r

      clickRadius = 1.0

  liftEffect $ initDebugDiv clickRadius

  cmdInfoBox <- liftEffect $ initInfoBox






  let setHandlers tc track = liftEffect do
        resizeEvent \d -> do
          launchAff_ $ track.queueCommand $ inj _docResize d

        let btnMods = { scrollMod: 0.10, zoomMod: 0.15 }
        btnUI btnMods \u ->
          track.queueUpdateView u

        buttonEvent "reset" do
          let cmd = ModView (const $ unwrap initialView)
          track.queueUpdateView cmd

        keyUI (bc ^. _Container) { scrollMod: 0.075 } \u -> do
          track.queueUpdateView u

        dragScroll bc \ {x,y} -> do
          -- only do anything when scrolling at least a pixel
          when (Math.abs x >= one) do
            trackDims <- _.center <<< trackSlots <$> getDimensions tc
            let cmd = ScrollView $ (x) / trackDims.size.width
            track.queueUpdateView cmd

        let scrollZoomScale = 0.06
        wheelZoom bc \dY -> do
          let cmd = ZoomView $ 1.0 + scrollZoomScale * dY
          track.queueUpdateView cmd




  gwasTrack <- forkAff do

    gwasTC <- getTrack "gwas" bc
    gwasData <- withLoadingIndicator gwasTC
                $  {snps:_, annotations:_}
               <$> foldMap (getSNPs        cSys) config.urls.snps
               <*> foldMap (getAnnotations cSys) config.urls.annotations
    render <- do
      chrLayers <- addChrLayers { coordinateSystem: cSys
                                , segmentPadding: 12.0 }
                                config.chrs gwasTC
      gwasLayers <- addGWASLayers cSys config.tracks.gwas gwasData gwasTC
      pure $ Record.merge { chrs: chrLayers } gwasLayers

    track <- initializeTrack cSys render initialView gwasTC
    setHandlers gwasTC track


    liftEffect do
      let sigSnps = filterSig config.score gwasData.snps
          annotAround pks snp =
            Array.find (\a -> a.covers `pairsOverlap` snp.position)
              =<< Map.lookup snp.feature.chrId pks

          glyphClick :: Point -> Effect Unit
          glyphClick p = launchAff_ do
            v  <- liftEffect $ track.getView

            trackDims <- _.center <<< trackSlots <$> getDimensions gwasTC
            let segs = pixelSegments { segmentPadding: 12.0 } cSys trackDims.size v
                annoPeaks = annotationsForScale cSys sigSnps
                              gwasData.annotations segs


            lastHotspots' <- track.lastHotspots
            let clicked = lastHotspots' clickRadius p

            liftEffect do
              case Array.head clicked of
                Nothing -> cmdInfoBox IBoxHide
                Just g  -> do
                  cmdInfoBox IBoxShow
                  cmdInfoBox $ IBoxSetX $ Int.round p.x
                  cmdInfoBox $ IBoxSetY $ Int.round p.y
                  cmdInfoBox $ IBoxSetContents
                    $ snpHTML g
                    <> foldMap annoPeakHTML (annotAround annoPeaks g)


      trackClickHandler gwasTC
        $ Center glyphClick


  geneTrack <- forkAff do


    geneTC <- getTrack "gene" bc

    genes <- withLoadingIndicator geneTC case config.urls.genes of
        Nothing  -> throwError $ error "no genes configured"
        Just url -> do
          log $ "fetching genes"
          g <- getGenes cSys url
          log $ "genes fetched: " <> show (sum $ Array.length <$> g)
          pure g


    render <- do
      chrLayers <- addChrLayers { coordinateSystem: cSys
                                , segmentPadding: 12.0 }
                                config.chrs geneTC
      geneLayers <- addGeneLayers cSys config.tracks.gene { genes } geneTC
      -- pure { chrs: chrLayers }
      pure $ Record.merge { chrs: chrLayers } geneLayers

    track <- initializeTrack cSys render initialView geneTC
    setHandlers geneTC track

  pure unit



type DataURLs = { snps        :: Maybe String
                , annotations :: Maybe String
                , genes       :: Maybe String
                }


type BrowserConfig a =
  { score :: { min :: Number, max :: Number, sig :: Number }
  , urls :: DataURLs
  , initialChrs :: Maybe { left :: String, right :: String }
  , chrs ::  { chrLabels :: { fontSize :: Int }
             , chrBG1 :: HexColor
             , chrBG2 :: HexColor }
  , tracks :: a
  }

foreign import setWindow :: ∀ a. String -> a -> Effect Unit


main :: Foreign -> Effect Unit
main rawConfig = do

  el' <- do
    doc <- DOM.toDocument
           <$> (DOM.document =<< DOM.window)
    DOM.querySelector (wrap "#browser") (toParentNode doc)


  case el' of
    Nothing -> log "Could not find element '#browser'"
    Just el -> do

      case read rawConfig :: Either MultipleErrors (BrowserConfig _) of
        Left errs -> do
          setElementContents el
            $  "<p>Error when parsing provided config object:<p>"
            <> foldMap (wrapWith "p" <<< renderForeignError) errs

        Right c   -> do

          {width} <- windowInnerSize

          cs <- makeContainers width c.tracks

          bc <- browserContainer el

          addTrack bc "gwas" cs.gwas
          addTrack bc "gene" cs.gene

          log $ unsafeStringify c
          void $ runBrowser c bc



mouseChrSizes :: Array (Tuple ChrId BigInt)
mouseChrSizes =
  unsafePartial
  $ map (bimap ChrId (fromJust <<< BigInt.fromString))
      [ Tuple "1"   "195471971"
      , Tuple "2"   "182113224"
      , Tuple "3"   "160039680"
      , Tuple "4"   "156508116"
      , Tuple "5"   "151834684"
      , Tuple "6"   "149736546"
      , Tuple "7"   "145441459"
      , Tuple "8"   "129401213"
      , Tuple "9"   "124595110"
      , Tuple "10"  "130694993"
      , Tuple "11"  "122082543"
      , Tuple "12"  "120129022"
      , Tuple "13"  "120421639"
      , Tuple "14"  "124902244"
      , Tuple "15"  "104043685"
      , Tuple "16"  "98207768"
      , Tuple "17"  "94987271"
      , Tuple "18"  "90702639"
      , Tuple "19"  "61431566"
      ]
