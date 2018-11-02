{-# LANGUAGE DataKinds              #-}
{-# LANGUAGE DeriveGeneric          #-}
{-# LANGUAGE ExtendedDefaultRules   #-}
{-# LANGUAGE FlexibleContexts       #-}
{-# LANGUAGE FlexibleInstances      #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE KindSignatures         #-}
{-# LANGUAGE LambdaCase             #-}
{-# LANGUAGE MultiParamTypeClasses  #-}
{-# LANGUAGE OverloadedStrings      #-}
{-# LANGUAGE QuasiQuotes            #-}
{-# LANGUAGE RecursiveDo            #-}
{-# LANGUAGE ScopedTypeVariables    #-}
{-# LANGUAGE StandaloneDeriving     #-}
{-# LANGUAGE TemplateHaskell        #-}
{-# LANGUAGE TupleSections          #-}
{-# LANGUAGE TypeApplications       #-}
{-# LANGUAGE TypeFamilies           #-}

-- |
-- Copyright   :  (C) 2018 Kadena
-- License     :  BSD-style (see the file LICENSE)
--

module Frontend.ReplGhcjs where

------------------------------------------------------------------------------
import           Control.Lens
import           Control.Monad.State.Strict
import           Data.Aeson                  as Aeson (Object, encode, fromJSON, Result(..))
import qualified Data.ByteString.Lazy        as BSL
import           Data.Foldable
import qualified Data.HashMap.Strict         as H
import qualified Data.List                   as L
import qualified Data.List.Zipper            as Z
import           Data.Map                    (Map)
import qualified Data.Map                    as Map
import           Data.Maybe
import           Data.Semigroup
import           Data.Sequence               (Seq)
import qualified Data.Sequence               as S
import           Data.Set                    (Set)
import qualified Data.Set                    as Set
import           Data.Text                   (Text)
import qualified Data.Text                   as T
import qualified Data.Text.Encoding          as T
import           Data.Traversable            (for)
import           Generics.Deriving.Monoid    (mappenddefault, memptydefault)
import           GHC.Generics                (Generic)
import           Language.Javascript.JSaddle hiding (Object)
import           Reflex
import           Reflex.Dom.ACE.Extended
import qualified Reflex.Dom.Contrib.Widgets.DynTabs as Tabs
import           Reflex.Dom.Core             (keypress)
import qualified Reflex.Dom.Core             as Core
import           Reflex.Dom.SemanticUI       hiding (mainWidget)
import qualified GHCJS.DOM as DOM
import qualified GHCJS.DOM.EventM as EventM
import qualified GHCJS.DOM.GlobalEventHandlers as Events
------------------------------------------------------------------------------
import qualified Pact.Compile                as Pact
import qualified Pact.Parse                  as Pact
import           Pact.Repl
import           Pact.Repl.Types
import           Pact.Types.Lang
import           Obelisk.Generated.Static
------------------------------------------------------------------------------
import           Frontend.Backend
import           Frontend.Foundation
import           Frontend.Ide
import           Frontend.JsonData
import           Frontend.RightPanel
import           Frontend.UI.Button
import           Frontend.UI.Dialogs.DeployConfirmation
import           Frontend.UI.JsonData
import           Frontend.UI.Repl
import           Frontend.UI.Wallet
import           Frontend.Wallet
import           Frontend.Widgets
------------------------------------------------------------------------------

data ClickState = DownAt (Int, Int) | Clicked | Selected
  deriving (Eq,Ord,Show,Read)

app :: MonadWidget t m => m ()
app = void . mfix $ \ cfg -> do
  ideL <- makeIde cfg

  controlCfg <- controlBar ideL
  elAttr "main" ("id" =: "main" <> "class" =: "flexbox even") $ do
    editorCfg <- codePanel ideL
    envCfg <- elAttr "div" ("class" =: "flex" <> "id" =: "control-ui") $ do
      --envPanel ideL
      rightTabBar ideL

    modalCfg <- showModal ideL

    pure $ mconcat
      [ controlCfg
      , editorCfg
      , envCfg
      , modalCfg
      ]

showModal :: forall t m. MonadWidget t m => Ide t -> m (IdeCfg t)
showModal ideL = do
    document <- DOM.currentDocumentUnchecked

    onEsc <- wrapDomEventMaybe document (`EventM.on` Events.keyDown) $ do
      key <- getKeyEvent
      pure $ if keyCodeLookup (fromIntegral key) == Escape then Just () else Nothing

    (backdropEl, _) <- elDynAttr' "div"
      (ffor isVisible $ \isVis ->
        ("style" =: (isVisibleStyle isVis <> ";" <> existingBackdropStyle))
      )
      blank

    ev <- networkView $ showModal <$> _ide_modal ideL
    onFinish <- switchHold never $ snd <$> ev
    mCfg <- flatten $ fst <$> ev

    let
      onClose = leftmost [ onFinish
                         , onEsc
                         , domEvent Click backdropEl
                         ]
      lConf = mempty & ideCfg_reqModal .~ (Modal_NoModal <$ onClose)
    pure $ lConf <> mCfg
  where
    isVisible = getIsVisible <$> _ide_modal ideL
    getIsVisible = \case
      Modal_NoModal -> False
      _             -> True

    showModal = \case
      Modal_NoModal -> pure (mempty, never)
      Modal_DeployConfirmation -> uiDeployConfirmation ideL

    existingBackdropStyle = "position: fixed; top:0;bottom:0;left:0;right:0;z-index:100; background-color: rgba(0,0,0,0.5);"
    isVisibleStyle isVis = "display:" <> (if isVis then "block" else "none")

-- | Code editing (left hand side currently)
codePanel :: forall t m. MonadWidget t m => Ide t -> m (IdeCfg t)
codePanel ideL = do
  elAttr "div" ("class" =: "flex" <> "id" =: "main-wysiwyg") $
    divClass "wysiwyg" $ do
      pure mempty
      --onNewCode <- tagOnPostBuild $ _ide_code ideL
      --onUserCode <- codeWidget "" onNewCode

      --pure $ mempty & ideCfg_setCode .~ onUserCode

-- | Tabbed panel to the right
--
--   Offering access to:
--
--   - The REPL
--   - Compiler error messages
--   - Key & Data Editor
--   - Module explorer
-- TODO REMOVE!
envPanel :: forall t m. MonadWidget t m => Ide t -> m (IdeCfg t)
envPanel ideL = mdo
  let
    curSelection = _ide_envSelection ideL

  onSelect <- menu
    ( def & menuConfig_pointing .~ pure True
        & menuConfig_secondary .~ pure True
        & classes .~ pure "dark"
    )
    $ tabs curSelection

  explorerCfg <- tabPane
      ("style" =: "overflow-y: auto; overflow-x: hidden; flex-grow: 1")
      curSelection EnvSelection_ModuleExplorer
      $ moduleExplorer ideL

  replCfg <- tabPane
      ("class" =: "ui flex-content light segment")
      curSelection EnvSelection_Repl
      $ replWidget ideL

  envCfg <- tabPane
      ("class" =: "ui fluid accordion env-accordion")
      curSelection EnvSelection_Env $ mdo

    jsonCfg <- accordionItem True mempty "Data" $ do
      conf <- uiJsonData (ideL ^. ide_wallet) (ideL ^. ide_jsonData)
      pure $ mempty &  ideCfg_jsonData .~ conf

    keysCfg <- accordionItem True mempty "Keys" $ do
      conf <- uiWallet $ _ide_wallet ideL
      pure $ mempty & ideCfg_wallet .~ conf

    pure $ mconcat [ jsonCfg
                   , keysCfg
                   , replCfg
                   , explorerCfg
                   ]

  errorsCfg <- tabPane
      ("class" =: "ui code-font full-size")
      curSelection EnvSelection_Msgs $ do
    void . dyn $ traverse_ (snippetWidget . OutputSnippet) <$> _ide_msgs ideL
    pure mempty

  _functionsCfg <- tabPane ("style" =: "overflow: auto") curSelection EnvSelection_Functions $ do
    header def $ text "Public functions"
    dyn_ $ ffor (_ide_deployed ideL) $ \case
      Nothing -> paragraph $ text "Load a deployed contract with the module explorer to see the list of available functions."
      Just (backendUri, functions) -> functionsList ideL backendUri functions
    divider $ def & dividerConfig_hidden .~ Static True

  pure $ mconcat [ envCfg, errorsCfg ]

  where
    tabs :: Dynamic t EnvSelection -> m (Event t EnvSelection)
    tabs curSelection = do
      let
        selections = [ EnvSelection_Env, EnvSelection_Repl, EnvSelection_Msgs, EnvSelection_ModuleExplorer ]
      leftmost <$> traverse (tab curSelection) selections

    tab :: Dynamic t EnvSelection -> EnvSelection -> m (Event t EnvSelection)
    tab curSelection self = do
      let
        itemClasses = [boolClass "active" . Dyn $ fmap (== self) curSelection ]
        itemCfg = def & classes .~ dynClasses itemClasses
      onClick <- makeClickable $ menuItem' itemCfg $
        text $ selectionToText self
      pure $ self <$ onClick

functionsList :: MonadWidget t m => Ide t -> BackendUri -> [PactFunction] -> m ()
functionsList ideL backendUri functions = divClass "ui very relaxed list" $ do
  for_ functions $ \(PactFunction (ModuleName moduleName) name _ mdocs funType) -> divClass "item" $ do
    (e, _) <- elClass' "a" "header" $ do
      text name
      text ":"
      text $ tshow $ _ftReturn funType
      text " "
      elAttr "span" ("class" =: "description" <> "style" =: "display: inline") $ do
        text "("
        text $ T.unwords $ tshow <$> _ftArgs funType
        text ")"
    for_ mdocs $ divClass "description" . text
    open <- toggle False $ domEvent Click e
    dyn_ $ ffor open $ \case
      False -> pure ()
      True -> segment def $ form def $ do
        inputs <- for (_ftArgs funType) $ \arg -> field def $ do
          el "label" $ text $ "Argument: " <> tshow arg
          case _aType arg of
            TyPrim TyInteger -> fmap value . input def $ inputElement $ def
              & inputElementConfig_elementConfig . initialAttributes .~ Map.fromList
                [ ("type", "number")
                , ("step", "1")
                , ("placeholder", _aName arg)
                ]
            TyPrim TyDecimal -> do
              ti <- input def $ inputElement $ def
                & inputElementConfig_elementConfig . initialAttributes .~ Map.fromList
                  [ ("type", "number")
                  , ("step", "0.0000000001") -- totally arbitrary
                  , ("placeholder", _aName arg)
                  ]
              pure $ (\x -> if T.isInfixOf "." x then x else x <> ".0") <$> value ti
            TyPrim TyTime -> do
              i <- input def $ inputElement $ def
                & inputElementConfig_elementConfig . initialAttributes .~ Map.fromList
                  [ ("type", "datetime-local")
                  , ("step", "1") -- 1 second step
                  ]
              pure $ (\x -> "(time \"" <> x <> "Z\")") <$> value i
            TyPrim TyBool -> do
              d <- dropdown def (pure False) $ TaggedStatic $ Map.fromList
                [(True, text "true"), (False, text "false")]
              pure $ T.toLower . tshow . runIdentity <$> value d
            TyPrim TyString -> do
              ti <- input def $ textInput (def & textInputConfig_placeholder .~ pure (_aName arg))
              pure $ tshow <$> value ti -- TODO better escaping
            TyPrim TyKeySet -> do
              d <- dropdown (def & dropdownConfig_placeholder .~ "Select a keyset") Nothing $ TaggedDynamic $ ffor (_jsonData_keysets $ _ide_jsonData ideL) $
                Map.mapWithKey (\k _ -> text k)
              pure $ maybe "" (\x -> "(read-keyset \"" <> x <> "\")") <$> value d
            _ -> fmap value . input def $
              textInput (def & textInputConfig_placeholder .~ pure (_aName arg))
        let buttonConfig = def
              & buttonConfig_type .~ SubmitButton
              & buttonConfig_emphasis .~ Static (Just Primary)
        submit <- button buttonConfig $ text "Call function"
        let args = tag (current $ sequence inputs) submit
            callFun = ffor args $ \as -> mconcat ["(", moduleName, ".", name, " ", T.unwords as, ")"]
        -- for debugging: widgetHold blank $ ffor callFun $ label def . text
        let ed = ideL ^. ide_jsonData . jsonData_data
        deployedResult <- backendRequest (ideL ^. ide_wallet) $
          ffor (attach (current ed) callFun) $ \(cEd, c) -> BackendRequest
            { _backendRequest_code = c
            , _backendRequest_data = either mempty id cEd
            , _backendRequest_backend = backendUri
            }
        widgetHold_ blank $ ffor deployedResult $ \(_uri, x) -> case x of
          Left err -> message (def & messageConfig_type .~ Static (Just (MessageType Negative))) $ do
            text $ prettyPrintBackendError err
          Right v -> message def $ text $ tshow v

codeWidget
  :: MonadWidget t m
  => Text -> Event t Text
  -> m (Event t Text)
codeWidget iv sv = do
    let ac = def { _aceConfigMode = Just "ace/mode/pact"
                 , _aceConfigElemAttrs = "class" =: "ace-code ace-widget"
                 }
    ace <- resizableAceWidget mempty ac (AceDynConfig $ Just AceTheme_SolarizedDark) never iv sv
    return $ _extendedACE_onUserChange ace


------------------------------------------------------------------------------
moduleExplorer
  :: forall t m. MonadWidget t m
  => Ide t
  -> m (IdeCfg t)
moduleExplorer ideL = mdo
    demuxSel <- fmap demux $ holdDyn (Left "") $ leftmost [searchSelected, exampleSelected]

    header def $ text "Example Contracts"
    exampleClick <- divClass "ui inverted selection list" $ for demos $ \c -> do
      let isSel = demuxed demuxSel $ Left $ _exampleContract_name c
      selectableItem (_exampleContract_name c) isSel $ do
        text $ _exampleContract_name c
        (c <$) <$> loadButton isSel
    let exampleSelected = fmap Left . leftmost . fmap fst $ Map.elems exampleClick
        exampleLoaded = fmap Left . leftmost . fmap snd $ Map.elems exampleClick

    header def $ text "Deployed Contracts"

    (search, backend) <- divClass "ui form" $ divClass "ui two fields" $ do
      searchI <- field def $ input (def & inputConfig_icon .~ Static (Just RightIcon)) $ do
        ie <- inputElement $ def & initialAttributes .~ ("type" =: "text" <> "placeholder" =: "Search modules")
        icon "black search" def
        pure ie

      let mkMap = Map.fromList . map (\k@(BackendName n, _) -> (Just k, text n)) . Map.toList
          dropdownConf = def
            & dropdownConfig_placeholder .~ "Backend"
            & dropdownConfig_fluid .~ pure True
      d <- field def $ input def $ dropdown dropdownConf (Identity Nothing) $ TaggedDynamic $
        Map.insert Nothing (text "All backends") . maybe mempty mkMap <$> ideL ^. ide_backend . backend_backends
      pure (value searchI, value d)

    let
      deployedContracts = Map.mergeWithKey (\_ a b -> Just (a, b)) mempty mempty
          <$> ideL ^. ide_backend . backend_modules
          <*> (fromMaybe mempty <$> ideL ^. ide_backend . backend_backends)
      searchFn needle (Identity mModule)
        = concat . fmapMaybe (filtering needle) . Map.toList
        . maybe id (\(k', _) -> Map.filterWithKey $ \k _ -> k == k') mModule
      filtering needle (backendName, (m, backendUri)) =
        let f contractName =
              if T.isInfixOf (T.toCaseFold needle) (T.toCaseFold contractName)
              then Just (DeployedContract contractName backendName backendUri, ())
              else Nothing
        in case fmapMaybe f $ fromMaybe [] m of
          [] -> Nothing
          xs -> Just xs
      filteredCsRaw = searchFn <$> search <*> backend <*> deployedContracts
      paginate p =
        Map.fromList . take itemsPerPage . drop (itemsPerPage * pred p) . L.sort
    filteredCs <- holdUniqDyn filteredCsRaw
    let
      paginated = paginate <$> currentPage <*> filteredCs

    (searchSelected, searchLoaded) <- divClass "ui inverted selection list" $ do
      searchClick <- listWithKey paginated $ \c _ -> do
        let isSel = demuxed demuxSel $ Right c
        selectableItem c isSel $ do
          label (def & labelConfig_horizontal .~ Static True) $ do
            text $ unBackendName $ _deployedContract_backendName c
          text $ _deployedContract_name c
          (c <$) <$> loadButton isSel
      let searchSelected1 = switch . current $ fmap Right . leftmost . fmap fst . Map.elems <$> searchClick
          searchLoaded1 = switch . current $ fmap Right . leftmost . fmap snd . Map.elems <$> searchClick
      pure (searchSelected1, searchLoaded1)

    let itemsPerPage = 5 :: Int
        numberOfItems = length <$> filteredCs
        calcTotal a = ceiling $ (fromIntegral a :: Double)  / fromIntegral itemsPerPage
        totalPages = calcTotal <$> numberOfItems
    rec
      currentPage <- holdDyn 1 $ leftmost
        [ updatePage
        , 1 <$ updated numberOfItems
        ]
      updatePage <- paginationWidget currentPage totalPages

    pure $ mempty
      { _ideCfg_selContract = leftmost [searchLoaded, exampleLoaded]
      }
  where
    selectableItem :: k -> Dynamic t Bool -> m a -> m (Event t k, a)
    selectableItem k s m = do
      let mkAttrs a = Map.fromList
            [ ("style", "position:relative")
            , ("class", "item" <> (if a then " active" else ""))
            ]
      (e, a) <- elDynAttr' "a" (mkAttrs <$> s) m
      pure (k <$ domEvent Click e, a)
    loadButton s = switchHold never <=< dyn $ ffor s $ \case
      False -> pure never
      True -> let buttonStyle = "position: absolute; right: 0; top: 0; height: 100%; margin: 0"
                in button (def & classes .~ "primary" & style .~ buttonStyle) $ text "Load"

controlBar :: forall t m. MonadWidget t m => Ide t -> m (IdeCfg t)
controlBar ideL = do
<<<<<<< HEAD
    elAttr "header" ("id" =: "header") $ do
      divClass "flexbox even" $ do
        ideCfg <- controlBarLeft ideL
        controlBarRight
        return ideCfg

controlBarLeft :: MonadWidget t m => Ide t -> m (IdeCfg t)
controlBarLeft ideL = do
    divClass "flex" $ do
      el "h1" $ do
        imgWithAlt (static @"img/pact-logo.svg") "PACT" blank
        ver <- getPactVersion
        elClass "span" "version" $ text $ "v" <> ver
      elAttr "div" ("id" =: "header-project-loader") $ do
        onLoad <- uiButtonSimple "Load into REPL"

        --onDeployClick <- uiButtonSimple "Deploy"
        -- TODO Re-enable this later
        (confirmationCfg, onDeploy) <- uiDeployConfirmation ideL never --onDeployClick

        let
          reqConfirmation = Modal_DeployConfirmation <$ onDeployClick
          lcfg = mempty
            & ideCfg_load .~ onLoad
            & ideCfg_deploy .~ onDeploy
            & ideCfg_reqModal .~ reqConfirmation
        pure $ confirmationCfg <> lcfg

getPactVersion :: MonadWidget t m => m Text
getPactVersion = do
    is <- liftIO $ initReplState StringEval
    Right (TLiteral (LString ver) _) <- liftIO $ evalStateT (evalRepl' "(pact-version)") is
    return ver

controlBarRight :: MonadWidget t m => m ()
controlBarRight = do
    elAttr "div" ("class" =: "flex right" <> "id" =: "header-links") $ do
      elAttr "a" ( "href" =: "http://pact-language.readthedocs.io"
                <> "class" =: "documents" <> "target" =: "_blank"
                 ) $ do
        imgWithAlt (static @"img/document.svg") "Documents" blank
        text "Docs"
      elAttr "a" ( "href" =: "http://kadena.io"
                <> "class" =: "documents" <> "target" =: "_blank") $
        imgWithAlt (static @"img/gray-kadena-logo.svg") "Kadena" blank
