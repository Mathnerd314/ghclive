{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverlappingInstances  #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE QuasiQuotes           #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TypeFamilies          #-}
module Main where
import           Control.Monad.Trans
import qualified Data.ByteString              as BS
import           Data.Maybe                   (fromMaybe)
import           Data.Monoid
import qualified Data.Text.Lazy               as T
import           Language.Haskell.Interpreter hiding (get)
import           Network.Curl.Download
import           Network.Wai.Handler.Warp     (Settings(..), defaultSettings, runSettings)
import qualified Text.Blaze.Html5             as H
import           Text.Blaze.Html5.Attributes  (class_, href, rel, src, type_)
import           Yesod
import           Yesod.Static

import           Control.Concurrent
import           Control.Concurrent.MVar
import           Control.Monad                (forever, liftM, void)
import           Control.Monad                  (forM_, forever, liftM, mzero)
import           Control.Monad.Error.Class
import           Data.Aeson                   ((.=))
import qualified Data.Aeson                   as A
import           Data.Char                    (isUpper)
import qualified Data.Text                    as ST
import           Data.Typeable
import           Diagrams.Backend.SVG
import           Diagrams.Prelude
import           Network.Web.GHCLive.Display
import           Text.Blaze
import           Text.Blaze.Renderer.Text     (renderMarkup)

import           Data.Aeson                     ((.:))
import qualified Data.Aeson                     as J
import qualified Data.Aeson.Types               as J
import qualified Data.HashMap.Strict            as HM
import           Data.Map                       (Map)
import qualified Data.Map                       as M
import           Data.Maybe                     (isJust)
import           Data.Text                      (Text)
import           Data.Time.Clock                (UTCTime, getCurrentTime)
import           Data.Time.Clock.POSIX          (utcTimeToPOSIXSeconds)
import qualified Data.Vector                    as V
import           Network.Wai
import qualified Network.Wai.Handler.WebSockets as WS
import qualified Network.WebSockets             as WS


import qualified SeqMap                         as SM


cachedir = "cache/"

type Hint = Run (InterpreterT IO)
data Run m = Run { vRequest :: MVar (m ()) }

data GHCLive = GHCLive
                { ref       :: MVar [(H.Html,H.Html)]
                , hint      :: Hint
                , editor    :: Editor
                , getStatic :: Static
                }

data Editor = Editor
              { doc       :: MVar (Document, Map ClientId Client)
              , unique    :: MVar ClientId
              }

data Operation = InsertAfter AtomId AtomId Char
               | Remove AtomId
    deriving (Show, Eq, Ord)

data OpBlock = OpBlock [Operation] deriving (Show, Eq, Ord)

-- inefficiently, [(AtomId,TextAtom)]
type Document = SM.SeqMap AtomId TextAtom

-- Char, and whether this Char has been removed
data TextAtom = TextAtom
    { taCh      :: Char
    , taRemoved :: Maybe Timestamp
    }

emptyDoc = SM.singleton (AtomId (Timestamp 0) (ClientId 0)) (TextAtom ' ' (Just (Timestamp 0)))

newtype Timestamp = Timestamp { unTimestamp :: Integer }
    deriving (Eq, Ord, Show, J.ToJSON, J.FromJSON)

newtype ClientId  = ClientId  { unClientId  :: Integer }
    deriving (Eq, Ord, Show, Enum, J.ToJSON, J.FromJSON)



data Client = Client
              { clientConnected :: Timestamp       -- timestamp when client connected
              , clientId        :: ClientId        -- unique id
              , clientChan      :: Chan J.Value    -- post outgoing messages to this chan
              }


mkTa :: Char -> TextAtom
mkTa ch = TextAtom ch Nothing

-- a Client never makes two IDs with the same timestamp
data AtomId    = AtomId
                  { aiTime :: Timestamp
                  , aiClient :: ClientId
                  } deriving (Show, Ord, Eq)

instance J.ToJSON AtomId where
   toJSON (AtomId (Timestamp t) (ClientId c)) = J.toJSON [t,c]

-- atoms encoded in json as [time,clientid]
instance J.FromJSON AtomId where
   parseJSON (J.Array v) | V.length v == 2 = AtomId <$> J.parseJSON (v V.! 0) <*> J.parseJSON (v V.! 1)
   parseJSON _ = mzero

staticSite = static "static"
$(staticFiles "static")

mkYesod "GHCLive" [parseRoutes|
/       RootR   GET
/output OutputR GET
/eval   EvalR   GET
/load   LoadR   POST
/static StaticR Static getStatic
/edit   EditR   GET
|]

instance Yesod GHCLive

main :: IO ()
main = do
  -- hint setup
  r  <- newMVar defaultOutput
  h  <- newHint
  st <- staticSite
  -- LOTR shared editor setup
  d  <- newMVar (emptyDoc, M.empty)
  u  <- newMVar (ClientId 0)
  let editor = (Editor d u)
  let master = GHCLive r h editor st
      s      = defaultSettings
               { settingsPort = 3000
               , settingsIntercept = WS.intercept (sockets editor) -- XXX expecting an Editor?
               }
  runSettings defaultSettings =<< (toWaiApp master :: IO Yesod.Application)


getOutputR :: Handler RepHtml
getOutputR = do
  y <- getYesod
  h <- liftIO $ readMVar (ref y)
  defaultLayout $ do
    addScript (StaticR jquery_js)
    addScriptRemote "http://localhost:9090/bdo"
    setTitle "ghclive output"
    [whamlet|
      <p>ghclive output
      $forall chunk <- h
        <div class=hint-prompt>hint>
        <div class=hint-expr>#{fst chunk}
        <p>
          <div class=hint-res>#{snd chunk}
    |]

getEvalR :: Handler RepJson
getEvalR = do
  y <- getYesod
  e <- fromMaybe "" <$> lookupGetParam "expr"
  t <- liftIO . performHint (hint y) $ interpretHint (ST.unpack e)
  case t of
    Left error -> do
             liftIO $ modifyMVar_ (ref y) $ \x -> return (x ++ [(H.toMarkup e,H.toMarkup $ cleanShow error)]) -- (happend e (H.toMarkup $ cleanShow error))
             jsonToRepJson . display $ cleanShow error
    Right displayres -> do
             liftIO $ modifyMVar_ (ref y) $ \x -> return (x ++ [(H.toMarkup e,displayres)]) -- (happend e displayres)
             jsonToRepJson $ display displayres

postLoadR :: Handler RepJson
postLoadR = do
  y <- getYesod
  f <- ST.unpack . fromMaybe "" <$> lookupPostParam "editor"
  t <- liftIO . performHint (hint y) $ moduleHint f
  case t of
    Left error -> do
             jsonToRepJson $ cleanShow error
    Right displayres -> do
             jsonToRepJson displayres

interpretHint :: (Typeable a, MonadInterpreter m) => String -> m a
interpretHint expr = do
  interpret expr as

moduleHint :: MonadInterpreter m => String -> m [ModuleName]
moduleHint ms = do
  -- save the file
  fname <- liftIO $ cacheFile ms
  let allfiles = "Helper.hs" : [fname]
  loadModules $ map (cachedir ++) allfiles
  setTopLevelModules $ map (takeWhile (/= '.')) allfiles
  setImportsQ $ [("Prelude",Nothing),("Network.Web.GHCLive.Display",Nothing),("Text.Blaze",Nothing)] ++ [(fname,Nothing)]
  getLoadedModules
  -- json $ display $ "Loaded module " ++ fname

runHint :: MonadInterpreter m => String -> String -> m H.Html
runHint expr fileurl = do
  files <- liftIO $ do
    putStrLn $ "fileurl is " ++ show (lines fileurl)
    mapM cacheUrl (urls fileurl)
  let allfiles = "Helper.hs" : files
  loadModules $ map (cachedir ++) allfiles
  setTopLevelModules $ map (takeWhile (/= '.')) allfiles
  let imports = map (flip (,) Nothing) $ mods fileurl
  setImportsQ $ [("Prelude",Nothing),("Network.Web.GHCLive.Display",Nothing),("Text.Blaze",Nothing)] ++ imports
  interpret expr as

    -- eval :: String -> Interpret String
    -- eval "something" ~= interpret "(show something) (as :: String)"

{-----------------------------------------------------------------------------
    Interpreter abstraction
------------------------------------------------------------------------------}
newHint :: IO Hint
newHint = newRun $ void . runInterpreter

performHint :: Hint -> InterpreterT IO a -> IO (Either InterpreterError a)
performHint hint act = perform hint $ do
                         (Right `liftM` act) `catchError` (return . Left) -- can no longer do C-c !
{-
loadFile :: Hint -> FilePath -> IO ()
loadFile w filepath = perform w $ do

evaluate :: Hint -> String -> IO String
evaluate w expr = perform w $ do

-- stopInterpreter :: Hint -> IO ()
-}

-- | Thread responsible for "running" a monad that can do IO.
perform :: MonadIO m => Run m -> m a -> IO a
perform run act = do
    ref <- newEmptyMVar
    putMVar (vRequest run) $ do
        a <- act
        liftIO $ putMVar ref a
    takeMVar ref

newRun :: MonadIO m => (m () -> IO ()) -> IO (Run m)
newRun f = do
    vRequest <- newEmptyMVar
    forkIO . f . forever $ do
        act <- liftIO $ takeMVar vRequest
        act
    return $ Run { vRequest = vRequest }


cleanShow    :: InterpreterError -> String
cleanShow ie = case ie of
                 UnknownError e -> "UnknownError\n" ++ e
                 WontCompile es -> unlines $ map errMsg es
                 NotAllowed e -> "NotAllowed\n" ++ e
                 GhcException e -> "GhcException\n" ++ e


{--- output page goodies ---}
defaultOutput :: [(H.Html,H.Html)]
defaultOutput = mempty

filenameFromUrl = reverse . takeWhile (/= '/') . reverse

cacheUrl fileurl = do
  putStrLn ("cacheFile got " ++ fileurl)
  Right doc <- openURI fileurl
  BS.writeFile (cachedir ++ fname) doc -- is wrong if filename /= module name!
  return fname
      where fname = filenameFromUrl fileurl

cacheFile f = do
  writeFile (cachedir ++ fname ++ ".hs") f
  return fname
    where fname = filenameFromText f

-- this ugly hack WILL fail with PRAGMAs at the top of the file! fix it later!
filenameFromText f = head . take 1 . drop 1 . words . head . take 1 $ lines f

listmatch a b = and $ zipWith (==) a b

urls fbox = filter (listmatch "http://") $ lines fbox

mods fbox = filter (isUpper . head) $ lines fbox -- blows up with empty lines?

getRootR :: Handler RepHtml
getRootR = do
  defaultLayout $ do
    addScript (StaticR jquery_js)
    addScript (StaticR jquery_console_js)
    addScript (StaticR hintconsole_js)
    addStylesheetRemote "http://c-71-207-252-122.hsd1.al.comcast.net:8000/lib/cm/lib/codemirror.css"
    addStylesheet $ StaticR style_css
    addScriptRemote "http://localhost:9090/bdo"
    addScriptRemote "http://c-71-207-252-122.hsd1.al.comcast.net:8000/lib/cm/lib/codemirror.js"
    addScriptRemote "http://c-71-207-252-122.hsd1.al.comcast.net:8000/lib/cm/mode/haskell/haskell.js"
    addScriptRemote "http://c-71-207-252-122.hsd1.al.comcast.net:8000/channel/bcsocket.js"
    addScriptRemote "http://c-71-207-252-122.hsd1.al.comcast.net:8000/share/share.uncompressed.js"
    addScriptRemote "http://c-71-207-252-122.hsd1.al.comcast.net:8000/share/cm.js"
    toWidget [julius|
    var doc = null, editor = null;

function setDoc(docName) {
  document.title = docName;
  sharejs.open(docName, 'text', 'http://c-71-207-252-122.hsd1.al.comcast.net:8000/channel', function(error, newDoc) {
      if (doc !== null) {
          doc.close();
          doc.detach_ace();
      }
      doc = newDoc;
      if (error) {
          console.error(error);
          return;
      }
      doc.attach_cm(editor);
  });
};
window.onload = function() {
  var ed = document.getElementById('editor');
  editor = CodeMirror.fromTextArea(document.getElementById('editor'), {
    mode: "haskell",
    tabSize: 2,
    lineNumbers:true,
    indentUnit: 4,
    matchBrackets: true
  });
  setDoc('cm');  // Hooking ShareJS and CodeMirror for the first time.
  var namefield = document.getElementById('namefield');
  function fn() {
      var docName = namefield.value;
      if (docName) setDoc(docName);
  }
  if (namefield.addEventListener) {
      namefield.addEventListener('input', fn, false);
  } else {
      namefield.attachEvent('oninput', fn);
  }
};
      $("#testclick").click(function() {
      alert("Handler for #load.click() called");
      });

      $("#load").click(function() {
         $("#editor").val(editor.getValue());
         var serData = $("#source").serialize();
         // alert(serData);
         $.post('/load', serData, function (data) {
           alert(data);
         });
         return false;
      });
      |]
    setTitle "ghclive output"
    [whamlet|
      <form action=/hint method=get>
        <input type=text id=fileurl name=fileurl> File to load
      <div id=header>
        <div id="htext">
          <b>Editing
            <input type=text value=cm id=namefield>
      <form id=source>
        <textarea id=editor class=editor name=editor>
        <input id=load type=button value=Load Module>
      <p>ghclive output
    |]

{-- shared editor --}
getEditR :: Handler RepHtml
getEditR = defaultLayout $ do
             -- addScriptRemote "https://ajax.googleapis.com/ajax/libs/jquery/1.7.2/jquery.min.js"
             addScript     (StaticR jquery_js)
             addScript     (StaticR codemirror_lib_codemirror_js)
             addScript     (StaticR codemirror_mode_haskell_haskell_js)
             addScript     (StaticR es6_shim_js)
             addScript     (StaticR document_js)
             addStylesheet (StaticR codemirror_lib_codemirror_css)
             toWidget [lucius|
                         #editor {
                           width: 800px;
                           height: 500px;
                         }
                      |]
             toWidget [julius|
                        function wsLocation() {
                          return window.location.href.replace(/^([a-z]+)\:/i, "ws:");
                        }

                        var ignoreChange = false;
                        function handleChange(editor, change) {
                           if(ignoreChange) { return; }
                           var msgs = doc.replace(change.from, change.to, change.text);
                           if(msgs.length > 0) {
                             sock.send(JSON.stringify({ actions: msgs }));
                           }
                        }

                        function refreshEditor() {
                          ignoreChange = true;
                          // fixme: try to preserve cursor position and selection better if other users insert lines etc
                          var sel = cm.somethingSelected();
                          var selStart;
                          var selEnd;
                          var cursor = cm.getCursor();
                          if(sel) {
                            selStart = cm.getCursor(start);
                            selEnd   = cm.getCursor(end);
                          }
                          cm.setValue(doc.currentVersion());
                          cm.setCursor(cursor);
                          if(sel) {
                            cm.setSelection(selStart,selEnd);
                          }
                          ignoreChange = false;
                        }

                        doc = new Document();

                        cm = CodeMirror.fromTextArea($('#editor')[0],
                           { mode:         'text/x-haskell'
                           , lineWrapping: true
                           , lineNumbers:  true
                           , fixedGutter:  true
                           , onChange:     handleChange
                           }
                        );
                        sock = new WebSocket(wsLocation());
                        sock.onmessage = function(evt) {
                          evtJson(evt,function(msg) {
                            if(msg.time) {
                              updateTimestamp(msg.time);
                            }
                            var refresh = false;
                            var r;
                            if(msg.actions) {
                              for(var i=0;i<msg.actions.length;i++) {
                                var a = msg.actions[i];
                                if(a.action === "doc") {
                                  doc.setDocument(a.doc);
                                  refresh = true;
                                } else if(a.action == "clientid") {
                                  setClientId(a.clientId);
                                } else if(a.action === "insert") {
                                  r = doc.applyOp(a);
                                  if(r) { refresh = true; }
                                } else if(a.action === "remove") {
                                  r = doc.applyOp(a);
                                  if(r) { refresh = true; }
                                }
                              }
                            }
                            if(refresh) {
                              refreshEditor();
                            }
                          });
                        }
                      |]
             [whamlet|
               <h1>editor
               <textarea #editor></textarea>
             |]






