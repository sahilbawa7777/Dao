-- "src/Dao/Token.hs"  Defines the 'Token' and 'Location' types
-- used by "src/Dao/Object.hs" and "src/Dao/Parser.hs".
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

{-# LANGUAGE DeriveDataTypeable #-}

module Dao.Token where

import           Data.Monoid
import           Data.Typeable
import           Data.Word

-- | 'Token's are created by 'Parser's like 'regex' or 'regexMany1'. You can combine tokens using
-- 'append', 'appendTokens' and 'parseAppend'. There is no restriction on the order in which you
-- combine tokens, but it is less confusing if you append tokens in the order in which they were
-- parsed.  You can then use the 'tokenChars' function to retrieve the characters stored in the
-- 'Token' to create data structures that can be returned by your 'Parser' function. You can also
-- "undo" a parse by passing a 'Token' to the 'backtrack' function, which pushes the 'Token's
-- characters back onto the head of the input string, however this is inefficient and should be
-- avoided.
data Token
  = Token
    { tokenLocation  :: Location
    , tokenChars     :: String
    }
  deriving (Eq, Ord)

instance Show Token where
  show t = show (tokenLocation t) ++ ' ' : show (tokenChars t)

-- | Used mostly by 'Dao.Parser' and 'Dao.Object.Parser' but is also used to report location of
-- errors and are stored in the abstract syntax tree, 'ObjectExpr', 'ScriptExpr'.
data Location
  = LocationUnknown
  | Location
    { startingLine   :: Word64
    , startingChar   :: Word64
    , startingColumn :: Word
    , endingLine     :: Word64
    , endingChar     :: Word64
    , endingColumn   :: Word
    }
    deriving (Eq, Ord, Typeable)

class HasLocation a where
  getLocation :: a -> Location
  setLocation :: a -> Location -> a

instance Show Location where
  show t = show (startingLine t) ++ ':' : show (startingColumn t)

instance Monoid Location where
  mempty =
    Location
    { startingLine   = 0
    , startingChar   = 0
    , startingColumn = 0
    , endingLine     = 0
    , endingChar     = 0
    , endingColumn   = 0
    }
  mappend loc a =
    loc
    { startingLine   = min (startingLine   loc) (startingLine   a)
    , startingChar   = min (startingChar   loc) (startingChar   a)
    , startingColumn = min (startingColumn loc) (startingColumn a)
    , endingLine     = max (endingLine     loc) (endingLine     a)
    , endingChar     = max (endingChar     loc) (endingChar     a)
    , endingColumn   = max (endingColumn   loc) (endingColumn   a)
    }

instance Monoid Token where
  mempty = Token{tokenLocation = mempty, tokenChars = mempty}
  mappend token a =
    token
    { tokenLocation  = mappend (tokenLocation token) (tokenLocation a)
    , tokenChars     = tokenChars token ++ tokenChars a
    } 
