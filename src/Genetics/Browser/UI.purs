module Genetics.Browser.UI where

import Prelude

import Control.Coroutine (Consumer, Producer, connect, runProcess)
import Control.Coroutine as Co
import Control.Monad.Aff (Aff, Milliseconds, delay, forkAff, killFiber, launchAff, launchAff_)
import Control.Monad.Aff.AVar (AVar)
import Control.Monad.Aff.AVar as AVar
import Control.Monad.Eff (Eff)
import Control.Monad.Eff.Class (liftEff)
import Control.Monad.Eff.Console (log)
import Control.Monad.Eff.Exception (error, throw)
import DOM.Classy.HTMLElement (appendChild, setId) as DOM
import DOM.Classy.ParentNode (toParentNode)
import DOM.Event.KeyboardEvent (key) as DOM
import DOM.Event.Types (KeyboardEvent)
import DOM.HTML (window) as DOM
import DOM.HTML.Types (htmlDocumentToDocument) as DOM
import DOM.HTML.Window (document) as DOM
import DOM.Node.Document (createElement, documentElement) as DOM
import DOM.Node.ParentNode (querySelector) as DOM
import DOM.Node.Types (Element, ElementId)
import Data.Array as Array
import Data.Bifunctor (bimap)
import Data.BigInt (BigInt)
import Data.BigInt as BigInt
import Data.Either (Either(Right, Left))
import Data.Filterable (filterMap)
import Data.Foldable (class Foldable, foldMap, length, null)
import Data.Foreign (Foreign, MultipleErrors, renderForeignError)
import Data.Generic.Rep (class Generic)
import Data.Generic.Rep.Show (genericShow)
import Data.Int as Int
import Data.Lens ((^.))
import Data.Lens as Lens
import Data.Lens.Iso.Newtype (_Newtype)
import Data.List (List)
import Data.List as List
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..), fromJust, fromMaybe)
import Data.Monoid (class Monoid, mempty)
import Data.Newtype (over, unwrap, wrap)
import Data.Pair (Pair(..))
import Data.Pair as Pair
import Data.Record.Extra (eqRecord)
import Data.Symbol (SProxy(SProxy))
import Data.Traversable (for_, traverse_)
import Data.Tuple (Tuple(Tuple))
import Data.Variant (Variant, case_, inj)
import Data.Variant as V
import Genetics.Browser (LegendConfig, Peak, RenderedTrack, VScale, pixelSegments)
import Genetics.Browser.Canvas (BrowserCanvas, BrowserContainer(..), Renderable, TrackPadding, _Dimensions, _Track, browserCanvas, browserClickHandler, browserContainer, browserOnClick, debugBrowserCanvas, dragScroll, getDimensions, getLayers, renderBrowser, setBrowserCanvasSize, setBrowserContainerSize, setElementStyle, wheelZoom, zIndexLayers)
import Genetics.Browser.Coordinates (CoordSys, CoordSysView(CoordSysView), _TotalSize, coordSys, normalizeView, pairSize, pairsOverlap, scalePairBy, scaleToScreen, translatePairBy, viewScale)
import Genetics.Browser.Demo (Annotation, AnnotationField, SNP, SNPConfig, AnnotationsConfig, addDemoLayers, annotationsForScale, filterSig, getAnnotations, getGenes, getSNPs, showAnnotationField)
import Genetics.Browser.Layer (Component(..), Layer(..), browserSlots)
import Genetics.Browser.Types (ChrId(ChrId), _NegLog10, _prec)
import Global.Unsafe (unsafeStringify)
import Graphics.Canvas as Canvas
import Graphics.Drawing (Drawing, Point)
import Math as Math
import Partial.Unsafe (unsafePartial)
import Simple.JSON (read)
import Unsafe.Coerce (unsafeCoerce)


foreign import windowInnerSize :: ∀ e. Eff e Canvas.Dimensions