insertAtom :: AtomId -> AtomId -> Char -> Document -> Document
insertAtom after aid ch d = go xs
    where
      xs = drop 1 $ SM.toListFrom after d
      go []     = d SM.|> (aid, mkTa ch)
      go ((y,_):ys) | aid < y   = go xs
                    | otherwise = SM.insertBefore y (aid, mkTa ch) d

removeAtom :: AtomId -> Timestamp -> Document -> Document
removeAtom a time = SM.adjust (\(TextAtom ch _) -> TextAtom ch (Just time)) a

-- timestamp in milliseconds
getTimestamp :: MonadIO m => m Timestamp
getTimestamp = liftIO $ liftM (Timestamp . round . (*1000) . utcTimeToPOSIXSeconds) getCurrentTime

{-
collectGarbage :: Integer -> Document -> Document
collectGarbage time d = SM.removeAll ks d
    where
      ks = filter ((< time) . aiTime) (SM.keys d)
-}

t :: Text -> Text
t = id

mkClientId :: MonadIO m => Editor -> m ClientId
mkClientId e = liftIO (modifyMVar (unique e) $ \u -> let u' = succ u in return (u',u'))

pushToClients :: MonadIO m => Map ClientId Client -> J.Value -> m ()
pushToClients cs msg = do
  forM_ (M.elems cs) $ \c -> liftIO (writeChan (clientChan c) msg)

applyOps :: MonadIO m => Editor -> [Operation] -> m ()
applyOps e ops = do
  mapM_ (applyOp e) ops
  (_, clients) <- liftIO $ readMVar (doc e)
  pushToClients clients $ J.toJSON (OpBlock ops)

applyOp :: MonadIO m => Editor -> Operation -> m ()
applyOp e (InsertAfter a0 ai ch) = liftIO $ modifyMVar_ (doc e) $ \(d,clients) -> do
                                       let d' = insertAtom a0 ai ch d
                                       return (d',clients)
applyOp e (Remove      a) = liftIO $ modifyMVar_ (doc e) $ \(d,clients) -> do
                                       time <- getTimestamp
                                       let d' = removeAtom a time d
                                       return (d', clients)


instance J.FromJSON OpBlock where
  parseJSON (J.Object o) = OpBlock <$> o .: "actions"
  parseJSON _            = mzero

instance J.ToJSON OpBlock where
  toJSON (OpBlock ops) = J.object [ "actions" .= ops ]

instance J.FromJSON Operation where
    parseJSON (J.Object o) = do
      a <- o .: "action"
      case () of
        () | a == t"insert" -> InsertAfter <$> o .: "after" <*> o .: "id" <*> o .: "ch"
        () | a == t"remove" -> Remove <$> o .: "atom"
        () | otherwise      -> mzero
    parseJSON _ = mzero

instance J.ToJSON Operation where
  toJSON (InsertAfter after aid ch) = J.object [ "action" .= t"insert", "after" .= after, "id" .= aid, "ch" .= ch ]
  toJSON (Remove aid)               = J.object [ "action" .= t"remove", "id" .= aid]

---


receiveJson :: J.FromJSON a => WS.WebSockets WS.Hybi10 a
receiveJson = do
  bs <- WS.receiveData
  case J.decode' bs of
    Nothing -> sendJson (jsonError "invalid message") >> receiveJson
    Just a  -> return a

sendJson :: J.ToJSON a => a -> WS.WebSockets WS.Hybi10 ()
sendJson j = do
    msg <- mkJsonMsg (J.toJSON j)
    WS.sendBinaryData (J.encode msg)

sendSinkJson :: (MonadIO m, J.ToJSON a) => WS.Sink WS.Hybi10 -> a -> m ()
sendSinkJson sink j = do
  msg <- mkJsonMsg (J.toJSON j)
  liftIO $ WS.sendSink sink $ WS.binaryData (J.encode msg)

-- if we send an object, and it does not have a time field, inject it
mkJsonMsg :: MonadIO m => Value -> m J.Value
mkJsonMsg (J.Object o) | not (HM.member "time" o) = do
  t <- getTimestamp
  return $ J.Object (HM.insert "time" (J.toJSON t) o)
mkJsonMsg x = return x

jsonError :: String -> J.Value
jsonError msg = J.object [ "error" .= msg ]

sockets :: Editor -> WS.Request -> WS.WebSockets WS.Hybi10 ()
sockets y req
  | WS.requestPath req == "/edit"  = accept editSocket
  | otherwise                      = WS.rejectRequest req "Not found"
  where
    accept a = WS.acceptRequest req >> a y

editSocket :: Editor -> WS.WebSockets WS.Hybi10 ()
editSocket e = do
  client <- mkClientId e
  sendInit e client
  sink <- WS.getSink
  ch <- liftIO newChan
  t <- liftIO getTimestamp
  liftIO $ addClient e (Client t client ch)
  tid <- liftIO . forkIO . forever $ do
    acts <- readChan ch
    sendSinkJson sink acts
  forever $ do
    (OpBlock acts) <- receiveJson
    liftIO $ applyOps e acts
    liftIO $ mapM print acts
    return ()
  liftIO $ removeClient e client
  return ()

addClient :: Editor -> Client -> IO ()
addClient e c = modifyMVar_ (doc e) $ \(d, m) -> return (d, M.insert (clientId c) c m)

removeClient :: Editor -> ClientId -> IO ()
removeClient e cid = modifyMVar_ (doc e) $ \(d, m) -> return (d, M.delete cid m)

-- encode the whole document
currentVersion :: Document -> Value
currentVersion d =
    let xs = SM.toList d
        encodeAtom (a,v) = J.toJSON [ J.toJSON (aiTime a)
                                    , J.toJSON (aiClient a)
                                    , J.toJSON (taCh v)
                                    , J.toJSON (isJust $ taRemoved v)
                                    ]
    in  J.toJSON $ map encodeAtom xs

sendInit :: Editor -> ClientId -> WS.WebSockets WS.Hybi10 ()
sendInit e c = do
  d <- liftIO (readMVar $ doc e)
  sendJson $ actions [ J.object [ "action" .= t"clientid", "clientId" .= c]
                     , J.object [ "action" .= t"doc", "doc" .= currentVersion (fst d) ]
                     ]

actions :: [J.Value] -> J.Value
actions as = J.object ["actions" .= as ]

