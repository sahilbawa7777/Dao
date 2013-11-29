-- "src/Dao/Simple.hs"  a simplified version of the Dao runtime.
-- 
-- Copyright (C) 2008-2013  Ramin Honary.
-- This file is part of the Dao System.
--
-- The Dao System is free software: you can redistribute it and/or
-- modify it under the terms of the GNU General Public License as
-- published by the Free Software Foundation, either version 3 of the
-- License, or (at your option) any later version.
-- 
-- The Dao System is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
-- GNU General Public License for more details.
-- 
-- You should have received a copy of the GNU General Public License
-- along with this program (see the file called "LICENSE"). If not, see
-- <http://www.gnu.org/licenses/agpl.html>.

{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE RankNTypes #-}

-- | A simplified version of the Dao runtime.
module Dao.Simple where

import           Dao.Predicate
import qualified Dao.Tree                  as T

import           Data.Char
import           Data.Bits
import           Data.List (intercalate, stripPrefix)
import           Data.IORef
import           Data.Monoid
import           Data.Dynamic
import           Data.Array.IArray
import qualified Data.Map                  as M
import qualified Data.ByteString.Lazy.UTF8 as U
import qualified Data.ByteString.Lazy      as Z
import           Data.Functor.Identity

import           Control.Applicative
import           Control.Exception
import           Control.Monad
import           Control.Monad.Reader
import           Control.Monad.State
import           Control.Monad.Error hiding (Error)
import           Control.Monad.Trans
import           Control.Monad.IO.Class

import           System.IO
import           System.IO.Unsafe
import           System.Directory
import           System.Console.Readline

import Debug.Trace

----------------------------------------------------------------------------------------------------

daoStateGHCI :: IORef (DaoIOState ())
daoStateGHCI = unsafePerformIO (initialize >> newIORef (initDaoIOState ()))

withDaoIO :: DaoIO () a -> IO a
withDaoIO (DaoIO f) = do
  st <- readIORef daoStateGHCI
  (a, st) <- runStateT (runPTrans f) st
  a <- ioPValue a
  writeIORef daoStateGHCI st
  return a

-- | Get the current 'XData' object in the 'DataBuilder'.
showdb :: IO (Maybe XData)
showdb = withDaoIO $ getCurrentXData

-- | Evaluate a 'BuilderT' on the 'DataBuilder' state.
db :: BuilderT (DaoIO ()) t -> IO t
db = withDaoIO . updateDataBuilder

takedb :: Translatable t => IO (Maybe t)
takedb = withDaoIO getCurrentBuildData

lbl :: String -> IO Label
lbl = runPTransIO . parseLabel

addr :: String -> IO Address
addr = runPTransIO . parseAddress

run :: RunT (DaoIO ()) t -> IO t
run = withDaoIO . daoRunT

-- | Like 'eval' but in the IO monad and takes a @RW*@ data type which is easier to type in the GHCi
-- prompt. The @RW*@ data type is automaticaly converted to it's @X*@ counterpart data type using
-- 'io_x', which is why the 'RWX' instance is necessary.
evalio :: (RWX rwx eval, Evaluable eval) => rwx -> IO XData
evalio rwx = run $ eval $ io_x rwx

-- | Update the current runtime environment with a 'DeclareRuntime' function (e.g. 'basicIO'). This
-- loads built-in modules and system calls.
use :: DeclareRuntime (DaoIO ()) -> IO ()
use = withDaoIO . installModule

-- | Enter into a read-eval-print loop that executes 'RWCommand's.
execloop :: IO ()
execloop = fix $ \loop -> readline "evalio> " >>= \input -> case input of
  Nothing    -> return ()
  Just index -> do
    addHistory index
    case readsPrec 0 index of
      [(expr, "" )] -> evalio (expr::RWCommand) >>= print
      [(expr, rem)] -> hPutStrLn stderr ("(NO PARSE)\n  remainder "++show rem++")")
      []            -> hPutStrLn stderr "(NO PARSE)"
      ax            -> hPutStr stderr $ unwords $ "(AMBIGUOUS PARSE)" : map show ax
    loop

-- | Print the state of the virtual machine, the registers, stack, and so forth.
showvm :: IO ()
showvm = withDaoIO $ showVMState >>= liftIO . putStrLn

showmods :: IO ()
showmods = withDaoIO $ showLoadedMods >>= liftIO . putStrLn

showsyscalls :: IO ()
showsyscalls = withDaoIO $ showSystemCalls >>= liftIO . putStrLn

----------------------------------------------------------------------------------------------------

data DaoIOState st
  = DaoIOState
    { userState    :: st
    , ioRuntime    :: Runtime (DaoIO st)
    , fileHandles  :: M.Map Text Handle
    , dataBuilder  :: DataBuilder
    , editModuleCount   :: Integer
    , editModuleTable   :: M.Map Text XModule
    , editingModule     :: Maybe XModule
    , editingModulePath :: Maybe Text
    }

initDaoIOState :: st -> DaoIOState st
initDaoIOState ust =
  DaoIOState
  { userState   = ust
  , ioRuntime   = initRuntime
  , fileHandles = mempty
  , dataBuilder = initDataBuilder Nothing
  , editModuleCount   = 0
  , editModuleTable   = mempty
  , editingModule     = Nothing
  , editingModulePath = Nothing
  }

-- | This is a simple monadic interface for interacting with a mini-Dao runtime. You can evaluate
-- computations of this type using 'runDaoIO' in your main function. It instantiates
-- 'Control.Monad.IO.MonadIO' so you can read from and write to a command line interface, load
-- modules from files fork threads, and do anything else you need to do. This monad takes an
-- optional state parameter which could be @()@, or it could contain a data structure containing
-- stateful data, for example a command line history.
-- 
-- When you run a computation using 'runDaoIO', you should provide builtin modules using
-- 'installModule', and load modules from files using 'loadModule'. You can then construct a
-- read-eval-print loop which pre-processes input into a list of @['Text']@ objects, and broadcasts
-- that input to the various modules. You can select which modules you want using 'selectModule',
-- and you can evaluate a query in a module using 'evalQuery'.
newtype DaoIO st a = DaoIO{ daoStateT :: PTrans XThrow (StateT (DaoIOState st) IO) a }
  deriving (Functor, Applicative, Alternative, Monad, MonadPlus, MonadIO)
instance MonadState st (DaoIO st) where
  state f = DaoIO $ lift $ state $ \st -> let (a, ust) = f (userState st) in (a, st{userState=ust})
instance MonadError XThrow (DaoIO st) where
  throwError = DaoIO . throwError
  catchError (DaoIO try) catch = DaoIO $ catchError try (daoStateT . catch)
instance MonadPlusError XThrow (DaoIO st) where
  catchPValue (DaoIO f) = DaoIO (catchPValue f)
  assumePValue = DaoIO . assumePValue

runDaoIO :: DaoIO st a -> DaoIOState st -> IO (PValue XThrow a, DaoIOState st)
runDaoIO (DaoIO f) = runStateT (runPTrans f)

-- | Using the 'DeclareRuntime' monad, you can install built-in modules. Built-in modules are
-- constructed using the 'DeclareRuntime' interface, the 'installModule' function applies this
-- function to the runtime. For example, suppose you have a function called @xmlFile@ of type
-- 'DeclareRuntime' which constructs a built-in module, and this module provides an interface for
-- the mini-Dao language to work with XML files. If you want this module to be provided in your Dao
-- program, simply evaluate @'installModule' xmlFile@ in the main 'runDaoIO' function.
installModule :: DeclareRuntime (DaoIO st) -> DaoIO st ()
installModule (DeclareRuntime mod) = do
  st  <- DaoIO (lift get)
  run <- execStateT mod (ioRuntime st)
  DaoIO $ lift $ put (st{ioRuntime=run})

-- | Provide a list of 'Prelude.String's that will be used to select modules. Modules that could not
-- be selected will ouput an error message.
selectModule :: [String] -> DaoIO st [XModule]
selectModule qs = fmap concat $ forM qs $ \q -> do
  let err msg = liftIO (hPutStrLn stderr ("(selectModule) "++msg)) >> return []
  case readsPrec 0 q of
    [(addr, "")] -> do
      run <- DaoIO $ lift $ gets ioRuntime
      (pval, run) <- evalRun run $ lookupModule addr
      case pval of
        OK    mod -> return [mod]
        Backtrack -> err ("unknown error occurred when selecting "++show addr)
        PFail msg -> case msg of
          XError  msg -> err (show $ x_io msg)
          XReturn msg -> err (show $ x_io msg)
    _ -> err ("invalid address "++show q) >> return []

-- | Select all modules.
selectAllModules :: DaoIO st [XModule]
selectAllModules = DaoIO $ lift $ gets (map getXModule . T.elems . loadedModules . ioRuntime)

showLoadedMods :: DaoIO st String
showLoadedMods = DaoIO $ showTreeAddresses <$> lift (gets (loadedModules . ioRuntime))

-- | Evaluate a pre-processed string query. It is up to your implementation to do the preprocessing
-- of the string, for example, converting to all lower-case or splitting the string by whitespaces.
-- As a reminder, you can use the 'text' function to convert a 'Prelude.String' to a 'Text' data
-- type.
evalQuery :: [Text] -> [XModule] -> DaoIO st ()
evalQuery qs mods = forM_ mods $ \mod ->
  DaoIO (lift $ gets ioRuntime) >>= \run -> evalRun run (evalRulesInMod qs mod)

updateDataBuilder :: BuilderT (DaoIO st) t -> DaoIO st t
updateDataBuilder builder = do
  st <- DaoIO (lift get)
  (result, dbst) <- runBuilderT builder (dataBuilder st)
  result <- liftIO (ioPValue result)
  DaoIO (lift $ put $ st{dataBuilder=dbst}) >> return result

-- | Create a temporary copy of the current 'DataBuilder' state, and the collapse the copy to a
-- single 'XData' object, returning that object.
getCurrentXData :: DaoIO st (Maybe XData)
getCurrentXData = DaoIO (lift $ gets dataBuilder) >>= loop where
  loop dbst = do
    (p, dbst) <- runBuilderT popStep dbst
    xdat <- liftIO (ioPValue p)
    if null (builderPath dbst) then return xdat else loop dbst

-- | Try to construct a Haskell object of a 'Translatable' data type from current 'XData' value
-- returned by 'getCurrentXData'.
getCurrentBuildData :: Translatable t => DaoIO st (Maybe t)
getCurrentBuildData = getCurrentXData >>= \xdat -> case xdat of
  Nothing -> return Nothing
  xdat    -> runBuilderT fromXData (initDataBuilder xdat) >>= liftIO . ioPValue . fst

showDataBuilder :: DaoIO st String
showDataBuilder = DaoIO $ lift $ show <$> gets dataBuilder

showTreeAddresses :: T.Tree Label a -> String
showTreeAddresses = intercalate "\n" . map (show . labelsToAddr . fst) . T.assocs

runPTransIO :: PTrans XThrow IO a -> IO a
runPTransIO = runPTrans >=> ioPValue

ioPValue :: PValue XThrow a -> IO a
ioPValue p = case p of
  Backtrack -> fail "Backtrack"
  PFail err -> fail (show err)
  OK      a -> return a

daoRunT :: RunT (DaoIO st) t -> DaoIO st t
daoRunT f = DaoIO $ do
  st <- lift get
  (result, st) <- liftIO $ do
    (result, st) <- runDaoIO (evalRun (ioRuntime st) f) st
    (result, runtime) <- ioPValue result
    result <- ioPValue result
    return (result, st{ioRuntime=runtime})
  lift $ put st
  return result

showVMState :: DaoIO st String
showVMState = DaoIO $ do
  st <- lift (gets ioRuntime)
  let shows f = show (f st)
  let showm f = concatMap (\ (a, b) -> concat ["  ",show a," = ",show b,"\n"]) (M.assocs (f st))
  return $ intercalate "\n" $ filter (not . null) $ map unwords $
    [ ["currentBlock:"]
    , [ maybe [] (intercalate "\n" . map (\ (i, a) -> concat [show i,": ",show a]) . assocs)
          (currentBlock st) ]
    , ["evalCounter =", shows evalCounter]
    , ["lastResult  =", shows lastResult ]
    , ["registers:"]
    , [showm registers]
    , ["pcRegisters:"]
    , [showm pcRegisters]
    , ["evalStack = ", shows evalStack]
    ]

showSystemCalls :: DaoIO st String
showSystemCalls = DaoIO $ showTreeAddresses <$> lift (gets (systemCalls . ioRuntime))

setModuleName :: FilePath -> DaoIO st ()
setModuleName path = do
  when (null path) $ throwXData "Module.Error" [("problem", mkXStr "null file path")]
  tpath <- return (text path)
  DaoIO $ do
    st <- lift get
    if maybe False (const True) $ M.lookup tpath (editModuleTable st)
    then  throwXData "Module.Error" $
            [ ("problem", mkXStr "already loaded, cannot set name of current module")
            , ("path", mkXStr path)
            ]
    else do
      exists <- liftIO $ doesFileExist path
      if exists
      then throwXData "Parameter" [("problem", mkXStr "file already exists"), ("path", mkXStr path)]
      else lift $ put $ st{ editingModulePath = Just tpath }

saveModule :: DaoIO st ()
saveModule = DaoIO $ do
  st <- lift get
  case editingModule st of
    Nothing  -> return ()
    Just mod -> case editingModulePath st of
      Just path -> do
        liftIO $ writeFile (textChars path) (show mod) >>= evaluate
        lift $ put $ st{editModuleTable = M.insert path mod (editModuleTable st), editModuleCount=0}
      Nothing | editModuleCount st==0 -> return ()
      Nothing -> throwXData "Module.Error" $
        [("problem", mkXStr "Current module has no file path.")]

currentModuleIsSaved :: DaoIO st Bool
currentModuleIsSaved = DaoIO $ lift $ get >>= \st -> return $ editModuleCount st == 0 &&
  (maybe False (const True) $ pure (,) <*> editingModule st <*> editingModulePath st)

requireModuleBeSaved :: DaoIO st ()
requireModuleBeSaved = currentModuleIsSaved >>= flip unless unsavedException

-- | Load a module but do not switch to it.
loadModule :: FilePath -> DaoIO st ()
loadModule path = DaoIO $ do
  mod <- liftIO $ readFile path >>= readIO >>= evaluate . io_x >>= evaluate
  lift $ modify $ \st -> st{editModuleTable = M.insert (text path) mod (editModuleTable st)}

unsavedException :: DaoIO st ig
unsavedException = DaoIO (lift get) >>= \st -> throwXData "Module.Error" $ concat $
  [ [("problem", mkXStr "current module has unsaved changed")]
  , maybe [] (\p -> [("currentPath", mkXStr $ textChars p)]) $ editingModulePath st
  ]

-- | Unload the current module, do not place it back into the table of editable modules.
unloadCurrentModule :: DaoIO st ()
unloadCurrentModule = do
  requireModuleBeSaved
  DaoIO $ lift $ modify $ \st -> st{editingModule = Nothing, editingModulePath = Nothing}

unloadModule :: FilePath -> DaoIO st ()
unloadModule path = DaoIO $ lift $ modify $ \st ->
  st{editModuleTable = M.delete (text path) (editModuleTable st)}

switchToModule :: FilePath -> DaoIO st ()
switchToModule path = do
  requireModuleBeSaved
  DaoIO $ do
    path <- return (text path)
    tab  <- lift $ gets editModuleTable
    case M.lookup path tab of
      Nothing  -> fail ("no modules called "++show path++"have been loaded")
      Just mod -> lift $ modify $ \st ->
        st{ editingModule     = Just mod
          , editingModulePath = Just path
          , editModuleTable   = maybe (editModuleTable st)
              (\ (a,b) -> M.insert a b (editModuleTable st))
                (pure (,) <*> editingModulePath st <*> editingModule st)
          , editModuleCount   = 0
          }

-- | Place the current module into the runtime environment at the address given by the
-- 'Prelude.String' parameter so it can respond to queries. The module must be saved to disk. This
-- will unload the current module.
activateModule :: String -> DaoIO st ()
activateModule addr = do
  addr <- addrToLabels <$> parseAddress addr
  requireModuleBeSaved
  st <- DaoIO (lift get)
  let nomod = throwXData "Module.Error" [("problem", mkXStr "no module currently selected")]
  let rt = ioRuntime st
  mod <- maybe nomod return (editingModule st)
  case T.lookup addr (loadedModules rt) of
    Nothing -> do
      DaoIO $ lift $ modify $ \st ->
        st{ ioRuntime = rt{loadedModules = T.insert addr (PlainModule mod) (loadedModules rt)} }
      unloadCurrentModule
    Just _  -> throwXData "Module.Error" $
      [ ("problem", mkXStr "a module is already active under the given address")
      , ("address", XPTR $ labelsToAddr addr)
      ]

deactivateModule :: String -> DaoIO st ()
deactivateModule addr = do
  addr <- addrToLabels <$> parseAddress addr
  DaoIO $ lift $ modify $ \st ->
    let rt = ioRuntime st
    in  st{ ioRuntime =
              rt{ loadedModules = T.delete addr (loadedModules rt)
                , systemCalls = T.alter (T.alterBranch (const Nothing)) addr (systemCalls rt)
                }
          }

----------------------------------------------------------------------------------------------------

data ModBuilderState m
  = ModBuilderState
    { modBuilderRules    :: [XRule]
    , modBuilderBuiltins :: M.Map Label (RunT m XData)
    , modBuilderData     :: M.Map Label XData
    }

initModBuilderState :: ModBuilderState m
initModBuilderState =
  ModBuilderState
  { modBuilderRules    = []
  , modBuilderBuiltins = mempty
  , modBuilderData     = mempty
  }

-- | The monadic function used to declare a 'Module'. Pass a monadic computation of this type to the
-- 'newModule' function.
newtype ModBuilderM m a
  = ModBuilder{ runDeclMethods :: State (ModBuilderState m) a }
  deriving (Functor, Monad)
type ModBuilder m = ModBuilderM m ()

-- | Defines a method for a module with the given name.
newMethod :: String -> RunT m XData -> ModBuilder m
newMethod nm fn = case readsPrec 0 nm of
  [(nm, "")] -> ModBuilder $ modify $ \st ->
    st{modBuilderBuiltins = M.insert (read nm) fn (modBuilderBuiltins st)}
  _          -> fail ("could not define function, invalid name string: "++show nm)

-- | Declare a new rule for this module.
newRule :: XRule -> ModBuilder m
newRule rul = ModBuilder $ modify $ \st -> st{modBuilderRules = modBuilderRules st ++ [rul]}

-- | Define some static data for this module. All static data are stored in the 'xprivate' field of
-- the 'XModule' data type. This is also how you can declare built-in functions that are not system
-- calls but actual mini-Dao executable code that can be 'eval'uated at 'Runtime'.
newData :: String -> XData -> ModBuilder m
newData lbl dat = case readsPrec 0 lbl of
  [(lbl, "")] -> ModBuilder $ modify $ \st ->
    st{modBuilderData = M.insert lbl dat (modBuilderData st)}
  _ -> fail ("invalid label given while defining module: (newData "++show lbl++")")

-- | The monadic function used to declare a 'Runtime'. You can use this monad to build up a kind of
-- "default" module. When it comes time to run a mini-Dao program, this default module will be used
-- to initialize the runtime for the mini-Dao evaluator.
type DeclareRuntime m = DeclareRuntimeM m ()
newtype DeclareRuntimeM m a
  = DeclareRuntime { runDeclModule :: StateT (Runtime m) m a } deriving (Functor, Monad)
instance Monad m => MonadState (Runtime m) (DeclareRuntimeM m) where
  state f = DeclareRuntime (state f)
instance MonadTrans DeclareRuntimeM where { lift = DeclareRuntime . lift }

-- | Declare a built-in module for this runtime. The first paramater is the name of this module.
-- Here are the details about how this works:
-- 
-- Suppose you are declaring a module "myModule", and you declare a function @myFunc@ with
-- @'newMethod' "myFunc" (...)@. When 'newModule' is evaluated, a new system call will be added to
-- the 'systemCalls' table at the address @"myModule.myFunc"@. Then, a 'MODULE' is constructed,
-- and in this module a public variable declaration @"myFunc"@ is created which stores a 'FUNC'
-- object, and this 'FUNC' object is a system call to the @"myModule.myFunc"@ function.
newModule :: Monad m => String -> ModBuilder m -> Maybe (XEval -> RunT m XData) -> DeclareRuntime m
newModule name decls opfunc = DeclareRuntime $ case readsPrec 0 name of
  [(addr, "")] -> do
    bi <- gets loadedModules
    let modlbl   = addrToLabels addr
        modbst   = execState (runDeclMethods decls) initModBuilderState
        defs     = modBuilderBuiltins modbst
        syscalls = T.Branch (M.map T.Leaf defs)
        mod =
          XMODULE
          { ximports = []
          , xprivate = XDefines $ modBuilderData modbst
          , xpublic  = XDefines $ flip M.mapWithKey defs $ \func _ ->
              XFUNC $ XFunc [] $ XBlock $ mkXArray $
                [ XEVAL  (XSYS (labelsToAddr (modlbl++[func])) [])
                , XRETURN XRESULT
                ]
          , xrules   = modBuilderRules modbst
          }
    modify $ \st ->
      st{ loadedModules = T.insert modlbl (BuiltinModule mod opfunc) (loadedModules st)
        , systemCalls   = T.alter (T.union syscalls) modlbl (systemCalls st)
        }
  _ -> fail ("initializing built-in module, string cannot be used as module name: "++show name)

-- | Declare a system call in the runtime. The system call need not be part of any module, it can
-- simply be declared with a name like "print" and the system call will be accessible to the 'SYS'
-- instruction.
newSystemCall :: Monad m => String -> RunT m XData -> DeclareRuntime m
newSystemCall name func = DeclareRuntime $ modify $ \st ->
  st{ systemCalls = T.insert [Label $ text name] func (systemCalls st) }

printer :: MonadIO m => Handle -> RunT m XData
printer h = do
  let tostr o = case o of
        XNULL         -> "FALSE"
        XTRUE         -> "TRUE"
        XSTR (Text o) -> U.toString o
        XINT       o  -> show o
        XFLOAT     o  -> show o
        XLIST      o  -> show (maybe [] (map x_io . elems) o)
        XPTR       o  -> show o
        XDATA addr o  -> concat ["(DATA ", show addr, ' ':show (map (fmap x_io) $ M.assocs o)]
        XFUNC (XFunc args  o) -> concat ["(FUNC ", show args, ' ' : show (x_io o), ")"]
  str <- gets evalStack >>= return . concatMap tostr . reverse
  liftIO (hPutStrLn h str)
  return (mkXStr str)

-- | This is the default module which provides basic IO services to the mini-Dao runtime, like
-- print.
basicIO :: MonadIO m => DeclareRuntime m
basicIO = do
  newSystemCall "print" (printer stdout)
  newSystemCall "error" (printer stderr)

fileIO :: DeclareRuntime (DaoIO st)
fileIO = do
  let getPath = do
        str <- popEvalStack
        case str of
          XSTR path -> return (str, path)
          path      -> throwXData "FunctionParamater" $
            [ ("stackItem", path)
            , ("problem", mkXStr "expecting file path parameter")
            ]
      open func mode = do
        (str, path) <- getPath
        evalStackEmptyElse func []
        h <- liftIO (openFile (textChars path) mode)
        lift $ DaoIO $ lift $ modify (\st -> st{fileHandles = M.insert path h (fileHandles st)})
        return $ mkXData "File" [("path", XSTR path)]
      newOpenMethod func mode = newMethod func $ open func mode
      newHandleMethod func fn = newMethod func $ do
        xdat <- gets lastResult
        path <- mplus (tryXMember "path" xdat >>= asXSTR) $ throwXData "DataType" $
          [("object", xdat), ("problem", mkXStr "does not contain a file path")]
        h <- lift $ DaoIO $ lift $ gets fileHandles >>= return . M.lookup path
        case h of
          Nothing -> throwXData "file.NotOpen" [("path", XSTR path)]
          Just  h -> fn (path, h)
  newModule "File"
    (do newOpenMethod "openRead"      ReadMode
        newOpenMethod "openReadWrite" ReadWriteMode
        newOpenMethod "openAppend"    AppendMode
        newHandleMethod "close" $ \ (path, h) -> do
          evalStackEmptyElse "close" []
          liftIO (hClose h)
          lift $ DaoIO $ lift $ modify (\st -> st{fileHandles = M.delete path (fileHandles st)})
          return XTRUE
        newHandleMethod "write" $ \ (_, h) -> printer h
        newHandleMethod "read"  $ \ (_, h) -> do
          evalStackEmptyElse "read" []
          liftIO (hGetLine h) >>= setResult . mkXStr
        newHandleMethod "readAll" $ \ (_, h) -> do
          evalStackEmptyElse "readAll" []
          liftIO (hGetContents h) >>= setResult . mkXStr
    )
    Nothing

----------------------------------------------------------------------------------------------------

-- | A class of data types that can be isomorphically translated to and from an 'XData' data type.
class Translatable t where
  toXData   :: (Functor m, Monad m, Applicative m) => t -> BuilderT m ()
  fromXData :: (Functor m, Monad m, Applicative m) => BuilderT m t

newtype BuilderT m a = BuilderT { builderToPTrans :: PTrans XThrow (StateT DataBuilder m) a }
  deriving (Functor, Monad, MonadPlus)
instance (Functor m, Monad m) => Applicative (BuilderT m) where {pure=return; (<*>)=ap;}
instance (Functor m, Monad m) => Alternative (BuilderT m) where {empty=mzero; (<|>)=mplus;}
instance MonadTrans BuilderT where {lift = BuilderT . lift . lift}
instance Monad m => MonadError XThrow (BuilderT m) where
  throwError = BuilderT . throwError
  catchError (BuilderT try) catch = BuilderT (catchError try (builderToPTrans . catch))
instance Monad m => MonadPlusError XThrow (BuilderT m) where
  catchPValue (BuilderT f) = BuilderT (catchPValue f)
  assumePValue = BuilderT . assumePValue
instance Monad m => MonadState (Maybe XData) (BuilderT m) where
  get   = BuilderT $ lift $ gets (fmap fromBuildStep . builderItem)
  put o = BuilderT $ lift $ modify $ \st -> st{builderItem=fmap buildStep o}

-- | Run a 'BuilderT' monad.
runBuilderT :: BuilderT m t -> DataBuilder -> m (PValue XThrow t, DataBuilder)
runBuilderT (BuilderT fn) = runStateT (runPTrans fn)

data DataBuilder
  = DataBuilder
    { builderItem :: Maybe BuildStep
    , builderPath :: [BuildStep]
    }
instance Show DataBuilder where
  show db = concat $
    [ "DataBuilder:\n"
    , intercalate "\n" $ map (("  "++) . unwords) $ concat $
        [ [["builderItem =", show (builderItem db)], ["builderPath:"]]
        , map (return . intercalate "\n" . map ("  "++) . lines . show) (builderPath db)
        ]
    ]

-- | Create a new 'DataBuilder', optionally with an 'XData' object to analyze.
initDataBuilder :: Maybe XData -> DataBuilder
initDataBuilder init = DataBuilder{ builderItem = fmap buildStep init, builderPath = [] }

-- | Get the 'XData' object currently in the focus of a 'DataBuilder'.
dataBuilderItem :: DataBuilder -> Maybe XData
dataBuilderItem = fmap fromBuildStep . builderItem

data BuildStep
  = ConstStep XData
  | DataStep
    { buildDataAddress :: Address
    , buildDataDict    :: M.Map Label XData
    , buildDataField   :: Maybe Label
    }
  | ListStep
    { buildIndex      :: Int
    , buildListLength :: Int
    , buildListBefore :: [XData]
    , buildListAfter  :: [XData]
    }
instance Show BuildStep where
  show a = case a of
    ConstStep a       -> "CONST "++show a
    DataStep  a b c   -> 
      let pshow (a, b) = show a ++ " = " ++ show b
      in  concat $
            [ "DATA ", show a, maybe "" (\a -> "(on field: "++show a++")") c
            , concat $
                if M.size b < 2
                then  concat [["["], map pshow (M.assocs b), ["]"]]
                else  let each = map pshow (M.assocs b)
                      in ["[ ", head each, concatMap (\str -> ", "++str++"\n") each, "]"]
            ]
    ListStep  a b c d -> intercalate "\n" $ map concat $
      [ ["LIST (index=", show a, ", length=", show b, ")"]
      , ["  before = ", show c]
      , ["  after = ", show d]
      ]

buildStep :: XData -> BuildStep
buildStep o = case o of
  XLIST list ->
    ListStep
    { buildIndex      = 0
    , buildListLength = maybe 0 (uncurry subtract . bounds) list
    , buildListBefore = []
    , buildListAfter  = maybe [] elems list
    }
  XDATA addr dict -> DataStep{buildDataAddress=addr, buildDataDict=dict, buildDataField=Nothing}
  o -> ConstStep o

fromBuildStep :: BuildStep -> XData
fromBuildStep a = case a of
  ConstStep a       -> a
  DataStep  a b _   -> XDATA a b
  ListStep  _ _ a b -> mkXList $ reverse a ++ b

-- | Push the current path, set the current 'builderItem' to contain the given data. Use this to
-- force already-constructed data into the 'builderItem'. The previous 'builderItem' is pushed onto
-- the path stack, and unless it is a 'DataStep' or 'ListStep', it will be overwritten on the next
-- 'popStep' operation.
pushStep :: Monad m => XData -> BuilderT m ()
pushStep dat = BuilderT $ lift $ modify $ \st ->
  st{ builderItem = Just (buildStep dat)
    , builderPath = maybe [] (:[]) (builderItem st) ++ builderPath st
    }

-- | This is like a Unix shell @cd ..@ operation. After evaluating a @push*@ operation below (e.g.
-- 'pushXData' or 'pushXList') you can pop the current 'builderItem' and place it into the next
-- 'BuildStep' item in the 'builderPath', then make this popped-updated 'BuildStep' item the current
-- 'builderItem'. How the 'builderPath' item is updated depends on what kind of path item it is. The
-- item popped is returned.
popStep :: Monad m => BuilderT m (Maybe XData)
popStep = (BuilderT $ lift $ get) >>= \st -> case builderPath st of
  []         -> do
    BuilderT $ lift $ put $ st{builderItem=Nothing}
    return $ fmap fromBuildStep $ builderItem st
  step:stepx -> BuilderT $ lift $ do
    let item = builderItem st
    let xdat = fmap fromBuildStep item
    let putItem item = do
          put $ st{builderItem=item, builderPath=stepx}
          return xdat
    putItem $ case step of
      ConstStep a -> mplus item (Just step) -- overwrite const steps
      DataStep addr dict lbl -> case lbl of -- if lbl is nothing, treat as const and overwrite it
        Nothing  -> mplus item (Just step)  -- otherwise associate it with the label
        Just lbl -> Just $ DataStep addr (M.alter (const xdat) lbl dict) Nothing
      ListStep i len bef aft -> let inc i = maybe i (const (i+1)) xdat in Just $
        ListStep (inc i) (inc len) (maybe bef (:bef) xdat) aft

-- not for export
tryBuildStep :: Monad m => (BuildStep -> BuilderT m t) -> BuilderT m t
tryBuildStep update = (BuilderT $ lift $ gets builderItem) >>= maybe mzero update

-- | Update the current 'builderItem' if it is a 'ConstStep', otherwise backtrack.
tryXConst :: Monad m => (XData -> BuilderT m t) -> BuilderT m t
tryXConst update = tryBuildStep $ \s -> case s of {ConstStep a -> update a; _ -> mzero;}

-- | Update the current 'builderItem' if it is a 'DataStep', otherwise backtrack.
tryXData :: Monad m => (Address -> M.Map Label XData -> Maybe Label -> BuilderT m t) -> BuilderT m t
tryXData update = tryBuildStep $ \s -> case s of {DataStep a b c -> update a b c; _ -> mzero;}

-- | Update the current 'builderItem' if it is a 'ListStep', otherwise backtrack.
tryXList :: Monad m => (Int -> Int -> [XData] -> [XData] -> BuilderT m t) -> BuilderT m t
tryXList update = tryBuildStep $ \s -> case s of {ListStep a b c d -> update a b c d; _ -> mzero;}

-- | Push the 'builderPath' and create a new 'DataStep' as the current 'builderItem'. If the current
-- item is a 'ConstStep', or we have not stepped into a field with 'pushXField', the 'popStep'
-- operation will cause any data created after this 'pushXDataAddr' step to overwrite any element
-- that existed on the stack before it. Likewise an immediately consecutive call to this function
-- without an interveaning 'pushXField' operation will overwrite any data created by the current
-- call.
pushXDataAddr :: Monad m => String -> BuilderT m Address
pushXDataAddr addr = do
  addr <- parseAddress addr
  BuilderT $ lift $ modify $ \st ->
    st{ builderItem = Just $ DataStep addr mempty Nothing
      , builderPath = concat [maybe [] (:[]) (builderItem st), builderPath st]
      }
  return addr

-- | Evaluates a given 'BuilderT' but only if the current 'builderItem' is a 'DataStep' with an
-- address value matching the address given by the 'Prelude.String' parameter.
xdata :: Monad m => String -> BuilderT m a => BuilderT m a
xdata getAddr builder = tryXData $ \addr _ _ ->
  parseAddress getAddr >>= \getAddr -> guard (addr==getAddr) >> builder

-- | If the current 'builderItem' is an 'XDATA' constructor, step into a field of the 'XDATA' item
-- at the 'Label' provided by the 'Prelude.String' parameter. If the field does not exist, the field
-- will be created.
pushXField :: Monad m => String -> BuilderT m Label
pushXField newLbl = tryXData $ \addr dict lbl -> do
  newLbl <- parseLabel newLbl
  -- the above 'tryXData' ensures 'builderItem st' is a 'DataStep', so this stateful update can
  -- safely use 'buildDataFiled' without checking the constructor of 'builderItem st'.
  BuilderT $ lift $ modify $ \st ->
    st{ builderPath = DataStep addr dict lbl : builderPath st
      , builderItem = fmap buildStep $ M.lookup newLbl dict
      }
  return newLbl

-- | Evaluates a given 'BuilderT', but only if a given 'Label' (provided here as a 'Prelude.String'
-- parameter) can be stepped-into. This is the optional version, which means the function backtracks
-- rather than throwing an error if the field does not exist.
optXFieldWith :: Monad m => String -> BuilderT m a -> BuilderT m a
optXFieldWith lbl builder = do
  lbl <- parseLabel lbl
  tryXData $ \addr dict _ -> case M.lookup lbl dict of
    Nothing   -> mzero
    Just item -> do
      BuilderT $ lift $ modify $ \st ->
        st{ builderPath = DataStep addr dict (Just lbl) : builderPath st
          , builderItem = Just $ buildStep item
          }
      builder >>= \a -> popStep >> return a

-- | Like 'xfieldWith' but the 'BuilderT' used is the instantiation for the type @t@ of the
-- 'fromXData' function. This is the optional version, which means the function backtracks
-- rather than throwing an error if the field does not exist.
optXField :: (Monad m, Applicative m, Translatable t) => String -> BuilderT m t
optXField lbl = xfieldWith lbl fromXData

-- | This is the non-optional version of 'optXFieldWith'. If the field does not exist, an error is
-- thrown reporting which field that should have existed.
xfieldWith :: Monad m => String -> BuilderT m t -> BuilderT m t
xfieldWith lbl builder = mplus (optXFieldWith lbl builder) $
  tryXData $ \addr _ _ -> parseLabel lbl >>= \lbl -> throwXData "DataBuilder.Error" $
    [ ("problem", mkXStr "missing required field")
    , ("dataType", XPTR addr)
    , ("missingField", XPTR (labelsToAddr [lbl]))
    ]

-- | This is the non-optional version of 'optXField'. If the field does not exist, an error is
-- thrown reporting which field that should have existed.
xfield :: (Monad m, Applicative m, Translatable t) => String -> BuilderT m t
xfield lbl = xfieldWith lbl fromXData

-- | Combines the 'pushXDataAddr' and 'pushXField' steps into a single operation. Using this
-- function is the best way to construct arbitrary data.
pushXData :: Monad m => String -> [(String, BuilderT m ())] -> BuilderT m ()
pushXData addr newDict = do
  pushXDataAddr addr
  forM_ newDict (\ (lbl, builder) -> pushXField lbl >> builder >> popStep)

-- | Push the 'builderPath' and create a new 'ListStep' as the current 'builderItem'. If the current
-- item is a 'ConstStep', or we have not stepped into a field with 'pushXField', the 'popStep'
-- operation will cause any data created after this 'pushXList' operation to place the popped item
-- into the list after the cursor.
pushXList :: Monad m => BuilderT m ()
pushXList = BuilderT $ lift $ modify $ \st ->
  st{ builderItem = Just $ ListStep 0 0 [] []
    , builderPath = concat [maybe [] (:[]) (builderItem st), builderPath st]
    }

-- | Evaluate a 'BuilderT' only if the 'builderItem' is a 'ListStep'
xlist :: Monad m => BuilderT m a -> BuilderT m a
xlist builder = tryXList $ \ _ _ _ _ -> builder

-- | Step into the current list element, which is the element just before the cursor. If there are
-- no elements before the cursor, an element is created at index 0.
pushXElem :: Monad m => BuilderT m ()
pushXElem = tryXList $ \i len before after -> BuilderT $ lift $ modify $ \st -> case before of
  []       ->
    st{ builderItem = Nothing
      , builderPath = ListStep i len before after : builderPath st
      }
  b:before ->
    st{ builderItem = Just (buildStep b)
      , builderPath = ListStep (i-1) (len-1) before after : builderPath st
      }

-- | Evaluate a 'BuilderT' only if the cursor is positioned on an element.
xelemWith :: Monad m => BuilderT m a -> BuilderT m a
xelemWith builder = tryXList $ \i len before after -> guard (i<len) >> case after of
  []      -> mzero
  a:after -> do
    BuilderT $ lift $ modify $ \st ->
      st{ builderItem = Just $ buildStep a
        , builderPath = ListStep i (len-1) before after : builderPath st
        }
    builder >>= \a -> popStep >> return a

-- | Like 'xelem' but evaluates the 'BuilderT' used is the instantiation of the 'fromXData' function
-- for the 'Translatable' type @t@.
xelem :: (Monad m, Applicative m, Translatable t) => BuilderT m t
xelem = xelemWith fromXData

-- | Like 'xelemWith', evaluate a 'BuilderT' only if the cursor is positioned on an element. However
-- after evaluation of the 'BuilderT' completes, advance the listt cursor
xiterateWith :: Monad m => BuilderT m a -> BuilderT m a
xiterateWith builder = xelemWith builder >>= \a -> moveCursor 1 >> return a

-- | Like 'xiterateWith' but the 'BuilderT' used is the instantiation of 'fromXData' the function
-- for the 'Translatable' type @t@.
xiterate :: (Monad m, Applicative m, Translatable t) => BuilderT m t
xiterate = xiterateWith fromXData

-- | If the current 'builderItem' is a 'ListStep' and the list cursor is at the end of the list,
-- return 'Prelude.True'. Works well when used before evaluating 'xiterate'.
endOfXList :: Monad m => BuilderT m Bool
endOfXList = tryXList $ \i len _ _ -> return (i>=len)

-- | Assuming the current 'builderItem' is a 'ListStep', get the length of the current list.
lengthXList :: Monad m => BuilderT m Int
lengthXList = tryXList $ \ _ len _ _ -> return len

-- | Assuming the current 'builderItem' is a 'ListStep', get the current cursor position.
getCursor :: Monad m => BuilderT m Int
getCursor = tryXList $ \ i _ _ _ -> return i

-- | Assuming the current 'builderItem' is a 'ListStep', place a list of items before the current
-- cursor position.
putBefore :: Monad m => [XData] -> BuilderT m ()
putBefore tx = tryXList $ \i len before after -> BuilderT $ lift $ modify $ \st ->
  st{ builderItem = Just $ ListStep i (len + length tx) before (tx++after) }

-- | Assuming the current 'builderItem' is a 'ListStep', place a list of items before the current
-- cursor position.
putAfter :: Monad m => [XData] -> BuilderT m ()
putAfter tx = tryXList $ \i len before after ->
  let len' = length tx
  in  BuilderT $ lift $ modify $ \st ->
        st{ builderItem = Just $ ListStep (i+len') (len+len') (before++reverse tx) after }

indexError :: MonadError XThrow m => Int -> Int -> String -> Integer -> String -> m ig
indexError i len msg req opmsg = throwXData "DataBuilder.Error" $
  [ ("problem", mkXStr msg), ("cursorPosition", XINT i), ("listLength", XINT len)
  , ( opmsg
    , if curry inRange (fromIntegral (minBound::Int)) (fromIntegral (maxBound::Int)) req
      then XINT (fromIntegral req)
      else mkXStr (show req)
    )
  ]

-- | Assuming the current 'builderItem' is a 'ListStep', move forward or backward through the list. The
-- resulting index must be in bounds or this function evaluates to an error.
moveCursor :: Monad m => Integer -> BuilderT m ()
moveCursor delta = tryXList $ \i len before after -> do
  let checkBounds msg errorCondition = unless errorCondition $
        indexError i len ("moved cursor passed "++msg++" of list") delta "shiftValue"
  let newCursor = fromIntegral delta + i
  case delta of
    0               -> return ()
    delta | delta<0 -> do
      checkBounds "before" (fromIntegral i + delta >= 0)
      BuilderT $ lift $ modify $ \st ->
        let (took, remain) = splitAt (abs (fromIntegral delta)) before
        in  st{ builderItem = Just $ ListStep newCursor len remain (reverse took ++ after) }
    delta | delta>0 -> do
      checkBounds "after" (fromIntegral (len-i) > delta)
      BuilderT $ lift $ modify $ \st ->
        let (took, remain) = splitAt (fromIntegral delta) after
        in  st{ builderItem = Just $ ListStep newCursor len (before ++ reverse took) remain }

-- | Assuming the current 'builderItem' is a 'ListStep', move the cursor to the specific index. The
-- index must be in bounds or this function evaluates to an error.
cursorToIndex :: Monad m => Integer -> BuilderT m ()
cursorToIndex i' = join $ tryXList $ \i len before after ->
  if curry inRange 0 (fromIntegral len) i'
  then return $ moveCursor (fromIntegral i' - fromIntegral i)
  else indexError i len "moved cursor to index out of range" i' "requestedIndex"

cursorToStart :: Monad m => BuilderT m ()
cursorToStart = tryXList $ \i len before after -> BuilderT $ lift $ modify $ \st ->
  st{ builderItem = Just $ ListStep 0 len [] (reverse before ++ after) }

cursorToEnd :: Monad m => BuilderT m ()
cursorToEnd = tryXList $ \i len before after -> BuilderT $ lift $ modify $ \st ->
  st{ builderItem = Just $ ListStep len len [] (before ++ reverse after) }

-- | Assuming the current 'builderItem' is a 'ListStep', starting at the current cursor position
-- step through the current list by pushing each list item to the 'builderItem', evaluating the
-- given function, then popping the item.
forEachForward :: Monad m => BuilderT m t -> BuilderT m [t]
forEachForward update = loop [] where
  loop tx = tryXList $ \i len before after -> case after of
    [] -> return tx
    _  -> pushXElem >> update >>= \t -> popStep >> moveCursor 1 >> loop (tx++[t])

-- | Assuming the current 'builderItem' is a 'ListStep', starting at the current cursor position
-- step through the current list by pushing each list item to the 'builderItem', evaluating the
-- given function, then popping the item.
forEachBackward :: Monad m => BuilderT m t -> BuilderT m [t]
forEachBackward update = loop [] where
  loop tx = tryXList $ \i len before after -> case before of
    [] -> return tx
    _  -> pushXElem >> update >>= \t -> popStep >> moveCursor (negate 1) >> loop (t:tx)

instance Translatable Bool where
  toXData a = put $ Just $ if a then XTRUE else XNULL
  fromXData = tryXConst $ \o -> case o of
    XNULL -> return False
    XTRUE -> return True
    _     -> mzero

instance Translatable Int where
  toXData   = put . Just . XINT
  fromXData = tryXConst $ \o -> case o of { XINT o -> return o; _ -> mzero; }

instance Translatable Double where
  toXData   = put . Just . XFLOAT
  fromXData = tryXConst $ \o -> case o of { XFLOAT o -> return o; _ -> mzero; }

instance Translatable Text where
  toXData   = put . Just . XSTR
  fromXData = tryXConst $ \o -> case o of { XSTR o -> return o; _ -> mzero; }

instance Translatable U.ByteString where
  toXData   = put . Just . XSTR . Text
  fromXData = tryXConst $ \o -> case o of { XSTR (Text o) -> return o; _ -> mzero; }

instance Translatable String where
  toXData   = put . Just . XSTR . text
  fromXData = tryXConst $ \o -> case o of { XSTR o -> return (textChars o); _ -> mzero; }

instance Translatable Address where
  toXData   = put . Just . XPTR
  fromXData = tryXConst $ \o -> case o of { XPTR o -> return o; _ -> mzero; }

instance Translatable Label where
  toXData   = put . Just . XPTR . labelsToAddr . return
  fromXData = tryXConst $ \o -> case o of
    XPTR o -> parseLabel (show o)
    _      -> mzero

instance Translatable a => Translatable [a] where
  toXData ax = pushXList >> forM_ ax (\a -> pushXElem >> toXData a >> popStep >> moveCursor 1)
  fromXData  = tryXList $ \i len _ _ -> do
    when (i>0) cursorToStart
    fix (\loop ax -> do
            end <- endOfXList
            if end then return ax else xiterate >>= \a -> loop (ax++[a])
        ) []

instance (Translatable a, Translatable b) => Translatable (a, b) where
  toXData (a, b) = do
    pushXList
    pushXElem >> toXData a >> popStep
    moveCursor 1
    pushXElem >> toXData b >> popStep
    return ()
  fromXData = tryXList $ \i len _ _ -> do
    unless (len==2) $ do
      ptr <- parseAddress "Pair"
      throwXData "DataBuilder.Error" $
        [ ("problem", mkXStr "wrong number of elements to construct pair")
        , ("dataType", XPTR ptr)
        , ("elemCount", XINT len)
        ]
    when (i>0) cursorToStart
    pure (,) <*> xiterate <*> xiterate

instance (Ord a, Translatable a, Translatable b) => Translatable (M.Map a b) where
  toXData   = toXData . M.assocs
  fromXData = fmap M.fromList fromXData

instance Translatable XData where
  toXData   = put . Just
  fromXData = get >>= maybe mzero return

instance Translatable a => Translatable (Maybe a) where
  toXData m = pushXData "Maybe" (maybe [] (\a -> [("just", toXData a)]) m)
  fromXData = xdata "Maybe" (optXField "just")

instance Translatable DataBuilder where
  toXData (DataBuilder item path) = pushXData "DataBuilder" $
    [("builderItem", toXData item), ("builderPath", toXData path)]
  fromXData = xdata "DataBuilder" $
    pure DataBuilder <*> xfield "builderItem" <*> xfield "builderPath"

instance Translatable BuildStep where
  toXData a = case a of
    ConstStep a -> pushXData "BuildStep" [("const", toXData a)]
    DataStep a b c -> pushXData "BuildStep.Data" $
      [ ("buildDataAddress", toXData a)
      , ("buildDataDict"   , toXData b)
      , ("buildDataField"  , toXData c)
      ]
    ListStep a b c d -> pushXData "BuildStep.List" $
      [ ("buildIndex"     , toXData a)
      , ("buildListLength", toXData b)
      , ("buildListBefore", toXData c)
      , ("buildListAfter" , toXData d)
      ]
  fromXData = msum $
    [ xdata "BuildStep" (ConstStep <$> xfield "const")
    , xdata "BuildStep.Data" $
        pure DataStep
          <*> xfield "buildDataAddress"
          <*> xfield "buildDataDict"
          <*> xfield "buildDataField"
    , xdata "BuildStep.List" $
        pure ListStep
          <*> xfield "buildIndex"
          <*> xfield "buildListLength"
          <*> xfield "buildListBefore"
          <*> xfield "buildListAfter"
    ]

----------------------------------------------------------------------------------------------------

data XThrow
  = XError  { thrownXData :: XData }
  | XReturn { thrownXData :: XData }
instance Show XThrow where
  show (XError  o) = "ERROR " ++show o
  show (XReturn o) = "RETURN "++show o

-- | Pass an 'Address' as a 'Prelude.String' and a list of string-data pairs to be used to construct
-- a 'Data.Map.Lazy.Map' to be used for the 'XDATA' constructor. The string-data pairs will be
-- converted to a @('Data.Map.Lazy.Map' 'Label' 'XData')@ data structure which is how 'XDATA' types
-- store values. If the string constructing the 'Address' or any of the strings constructing
-- 'Label's for the 'Data.Map.Lazy.Map' cannot be parsed, a generic exception constructed from
-- 'XLIST' is thrown instead.
throwXData :: MonadError XThrow m => String -> [(String, XData)] -> m ig
throwXData addr itms = throwError $ XError $ mkXData addr itms

data LoadedModule m
  = PlainModule   { getXModule :: XModule }
  | BuiltinModule { getXModule :: XModule, getBuiltinEval :: Maybe (XEval -> RunT m XData) }
    -- ^ contains a directory of built-in modules paired with their XEval evaluators. An XEval
    -- evaluator is used when an object of a type matching this module is found in an 'XEval'
    -- operator like 'XADD' or 'XINDEX'. The data type in the 'XEval' is stored with the object
    -- and is used to select the pair
    -- > ('XModule', 'Prelude.Maybe' ('XEval' -> 'RunT' m 'XData'))
    -- If the 'Prelude.snd' item in the pair is not 'Prelude.Nothing', it is used to evaluate the
    -- 'XEval'.

data Runtime m
  = Runtime
    { evalCounter     :: Integer -- ^ counts how many evaluation steps have been taken
    , lastResult      :: XData
    , registers       :: M.Map Label XData
    , pcRegisters     :: M.Map Label Int
    , evalStack       :: [XData]
    , currentModule   :: Maybe XModule
    , currentBlock    :: Maybe (Array Int XCommand)
    , programCounter  :: Int
    , systemCalls     :: T.Tree Label (RunT m XData)
    , loadedModules   :: T.Tree Label (LoadedModule m)
    }

initRuntime :: Runtime m
initRuntime =
  Runtime
  { evalCounter    = 0
  , lastResult     = XNULL
  , registers      = mempty
  , pcRegisters    = mempty
  , evalStack      = []
  , currentModule  = Nothing
  , currentBlock   = Nothing
  , programCounter = 0
  , systemCalls    = T.Void
  , loadedModules  = T.Void
  }

-- | This is the monad used for evaluating the mini-Dao language. It is a
-- 'Control.Monad.Reader.MonadReader' where 'Control.Monad.Reader.ask' provides the an interface to
-- the 'Runtime' data structure, 'Control.Monad.State.state' provides an interface to update the
-- 'Runtime' data structure, 'Control.Monad.Trans.lift' allows you to lift the 'RunT' monad into
-- your own custom monad, and 'Control.Monad.IO.Class.liftIO' allows you to lift the 'RunT' monad
-- into your own custom @IO@ monad. The 'Control.Monad.Error.throwError' interface is provided which
-- lets you safely (without having to catch exceptions in the IO monad) throw an exception of type
-- 'XData', Lifting 'RunT' into the 'Control.Monad.Trans.Identity' monad is will allow all
-- evaluation to be converted to a pure function, however it will make it difficult to provide
-- system calls that do things like communicate with threads or read or write files.
newtype RunT m a = RunT{ runToPTrans :: PTrans XThrow (StateT (Runtime m) m) a }

evalRun :: Monad m => Runtime m -> RunT m a -> m (PValue XThrow a, Runtime m)
evalRun st (RunT f) = runStateT (runPTrans f) st

instance Functor m => Functor (RunT m) where { fmap f (RunT m) = RunT (fmap f m) }
instance Monad m => Monad (RunT m) where
  return = RunT . return
  RunT a >>= f = RunT $ a >>= runToPTrans . f
  RunT a >> RunT b = RunT (a >> b)
  fail = RunT . pvalue . PFail . XError . mkXStr
instance Monad m => MonadPlus (RunT m) where
  mzero = RunT mzero
  mplus (RunT a) (RunT b) = RunT (mplus a b)
instance (Functor m, Monad     m) => Applicative (RunT m) where { pure = return; (<*>) = ap; }
instance (Functor m, MonadPlus m) => Alternative (RunT m) where { empty = mzero; (<|>) = mplus; }
instance Monad m => MonadError XThrow (RunT m) where
  throwError = RunT . throwError
  catchError (RunT try) catch = RunT (catchError try (runToPTrans . catch))
instance MonadIO m => MonadIO (RunT m) where { liftIO = RunT . liftIO }
instance MonadTrans RunT where { lift = RunT . lift . lift }
instance Monad m => MonadState  (Runtime m) (RunT m) where { state = RunT . lift . state }
instance (MonadPlus m, Monad m) => MonadPlusError XThrow (RunT m) where
  catchPValue (RunT f) = RunT (catchPValue f)
  assumePValue p = RunT (assumePValue p)

----------------------------------------------------------------------------------------------------

readLabel :: String -> [(String, String)]
readLabel str = case dropWhile isSpace str of
  str@(c:_) | isAlpha c || c=='_' -> return (span isAlphaNum str)
  [] -> fail "expecting Label"

parseLabel :: MonadError XThrow m => String -> m Label
parseLabel str = case readsPrec 0 str of
  [(addr, "")] -> return addr
  _ -> throwXData "Label.Error" $
    [ ("problem", mkXStr "Labels must have no dots, commas, parens, spaces, and must not be null")
    , ("parseInput", mkXStr str)
    ]

readAddress :: String -> [(String, String)]
readAddress = readLabel >=> uncurry loop where 
  loop nm str = case dropWhile isSpace str of
    '.':str -> do
      (lbl, str) <- readLabel str
      mplus (loop (nm++'.':lbl) str) (fail "expecting Address")
    str     -> return (nm, str)

parseAddress :: MonadError XThrow m => String -> m Address
parseAddress str = case readsPrec 0 str of
  [(addr, "")] -> return addr
  _ -> throwXData "Address.Error" $
    [ ("problem", mkXStr "address must have no commas, parens, spaces, and must not be null")
    , ("parseInput", mkXStr str)
    ]

newtype Label = Label { label :: Text } deriving (Eq, Ord)
instance Show Label where { show (Label u) = textChars u }
instance Read Label where
  readsPrec _ = readLabel >=> \ (lbl, rem) -> return (Label (text lbl), rem)

newtype Address = Address  { name :: U.ByteString } deriving (Eq, Ord)
instance Show Address where { show (Address u) = U.toString u }
instance Read Address where
  readsPrec _ = readAddress >=> \ (nm, rem) -> return (Address (U.fromString nm), rem)

addrToLabels :: Address -> [Label]
addrToLabels (Address nm) = loop [] (U.toString nm) where
  loop lx str = case break (=='.') str of
    ("" , ""     ) -> lx
    (lbl, '.':str) -> loop (lx++[Label $ text lbl]) str
    (lbl, ""     ) -> lx++[Label $ text lbl]
    _              -> []

labelsToAddr :: [Label] -> Address
labelsToAddr = Address . U.fromString . intercalate "." . map (\ (Label o) -> textChars o)

newtype Text = Text { byteString :: U.ByteString } deriving (Eq, Ord)
instance Show Text where { show (Text u) = show (U.toString u) }
instance Read Text where
  readsPrec p = readsPrec p >=> \ (str, rem) -> return (Text (U.fromString str), rem)

text :: String -> Text
text = Text . U.fromString

textChars :: Text -> String
textChars (Text u) = U.toString u

----------------------------------------------------------------------------------------------------

class RWX io x | io -> x, x -> io where { io_x :: io -> x; x_io :: x -> io }

newtype Hidden a = Hidden { unhide :: Maybe a }
instance Eq  (Hidden a) where { _==_ = True }
instance Ord (Hidden a) where { compare _ _ = EQ }
instance Show (Hidden a) where { show _ = "" }
instance Read (Hidden a) where { readsPrec _ s = [(Hidden Nothing, s)] }

data RWData
  = NULL | TRUE | INT Int | FLOAT Double | STR Text | PTR Address
  | LIST [RWData]
  | DATA Address [RWDef]
  | FUNC [Label] [RWCommand]
  deriving (Eq, Ord, Show, Read)
data XData
  = XNULL | XTRUE | XINT Int | XFLOAT Double | XSTR Text | XPTR Address
  | XLIST (Maybe (Array Int XData))
  | XDATA Address (M.Map Label XData)
  | XFUNC XFunc
  deriving (Eq, Ord)
instance Show XData where { show = show . x_io }
instance RWX RWData XData where
  io_x io = case io of
    NULL     -> XNULL
    TRUE     -> XTRUE
    INT   io -> XINT       io
    FLOAT io -> XFLOAT     io
    STR   io -> XSTR       io
    PTR   io -> XPTR       io
    LIST  io -> mkXList (map io_x io)
    DATA a b -> XDATA a (M.fromList $ map ((fmap io_x) . defToPair) b)
    FUNC a b -> XFUNC (XFunc{funcArgVars=a, funcBlock=io_x b})
  x_io x  = case x  of
    XNULL     -> NULL
    XTRUE     -> TRUE
    XINT    x -> INT        x
    XFLOAT  x -> FLOAT      x
    XSTR    x -> STR        x
    XPTR    x -> PTR        x
    XLIST   x -> LIST $ maybe [] (map x_io . elems) x
    XDATA a b -> DATA a (map (uncurry DEFINE . fmap x_io) (M.assocs b))
    XFUNC   x -> FUNC (funcArgVars x) (x_io $ funcBlock x)

data XFunc = XFunc { funcArgVars :: [Label], funcBlock :: XBlock } deriving (Eq, Ord)
instance Show XFunc where { show (XFunc lbls block) = unwords ["FUNC", show lbls, show block] }

mkXStr :: String -> XData
mkXStr = XSTR . text

mkXArray :: [a] -> Maybe (Array Int a)
mkXArray o = if null o then Nothing else Just $ listArray (0, length o - 1) o

mkXList :: [XData] -> XData
mkXList = XLIST . mkXArray

mkXData :: String -> [(String, XData)] -> XData
mkXData addr itms = do
  let mkDefault = mkXList $ concat $
        [[mkXStr addr], flip concatMap itms $ (\ (lbl, dat) -> [mkXStr lbl, dat])]
  maybe mkDefault id $ do
    addr <- case readsPrec 0 addr of
      [(addr, "")] -> return addr
      _            -> mzero
    itms <- forM itms $ \ (lbl, dat) -> case readsPrec 0 lbl of
      [(lbl, "")] -> return (lbl, dat)
      _           -> mzero
    return $ XDATA addr $ M.fromList itms

asXBool :: MonadPlus m => XData -> m Bool
asXBool  o = case o of {XTRUE -> return True; XNULL -> return False; _ -> mzero;}

asXINT :: MonadPlus m => XData -> m Int
asXINT   o = case o of {XINT o -> return o; _ -> mzero;}

asXFLOAT :: MonadPlus m => XData -> m Double
asXFLOAT o = case o of {XFLOAT o -> return o; _ -> mzero;}

asXSTR :: MonadPlus m => XData -> m Text
asXSTR   o = case o of {XSTR o -> return o; _ -> mzero;}

asXPTR :: MonadPlus m => XData -> m Address
asXPTR   o = case o of {XPTR o -> return o; _ -> mzero;}

asXLIST :: MonadPlus m => XData -> m [XData]
asXLIST  o = case o of {XLIST o -> return (maybe [] elems o); _ -> mzero;}

asXFUNC :: MonadPlus m => XData -> m XFunc
asXFUNC  o = case o of {XFUNC o -> return o; _ -> mzero; }

-- | Get an 'XData' type constructed with 'XDATA' of a specific 'Address' where the 'Address'
-- represents the mini-Dao language type of the 'XDATA'. The 'Address' is passed here as a
-- 'Prelude.String'. Returns the 'Data.Map.Lazy.Map' of elements that construct the mini-Dao
-- language data type.
asXDATA :: MonadPlus m => String -> XData -> m (M.Map Label XData)
asXDATA str o = case readsPrec 0 str of
  [(getAddr, "")] -> case o of
    XDATA addr o | addr==getAddr -> return o
    _  -> mzero
  _  -> fail $ "asXDATA: could not parse Address from string "++show str

-- | Get an 'XData' type constructed with 'XDATA', and from within the 'XDATA' lookup a 'Label' in
-- the 'Data.Map.Lazy.Map' of member objects. The 'Label' is passed here as a 'Prelude.String'.
tryXMember :: MonadPlus m => String -> XData -> m XData
tryXMember str o = case readsPrec 0 str of
  [(lbl, "")] -> case o of
    XDATA _ o -> maybe mzero return (M.lookup lbl o)
    _ -> mzero
  _ -> fail $ "tryXMember: could not parse Label from string "++show str

data RWModule
  = MODULE
    { imports :: [Address]
    , private :: [RWDef]
    , public  :: [RWDef]
    , rules   :: [RWRule]
    }
  deriving (Eq, Ord, Show, Read)
data XModule
  = XMODULE
    { ximports :: [Address]
    , xprivate :: XDefines
    , xpublic  :: XDefines
    , xrules   :: [XRule]
    }
  deriving (Eq, Ord)
instance Show XModule where { show = show . x_io }
instance RWX RWModule XModule where
  io_x (MODULE imp pri exp act) = XMODULE imp (io_x pri) (io_x exp) (map io_x act) 
  x_io (XMODULE imp pri exp act) = MODULE imp (x_io pri) (x_io exp) (map x_io act) 

initXModule :: XModule
initXModule = XMODULE{ximports=[], xprivate=initXDefines, xpublic=initXDefines, xrules=[] }

data RWRule = RULE [Text] [RWCommand] deriving (Eq, Ord, Show, Read)
data XRule = XRULE [Text] XBlock deriving (Eq, Ord)
instance Show XRule where { show = show . x_io }
instance RWX RWRule XRule where
  io_x (RULE a b) = XRULE a (io_x b :: XBlock)
  x_io (XRULE a b) = RULE a (x_io b :: [RWCommand])

data RWDef = DEFINE Label RWData deriving (Eq, Ord, Show, Read)
defToPair :: RWDef -> (Label, RWData)
defToPair (DEFINE a b) = (a, b)

newtype XDefines = XDefines { defsToMap :: M.Map Label XData } deriving (Eq, Ord)
instance Show XDefines where { show = show . x_io }
instance RWX [RWDef] XDefines where
  io_x = XDefines . M.fromList . map (\ (DEFINE a b) -> (a, io_x b) )
  x_io (XDefines x) = map (\ (a, b) -> DEFINE a (x_io b)) (M.assocs x)

initXDefines :: XDefines
initXDefines = XDefines{ defsToMap = mempty }

data RWLookup
  = RESULT        -- ^ return the result register
  | CONST  RWData -- ^ return a constant value
  | VAR    Label  -- ^ return a value in a register
  | DEREF  Label  -- ^ lookup a value in the current module
  | LOOKUP Address Label -- ^ lookup a value in another module
  deriving (Eq, Ord, Show, Read)
data XLookup
  = XRESULT | XCONST XData | XVAR Label | XDEREF Label | XLOOKUP Address Label
  deriving (Eq, Ord)
instance Show XLookup where { show = show . x_io }
instance RWX RWLookup XLookup where
  io_x io = case io of
    RESULT     -> XRESULT
    CONST   io -> XCONST (io_x io)
    VAR     io -> XVAR         io 
    DEREF   io -> XDEREF       io
    LOOKUP a b -> XLOOKUP a b
  x_io x  = case x  of
    XRESULT     -> RESULT
    XCONST   x  -> CONST (x_io x)
    XVAR     x  -> VAR         x 
    XDEREF   x  -> DEREF       x
    XLOOKUP a b -> LOOKUP a b

data RWCommand
  = LOAD    RWLookup  -- ^ load a register to the result register
  | STORE   Label  -- ^ store the result register to the given register
  | UPDATE  RWLookup Label -- ^ copy a value into a local variable of the current module.
  | DELETE  Label
  | SETJUMP Label
  | JUMP    Label
  | PUSH    RWLookup
  | PEEK
  | POP
  | CLRFWD  -- ^ clear the stack into a LIST object in the RESULT register
  | CLRREV  -- ^ like 'CLRFWD' but reveres the lits of items.
  | EVAL    RWEval -- ^ evaluate a lisp-like expression
  | DO      RWCondition  -- ^ conditional evaluation
  | RETURN  RWLookup     -- ^ end evaluation
  | THROW   RWLookup
  | FOREACH Label Label RWLookup [RWCommand]
  | BREAK
  deriving (Eq, Ord, Show, Read)
data XCommand
  = XLOAD    XLookup -- ^ copy a register to the last result
  | XSTORE   Label -- ^ copy the last result to a register
  | XUPDATE  XLookup Label -- ^ copy a value into a local variable of the current module.
  | XSETJUMP Label -- ^ set a jump point
  | XJUMP    Label -- ^ goto a jump point
  | XPUSH    XLookup -- ^ push a value onto the stack
  | XPEEK    -- ^ copy the top item off of the stack
  | XPOP     -- ^ remove the top item off of the stack
  | XCLRFWD
  | XCLRREV
  | XEVAL    XEval -- ^ evaluate a lisp-like expression
  | XDO      XCondition  -- ^ branch conditional
  | XRETURN  XLookup     -- ^ end evaluation
  | XTHROW   XLookup
  deriving (Eq, Ord)
instance Show XCommand where { show = show . x_io }
instance RWX RWCommand XCommand where
  io_x io = case io of
    LOAD    a   -> XLOAD    (io_x a)
    STORE   a   -> XSTORE         a
    UPDATE  a b -> XUPDATE  (io_x a) b
    SETJUMP a   -> XSETJUMP       a
    JUMP    a   -> XJUMP          a
    PUSH    a   -> XPUSH    (io_x a)
    PEEK        -> XPEEK
    POP         -> XPOP
    CLRFWD      -> XCLRFWD
    CLRREV      -> XCLRREV
    EVAL    a   -> XEVAL    (io_x a)
    DO      a   -> XDO      (io_x a)
    RETURN  a   -> XRETURN  (io_x a)
    THROW   a   -> XTHROW   (io_x a)
  x_io x  = case x of
    XLOAD    a   -> LOAD    (x_io a)
    XSTORE   a   -> STORE         a
    XUPDATE  a b -> UPDATE  (x_io a) b
    XSETJUMP a   -> SETJUMP       a
    XJUMP    a   -> JUMP          a
    XPUSH    a   -> PUSH    (x_io a)
    XPEEK        -> PEEK
    XPOP         -> POP
    XCLRFWD      -> CLRFWD
    XCLRREV      -> CLRREV
    XEVAL    a   -> EVAL    (x_io a)
    XDO      a   -> DO      (x_io a)
    XRETURN  a   -> RETURN  (x_io a)
    XTHROW   a   -> THROW   (x_io a)

newtype XBlock = XBlock { toCommands :: Maybe (Array Int XCommand) } deriving (Eq, Ord)
instance Show XBlock where { show = show . x_io }
instance RWX [RWCommand] XBlock where
  io_x io = XBlock (mkXArray $ map io_x io)
  x_io (XBlock x) = maybe [] (map x_io . elems) x

data RWCondition
  = WHEN      RWLookup RWCommand
  | UNLESS   RWLookup RWCommand
    -- ^ iterate over a 'LIST' or 'DATA' value. If it is a data value to be iterated, the first to
    -- registers provide where to store the data header and the key of each iteration. The result
    -- register always stored the value to be scrutinized.
  deriving (Eq, Ord, Show, Read)
data XCondition
  = XWHEN   XLookup XCommand
  | XUNLESS XLookup XCommand
  deriving (Eq, Ord)
instance Show XCondition where { show = show . x_io }
instance RWX RWCondition XCondition where
  io_x io = case io of
    WHEN   a b -> XWHEN          (io_x a) (io_x b)
    UNLESS a b -> XUNLESS       (io_x a) (io_x b)
  x_io io = case io of
    XWHEN   a b -> WHEN          (x_io a) (x_io b)
    XUNLESS a b -> UNLESS       (x_io a) (x_io b)

data RWEval
  = TAKE   RWLookup
  | NOT    RWEval
  | ABS    RWEval
  | SIZE   RWEval
  | ADD    RWEval RWEval
  | SUB    RWEval RWEval
  | MULT   RWEval RWEval
  | DIV    RWEval RWEval
  | MOD    RWEval RWEval
  | INDEX  RWEval RWEval
  | GRTR   RWEval RWEval
  | GREQ   RWEval RWEval
  | LESS   RWEval RWEval
  | LSEQ   RWEval RWEval
  | EQUL   RWEval RWEval
  | NEQL   RWEval RWEval
  | APPEND RWEval RWEval
  | AND    RWEval RWEval
  | OR     RWEval RWEval
  | XOR    RWEval RWEval
  | SHIFTR RWEval RWEval
  | SHIFTL RWEval RWEval
  | IF     RWEval RWEval RWEval
  | IFNOT  RWEval RWEval RWEval
  | SYS    Address  [RWEval] -- ^ system call
  | CALL   Address  RWLookup [RWEval]
  | LOCAL  RWLookup [RWEval] -- ^ call a local function, push the result onto the stack
  | GOTO   RWLookup [RWEval] -- ^ goto a local function, never return. Good for tail recursion.
  deriving (Eq, Ord, Show, Read)
data XEval
  = XTAKE   XLookup
  | XNOT    XEval
  | XSIZE   XEval       -- ^ also functions as the absolute value operator
  | XADD    XEval XEval
  | XSUB    XEval XEval
  | XMULT   XEval XEval
  | XDIV    XEval XEval
  | XMOD    XEval XEval
  | XINDEX  XEval XEval
  | XGRTR   XEval XEval
  | XGREQ   XEval XEval
  | XLESS   XEval XEval
  | XLSEQ   XEval XEval
  | XEQUL   XEval XEval
  | XNEQL   XEval XEval
  | XAPPEND XEval XEval
  | X_AND   XEval XEval
  | X_OR    XEval XEval -- ^ not to be confused with ORX
  | X_XOR   XEval XEval
  | XSHIFTR XEval XEval
  | XSHIFTL XEval XEval
  | XIF     XEval XEval XEval
  | XIFNOT  XEval XEval XEval
  | XSYS    Address [XEval] -- ^ system call
  | XCALL   Address XLookup [XEval] -- ^ call code in a module
  | XLOCAL  XLookup [XEval] -- ^ call a local function, push the result onto the stack
  | XGOTO   XLookup [XEval] -- ^ goto a local function, never return
  deriving (Eq, Ord)
instance Show XEval where { show = show . x_io }
instance RWX RWEval XEval where
  io_x x  = case x  of
    TAKE   a   -> XTAKE   (io_x a)
    NOT    a   -> XNOT    (io_x a)  
    SIZE   a   -> XSIZE   (io_x a)  
    ADD    a b -> XADD    (io_x a) (io_x b)
    SUB    a b -> XSUB    (io_x a) (io_x b)
    MULT   a b -> XMULT   (io_x a) (io_x b)
    DIV    a b -> XDIV    (io_x a) (io_x b)
    MOD    a b -> XMOD    (io_x a) (io_x b)
    INDEX  a b -> XINDEX  (io_x a) (io_x b)
    GRTR   a b -> XGRTR   (io_x a) (io_x b)
    GREQ   a b -> XGREQ   (io_x a) (io_x b)
    LESS   a b -> XLESS   (io_x a) (io_x b)
    LSEQ   a b -> XLSEQ   (io_x a) (io_x b)
    EQUL   a b -> XEQUL   (io_x a) (io_x b)
    NEQL   a b -> XNEQL   (io_x a) (io_x b)
    APPEND a b -> XAPPEND (io_x a) (io_x b)
    AND    a b -> X_AND   (io_x a) (io_x b)
    OR     a b -> X_OR    (io_x a) (io_x b)
    XOR    a b -> X_XOR   (io_x a) (io_x b)
    SHIFTR a b -> XSHIFTR (io_x a) (io_x b)
    SHIFTL a b -> XSHIFTL (io_x a) (io_x b)
    IF     a b c -> XIF    (io_x a) (io_x b) (io_x c)
    IFNOT  a b c -> XIFNOT (io_x a) (io_x b) (io_x c)
    SYS    a b   -> XSYS  a   (map io_x b)
    CALL   a b c -> XCALL a (io_x b) (map io_x c)
    LOCAL  a b   -> XLOCAL  (io_x a) (map io_x b)
    GOTO   a b   -> XGOTO   (io_x a) (map io_x b)
  x_io io = case io of
    XTAKE   a   -> TAKE   (x_io a)
    XNOT    a   -> NOT    (x_io a)  
    XSIZE   a   -> SIZE   (x_io a)  
    XADD    a b -> ADD    (x_io a) (x_io b)
    XSUB    a b -> SUB    (x_io a) (x_io b)
    XMULT   a b -> MULT   (x_io a) (x_io b)
    XDIV    a b -> DIV    (x_io a) (x_io b)
    XMOD    a b -> MOD    (x_io a) (x_io b)
    XINDEX  a b -> INDEX  (x_io a) (x_io b)
    XGRTR   a b -> GRTR   (x_io a) (x_io b)
    XLESS   a b -> LESS   (x_io a) (x_io b)
    XEQUL   a b -> EQUL   (x_io a) (x_io b)
    XAPPEND a b -> APPEND (x_io a) (x_io b)
    X_AND   a b -> AND    (x_io a) (x_io b)
    X_OR    a b -> OR     (x_io a) (x_io b)
    X_XOR   a b -> XOR    (x_io a) (x_io b)
    XSHIFTR a b -> SHIFTR (x_io a) (x_io b)
    XSHIFTL a b -> SHIFTL (x_io a) (x_io b)
    XIF     a b c -> IF    (x_io a) (x_io b) (x_io c)
    XIFNOT  a b c -> IFNOT (x_io a) (x_io b) (x_io c)
    XSYS    a b   -> SYS  a   (map x_io b)
    XCALL   a b c -> CALL a (x_io b) (map x_io c)
    XLOCAL  a b   -> LOCAL  (x_io a) (map x_io b)
    XGOTO   a b   -> GOTO   (x_io a) (map x_io b)

----------------------------------------------------------------------------------------------------

-- | A class of evaluate-able data types: Any data type that can be treated as "code" to be run in
-- the mini-Dao runtime should instantiate this class.
class Evaluable a where { eval :: forall m . Monad m => a -> RunT m XData }

setRegister :: Monad m => Label -> XData -> RunT m ()
setRegister a b = modify (\st -> st{registers = M.insert a b (registers st)})

setResult :: Monad m => XData -> RunT m XData
setResult a = modify (\st -> st{lastResult=a}) >> return a

evalError :: Monad m => String -> String -> XData -> RunT m ig
evalError clas msg dat = case (readsPrec 0 clas, readsPrec 0 msg) of
  ([(clas, "")], [(msg, "")]) -> throwXData clas [(msg, dat)]
  _ -> fail $ concat [clas, ": ", msg, "\n\t", show (x_io dat)]

lookupModule :: Monad m => Address -> RunT m XModule
lookupModule addr = gets loadedModules >>= \mods ->
  maybe (evalError "Undefined" "moduleName" (XPTR addr)) return $
    let lbls = addrToLabels addr in fmap getXModule $ T.lookup lbls mods

instance Evaluable XLookup where
  eval o = case o of
    XRESULT     -> gets lastResult
    XCONST   o  -> return o
    XVAR     o  -> gets registers >>= \reg -> case M.lookup o reg of
      Nothing -> evalError "Undefined" "variableName" (mkXStr $ show o)
      Just  o -> return o
    XDEREF   o  -> do
      mod <- gets currentModule
      case msum $ map (fmap defsToMap >=> M.lookup o) [fmap xprivate mod, fmap xpublic mod] of
        Nothing -> evalError "Undefined" "moduleVariable" (mkXStr $ show o)
        Just  o -> return o
    XLOOKUP a b -> do
      mod <- lookupModule a
      case M.lookup b (defsToMap $ xpublic mod) of
        Nothing -> throwXData "Undefined" $
          [(read "inModule", XPTR a), (read "variableName", mkXStr $ show b)]
        Just  o -> return o

-- Increment evaluation counter
incEC :: Monad m => RunT m ()
incEC = modify (\st -> st{evalCounter=evalCounter st + 1})

-- Increment program counter
incPC :: Monad m => RunT m ()
incPC = modify (\st -> st{programCounter=programCounter st + 1})

popEvalStack :: Monad m => RunT m XData
popEvalStack = get >>= \st -> case evalStack st of
  []   -> throwXData "StackUnderflow" []
  a:ax -> put (st{evalStack=ax}) >> setResult a

pushEvalStack :: Monad m => [XData] -> RunT m ()
pushEvalStack dx = get >>= \st -> modify (\st -> st{evalStack=reverse dx++evalStack st})

evalStackEmptyElse :: Monad m => String -> [(String, XData)] -> RunT m ()
evalStackEmptyElse functionLabel params = gets evalStack >>= \stk ->
  if null stk
    then  return ()
    else  throwXData "FuncArgs" $
            [ ("problem", mkXStr "too many arguments to function")
            , ("function", mkXStr functionLabel)
            , ("extraneousArguments", mkXList stk)
            ]

instance Evaluable XCommand where
  eval o = incEC >> incPC >> case o of
    XLOAD   a   -> eval a >>= setResult
    XSTORE  a   -> gets lastResult >>= \b -> setRegister a b >> return b
    XUPDATE a b -> gets currentModule >>= \mod -> case mod of
      Nothing  -> throwXData "Undefined" $
        [ ("problem", mkXStr "update occurred with no current module")
        , ("instruction", mkXStr (show (x_io o)))
        ]
      Just mod -> case M.lookup b $ defsToMap $ xprivate mod of
        Nothing  -> throwXData "Undefined" [("variableName", mkXStr (show (x_io a)))]
        Just var -> do
          a <- eval a
          modify $ \st ->
            st{ lastResult    = var
              , currentModule = Just $
                  mod
                  { xprivate =
                      XDefines{ defsToMap = M.insert b a (defsToMap (xprivate mod)) }
                  }
              }
          gets lastResult
    XSETJUMP a   -> gets lastResult
    XJUMP    a   -> do
      pcreg <- gets pcRegisters
      let badJump = evalError "Undefined" "jumpTo" (mkXStr $ show a)
      case M.lookup a pcreg of
        Nothing -> badJump
        Just  i -> get >>= \st -> case currentBlock st of
          Nothing -> badJump
          Just  b ->
            if inRange (bounds b) i then put (st{programCounter=i}) >> return XNULL else badJump
    XPUSH    a   -> eval a >>= \b -> modify (\st -> st{evalStack = b : evalStack st}) >> return b
    XPEEK        -> gets evalStack >>= \ax -> case ax of
      []  -> throwXData "StackUnderflow" []
      a:_ -> setResult a
    XPOP         -> popEvalStack
    XCLRFWD      -> do
      modify (\st -> st{lastResult=mkXList (evalStack st), evalStack=[]})
      gets lastResult
    XCLRREV      -> do
      modify (\st -> st{lastResult=mkXList (reverse $ evalStack st), evalStack=[]})
      gets lastResult
    XEVAL    a   -> eval a
    XDO      a   -> eval a
    XRETURN  a   -> eval a >>= \a -> throwError (XReturn a)
    XTHROW   a   -> eval a >>= \a -> throwError (XError  a)

instance Evaluable XCondition where
  eval o = incEC >> case o of
    XWHEN a b -> eval a >>= \a -> case a of
      XNULL     -> return XNULL
      _         -> eval b
    XUNLESS a b -> eval a >>= \a -> case a of
      XNULL       -> eval b
      _           -> return XNULL

instance Evaluable XBlock where
  eval (XBlock cmds) = fix $ \loop -> incEC >> do
    pc <- gets programCounter
    block <- gets currentBlock
    case block of
      Just block | inRange (bounds block) pc -> eval (block!pc) >> loop
      _                                      -> gets lastResult

badEval :: Monad m => XEval -> [(String, XData)] -> RunT m ig
badEval o other = throwXData "BadInstruction" $
  [ ("instruction", mkXStr (show $ x_io o))
  , ("problem", mkXStr "evaluated operator on incorrect type of data")
  ] ++ other

evalDataOperand :: Monad m => Address -> XEval -> RunT m XData
evalDataOperand addr o = do
  -- avoids use of 'fmap' or '(<$>)' so we are not forced to put Functor in the context
  tabl <- gets loadedModules >>= return . join . fmap getBuiltinEval . T.lookup (addrToLabels addr)
  case tabl of
    Nothing   -> badEval o [("dataType", XPTR addr)]
    Just eval -> eval o

-- Automatically reverse and clear the stack, append the given parameters, and pair them with the
-- 'Label' parameters, placing the remaining unpaired items back onto the stack and setting the
-- registers by the pairs. Throw an error if there are not enough arguments to pair with the 'Label'
-- parameters.
matchArgs :: Monad m => [Label] -> [XData] -> RunT m ()
matchArgs argVars argValues = do
  stk <- gets evalStack
  let loop m ax bx = case (ax, bx) of
        (ax  , []  ) -> Just (m, [])
        ([]  , _   ) -> Nothing
        (a:ax, b:bx) -> loop ((a,b):m) ax bx
  case loop [] argVars (reverse stk ++ argValues) of
    Nothing -> evalError "FuncCall" "notEnoughParams" (mkXList argValues)
    Just (elms, rem) -> get >>= \old ->
      modify $ \st -> st{registers=M.fromList elms, evalStack=reverse rem}

setupJumpRegisters :: Monad m => Array Int XCommand -> RunT m ()
setupJumpRegisters block = modify $ \st ->
  st{ pcRegisters = M.fromList $
        flip concatMap (assocs block) $ \ (i, x) -> case x of
          XSETJUMP x -> [(x, i)]
          _          -> []
    }

callLocalMethod :: Monad m => XLookup -> [XData] -> RunT m XData
callLocalMethod lbl argValues = do
  func <- eval lbl
  case func of
    XFUNC (XFunc argVars (XBlock (Just block))) -> do
      let loop m ax bx = case (ax, bx) of
            (ax  , []  ) -> Just (m, [])
            ([]  , _   ) -> Nothing
            (a:ax, b:bx) -> loop ((a,b):m) ax bx
      case loop [] argVars argValues of
        Nothing -> evalError "FuncCall" "notEnoughParams" (mkXList argValues)
        Just (elms, rem) -> get >>= \old -> do
          matchArgs argVars argValues
          setupJumpRegisters block
          modify $ \st ->
            st{ currentBlock   = Just block
              , programCounter = programCounter old
              }
          catchError (eval (XBlock $ Just block)) $ \err -> case err of
            XError  err -> throwError (XError err)
            XReturn dat -> do
              modify $ \st ->
                st{ registers      = registers      old
                  , pcRegisters    = pcRegisters    old
                  , evalStack      = evalStack      old
                  , currentBlock   = currentBlock   old
                  , programCounter = programCounter old
                  }
              return dat
    XFUNC (XFunc _ (XBlock Nothing)) -> gets lastResult
    _ -> throwXData "FuncCall" $
            [ (read "problem", mkXStr "target of call is not executable data")
            , (read "targetRegister", mkXStr $ show $ x_io lbl)
            ]

arithmetic
  :: Monad m
  => XEval
  -> (forall a . Integral a => a -> a -> a)
  -> (forall b . Fractional b => b -> b -> b)
  -> XEval -> XEval -> RunT m XData
arithmetic o num frac a b = do
  a <- eval a
  b <- eval b
  case (a, b) of
    (XINT   a, XINT   b) -> return (XINT   $ num  a b)
    (XFLOAT a, XFLOAT b) -> return (XFLOAT $ frac a b)
    _                    -> badEval o []

boolean :: Monad m => XEval -> (forall a . Ord a => a -> a -> Bool) -> XEval -> XEval -> RunT m XData
boolean o comp a b = eval a >>= \a -> eval b >>= \b -> case (a, b) of
  (XINT   a, XINT   b) -> return (if comp a b then XTRUE else XNULL)
  (XFLOAT a, XFLOAT b) -> return (if comp a b then XTRUE else XNULL)
  _                    -> badEval o []

bitwise :: Monad m => XEval -> (Int -> Int -> Int) -> XEval -> XEval -> RunT m XData
bitwise o bit a b = eval a >>= \a -> eval b >>= \b -> case (a, b) of
  (XINT a, XINT b) -> return (XINT $ bit a b)
  _                -> badEval o []

evalCondition :: Monad m => XEval -> Bool -> XEval -> XEval -> XEval -> RunT m XData
evalCondition o inv a b c = do
  a <- mplus (eval a >>= asXBool) $
    badEval o [("problem", mkXStr "conditional does not evaluate to boolean value")]
  if not inv && a || inv && not a then eval b else eval c

instance Evaluable XEval where
  eval o = incEC >> case o of
    XTAKE   a   -> eval a
    XNOT    a   -> eval a >>= \a -> case a of
      XNULL     -> return XTRUE
      XTRUE     -> return XNULL
      XINT  a   -> return (XINT $ a `xor` 0xFFFFFFFFFFFFFFFF)
      XDATA a _ -> evalDataOperand a o
      _         -> badEval o []
    XSIZE   a   -> eval a >>= \a -> case a of
      XNULL     -> return XNULL
      XTRUE     -> return XTRUE
      XINT    a -> return (XINT   $ abs a)
      XFLOAT  a -> return (XFLOAT $ abs a)
      XLIST   a -> return (XINT   $ maybe 0 (fromIntegral .(+1).abs. uncurry subtract . bounds) a)
      XDATA a _ -> evalDataOperand a o
      _         -> badEval o []
    XADD    a b -> arithmetic o (+) (+) a b
    XSUB    a b -> arithmetic o (-) (-) a b
    XMULT   a b -> arithmetic o (*) (*) a b
    XDIV    a b -> arithmetic o div (/) a b
    XMOD    a b -> eval a >>= \a -> eval b >>= \b -> case (a, b) of
      (XINT a, XINT b) -> return (XINT $ mod a b)
      _                -> badEval o []
    XINDEX  a b -> eval a >>= \a -> eval b >>= \b -> case (a, b) of
      (XINT i, XLIST l  ) -> return (maybe XNULL (!i) l)
      (XSTR i, XDATA _ m) -> return (maybe XNULL id (M.lookup (Label i) m))
      (XTRUE , XDATA p _) -> return (XPTR p)
    XGRTR   a b -> boolean o (>)  a b
    XGREQ   a b -> boolean o (>=) a b
    XLESS   a b -> boolean o (<)  a b
    XLSEQ   a b -> boolean o (<=) a b
    XEQUL   a b -> return (if a==b then XTRUE else XNULL)
    XNEQL   a b -> return (if a/=b then XTRUE else XNULL)
    XAPPEND a b -> eval a >>= \a -> eval b >>= \b -> case (a, b) of
      (XSTR (Text a), XSTR (Text b)) -> return (XSTR $ Text $ U.fromString (U.toString a ++ U.toString b))
      (XLIST a      , XLIST b      ) -> let el = maybe [] elems in return (mkXList (el a ++ el b))
    X_AND   a b -> bitwise o (.&.) a b
    X_OR    a b -> bitwise o (.|.) a b
    X_XOR   a b -> bitwise o  xor  a b
    XSHIFTR a b -> bitwise o shift a b
    XSHIFTL a b -> bitwise o (\a b -> shift a (negate b)) a b
    XIF     a b c -> evalCondition o True  a b c
    XIFNOT  a b c -> evalCondition o False a b c
    XSYS    a b   -> do
      syscall <- gets systemCalls >>= return . T.lookup (addrToLabels a)
      case syscall of
        Nothing -> evalError "Undefined" "systemCall" (XPTR a)
        Just fn -> do
          oldstk <- gets evalStack
          b      <- mapM eval b
          modify (\st -> st{evalStack=reverse b})
          dat <- catchError fn $ \err -> case err of
            XReturn dat -> return dat
            XError  err -> throwXData "SystemCall" [("exception", err)]
          modify (\st -> st{evalStack=oldstk})
          setResult dat
    XCALL   a b c -> do
      this   <- gets lastResult
      mod    <- lookupModule a
      curmod <- gets currentModule
      c      <- mapM eval c
      modify (\st -> st{currentModule=Just mod, lastResult=this})
      catchError (callLocalMethod b c) $ \err -> case err of
        XReturn dat -> modify (\st -> st{currentModule=curmod}) >> return dat
        XError  err -> throwError (XError err)
    XLOCAL  a b   -> mapM eval b >>= callLocalMethod a
    XGOTO   a b   -> eval a >>= \a -> case a of
      XFUNC (XFunc argParams (XBlock (Just block))) -> do
        argValues <- mapM eval b
        modify $ \st ->
          st{ registers      = mempty
            , evalStack      = []
            , programCounter = 0
            , currentBlock   = Just block
            }
        matchArgs argParams argValues
        setupJumpRegisters block
        gets lastResult
      XFUNC (XFunc _ (XBlock Nothing)) -> gets lastResult
      _ -> badEval o [(read "register", mkXStr "target of GOTO is non-function data type")]

----------------------------------------------------------------------------------------------------

-- | Matches the head of the input text list to each rule in the given module. Matching rules will
-- strip the matched portion of the input text list, the remainder is placed onto the stack such
-- that successive 'POP' operations retrieve each item in the remaining input text from head to
-- tail.
evalRulesInMod :: Monad m => [Text] -> XModule -> RunT m ()
evalRulesInMod qs mod = do
  modify (\st -> st{currentModule=Just mod})
  forM_ (xrules mod) $ \ (XRULE pat block) -> case stripPrefix pat qs of
    Nothing -> return ()
    Just qs -> do
      oldstk <- gets evalStack
      modify (\st -> st{evalStack=map XSTR qs})
      eval block
      modify (\st -> st{evalStack=oldstk})