-- | Set an event to fire on the given button id
foreign import buttonEvent :: ∀ e.
                              String
                           -> Eff e Unit
                           -> Eff e Unit

foreign import keydownEvent :: ∀ e.
                                Element
                             -> (KeyboardEvent -> Eff e Unit)
                             -> Eff e Unit

-- | Set callback to run after the window has resized (see UI.js for
-- | time waited), providing it with the new window size.
foreign import resizeEvent :: ∀ e.
                              ({ width  :: Number
                               , height :: Number } -> Eff e Unit)
                           -> Eff e Unit


-- | The value returned by the function that initializes the genome browser;
-- | provides an interface to the running browser instance.
type BrowserInterface e a
  = { getView          :: Aff e CoordSysView
    , getBrowserCanvas :: Aff e BrowserCanvas
    , lastOverlaps     :: Aff e (Number -> Point -> a)
    , queueCommand     :: Variant UICmdR -> Aff e Unit
    , queueUpdateView  :: UpdateView -> Eff e Unit
    }

-- | Creates the browser using the provided initial data, returning
-- | a BrowserInterface for reading state & sending commands to it
initializeBrowser :: CoordSys _ _
                  -> (BrowserCanvas -> CoordSysView
                      -> { tracks :: { snps :: RenderedTrack (SNP ())
                                     , annotations :: RenderedTrack (Annotation ()) }
                         , relativeUI :: Drawing
                         , fixedUI :: Drawing })
                  -> CoordSysView
                  -> BrowserCanvas
                  -> Aff _ (BrowserInterface _ ({snps :: Array (SNP ())}))
