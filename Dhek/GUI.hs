{-# LANGUAGE OverloadedStrings #-}
--------------------------------------------------------------------------------
-- |
-- Module : Dhek.GUI
--
-- This module declares everything related to the GUI like widgets
--
--------------------------------------------------------------------------------
module Dhek.GUI
    ( GUI(..)
    , initGUI
    , guiClearPdfCache
    , guiPdfSurface
    , guiRenderGuide
    , guiRenderGuides
    , loadImage
    , makeGUI
    , runGUI
    ) where

--------------------------------------------------------------------------------
import Prelude hiding (foldr)
import Control.Monad ((>=>))
import Control.Monad.Trans (MonadIO(..))
import Data.Foldable (Foldable, foldr, for_, traverse_)
import Data.IORef
import Data.Maybe
import Data.Monoid ((<>))
import Foreign.Ptr

--------------------------------------------------------------------------------
import           Control.Lens ((^.))
import           Data.Text (pack)
import qualified Graphics.Rendering.Cairo     as Cairo
import qualified Graphics.UI.Gtk              as Gtk
import qualified Graphics.UI.Gtk.Poppler.Page as Poppler

--------------------------------------------------------------------------------
import           Dhek.AppUtil (appTerminate, uiLoaded)
import           Dhek.I18N
import           Dhek.Mode.Common.Draw
import qualified Dhek.Resources as Resources
import           Dhek.Types
import           Dhek.Widget.Type
import           Dhek.Widget.BlankDocument

--------------------------------------------------------------------------------
data GUI =
    GUI
    { guiWindow :: Gtk.Window
    , guiPdfDialog :: Gtk.FileChooserDialog
    , guiJsonOpenDialog :: Gtk.FileChooserDialog
    , guiJsonSaveDialog :: Gtk.FileChooserDialog
    , guiPdfOpenMenuItem :: Gtk.MenuItem
    , guiOpenBlankMenuItem :: Gtk.MenuItem
    , guiJsonOpenMenuItem :: Gtk.MenuItem
    , guiJsonSaveMenuItem :: Gtk.MenuItem
    , guiOverlapMenuItem :: Gtk.CheckMenuItem
    , guiPrevButton :: Gtk.ToolButton
    , guiNextButton :: Gtk.ToolButton
    , guiZoomInButton :: Gtk.ToolButton
    , guiZoomOutButton :: Gtk.ToolButton
    , guiRemoveButton :: Gtk.Button
    , guiApplyButton :: Gtk.Button
    , guiDrawToggle :: Gtk.ToggleToolButton
    , guiDupToggle :: Gtk.ToggleToolButton
    , guiMultiSelToggle :: Gtk.ToggleToolButton
    , guiVRuler :: Gtk.VRuler
    , guiHRuler :: Gtk.HRuler
    , guiDrawingArea :: Gtk.DrawingArea
    , guiRectStore :: Gtk.ListStore Rect
    , guiNameEntry :: Gtk.Entry
    , guiValueEntry :: Gtk.Entry
    , guiTypeCombo :: Gtk.ComboBox
    , guiRectTreeSelection :: Gtk.TreeSelection
    , guiTypeStore :: Gtk.ListStore Gtk.ComboBoxText
    , guiValueEntryAlign :: Gtk.Alignment
    , guiWindowVBox :: Gtk.VBox
    , guiWindowHBox :: Gtk.HBox
    , guiVRulerAdjustment :: Gtk.Adjustment
    , guiHRulerAdjustment :: Gtk.Adjustment
    , guiModeToolbar :: Gtk.Toolbar
    , guiTranslate :: DhekMessage -> String
    , guiDokButton :: Gtk.ToolButton
    , guiIndexAlign :: Gtk.Alignment
    , guiIndexSpin :: Gtk.SpinButton
    , guiSplashAlign :: Gtk.Alignment
    , guiSplashOpen :: Gtk.Button
    , guiSplashDok :: Gtk.Button
    , guiPdfCache :: IORef (Maybe Cairo.Surface)
    , guiStatusBar :: Gtk.Statusbar
    , guiContextId :: Gtk.ContextId
    , guiDrawPopup :: Gtk.Window
    , guiBlankDocumentWidget :: Widget BlankDocumentEvent
    , guiDrawingAreaViewport :: Gtk.Viewport
    , guiMagneticForceMenuItem :: Gtk.CheckMenuItem
    }

--------------------------------------------------------------------------------
initGUI :: IO [String]
initGUI = do
    gtk      <- Gtk.initGUI
    Gtk.settingsGetDefault >>=
        foldr (\s _ -> settings gtk s) (fail "No GTK default settings")
  where
    settings :: [String] -> Gtk.Settings -> IO [String]
    settings gui gs = do
        Gtk.settingsSetLongProperty gs
                                   ("gtk-button-images" :: String)
                                   1
                                   "Dhek"
        return gui

makeGUI :: IO GUI
makeGUI = do
    _ <- initGUI

    -- Window creation
    win   <- Gtk.windowNew
    wvbox <- Gtk.vBoxNew False 10
    vbox  <- Gtk.vBoxNew False 10
    hbox  <- Gtk.hBoxNew False 10
    vleft <- Gtk.vBoxNew False 10
    Gtk.containerAdd win wvbox

    msgStr <- mkI18N

    -- PDF Dialog
    pdfch <- createDialog win
             (msgStr MsgOpenPDF)
             "*.pdf"
             (msgStr MsgPdfFilter)
             (msgStr MsgOpen)
             Gtk.FileChooserActionOpen
             msgStr

    -- JSON Save Dialog
    jsonSch <- createDialog win
              (msgStr MsgSaveMappings)
              "*.json"
              (msgStr MsgJsonFilter)
              (msgStr MsgSave)
              Gtk.FileChooserActionSave
              msgStr

    -- JSON Load Dialog
    jsonLch <- createDialog win
              (msgStr MsgLoadMappings)
              "*.json"
              (msgStr MsgJsonFilter)
              (msgStr MsgOpen)
              Gtk.FileChooserActionOpen
              msgStr

    -- Menu Bar
    mbar   <- Gtk.menuBarNew
    fmenu  <- Gtk.menuNew
    malign <- Gtk.alignmentNew 0 0 1 0
    fitem  <- Gtk.menuItemNewWithLabel $ msgStr MsgFile
    oitem  <- Gtk.menuItemNewWithLabel $ msgStr MsgOpenPDF
    ovitem <- Gtk.menuItemNewWithLabel $ msgStr MsgOpenBlank
    Gtk.set ovitem [Gtk.widgetTooltipText Gtk.:=
                    Just $ msgStr MsgOpenBlankTooltip]
    iitem  <- Gtk.menuItemNewWithLabel $ msgStr MsgLoadMappings
    sitem  <- Gtk.menuItemNewWithLabel $ msgStr MsgSaveMappings
    citem  <- Gtk.checkMenuItemNewWithLabel $ msgStr MsgEnableOverlap
    mitem  <- Gtk.checkMenuItemNewWithLabel $ msgStr MsgMagneticForce
    Gtk.menuShellAppend fmenu oitem
    Gtk.menuShellAppend fmenu ovitem
    Gtk.menuShellAppend fmenu iitem
    Gtk.menuShellAppend fmenu sitem
    Gtk.menuShellAppend fmenu citem
    Gtk.menuShellAppend fmenu mitem
    Gtk.menuItemSetSubmenu fitem fmenu
    Gtk.menuShellAppend mbar fitem
    Gtk.containerAdd malign mbar
    Gtk.widgetSetSensitive iitem False
    Gtk.widgetSetSensitive sitem False
    Gtk.widgetSetSensitive citem False
    Gtk.widgetSetSensitive mitem False
    Gtk.checkMenuItemSetActive mitem True
    Gtk.boxPackStart wvbox malign Gtk.PackNatural 0

    -- Button Next
    next  <- createToolButton Resources.goNext $ msgStr MsgNextPageTooltip
     -- Previous Prev
    prev  <- createToolButton Resources.goPrevious $
                 msgStr MsgPreviousPageTooltip
    -- Button Zoom out
    minus <- createToolButton Resources.zoomOut $ msgStr MsgZoomOutTooltip
    -- Button Zoom in
    plus  <- createToolButton Resources.zoomIn $ msgStr MsgZoomInTooltip
    -- Button Draw
    drwb  <- createToggleToolButton Resources.drawRectangle $
                Just $ msgStr MsgNormalModeTooltip
    Gtk.toggleToolButtonSetActive drwb True
    -- Button Duplicate
    db    <- createToggleToolButton Resources.duplicateRectangle Nothing
    -- Button MultiSelection
    msb   <- createToggleToolButton Resources.rectangularSelection $
                Just $ msgStr MsgSelectionModeTooltip

    -- Main Toolbar
    toolbar <- Gtk.toolbarNew
    Gtk.toolbarSetStyle toolbar Gtk.ToolbarIcons
    Gtk.toolbarSetIconSize toolbar (Gtk.IconSizeUser 32)
    vsep1   <- Gtk.separatorToolItemNew
    vsep2   <- Gtk.separatorToolItemNew
    Gtk.toolbarInsert toolbar prev (-1)
    Gtk.toolbarInsert toolbar next (-1)
    Gtk.toolbarInsert toolbar vsep1 (-1)
    Gtk.toolbarInsert toolbar minus (-1)
    Gtk.toolbarInsert toolbar plus (-1)
    Gtk.toolbarInsert toolbar vsep2 (-1)
    Gtk.toolbarInsert toolbar drwb (-1)
    Gtk.toolbarInsert toolbar db (-1)
    Gtk.toolbarInsert toolbar msb (-1)
    Gtk.boxPackStart vbox toolbar Gtk.PackNatural 0

    -- Button Applidok
    kimg <- loadImage Resources.applidok
    akb  <- Gtk.toolButtonNew (Just kimg) (Nothing :: Maybe String)
    Gtk.set akb [Gtk.widgetTooltipText Gtk.:=
                 Just $ msgStr MsgApplidokTooltip]

    -- Mode toolbar
    mtoolbar <- Gtk.toolbarNew
    Gtk.toolbarSetStyle mtoolbar Gtk.ToolbarIcons
    Gtk.toolbarSetIconSize mtoolbar (Gtk.IconSizeUser 32)
    Gtk.toolbarInsert mtoolbar akb 0
    Gtk.boxPackStart vbox mtoolbar Gtk.PackNatural 0

    -- Splash screen
    splash   <- Gtk.vBoxNew False 40
    splalign <- Gtk.alignmentNew 0.5 0.4 0 0
    splelign <- Gtk.alignmentNew 0 0 0 0
    splslign <- Gtk.alignmentNew 0 0 0 0
    splopen  <- Gtk.buttonNewWithLabel $ msgStr MsgSplashOpenPDFFile
    spledit  <- Gtk.labelNew $ Just $ msgStr MsgSplashEdit
    splsave  <- Gtk.labelNew $ Just $ msgStr MsgSplashSave
    spldok   <- Gtk.buttonNewWithLabel $ msgStr MsgSplashCopy
    Gtk.containerAdd splalign splash
    Gtk.containerAdd splelign spledit
    Gtk.containerAdd splslign splsave
    Gtk.buttonSetAlignment splopen (0, 0)
    Gtk.buttonSetAlignment spldok (0, 0)
    Gtk.boxPackStart splash splopen Gtk.PackRepel 0
    Gtk.boxPackStart splash splelign Gtk.PackNatural 0
    Gtk.boxPackStart splash splslign Gtk.PackNatural 0
    Gtk.boxPackStart splash spldok Gtk.PackNatural 0
    Gtk.containerAdd wvbox splalign

    -- Drawing Area tooltip
    drawpop <- Gtk.windowNewPopup
    dplabel <- Gtk.labelNew (Nothing :: Maybe String)
    Gtk.labelSetMarkup dplabel $ msgStr MsgDuplicationModePopup
    Gtk.containerAdd drawpop dplabel
    Gtk.windowSetTypeHint drawpop Gtk.WindowTypeHintTooltip
    Gtk.widgetModifyBg drawpop Gtk.StateNormal (Gtk.Color 0 0 0)
    Gtk.widgetModifyFg dplabel Gtk.StateNormal (Gtk.Color 65000 65000 65000)

    -- Drawing Area
    area     <- Gtk.drawingAreaNew
    vruler   <- Gtk.vRulerNew
    hruler   <- Gtk.hRulerNew
    hadj     <- Gtk.adjustmentNew 0 0 0 0 0 0
    vadj     <- Gtk.adjustmentNew 0 0 0 0 0 0
    viewport <- Gtk.viewportNew hadj vadj
    hscroll  <- Gtk.hScrollbarNew hadj
    vscroll  <- Gtk.vScrollbarNew vadj
    atable   <- Gtk.tableNew 3 3 False
    Gtk.containerAdd viewport area
    Gtk.set vruler [Gtk.rulerMetric Gtk.:= Gtk.Pixels]
    Gtk.set hruler [Gtk.rulerMetric Gtk.:= Gtk.Pixels]
    Gtk.widgetAddEvents area [ Gtk.PointerMotionMask
                             , Gtk.KeyPressMask
                             , Gtk.KeyReleaseMask
                             ]
    Gtk.widgetSetCanFocus area True
    Gtk.widgetSetSizeRequest viewport 200 200
    Gtk.widgetSetSizeRequest hruler 25 25
    Gtk.widgetSetSizeRequest vruler 25 25
    Gtk.tableSetRowSpacing atable 0 0
    Gtk.tableSetColSpacing atable 0 0
    let gtkTabAll  = [Gtk.Expand, Gtk.Shrink, Gtk.Fill]
        gtkTabView = [Gtk.Expand, Gtk.Fill]
    Gtk.tableAttach atable hruler 1 2 0 1 gtkTabAll [Gtk.Fill] 0 0
    Gtk.tableAttach atable hscroll 1 2 2 3 gtkTabAll [Gtk.Fill] 0 0
    Gtk.tableAttach atable vruler 0 1 1 2 [Gtk.Fill] gtkTabAll 0 0
    Gtk.tableAttach atable vscroll 2 3 1 2 [Gtk.Fill] gtkTabAll 0 0
    Gtk.tableAttach atable viewport 1 2 1 2 gtkTabView gtkTabView 0 0
    Gtk.boxPackStart vbox atable Gtk.PackGrow 0

    -- Area list
    store  <- Gtk.listStoreNew ([] :: [Rect])
    treeV  <- Gtk.treeViewNewWithModel store
    sel    <- Gtk.treeViewGetSelection treeV
    tswin  <- Gtk.scrolledWindowNew Nothing Nothing
    atswin <- Gtk.alignmentNew 0 0 1 1
    col    <- Gtk.treeViewColumnNew
    trend  <- Gtk.cellRendererTextNew

    Gtk.treeViewColumnSetTitle col $ msgStr $ MsgAreas
    Gtk.cellLayoutPackStart col trend False
    Gtk.cellLayoutSetAttributes col trend store layoutMapping
    _ <- Gtk.treeViewAppendColumn treeV col
    Gtk.scrolledWindowAddWithViewport tswin treeV
    Gtk.scrolledWindowSetPolicy tswin Gtk.PolicyAutomatic Gtk.PolicyAutomatic
    Gtk.containerAdd atswin tswin
    Gtk.boxPackStart vleft atswin Gtk.PackGrow 0
    Gtk.boxPackStart hbox vbox Gtk.PackGrow 0
    Gtk.boxPackStart hbox vleft Gtk.PackNatural 0

    -- Remove button
    remb <- createButton Resources.drawEraser
            (msgStr MsgRemove)
            (Just $ msgStr MsgRemoveTooltip)

    -- Apply button
    app  <- createButton Resources.dialogAccept
            (msgStr MsgApply)
            (Just $ msgStr MsgApplyTooltip)

    idxspin <- Gtk.spinButtonNewWithRange 0 200 1
    nlabel  <- Gtk.labelNew (Just $ msgStr MsgName)
    tlabel  <- Gtk.labelNew (Just $ msgStr MsgType)
    vlabel  <- Gtk.labelNew (Just $ msgStr MsgValue)
    idxlabel <- Gtk.labelNew (Just $ msgStr MsgIndex)
    pentry  <- Gtk.entryNew
    ventry  <- Gtk.entryNew
    nalign  <- Gtk.alignmentNew 0 0.5 0 0
    talign  <- Gtk.alignmentNew 0 0.5 0 0
    valign  <- Gtk.alignmentNew 0 0.5 0 0
    idxalign <- Gtk.alignmentNew 0 0.5 0 0
    salign  <- Gtk.alignmentNew 0 0 1 0
    table   <- Gtk.tableNew 2 4 False
    tvbox   <- Gtk.vBoxNew False 10
    pcombo  <- Gtk.comboBoxNew
    tstore  <- Gtk.comboBoxSetModelText pcombo
    hsep    <- Gtk.hSeparatorNew
    arem    <- Gtk.alignmentNew 0.5 0 0 0
    aapp    <- Gtk.alignmentNew 0.5 0 0 0
    Gtk.containerAdd arem remb
    Gtk.containerAdd aapp app
    Gtk.containerAdd nalign nlabel
    Gtk.containerAdd talign tlabel
    Gtk.containerAdd valign vlabel
    Gtk.containerAdd idxalign idxlabel
    Gtk.tableAttachDefaults table nalign 0 1 0 1
    Gtk.tableAttachDefaults table pentry 1 2 0 1
    Gtk.tableAttachDefaults table talign 0 1 1 2
    Gtk.tableAttachDefaults table pcombo 1 2 1 2
    Gtk.tableAttachDefaults table valign 0 1 2 3
    Gtk.tableAttachDefaults table ventry 1 2 2 3
    Gtk.tableAttachDefaults table idxalign 0 1 3 4
    Gtk.tableAttachDefaults table idxspin 1 2 3 4
    Gtk.tableSetRowSpacings table 10
    Gtk.tableSetColSpacings table 10
    let types = ["text", "checkbox", "radio", "comboitem", "textcell"]
    traverse_ (Gtk.listStoreAppend tstore) types
    Gtk.containerAdd salign hsep
    Gtk.widgetSetSensitive remb False
    Gtk.widgetSetSensitive app False
    Gtk.widgetSetSensitive pentry False
    Gtk.widgetSetSensitive pcombo False
    Gtk.boxPackStart tvbox table Gtk.PackNatural 0
    Gtk.boxPackStart tvbox aapp Gtk.PackNatural 0
    Gtk.boxPackStart vleft salign Gtk.PackNatural 0
    Gtk.boxPackStart vleft arem Gtk.PackNatural 0
    Gtk.containerAdd vleft tvbox
    Gtk.widgetSetChildVisible valign False
    Gtk.widgetSetChildVisible ventry False
    Gtk.widgetSetChildVisible idxalign False
    Gtk.widgetSetChildVisible idxspin False
    Gtk.widgetHideAll valign
    Gtk.widgetHideAll ventry
    Gtk.widgetHideAll idxalign
    Gtk.widgetHideAll idxspin

    -- Window configuration
    Gtk.set win [ Gtk.windowTitle          Gtk.:= msgStr MsgMainTitle
                , Gtk.windowDefaultWidth   Gtk.:= 800
                , Gtk.windowDefaultHeight  Gtk.:= 600
                , Gtk.containerBorderWidth Gtk.:= 10
                ]

    -- Status bar
    sbar    <- Gtk.statusbarNew
    sbalign <- Gtk.alignmentNew 0 1 1 0
    ctxId   <- Gtk.statusbarGetContextId sbar ("mode" :: String)
    Gtk.statusbarSetHasResizeGrip sbar False
    Gtk.containerAdd sbalign sbar
    Gtk.boxPackEnd vbox sbalign Gtk.PackNatural 0

    _ <- Gtk.onDestroy win $
             do Gtk.mainQuit
                appTerminate

    cache  <- newIORef Nothing

    bdw <- newBlankDocumentWidget msgStr win

    _ <- uiLoaded msgStr win
    Gtk.widgetShowAll win

    return $ GUI{ guiWindow = win
                , guiPdfDialog = pdfch
                , guiJsonOpenDialog = jsonLch
                , guiJsonSaveDialog = jsonSch
                , guiPdfOpenMenuItem = oitem
                , guiOpenBlankMenuItem = ovitem
                , guiJsonOpenMenuItem = iitem
                , guiJsonSaveMenuItem = sitem
                , guiOverlapMenuItem = citem
                , guiPrevButton = prev
                , guiNextButton = next
                , guiZoomInButton = plus
                , guiZoomOutButton = minus
                , guiRemoveButton = remb
                , guiApplyButton = app
                , guiDrawToggle = drwb
                , guiDupToggle = db
                , guiMultiSelToggle = msb
                , guiVRuler = vruler
                , guiHRuler = hruler
                , guiDrawingArea = area
                , guiRectStore = store
                , guiNameEntry = pentry
                , guiValueEntry = ventry
                , guiTypeCombo = pcombo
                , guiRectTreeSelection = sel
                , guiTypeStore = tstore
                , guiValueEntryAlign = valign
                , guiWindowVBox = wvbox
                , guiWindowHBox = hbox
                , guiVRulerAdjustment = vadj
                , guiHRulerAdjustment = hadj
                , guiModeToolbar = mtoolbar
                , guiTranslate = msgStr
                , guiDokButton = akb
                , guiIndexAlign = idxalign
                , guiIndexSpin = idxspin
                , guiSplashAlign = splalign
                , guiSplashOpen = splopen
                , guiSplashDok = spldok
                , guiPdfCache = cache
                , guiContextId = ctxId
                , guiStatusBar = sbar
                , guiDrawPopup = drawpop
                , guiBlankDocumentWidget = bdw
                , guiDrawingAreaViewport = viewport
                , guiMagneticForceMenuItem = mitem
                }

--------------------------------------------------------------------------------
createDialog :: Gtk.Window
             -> String -- title
             -> String -- file pattern
             -> String -- filter name
             -> String -- affirmative action label
             -> Gtk.FileChooserAction
             -> (DhekMessage -> String)
             -> IO Gtk.FileChooserDialog
createDialog win title pat filtName afflabel action msgStr = do
    ch   <- Gtk.fileChooserDialogNew (Just title) (Just win) action responses
    filt <- Gtk.fileFilterNew
    Gtk.fileFilterAddPattern filt pat
    Gtk.fileFilterSetName filt filtName
    Gtk.fileChooserAddFilter ch filt
    return ch
  where
    responses = [ (afflabel        , Gtk.ResponseOk)
                , (msgStr MsgCancel, Gtk.ResponseCancel)
                ]

--------------------------------------------------------------------------------
runGUI :: GUI -> IO ()
runGUI _ = do Gtk.mainGUI

--------------------------------------------------------------------------------
loadImage :: Ptr (Gtk.InlineImage) -> IO Gtk.Image
loadImage = Gtk.pixbufNewFromInline >=> Gtk.imageNewFromPixbuf

--------------------------------------------------------------------------------
guiPdfSurface :: MonadIO m => PageItem -> Double -> GUI -> m Cairo.Surface
guiPdfSurface pg ratio gui
    = liftIO $
          do opt <- readIORef (guiPdfCache gui)
             let pgw = pageWidth pg  * ratio
                 pgh = pageHeight pg * ratio
                 nocache
                     = do suf <- Cairo.createImageSurface Cairo.FormatARGB32
                                 (truncate pgw) (truncate pgh)
                          Cairo.renderWith suf $
                              do Cairo.setSourceRGB 1.0 1.0 1.0
                                 Cairo.rectangle 0 0 pgw pgh
                                 Cairo.fill
                                 Cairo.scale ratio ratio
                                 Poppler.pageRender (pagePtr pg)

                          writeIORef (guiPdfCache gui) $ Just suf
                          return suf
             maybe nocache return opt

--------------------------------------------------------------------------------
guiClearPdfCache :: MonadIO m => GUI -> m ()
guiClearPdfCache gui
    = liftIO $
          do opt <- readIORef (guiPdfCache gui)
             let oncache suf
                     = do Cairo.surfaceFinish suf
                          writeIORef (guiPdfCache gui) Nothing
             maybe (return ()) oncache opt

--------------------------------------------------------------------------------
layoutMapping :: Rect -> [Gtk.AttrOp Gtk.CellRendererText]
layoutMapping r
    | r ^. rectType == "radio" || r ^. rectType == "comboitem" =
        let value = fromMaybe "" (r ^. rectValue)
            name  = r ^. rectName
            label = name <> " (" <> value <> ")" in
        [Gtk.cellText Gtk.:= label]
    | r ^. rectType == "textcell" =
        let idx   = maybe "" (pack . show) (r ^. rectIndex)
            name  = r ^. rectName
            label = name <> " (" <> idx <> ")" in
        [Gtk.cellText Gtk.:= label]
    | otherwise = [Gtk.cellText Gtk.:= r ^. rectName]

--------------------------------------------------------------------------------
createToolButton :: Ptr Gtk.InlineImage -> String -> IO Gtk.ToolButton
createToolButton img msg
    = do imgb <- loadImage img
         b    <- Gtk.toolButtonNew (Just imgb) (Nothing :: Maybe String)
         Gtk.set b [Gtk.widgetTooltipText Gtk.:=
                       Just msg]
         return b

--------------------------------------------------------------------------------
createToggleToolButton :: Ptr Gtk.InlineImage
                       -> Maybe String
                       -> IO Gtk.ToggleToolButton
createToggleToolButton img mMsg
    = do b    <- Gtk.toggleToolButtonNew
         dimg <- loadImage img
         Gtk.toolButtonSetIconWidget b $ Just dimg
         Gtk.set b [Gtk.widgetTooltipText Gtk.:= mMsg]
         return b

--------------------------------------------------------------------------------
createButton :: Ptr Gtk.InlineImage
             -> String
             -> Maybe String
             -> IO Gtk.Button
createButton img label mTooltipMsg
    = do b    <- Gtk.buttonNewWithLabel label
         imgb <- loadImage img
         Gtk.buttonSetImage b imgb
         Gtk.set b [Gtk.widgetTooltipText Gtk.:= mTooltipMsg]
         return b

--------------------------------------------------------------------------------
guiRenderGuides :: Foldable f
                => GUI
                -> Double
                -> PageItem
                -> RGB
                -> f Guide
                -> IO ()
guiRenderGuides gui ratio _ guideColor gs
    = do frame     <- Gtk.widgetGetDrawWindow area
         (fw',fh') <- Gtk.drawableGetSize frame
         let fw     = fromIntegral fw'
             fh     = fromIntegral fh'
             --width  = ratio * (pageWidth page)
             --height = ratio * (pageHeight page)

         Gtk.renderWithDrawable frame $
             do Cairo.scale ratio ratio
                for_ gs $ \g ->
                    do drawGuide fw fh guideColor g
                       Cairo.closePath
                       Cairo.stroke
  where
    area = guiDrawingArea gui

--------------------------------------------------------------------------------
guiRenderGuide :: GUI -> Double -> PageItem -> RGB -> Guide -> IO ()
guiRenderGuide gui ratio page guideColor g =
    guiRenderGuides gui ratio page guideColor [g]
