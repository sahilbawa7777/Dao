-- "src/Dao/Object/Show.hs"  provides functions for pretty printing Dao
-- objects, Dao scripts, and Dao programs.
-- 
-- Copyright (C) 2008-2012  Ramin Honary.
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


module Dao.Object.Show where

import           Dao.Types
import           Dao.Pattern
import qualified Dao.Tree as T
import           Dao.Object

import           Control.Monad

import           Numeric

import           Data.Maybe (fromMaybe, maybeToList)
import           Data.List
import           Data.Complex
import qualified Data.Map as M
import qualified Data.IntMap as I
import qualified Data.Set as S
import qualified Data.ByteString           as Byt (pack, unpack, take, drop, null)
import qualified Data.ByteString.Base64    as B64 (encode)
import qualified Data.ByteString.Lazy      as B
import qualified Data.ByteString.Lazy.UTF8 as U
import           Data.Int
import           Data.Char
import           Data.Word
import           Data.Ratio
import           Data.Array.IArray
import           Data.Time hiding (parseTime)

----------------------------------------------------------------------------------------------------

indent :: Int -> String
indent idnc = take idnc (repeat '\t')

showRef :: [Name] -> String
showRef nmx = "${" ++ intercalate "." (map str nmx) ++ "}" where
  str nm = case uchars nm of
    "" -> "$\"\""
    a:ax | (isAlpha a || a=='_') && and (map isPrint ax) -> a:ax
    _ -> '$':show nm

showObj :: Int -> Object -> String
showObj idnc o = case o of
  ONull       -> "null"
  OTrue       -> "true"
  OType     o -> show o
  OInt      o -> show o
  OWord     o -> sh "word" o
  OLong     o -> sh "long" o
  OFloat    o -> show o
  ORatio    o -> "ratio ("++show o++")"
  OComplex  o -> show o
  OTime     o -> "date ("++show o++")"
  ODiffTime o -> "difftime ("++show o++")"
  OChar     o -> show o
  OString   o -> show o
  ORef      o -> '$':showReference o
  OPair (a,b) -> let i = idnc+1 in "pair ("++showObj i a++", "++showObj i b++")"
  OList     o -> simplelist idnc o
  OSet      o -> "set "++simplelist idnc (S.elems o)
  OArray    o ->
    let (a,b) = bounds o
    in  multiline ("array ("++show a++',':show b++")") "[" "," "]" (elems o)
  ODict     o -> pairlist "dict " show (M.assocs o)
  OIntMap   o -> pairlist "intmap " show (I.assocs o)
  OTree     o -> pairlist "tree " showRef (T.assocs o)
  OPattern  o -> "pattern "++show o
  ORule     o -> showRule idnc o
  OScript   o -> showScript idnc Nothing o
  OBytes    o -> "base64 " ++ if B.null o then "{}" else "{\n"++base64++indent idnc++"}" where
    base64 = block (B64.encode (Byt.pack (B.unpack o)))
    block o = if Byt.null o then "\n" else indent (idnc+1)
      ++ map (chr . fromIntegral) (Byt.unpack (Byt.take 72 o))
      ++ '\n':block (Byt.drop 72 o)
  where
    sh lbl o = lbl++" "++show o
    simplelist idnc o = '[':intercalate ", " (map (showObj (idnc+1)) o)++"]" 
    pairlist prefix showKey items =
      let tabs = indent (idnc+1)
          line (key, o) = tabs ++ showKey key ++ ": " ++ showObj (idnc+1) o ++ ",\n"
      in  prefix ++ "{\n" ++ concatMap line items ++ '\n':indent idnc ++ "}"
    multiline prefix open itemsep close items =
      let tabs = indent (idnc+1)
      in  prefix ++ ' ':open ++ "\n"
            ++ intercalate (itemsep++"\n") (map (showObj (idnc+1)) items)
            ++ ('\n':indent idnc++close)

showCom :: (Int -> a -> String) -> Int -> Com a -> String
showCom showItem idnc com = case com of
  Com         b   ->         showItem idnc b
  ComBefore a b   -> sh a ++ showItem idnc b
  ComAfter    b c ->         showItem idnc b ++ sh c
  ComAround a b c -> sh a ++ showItem idnc b ++ sh c
  where
    idnc' = idnc+1
    sh comx = flip concatMap comx $ \com -> case com of
      InlineComment  com -> " /*"++uchars com++"*/ "
      EndlineComment com -> " //"++uchars com++"\n"++indent idnc'

showScript :: Int -> Maybe Name -> Script -> String
showScript idnc maybeName scrp =
     "func"++ fromMaybe "" (maybeName >>= Just . (" "++) . uchars)
  ++ showCom argv idnc (scriptArgv scrp) ++ " {"
  ++ showScriptBlock (idnc+1) (scriptCode scrp)
  ++ '\n':indent idnc ++ "}"
  where
    argv idnc ax = "("
      ++ intercalate ", " (map (\a -> showCom (\_ a -> show a) (idnc+1) a) ax)
      ++ ")"

showScriptBlock :: Int -> Com [Com ScriptExpr] -> String
showScriptBlock idnc linex = " {" ++ showCom loop (idnc+1) linex ++ '\n':indent idnc ++ "}" where
  loop idnc linex = case linex of
    []         -> ""
    line:linex -> '\n':indent idnc++showScriptExpr idnc line++loop idnc linex