initializeBrowser cSys mainBrowser initView bc = do

  renderFiberVar <- AVar.makeEmptyVar

  viewVar <- AVar.makeVar initView
  bcVar <- AVar.makeVar bc

  uiCmdVar <- AVar.makeEmptyVar
  lastOverlapsVar <- AVar.makeEmptyVar

  drawCachedBrowser <- browserCache mainBrowser

  let getView = AVar.readVar viewVar
      getBrowserCanvas = AVar.readVar bcVar
      queueCommand = flip AVar.putVar uiCmdVar
      lastOverlaps = AVar.readVar lastOverlapsVar

    -- hardcoded timeout for now
  queueUpdateView <- uiViewUpdate cSys (wrap 100.0) {view: viewVar, uiCmd: uiCmdVar}

  let mainLoop = do
        uiCmd <- AVar.takeVar uiCmdVar
        case_ # V.on _render (\_ -> pure unit)
              # V.on _docResize (\ {width} -> do
                      canvas <- AVar.takeVar bcVar
                      let {height} = canvas ^. _Dimensions
                      canvas' <- liftEff $ setBrowserCanvasSize {width, height} canvas
                      AVar.putVar canvas' bcVar
                      queueCommand $ inj _render unit
                      mainLoop)
              $ uiCmd
        -- case_ # V.on _render (\_ -> pure unit)
        --       # V.on _docResize (\ {width} -> do
        --               canvas <- AVar.takeVar bcVar
        --               {height} <- _.size <$> getDimensions canvas
        --               -- let {height} = dims.size
        --               _ <- liftEff $ setBrowserContainerSize {width, height} canvas
        --               AVar.putVar canvas bcVar
        --               queueCommand $ inj _render unit
        --               mainLoop)
        --       $ uiCmd


        -- if there's a rendering fiber running, we kill it
        traverse_ (killFiber (error "Resetting renderer"))
          =<< AVar.tryTakeVar renderFiberVar

        csView <- getView
        canvas <- getBrowserCanvas
        toRender <- drawCachedBrowser canvas csView

        let currentScale = viewScale (canvas ^. _Track <<< _Dimensions) csView
            offset = scaleToScreen  currentScale (Pair.fst $ unwrap $ csView)

                          -- offset the click by the current canvas translation
        _ <- AVar.tryTakeVar lastOverlapsVar
        AVar.putVar (\n r -> let r' = {x: r.x + offset, y: r.y }
                             in { snps: toRender.tracks.snps.overlaps n r' }) lastOverlapsVar

        -- fork a new renderFiber
        renderFiber <- forkAff
                       $ renderBrowser (wrap 2.0) canvas offset toRender
        AVar.putVar renderFiber renderFiberVar

        mainLoop

  _ <- forkAff mainLoop


  queueCommand $ inj _render unit

  pure { getView
       , getBrowserCanvas
       , lastOverlaps
       , queueCommand
       , queueUpdateView }


type BrowserInterface' e
  = { getView          :: Aff e CoordSysView
    , getBrowserCanvas :: Aff e BrowserContainer
    -- , lastOverlaps     :: Aff e (Number -> Point -> a)
    , queueCommand     :: Variant UICmdR -> Aff e Unit
    , queueUpdateView  :: UpdateView -> Eff e Unit
    }


initializeBrowser' :: ∀ r.
                      CoordSys _ _
                   -> { snps        :: Number -> CoordSysView -> Eff _ Unit
                      , annotations :: Number -> CoordSysView -> Eff _ Unit
                      , chrs        :: Number -> CoordSysView -> Eff _ Unit
                      , fixedUI     :: Eff _ Unit | r}
                  -> CoordSysView
                  -> BrowserContainer
                  -> Aff _ (BrowserInterface' _)
initializeBrowser' cSys renderFuns initView bc = do

  renderFiberVar <- AVar.makeEmptyVar

  viewVar <- AVar.makeVar initView
  bcVar <- AVar.makeVar bc

  uiCmdVar <- AVar.makeEmptyVar
  lastOverlapsVar <- AVar.makeEmptyVar

  let getView = AVar.readVar viewVar
      getBrowserCanvas = AVar.readVar bcVar
      queueCommand = flip AVar.putVar uiCmdVar
      lastOverlaps = AVar.readVar lastOverlapsVar

    -- hardcoded timeout for now
  queueUpdateView <- uiViewUpdate cSys (wrap 100.0) {view: viewVar, uiCmd: uiCmdVar}

  let mainLoop = do
        uiCmd <- AVar.takeVar uiCmdVar
        case_ # V.on _render (\_ -> pure unit)
              # V.on _docResize (\_ -> pure unit)
              -- # V.on _docResize (\ {width} -> do
              --         canvas <- AVar.takeVar bcVar
              --         {height} <- _.size <$> getDimensions canvas
              --         -- let {height} = dims.size
              --         _ <- liftEff $ setBrowserContainerSize {width, height} canvas
              --         AVar.putVar canvas bcVar
              --         queueCommand $ inj _render unit
              --         mainLoop)
              $ uiCmd

        -- if there's a rendering fiber running, we kill it
        traverse_ (killFiber (error "Resetting renderer"))
          =<< AVar.tryTakeVar renderFiberVar

        csView <- getView
        canvas <- getBrowserCanvas
        -- toRender <- liftEff $ renderFuns.snps csView
        -- toRender <- drawCachedBrowser canvas csView

        currentDims <- getDimensions canvas

        let trackDims = _.padded $ browserSlots currentDims
            currentScale = viewScale trackDims.size csView
            offset = scaleToScreen  currentScale (Pair.fst $ unwrap $ csView)

                          -- offset the click by the current canvas translation
        -- _ <- AVar.tryTakeVar lastOverlapsVar
        -- AVar.putVar (\n r -> let r' = {x: r.x + offset, y: r.y }
        --                      in unsafeCoerce $ unit) lastOverlapsVar
                             -- in { snps: toRender.tracks.snps.overlaps n r' }) lastOverlapsVar

        -- fork a new renderFiber
        renderFiber <- forkAff $ liftEff do
          log $ "rendering with offset: " <> show offset
          log <<< show =<< Map.keys <$> getLayers bc

          renderFuns.chrs        offset csView
          renderFuns.annotations offset csView
          renderFuns.snps        offset csView
          renderFuns.fixedUI



        AVar.putVar renderFiber renderFiberVar

        mainLoop

  _ <- forkAff mainLoop

  queueCommand $ inj _render unit

  pure { getView
       , getBrowserCanvas
       -- , lastOverlaps
       , queueCommand
       , queueUpdateView }


data UpdateView =
    ScrollView Number
  | ZoomView Number
  | ModView (Pair BigInt -> Pair BigInt)


instance showUpdateView :: Show UpdateView where
  show (ScrollView x) = "(Scroll by " <> show x <> ")"
  show (ZoomView s) = "(Zoom by " <> show s <> ")"
  show _ = "(ModView)"


    -- TODO idk if this instance makes sense??? whatevs
instance semigroupUpdateView :: Semigroup UpdateView where
  append (ScrollView x1) (ScrollView x2) = ScrollView (x1 + x2)
  append (ZoomView s1)   (ZoomView s2)   = ZoomView   (s1 * s2)
  append _ y = y

instance monoidUpdateView :: Monoid UpdateView where
  mempty = ModView id


updateViewFold :: UpdateView
               -> CoordSysView
               -> CoordSysView
updateViewFold uv = over CoordSysView case uv of
  ZoomView   x -> (_ `scalePairBy`     x)
  ScrollView x -> (_ `translatePairBy` x)
  ModView f    -> f


queueCmd :: ∀ a. AVar a -> a -> Eff _ Unit
queueCmd av cmd = launchAff_ $ AVar.putVar cmd av


-- | Provided with the AVar containing the view state (which is updated atomically)
-- | and the UICmd AVar queue (which is only written to),
-- | return a function that queues view updates using the provided timeout.
uiViewUpdate :: ∀ r.
                CoordSys _ BigInt
             -> Milliseconds
             -> { view  :: AVar CoordSysView
                , uiCmd :: AVar (Variant UICmdR) | r }
             -> Aff _ (UpdateView -> Eff _ Unit)
uiViewUpdate cs timeout { view, uiCmd } = do
  viewCmd <- AVar.makeEmptyVar

  curCmdVar <- AVar.makeVar (ModView id)

  let normView = normalizeView cs (BigInt.fromInt 200000)
      loop' updater = do
        cmd <- AVar.takeVar viewCmd

        killFiber (error "Resetting view update") updater
        liftEff $ log $ "forking view update"

        curCmd <- AVar.takeVar curCmdVar
        let cmd' = curCmd <> cmd
        AVar.putVar cmd' curCmdVar

        updater' <- forkAff do
            delay timeout
            liftEff $ log "Running view update"

            vr <- AVar.takeVar view
            let vr' = normView $ updateViewFold cmd' vr
            AVar.putVar vr' view

            AVar.putVar (inj _render unit) uiCmd
            AVar.takeVar curCmdVar *> AVar.putVar mempty curCmdVar

        loop' updater'

  _ <- forkAff $ loop' (pure unit)

  pure $ queueCmd viewCmd



btnUI :: { scrollMod :: Number, zoomMod :: Number }
      -> (UpdateView -> Eff _ Unit)
      -> Eff _ Unit
btnUI mods cb = do
  buttonEvent "scrollLeft"  $ cb $ ScrollView     (-mods.scrollMod)
  buttonEvent "scrollRight" $ cb $ ScrollView       mods.scrollMod
  buttonEvent "zoomOut"     $ cb $ ZoomView $ 1.0 + mods.zoomMod
  buttonEvent "zoomIn"      $ cb $ ZoomView $ 1.0 - mods.zoomMod


keyUI :: ∀ r.
         Element
      -> { scrollMod :: Number | r }
      -> (UpdateView -> Eff _ Unit)
      -> Eff _ Unit
keyUI el mods cb = keydownEvent el f
  where f ke = case DOM.key ke of
          "ArrowLeft"  -> cb $ ScrollView (-mods.scrollMod)
          "ArrowRight" -> cb $ ScrollView   mods.scrollMod
          _ -> pure unit



type UICmdR = ( render :: Unit
              , docResize :: { width :: Number, height :: Number } )

_render = SProxy :: SProxy "render"
_docResize = SProxy :: SProxy "docResize"




debugView :: BrowserInterface _ _
          -> Eff _ { get :: _
                   , set :: _ }
debugView s = do
  let get name = launchAff_ do
         view <- s.getView
         liftEff do
           log $ "CoordSysView: " <> show (map BigInt.toString $ unwrap view)
           setWindow name $ (\(Pair l r) -> {l,r}) $ unwrap view

  let set lr = s.queueUpdateView
               $ ModView $ const (BigInt.fromNumber <$> Pair lr.l lr.r)

  pure {get, set}


browserCache
  :: ∀ a b.
     (BrowserCanvas
      -> CoordSysView
      -> { tracks :: { snps :: a
                     , annotations :: b }
         , relativeUI :: Drawing
         , fixedUI :: Drawing })
     -> Aff _ (BrowserCanvas
               -> CoordSysView
               -> Aff _ ({ tracks :: { snps :: a
                                     , annotations :: b }
                         , relativeUI :: Drawing
                         , fixedUI :: Drawing }))
browserCache f = do
  bcDim <- AVar.makeEmptyVar
  viewSize <- AVar.makeEmptyVar

  lastPartial <- AVar.makeEmptyVar
  lastFinal <- AVar.makeEmptyVar

  pure \bc csv -> do

    let newBCDim = bc ^. _Dimensions
    oldBCDim <- AVar.tryTakeVar bcDim
    AVar.putVar newBCDim bcDim

    oldPartial <- AVar.tryTakeVar lastPartial

    partial <- case oldBCDim, oldPartial of
      Just d, Just o -> do
        let changed = not $ d `eqRecord` newBCDim
        liftEff $ log $ "BrowserCanvas changed? " <> (show changed)
        -- remove the cached final output value on canvas resize,
        -- since we need to recalculate everything
        when changed (void $ AVar.tryTakeVar lastFinal)
        pure $ if d `eqRecord` newBCDim then o else f bc

      _, _ -> do
        liftEff $ log "Cache was empty! Recalculating all"
        _ <- AVar.tryTakeVar lastFinal
        pure $ f bc

    AVar.putVar partial lastPartial

    let newViewSize = pairSize $ unwrap csv
    oldViewSize <- AVar.tryTakeVar viewSize
    AVar.putVar newViewSize viewSize

    oldFinal <- AVar.tryTakeVar lastFinal

    let output = case oldViewSize, oldFinal of
          Just vs, Just o -> if newViewSize == vs then o else partial csv
          _, _ -> partial csv

    AVar.putVar output lastFinal
    pure output





printSNPInfo :: ∀ r. Array (SNP r) -> Eff _ Unit
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


peakHTML :: ∀ a.
            (a -> String)
         -> Peak _ _ a
         -> String
peakHTML disp peak =
  case Array.uncons peak.elements of
    Nothing               -> ""
    Just {head, tail: []} -> disp head
    Just {head, tail}     ->
      wrapWith "div" $ wrapWith "p"
        $ show (length tail + 1) <> " annotations"


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


-- | Example HTML generator that only shows the "anno" field
annotationHTMLAnnoOnly :: Annotation () -> String
annotationHTMLAnnoOnly = annotationHTML disp
  where disp fv
          | fv.field == "anno" = pure $ showAnnotationField fv
          | otherwise          = Nothing



foreign import initDebugDiv :: ∀ e. Number -> Eff e Unit
foreign import setDebugDivVisibility :: ∀ e. String -> Eff e Unit
foreign import setDebugDivPoint :: ∀ e. Point -> Eff e Unit


foreign import setElementContents :: ∀ e. Element -> String -> Eff e Unit

data InfoBoxF
  = IBoxShow
  | IBoxHide
  | IBoxSetY Int
  | IBoxSetX Int
  | IBoxSetContents String

derive instance genericInfoBoxF :: Generic InfoBoxF _

instance showInfoBoxF :: Show InfoBoxF where
  show = genericShow

updateInfoBox :: Element -> InfoBoxF -> Eff _ Unit
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

infoBoxId :: ElementId
infoBoxId = wrap "infoBox"

initInfoBox :: Eff _ (InfoBoxF -> Eff _ Unit)
initInfoBox = do
  doc <- map DOM.htmlDocumentToDocument
           $ DOM.document =<< DOM.window
  el <- DOM.createElement "div" doc

  DOM.setId infoBoxId el

  DOM.documentElement doc >>= case _ of
    Nothing -> throw "Couldn't find document body!"
    Just docBody -> void $ DOM.appendChild el docBody

  pure $ updateInfoBox el


runBrowser :: Conf -> BrowserContainer -> Eff _ _
runBrowser config bc = launchAff $ do

  let clickRadius = 1.0

  liftEff $ initDebugDiv clickRadius

  cmdInfoBox <- liftEff $ initInfoBox

  let cSys :: CoordSys ChrId BigInt
      cSys = coordSys mouseChrSizes

  trackData <-
    {genes:_, snps:_, annotations:_}
    <$> foldMap (getGenes       cSys) config.urls.genes
    <*> foldMap (getSNPs        cSys) config.urls.snps
    <*> foldMap (getAnnotations cSys) config.urls.annotations


  render <- liftEff
            $ addDemoLayers cSys config trackData bc

  browser <-
    initializeBrowser' cSys render (wrap $ Pair zero (cSys^._TotalSize)) bc

  -- zI

  browserClickHandler bc
    $ Padded 5.0 \pt -> do
        log $ "clicked Padded (" <> show pt.x <> ", " <> show pt.y <> ")"

  browserClickHandler bc
    $ CLeft \pt -> do
        log $ "clicked Left (" <> show pt.x <> ", " <> show pt.y <> ")"

  browserClickHandler bc
    $ CRight \pt -> do
        log $ "clicked Right (" <> show pt.x <> ", " <> show pt.y <> ")"

  liftEff do
    resizeEvent \d ->
      launchAff_ $ browser.queueCommand $ inj _docResize d

    let mods = { scrollMod: 0.05, zoomMod: 0.1 }

    btnUI mods browser.queueUpdateView

    -- keyUI (unsafeCoerce $ (unwrap bc).staticOverlay)
    --       mods browser.queueUpdateView

    dragScroll bc \ {x,y} ->
      -- only do anything when scrolling at least a pixel
      when (Math.abs x >= one) do
        trackDims <- _.padded <<< browserSlots <$> getDimensions bc
        browser.queueUpdateView
         $ ScrollView $ (-x) / trackDims.size.width

    let scrollZoomScale = 0.06
    wheelZoom bc \dY ->
       browser.queueUpdateView
         $ ZoomView $ 1.0 + scrollZoomScale * dY

    pure unit
{-
  liftEff do
    let overlayDebug :: _
        overlayDebug p = do
          setDebugDivVisibility "visible"
          setDebugDivPoint p

    let sigSnps = filterSig config.score trackData.snps
        annotAround pks snp =
          Array.find (\a -> a.covers `pairsOverlap` snp.position)
            =<< Map.lookup snp.feature.chrId pks

        glyphClick :: _
        glyphClick p = launchAff_ do
          v  <- browser.getView
          bc <- browser.getBrowserCanvas

          -- let segs = pixelSegments { segmentPadding: 12.0 } cSys bc v
          let segs = unsafeCoerce unit
              annoPeaks = annotationsForScale cSys sigSnps
                            trackData.annotations segs

          lastOverlaps' <- browser.lastOverlaps
          liftEff do
            let clicked = (lastOverlaps' clickRadius p).snps
            printSNPInfo clicked
            case Array.head clicked of
              Nothing -> cmdInfoBox IBoxHide
              Just g  -> do
                cmdInfoBox IBoxShow
                cmdInfoBox $ IBoxSetX $ Int.round p.x
                cmdInfoBox $ IBoxSetContents
                  $ snpHTML g
                  <> foldMap (peakHTML annotationHTMLDefault) (annotAround annoPeaks g)
-}

    {-
    ?browserOnClick bc
      { overlay: \_ -> pure unit
      -- { overlay: overlayDebug
      , track:   glyphClick }
    -}

    pure unit

  pure unit



type DataURLs = { snps        :: Maybe String
                , annotations :: Maybe String
                , genes       :: Maybe String
                }



type Conf =
  { browserHeight :: Number
  , trackPadding :: TrackPadding
  , score :: { min :: Number, max :: Number, sig :: Number }
  , urls :: DataURLs
  , snpsConfig        :: SNPConfig
  , annotationsConfig :: AnnotationsConfig
  , legend :: LegendConfig ()
  , vscale :: VScale ()
  }

foreign import setWindow :: ∀ e a. String -> a -> Eff e Unit


main :: Foreign -> Eff _ _
main rawConfig = do

  el' <- do
    doc <- DOM.htmlDocumentToDocument
           <$> (DOM.document =<< DOM.window)
    DOM.querySelector (wrap "#browser") (toParentNode doc)

  case read rawConfig :: Either MultipleErrors Conf of
    Left errs -> traverse_ (log <<< renderForeignError) errs
    Right c   -> do
      case el' of
        Nothing -> log "Could not find element '#browser'"
        Just el -> do

          {width} <- windowInnerSize
          let dimensions = { width, height: c.browserHeight }
          -- bc <- browserCanvas dimensions c.trackPadding el
          bc <- browserContainer dimensions c.trackPadding el

          -- debugBrowserCanvas "debugBC" bc

          log $ unsafeStringify c
          void $ runBrowser c bc



-- TODO this could almost certainly be done better
chunkConsumer :: ∀ m a.
                 Foldable m
              => Monoid (m a)
              => AVar (m a)
              -> Consumer (m a) (Aff _) Unit
chunkConsumer av = Co.consumer \m ->
  if null m
    then pure $ Just unit
    else do
      sofar <- AVar.takeVar av
      AVar.putVar (sofar <> m) av
      delay (wrap 20.0)
      pure Nothing


type TrackVar a = AVar (Map ChrId (Array a))
type TrackProducer eff a = Producer (Map ChrId (Array a)) (Aff eff) Unit

-- Feels like this one takes care of a bit too much...
fetchLoop1 :: ∀ a.
              (Maybe (Aff _ (TrackProducer _ a)))
           -> Aff _ (TrackVar a)
fetchLoop1 Nothing = AVar.makeEmptyVar
fetchLoop1 (Just startProd) = do
  prod <- startProd
  avar <- AVar.makeVar mempty
  _ <- forkAff $ runProcess $ prod `connect` chunkConsumer avar
  pure avar

-- | Starts threads that fetch & parse each of the provided tracks,
-- | filling an AVar over time per track, which can be used by other parts of the application
-- | (read only, should be a newtype)
{-
fetchLoop :: CoordSys ChrId BigInt
          -> DataURLs
          -> Aff _
               { gwas :: TrackVar (GWASFeature ())
               , genes :: TrackVar BedFeature
               }
fetchLoop cs urls = do
  gwas <-        fetchLoop1 $ produceGWAS   cs <$> urls.gwas
  genes <-       fetchLoop1 $ produceGenes  cs <$> urls.genes
  pure { gwas, genes }
-}


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
      , Tuple "X"   "171031299"
      , Tuple "Y"   "91744698"
      ]
