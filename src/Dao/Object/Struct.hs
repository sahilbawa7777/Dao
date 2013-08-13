-- "src/Dao/Object/Struct.hs"  instantiation of Dao objects into the
-- 'Dao.Struct.Structured' class.
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


-- {-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE FlexibleInstances #-}

module Dao.Object.Struct where

import           Prelude hiding (lookup)

import           Dao.Object
import           Dao.Object.AST
import           Dao.Struct
import           Dao.Predicate
import           Dao.Parser
import           Dao.Glob
import qualified Dao.EnumSet as Es
import           Dao.Token
import qualified Dao.Tree    as T

import           Control.Monad
import           Control.Monad.State
import           Control.DeepSeq

import           Data.Maybe
import           Data.List (partition, isSuffixOf)
import           Data.Int
import           Data.Word
import qualified Data.Map    as M
import qualified Data.Set    as S
import qualified Data.IntMap as I
import qualified Data.IntSet as IS

import qualified Data.ByteString.Lazy as B

import Debug.Trace

----------------------------------------------------------------------------------------------------

allStrings :: [Object] -> PValue UpdateErr [UStr]
allStrings ox = forM (zip (iterate (+1) 0) ox) $ \ (i, o) -> case o of
  OString o -> return o
  _         ->
    PFail ([], OList [ostr "in list, item number", OWord i, ostr "must be a string value"])

instance Structured Comment where
  dataToStruct a = case a of
    InlineComment  a -> done "inline"  a
    EndlineComment a -> done "endline" a
    where
      done msg a = T.Leaf $ OPair (ostr msg, OString a)
  structToData = reconstruct $ do
    a <- this
    case a of
      OString a -> return (InlineComment a)
      OPair (msg, OString a)
        | msg == ostr "inline"  -> return (InlineComment  a)
        | msg == ostr "endline" -> return (EndlineComment a)
        | otherwise             -> nope (OString a)
      _         -> nope a
    where { nope a = updateFailed a "must be a comment string or typed comment string" }

instance Structured a => Structured (Com a) where
  dataToStruct a = deconstruct $ case a of
    Com         c   -> putData c
    ComBefore b c   -> putData c >> com "Before" b
    ComAfter    c a -> putData c >> com "After"  a
    ComAround b c a -> putData c >> com "Before" b >> com "After" a
    where { com msg = putDataAt ("comments"++msg) }
  structToData = reconstruct $ do
    c <- getData
    befor <- mplus (getDataAt "commentsBefore") (return [])
    after <- mplus (getDataAt "commentsAfter")  (return [])
    return $ case (befor, after) of
      ([], []) -> Com c
      (ax, []) -> ComBefore ax c
      ([], bx) -> ComAfter     c bx
      (ax, bx) -> ComAround ax c bx

putComments :: [Comment] -> Update ()
putComments coms = if null coms then return () else putDataAt "comments" coms

getComments :: Update [Comment]
getComments = mplus (getDataAt "comments") (return [])

fromShowable :: Show a => a -> T.Tree Name Object
fromShowable = T.Leaf . OString . ustr . show

fromUStrType :: UStrType a => [Char] -> String -> T.Tree Name Object -> PValue UpdateErr a
fromUStrType chrs msg = reconstruct $ do
  let msg = "an "++msg++" expressed as a string value"
      asChar o = case o of
        OChar c | elem c chrs -> return [c]
        _ -> mzero
  a <- getUStrData msg
  case maybeFromUStr a of
    Just  o -> return o
    Nothing -> updateFailed (ostr a) ("was expecting "++msg)

fromReadableOrChars :: Read a => [Char] -> String -> T.Tree Name Object -> PValue UpdateErr a
fromReadableOrChars chrs msg = reconstruct $ do
  let msg = "an "++msg++" expressed as a string value"
      asChar o = case o of
        OChar c | elem c chrs -> return [c]
        _ -> mzero
  a <- getUStrData msg
  case readsPrec 0 (uchars a) of
    [(o, "")] -> return o
    _         -> updateFailed (ostr a) ("was expecting "++msg)

fromReadable :: Read a => String -> T.Tree Name Object -> PValue UpdateErr a
fromReadable = fromReadableOrChars ""

instance Structured UpdateOp where
  dataToStruct = fromShowable
  structToData = fromUStrType allUpdateOpChars "assignment operator"

instance Structured ArithOp1 where
  dataToStruct = fromShowable
  structToData = fromUStrType allArithOp1Chars "unary prefix operator"
  
instance Structured ArithOp2 where
  dataToStruct = fromShowable
  structToData = fromUStrType allArithOp2Chars "binary infix operator"

instance Structured LambdaExprType where
  dataToStruct = fromShowable
  structToData = fromReadable "type of lambda expression"

instance Structured TypeID   where
  dataToStruct = fromShowable
  structToData = fromReadable "type identifier"

-- This instance never places data in the immediate ('Data.Struct.this') node, so it is safe to call
-- 'putData' on a value of type 'Data.Token.Location' even if you have already placed data in the
-- immedate node with 'putData'.
instance Structured Location where
  dataToStruct loc = case loc of
    LocationUnknown  -> T.Void
    Location _ _ _ _ -> deconstruct $ do
      with "from" $ do
        with "line"   (place $ OWord $ fromIntegral $ startingLine   loc)
        with "column" (place $ OWord $ fromIntegral $ startingColumn loc)
      if   startingLine   loc == endingLine   loc
        && startingColumn loc == endingColumn loc
      then  return ()
      else  with "to"   $ do
              with "line"   (place $ OWord $ fromIntegral $ endingLine     loc)
              with "column" (place $ OWord $ fromIntegral $ endingColumn   loc)
  structToData = reconstruct $ flip mplus (return LocationUnknown) $ do
    let getPos = liftM2 (,) (getDataAt "line") (getDataAt "column")
    (a,b) <- with "from" getPos
    flip mplus (return (Location a b a b)) $ do
      (c,d) <- getPos
      return (Location a b c d)

-- optionally put a location
optPutLoc :: Location -> Update ()
optPutLoc loc = case loc of
  LocationUnknown -> return ()
  loc             -> with "location" (putData loc)

instance Structured AST_Object where
  dataToStruct a = deconstruct $ case a of
    AST_Void               -> return ()
    AST_Literal      a     loc -> with "literal" (place a >> putData loc)
    AST_Assign   a b c loc -> with "assign" $
      putDataAt "to" a >> putDataAt "op" b >> putData c >> putData loc
    AST_Equation     a b c loc -> with "equation" $
      putData a >> putDataAt "op" b >> putDataAt "next" c >> putData loc
    AST_Prefix   a b   loc -> with "prefix" $
      putDataAt "op" a >> putData b >> putData loc
    AST_Paren    a     loc -> with "paren" (putData a >> putData loc)
    AST_ArraySub a b c loc -> with "subscript" $
      putDataAt "bounds" a >> putComments b >> putData c >> putData loc
    AST_FuncCall     a b c loc -> with "funcCall" $
      putData a >> putComments b >> putDataAt "arguments" c >> putData loc
    AST_Dict     a b c loc -> with "container" $
      putData a >> putComments b >> putDataAt "arguments" c >> putData loc
    AST_Array    a b   loc -> with "container" $
      putData (ustr "array") >> putDataAt "bounds" a >> putDataAt "arguments" b >> putData loc
    AST_Struct   a b   loc -> with "container" $
      putData (ustr "struct") >> putData a >> putDataAt "arguments" b >> putData loc
    AST_Data     a b   loc -> with "container" $
      putData (ustr "data") >> putComments a >> putDataAt "arguments" b >> putData loc
    AST_Lambda   a b c loc -> with "container" $
      putData (ustr (show a)) >> putDataAt "arguments" b >> putDataAt "script" c >> putData loc
    AST_MetaEval a     loc -> with "metaEval" $ putData a >> putData loc
  structToData = reconstruct $ msum $
    [ with "literal"   $ liftM2 AST_Literal   getData getData
    , with "assign"    $ liftM4 AST_Assign   (getDataAt "to") (getDataAt "op")  getData              getData
    , with "equation"  $ liftM4 AST_Equation  getData         (getDataAt "op") (getDataAt "next")    getData
    , with "prefix"    $ liftM3 AST_Prefix   (getDataAt "op")  getData          getData
    , with "paren"     $ liftM2 AST_Paren     getData                                                getData
    , with "subscript" $ liftM4 AST_ArraySub (getDataAt "bounds") (getComments)     getData getData
    , with "funcCall"  $ liftM4 AST_FuncCall  getData (getComments) (getDataAt "arguments") getData
    , with "container" $ do
        kind <- fmap uchars $ getUStrData "constructor type"
        let mkDict = liftM3 (AST_Dict (ustr kind)) (getComments) (getDataAt "arguments") getData
        case kind of
          kind | kind=="set" || kind=="list" || kind=="dict" || kind=="intmap" -> mkDict
          "array"  -> liftM3 AST_Array (getDataAt "bounds") (getDataAt "arguments") getData
          "struct" -> liftM3 AST_Struct getData (getDataAt "arguments") getData
          "data"   -> liftM3 AST_Data   (getComments) (getDataAt "arguments") getData
          kind -> case readsPrec 0 kind of
            [(kind, "")] -> liftM3 (AST_Lambda kind) (getDataAt "arguments") (getDataAt "script") getData
            _ -> updateFailed (ostr kind) "unknown type of object expression contructor"
    , with "metaEval"  $ liftM2 AST_MetaEval getData getData
    , mplus this (return ONull) >>= \o -> updateFailed o "object expression"
    ]

instance Structured AST_Script where
  dataToStruct a = deconstruct $ case a of
    AST_Comment      a           -> with "notes" $ putData a
    AST_EvalObject   a b     loc -> with "eval" $
      putData a >> putComments b >> putData loc
    AST_IfThenElse   a b c d loc -> with "if" $
      putComments a >> putData b >> putDataAt "then" c >> putDataAt "else" d >> putData loc
    AST_TryCatch     a b c   loc -> with "try" $ do
      putData a
      if unComment b == nil then return () else putDataAt "varName" b >> putDataAt "catch" c
      putData loc
    AST_ForLoop      a b c   loc -> with "for" $
      putDataAt "varName" a >> putData b >> putDataAt "script" c >> putData loc
    AST_WhileLoop    a b     loc -> with "while" $
      putData a >> putDataAt "script" b >> putData loc
    AST_ContinueExpr a b c   loc -> with (if a then "continue" else "break") $
      putComments b >> putData c >> putData loc
    AST_ReturnExpr   a b     loc -> with (if a then "return" else "throw") $
      putData b >> putData loc
    AST_WithDoc      a b     loc -> with "with" $
      putData a >> putDataAt "script" b >> putData loc
  structToData = reconstruct $ msum $
    [ with "eval"  $ liftM3 AST_EvalObject getData (getComments) getData
    , with "if"    $
        liftM5 AST_IfThenElse (getComments) getData (getDataAt "then") (getDataAt "else") getData
    , with "try"   $ do
        script <- getData
        str <- getDataAt "varName"
        catch <- if unComment str == nil then return [] else getDataAt "catch"
        loc <- getData
        return (AST_TryCatch script str catch loc)
    , with "for"   $ liftM4 AST_ForLoop (getDataAt "varName") getData (getDataAt "script") getData
    , with "while" $ liftM3 AST_WhileLoop getData (getDataAt "script") getData
    , with "continue" $ getContinue True
    , with "break"    $ getContinue False
    , with "return"   $ getReturn True
    , with "throw"    $ getReturn False
    , with "with"  $ liftM3 AST_WithDoc getData (getDataAt "script") getData
    , with "notes" $ liftM  AST_Comment getData -- needs to have a different name from "comments" to avoid confusion
    , mplus this (return ONull) >>= \o -> updateFailed o "script expression"
    ]
    where
      getContinue tf = liftM3 (AST_ContinueExpr tf) (getComments) getData getData
      getReturn   tf = liftM2 (AST_ReturnExpr   tf)                       getData getData

instance Structured Reference where
  dataToStruct = deconstruct . place . ORef
  structToData = reconstruct $ do
    a <- this
    case a of
      ORef a -> return a
      _ -> updateFailed a "reference"

instance Structured GlobUnit  where
  dataToStruct a = T.Leaf $ OString $ case a of
    Wildcard -> ustr "$*"
    AnyOne   -> ustr "$?"
    Single s -> s
  structToData = reconstruct $ do
    str <- getUStrData "glob-unit"
    return $ case uchars str of
      "$*" -> Wildcard
      "*"  -> Wildcard
      "$?" -> AnyOne
      "?"  -> AnyOne
      str  -> Single (ustr str)

instance Structured Glob       where
  dataToStruct a = deconstruct $ case a of
    Glob       a _   -> putData a
  structToData = reconstruct $ getData >>= \a -> return (Glob a (length a))

uninitialized_err a = error $ concat $
  [ a, " was just constructed from 'structToData',"
  , "the executable has not yet been initialized"
  ]

instance Structured Subroutine where
  dataToStruct a = deconstruct $ case a of
    Subroutine a _ -> putData a
  structToData = reconstruct $ do
    a <- getData
    return $ Subroutine a $ uninitialized_err "subroutine"

instance Structured Pattern where
  dataToStruct a = deconstruct $ case a of
    ObjAnyX        -> putStringData "any"
    ObjMany        -> putStringData "many"
    ObjAny1        -> putStringData "any1"
    ObjEQ      a   -> with "equals" (place a)
    ObjType    a   -> putDataAt "type" a
    ObjBounded a b -> with "bounded" (putData a >> putDataAt "to" b)
    ObjList    a b -> with "list" (putDataAt "op" a >> putData b)
    ObjNameSet a b -> with "nameSet" (putDataAt "op" a >> putData (S.elems b))
    ObjIntSet  a b -> with "intSet" $
      putDataAt "op" a >> place (OList (map (OInt . fromIntegral) (IS.elems b)))
    ObjElemSet a b -> with "elemSet" (putDataAt "op" a >> putData (S.elems b))
    ObjChoice  a b -> with "choice" (putDataAt "op" a >> putData (S.elems b))
    ObjLabel   a b -> with "label" (putDataAt "name" a >> putData b)
    ObjFailIf  a b -> with "require" (putDataAt "message" a >> putData b)
    ObjNot     a   -> with "not" (putData a)
  structToData = reconstruct $ msum $
    [ getUStrData "src/Dao/Object/Struct.hs:318:pattern" >>= \a -> case uchars a of
        "any"  -> return ObjAnyX
        "many" -> return ObjMany
        "any1" -> return ObjAny1
        _      -> updatePValue Backtrack
    , with "equals"  $ liftM  ObjEQ       this
    , with "type"    $ liftM  ObjType     getData
    , with "bounded" $ liftM2 ObjBounded  getData           (getDataAt "to")
    , with "list"    $ liftM2 ObjList    (getDataAt "op")    getData
    , with "nameSet" $ liftM2 ObjNameSet (getDataAt "op")   (fmap S.fromList  getData)
    , with "intSet"  $ liftM2 ObjIntSet  (getDataAt "op")   (fmap IS.fromList getData)
    , with "elemSet" $ liftM2 ObjElemSet (getDataAt "op")   (fmap S.fromList  getData)
    , with "choice"  $ liftM2 ObjChoice  (getDataAt "op")   (fmap S.fromList  getData)
    , with "label"   $ liftM2 ObjLabel   (getDataAt "name")  getData
    , with "require" $ liftM2 ObjFailIf  (getDataAt "message") getData
    , with "not"     $ liftM  ObjNot     getData
    , mplus this (return ONull) >>= \a -> updateFailed a "pattern"
    ]

instance Structured ObjSetOp where
  dataToStruct a = deconstruct $ place $ ostr $ case a of
    ExactSet  -> "exact"
    AnyOfSet  -> "any"
    AllOfSet  -> "all"
    OnlyOneOf -> "only"
    NoneOfSet -> "none"
  structToData = reconstruct $ getUStrData "pattern set operator" >>= \a -> case uchars a of
    "exact" -> return ExactSet
    "any"   -> return AnyOfSet
    "all"   -> return AllOfSet
    "only"  -> return OnlyOneOf
    "none"  -> return NoneOfSet
    a       -> updateFailed (ostr a) "pattern set operator"

instance Structured TopLevelEventType where
  dataToStruct a = deconstruct $ place $ ostr $ case a of
    BeginExprType -> "BEGIN"
    EndExprType   -> "END"
    ExitExprType  -> "EXIT"
  structToData = reconstruct $ getUStrData "event type" >>= \a -> case uchars a of
    "BEGIN" -> return BeginExprType
    "END"   -> return EndExprType
    "EXIT"  -> return ExitExprType
    "QUIT"  -> return ExitExprType
    _       -> updateFailed (ostr a) "top-level event type"

instance Structured AST_TopLevel where
  dataToStruct a = deconstruct $ case a of
    AST_Attribute      a b     loc -> with "attribute" $
      putData a >> putDataAt "value" b >> putData loc
    AST_TopFunc        a b c d loc -> with "function" $ do
      putDataAt "comment" a >> putDataAt "name" b
      putData c >> putDataAt "script" d >> putData loc
    AST_TopScript      a       loc -> with "directive" $ putData a >> putData loc
    AST_TopLambda  a b c   loc -> with "lambda" $
      putDataAt "type" a >> putData b >> putDataAt "script" c >> putData loc
    AST_Event      a b c   loc -> with "event" $
      putDataAt "type" a >> putDataAt "comment" b >> putDataAt "script" c
    AST_TopComment     a         -> putDataAt "comment" a
  structToData = reconstruct $ msum $
    [ with "attribute" $ liftM3 AST_Attribute getData (getDataAt "value") getData
    , with "function"  $ liftM5 AST_TopFunc (getDataAt "comment") (getDataAt "name") getData (getDataAt "script") getData
    , with "directive" $ liftM2 AST_TopScript getData getData
    , with "lambda"    $ liftM4 AST_TopLambda (getDataAt "type") getData (getDataAt "script") getData
    , with "event"     $ liftM4 AST_Event (getDataAt "type") (getDataAt "comments") (getDataAt "script") getData
    , with "comment"   $ liftM AST_TopComment getData
    , updateFailed ONull "top-level directive"
    ]

putIntermediate :: (Intermediate obj ast, Structured ast) => String -> obj -> T.Tree Name Object
putIntermediate typ a = deconstruct $ case fromInterm a of
  []  -> return ()
  [a] -> putTree (dataToStruct a)
  _   -> error ("fromInterm returned more than one possible intermediate data structure for "++typ)

getIntermediate :: (Intermediate obj ast, Structured ast) => String -> T.Tree Name Object -> PValue UpdateErr obj
getIntermediate typ = reconstruct $ do
  a <- getData
  case toInterm a of
    []  -> get >>= \st ->
      updateFailed (OTree st) ("could not convert "++typ++" expression to it's intermediate")
    [a] -> return a
    _   -> error ("toInterm returned more than one possible abstract syntax tree for "++typ)

toplevel_intrm = "top-level intermedaite node"
script_intrm = "script intermedaite node"
object_intrm = "object intermedaite node"

instance Structured TopLevelExpr where
  dataToStruct = putIntermediate toplevel_intrm
  structToData = getIntermediate toplevel_intrm

instance Structured ScriptExpr where
  dataToStruct = putIntermediate script_intrm
  structToData = getIntermediate script_intrm

instance Structured ObjectExpr where
  dataToStruct = putIntermediate object_intrm
  structToData = getIntermediate object_intrm

instance (Ord a, Enum a, Structured a) => Structured (Es.Inf a) where
  dataToStruct a = deconstruct $ case a of
    Es.PosInf  -> putStringData "+inf"
    Es.NegInf  -> putStringData "-inf"
    Es.Point a -> putData a
  structToData = reconstruct $ msum $
    [ fmap Es.Point getData
    , getUStrData msg >>= \a -> case uchars a of
        "+inf" -> return Es.PosInf
        "-inf" -> return Es.NegInf
    , mplus this (return ONull) >>= \o -> updateFailed o msg
    ]
    where { msg = "unit of a segment of an enum set" }

instance (Ord a, Enum a, Bounded a, Structured a) => Structured (Es.Segment a) where
  dataToStruct a = deconstruct $
    mplus (maybeToUpdate (Es.singular a) >>= putDataAt "at") $
      maybeToUpdate (Es.plural a) >>= \ (a, b) -> putDataAt "to" a >> putDataAt "from" b
  structToData = reconstruct $ msum $
    [ getDataAt "to" >>= \a -> getDataAt "from" >>= \b -> return (Es.segment a b)
    , fmap Es.single (getDataAt "at")
    , mplus this (return ONull) >>= \o -> updateFailed o "unit segment of an enum set"
    ]

instance (Ord a, Enum a, Bounded a, Es.InfBound a, Structured a) => Structured (Es.Set a) where
  dataToStruct a = deconstruct (putData (Es.toList a))
  structToData = reconstruct (fmap Es.fromList getData)