showScriptExpr :: Int -> Com ScriptExpr -> String
showScriptExpr idnc line = showCom expr idnc line where
  expr idnc line = case line of
    NO_OP                    -> ""
    EvalObject   obj         -> showObjectExpr idnc obj ++ ";"
    IfThenElse   ifx thx elx -> ifloop ifx thx elx where
      ifloop ifx thx elx =
           "if(" ++ showObjectExpr idnc ifx ++ ')' : showScriptBlock idnc thx
        ++ let showElse = "else " ++ showScriptBlock idnc elx
           in case unComment elx of
                [] -> ""
                [elexpr] -> case unComment elexpr of
                  IfThenElse ifx thx elx -> "else " ++ ifloop ifx thx elx
                  _ -> showElse
                _ -> showElse
    TryCatch     try nm ctch -> "try " ++ showScriptBlock idnc try
      ++ '\n':indent idnc ++ "catch " ++ showCom (\_ -> uchars) (idnc+1) nm ++ showScriptBlock idnc ctch
    ForLoop      nm obj scrp -> "foreach " ++ showCom (\_ -> uchars) idnc nm
      ++ " in (" ++ showObjectExpr idnc obj ++ ")" ++ showScriptBlock idnc scrp
    ContinueExpr fn  obj com -> contBrkRetnThrow idnc fn obj com "continue" "break"
    ReturnExpr   fn  obj com -> contBrkRetnThrow idnc fn obj com "return"   "throw"
    WithDoc      obj with    -> "with " ++ showObjectExpr idnc obj ++ showScriptBlock idnc with

-- | Used to show 'Dao.Types.ContinueExpr' and 'Dao.Object.ReturnExpr'.
contBrkRetnThrow :: Int -> Com Bool -> Com ObjectExpr -> Com () -> String -> String -> String
contBrkRetnThrow idnc fn obj com cont brk = showCom (\_ fn -> if fn then cont else brk) 0 fn
  ++ " (" ++ showObjectExpr idnc obj ++ ")" ++ showCom (\_ _ -> ";") 0 com

showReference :: Reference -> String
showReference o = case o of
  IntRef       o -> '$':show o
  LocalRef     o -> uchars o
  QTimeRef     o -> "qtime "++showRef o
  StaticRef    o -> "static "++uchars o
  GlobalRef    o -> showRef o
  ProgramRef p o -> "program("++uchars p++", "++uchars o++")"
  FileRef    f o -> "file("++uchars f++", "++showRef o++")"
  MetaRef      o -> '$':showReference o

showObjectExpr :: Int -> Com ObjectExpr -> String
showObjectExpr idnc obj = showCom loop idnc obj where
  tuple sh idnc args = 
    '(':showCom (\idnc args -> intercalate ", " (map (sh idnc) args)) (idnc+1) args++")"
  assignExpr idnc expr = case expr of
    AssignExpr   ref  obj       -> showObjectExpr idnc ref ++ ": " ++ showObjectExpr (idnc+1) obj
    _ -> loop idnc expr
  dictExpr idnc objx = intercalate (",\n"++indent idnc) (map (showCom assignExpr (idnc+1)) objx)
  loop idnc obj = case obj of
    Literal      obj            -> showCom showObj idnc obj
    AssignExpr   ref      obj   ->
      showObjectExpr idnc ref ++ " = " ++ showObjectExpr (idnc+1) obj
    FuncCall     name args      ->
      showCom (\_ -> uchars) idnc name ++ tuple showObjectExpr idnc args
    LambdaCall   call obj  args ->
         showCom (\_ _ -> "call") idnc call
      ++ showObjectExpr (idnc+1) obj
      ++ tuple showObjectExpr idnc args
    ParenExpr    sub            -> '(' : showObjectExpr (idnc+1) sub ++ ")"
    Equation     left op  right -> showObjectExpr idnc left
      ++ showCom (\_ -> uchars) idnc op
      ++ case unComment right of
           Equation _ _ _ -> '(':showObjectExpr idnc right++")"
           _ -> showObjectExpr idnc right
    DictExpr     dict objx      -> showCom (\_ -> uchars) idnc dict
      ++ "{\n" ++ indent (idnc+1) ++ showCom dictExpr idnc objx ++ "}"
    ArrayExpr    com  bnds elms -> showCom (\_ _ -> "array") idnc com
      ++ tuple showObjectExpr (idnc+1) bnds ++ '['
      :  showCom (\idnc elms -> intercalate ", " (map (showObjectExpr (idnc+1)) elms)) idnc elms
      ++ "]"
    ArraySubExpr obj  sub       -> showObjectExpr idnc obj ++ '[':showObjectExpr (idnc+1) sub++"]"
    LambdaExpr   com  argv scrp ->
         showCom (\_ _ -> "func") idnc com ++ tuple (showCom (\_ -> uchars)) (idnc+1) argv
      ++ "{\n" ++ indent (idnc+1) ++ showScriptBlock (idnc+1) scrp ++ '\n':indent idnc++"}"

showRule :: Int -> Rule -> String
showRule idnc rule = "rule "
  ++ showCom (\ _ pat -> show pat) idnc (rulePattern rule)
  ++ showScriptBlock idnc (ruleAction rule)

showRuleSet :: Int -> PatternTree [Com [Com ScriptExpr]] -> String
showRuleSet idnc rules = unlines $ map mkpat $ T.assocs $ rules where
  showScrp rule scrp = rule++showScriptBlock 1 scrp ++ '\n':indent idnc
  mkpat (pat, scrpx) =
    let rule = indent idnc ++ "rule "
                ++ show (Pattern{getPatUnits = pat, getPatternLength = length pat})
    in  unlines (map (showScrp rule) scrpx)

showTask :: Task -> String
showTask task = case task of
  RuleTask pat _ _ _ -> "RuleTask: "++showObj 0 pat
  GuardTask _ _ -> "GuardTask"

