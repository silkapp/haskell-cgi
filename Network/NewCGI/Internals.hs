-----------------------------------------------------------------------------
-- |
-- Module      :  Network.NewCGI.Internals
-- Copyright   :  (c) Bjorn Bringert 2006
-- License     :  BSD-style
--
-- Maintainer  :  bjorn@bringert.net
-- Stability   :  experimental
-- Portability :  non-portable
--
-- Internal stuff that most people shouldn't have to use.
-- This module mostly deals which the CGI protocol side,
-- and the internals of the CGIT monad transformer.
-- This can for example be used to write alternative run functions.
--
-----------------------------------------------------------------------------

module Network.NewCGI.Internals (
    MonadCGI(..), CGIState(..), CGIT(..), CGIResult(..), CGI
  , Input(..), HeaderName(..),
  , hRunCGI, runCGIEnv, runCGIEnvFPS
  -- * Error handling
  , handleExceptionCGI
  -- * Logging
  , logCGI
  -- * Environment variables
  , getCGIVars
  -- * Inputs
  , takeInput
  -- * URL encoding
  , formEncode, urlEncode, formDecode, urlDecode
  -- * Utilities
  , maybeRead
 ) where

import Control.Exception as Exception (Exception,try)
import Control.Monad (liftM)
import Control.Monad.State (StateT(..), gets, lift, modify)
import Control.Monad.Trans (MonadTrans, MonadIO, liftIO)
import Data.Char (toLower)
import Data.List (intersperse)
import qualified Data.Map as Map
import Data.Map (Map)
import Data.Maybe (fromMaybe, listToMaybe)
import Network.URI (unEscapeString,escapeURIString,isUnescapedInURI)
import System.Environment (getEnv)
import System.IO (Handle, hPutStrLn, stderr, hFlush)

import qualified Data.ByteString.Lazy.Char8 as BS
import Data.ByteString.Lazy.Char8 (ByteString)

import Network.Multipart

-- | The state ept in the CGIT monad transformer.
data CGIState = CGIState {
                          -- | Environment variables.
                          cgiVars :: Map String String,
                          -- | Input parameters.
                          cgiInput :: Map String [Input],
                          -- | Response headers.
                          cgiHeaders :: Map HeaderName String
                         }
              deriving Show

-- | A string with case insensitive equality and comparisons.
newtype HeaderName = HeaderName String deriving (Show)

instance Eq HeaderName where
    HeaderName x == HeaderName y = map toLower x == map toLower y

instance Ord HeaderName where
    HeaderName x `compare` HeaderName y = map toLower x `compare` map toLower y

-- | The value of an input parameter, and some metadata.
data Input = Input {
                    value :: ByteString,
                    filename :: Maybe String,
                    contentType :: ContentType
                   }
              deriving Show

-- | The CGIT monad transformer.
newtype CGIT m a = CGIT { unCGIT :: StateT CGIState m a }

-- | A simple CGI monad with just IO.
type CGI a = CGIT IO a

-- | The result of a CGI program.
data CGIResult = CGIOutput ByteString
               | CGIRedirect String
                 deriving (Show, Read, Eq, Ord)

--
-- * CGIT monad transformer
--

instance Monad m => Functor (CGIT m) where
    fmap f c = CGIT (fmap f (unCGIT c))

instance Monad m => Monad (CGIT m) where
    c >>= f = CGIT (unCGIT c >>= unCGIT . f)
    return = CGIT . return
    -- FIXME: should we have an error monad instead?
    fail s = CGIT (fail s)

instance MonadIO m => MonadIO (CGIT m) where
    liftIO f = CGIT (liftIO f)

class Monad m => MonadCGI m where
    -- | Modify the CGIT state.
    cgiModify :: (CGIState -> CGIState) -> m ()
    -- | Get something from the CGIT state.
    cgiGet :: (CGIState -> a) -> m a

instance Monad m => MonadCGI (CGIT m) where
    cgiModify = CGIT . modify
    cgiGet = CGIT . gets

instance MonadTrans CGIT where
    lift = CGIT . lift

--
-- * Running CGI actions
--

-- | Run a CGI action. Gets CGI environment variables from
--   the program environment.
hRunCGI :: MonadIO m =>
           Handle -- ^ Handle that input will be read from.
        -> Handle -- ^ Handle that output will be written to.
        -> CGIT m CGIResult -> m ()
hRunCGI hin hout f = do env <- liftIO getCGIVars
                        inp <- liftIO $ BS.hGetContents hin
                        outp <- runCGIEnvFPS env inp f
                        liftIO $ BS.hPut hout outp
                        liftIO $ hFlush hout

-- | Run a CGI action in a given environment, using strings
--   for input and output. Note: this can be inefficient,
--   especially with file uploads. Use 'runCGIEnvFPS'
--   instead.
runCGIEnv :: Monad m =>
             [(String,String)] -- ^ CGI environment variables.
          -> String -- ^ Request body.
          -> CGIT m CGIResult -- ^ CGI action.
          -> m String -- ^ Response (headers and content).
runCGIEnv vars inp f = liftM BS.unpack $ runCGIEnvFPS vars (BS.pack inp) f

-- | Run a CGI action in a given environment, using a 'FastString'
--   for input and a lazy string for output. 
runCGIEnvFPS :: Monad m =>
             [(String,String)] -- ^ CGI environment variables.
          -> ByteString -- ^ Request body.
          -> CGIT m CGIResult -- ^ CGI action.
          -> m ByteString -- ^ Response (headers and content).
runCGIEnvFPS vars inp f
    = do let s = CGIState {
                           cgiVars = Map.fromList vars,
                           cgiInput = mkMultiMap $ decodeInput vars inp,
                           cgiHeaders = Map.empty
                          }
         (outp,s') <- runStateT (unCGIT f) s
         let hs = cgiHeaders s'
         return $ case outp of
           CGIOutput c ->  formatResponse c hs'
               where hs' = Map.insertWith (\_ o -> o) 
                             (HeaderName "Content-type") defaultContentType hs
           CGIRedirect url -> formatResponse BS.empty hs'
               where hs' = Map.insert (HeaderName "Location") url hs

formatResponse :: ByteString -> Map HeaderName String -> ByteString
formatResponse c hs = 
    BS.unlines ([BS.pack (n++": "++v) | (HeaderName n,v) <- Map.toList hs] 
                ++ [BS.empty,c])

defaultContentType :: String
defaultContentType = "text/html; charset=ISO-8859-1"

--
-- * Logging and error handling
--

-- | Handle an exception.
--   FIXME: could this be generalized?
handleExceptionCGI :: CGI a -> (Exception -> CGI a) -> CGI a
handleExceptionCGI (CGIT c) h = 
    CGIT (StateT (\s -> f s (runStateT c s))) >>= either h return
  where 
  f s = liftM (either (\ex -> (Left ex,s)) (\(a,s') -> (Right a,s'))) . try

-- | Log some message using the server\'s logging facility.
-- FIXME: does this have to be more general to support
-- FastCGI etc? Maybe we should store log messages in the
-- CGIState?
logCGI :: (MonadCGI m, MonadIO m) => String -> m ()
logCGI s = liftIO (hPutStrLn stderr s)

--
-- * Environment variables
--

getCGIVars :: IO [(String,String)]
getCGIVars = mapM (\n -> (,) n `liftM` getEnvOrNil n) cgiVarNames

cgiVarNames :: [String]
cgiVarNames =
   [ "DOCUMENT_ROOT"
   , "AUTH_TYPE"
   , "GATEWAY_INTERFACE"
   , "SERVER_SOFTWARE"
   , "SERVER_NAME"
   , "REQUEST_METHOD"
   , "REQUEST_URI"
   , "SERVER_ADMIN"
   , "SERVER_PORT"
   , "QUERY_STRING"
   , "CONTENT_LENGTH"
   , "CONTENT_TYPE"
   , "REMOTE_USER"
   , "REMOTE_IDENT"
   , "REMOTE_ADDR"
   , "REMOTE_HOST"
   , "TZ"
   , "PATH"
   , "PATH_INFO"
   , "PATH_TRANSLATED"
   , "SCRIPT_NAME"
   , "SCRIPT_FILENAME"
   , "HTTP_COOKIE"
   , "HTTP_CONNECTION"
   , "HTTP_ACCEPT_LANGUAGE"
   , "HTTP_ACCEPT"
   , "HTTP_HOST"
   , "HTTP_UA_COLOR"
   , "HTTP_UA_CPU"
   , "HTTP_UA_OS"
   , "HTTP_UA_PIXELS"
   , "HTTP_USER_AGENT"
   ]

--
-- * Inputs
--

-- | Get and decode the input according to the request
--   method and the content-type.
decodeInput :: [(String,String)] -- ^ CGI environment variables.
            -> ByteString        -- ^ Request body.
            -> [(String,Input)]  -- ^ Input variables and values.
decodeInput env inp = queryInput env ++ bodyInput env inp

-- | Build an 'Input' object for a simple value.
simpleInput :: String -> Input
simpleInput v = Input { value = BS.pack v,
                        filename = Nothing,
                        contentType = defaultInputType }

-- | The default content-type for variables.
defaultInputType :: ContentType
defaultInputType = ContentType "text" "plain" [] -- FIXME: use some default encoding?


--
-- * Query string
--

-- | Get inputs from the query string.
queryInput :: [(String,String)] -- ^ CGI environment variables.
           -> [(String,Input)] -- ^ Input variables and values.
queryInput env = formInput $ lookupOrNil "QUERY_STRING" env

-- | Decode application\/x-www-form-urlencoded inputs.
formInput :: String
          -> [(String,Input)] -- ^ Input variables and values.
formInput qs = [(n, simpleInput v) | (n,v) <- formDecode qs]

--
-- * URL encoding
--

-- | Format name-value pairs as application\/x-www-form-urlencoded.
formEncode :: [(String,String)] -> String
formEncode xs = 
    concat $ intersperse "&" [urlEncode n ++ "=" ++ urlEncode v | (n,v) <- xs]

-- | Convert a single value to the application\/x-www-form-urlencoded encoding.
urlEncode :: String -> String
urlEncode = replace ' ' '+' . escapeURIString okChar
  where okChar c = c == ' ' || 
                   (isUnescapedInURI c && c `notElem` "&=+")

-- | Get the name-value pairs from application\/x-www-form-urlencoded data.
formDecode :: String -> [(String,String)]
formDecode "" = []
formDecode s = (urlDecode n, urlDecode (drop 1 v)) : formDecode (drop 1 rs)
    where (nv,rs) = break (=='&') s
          (n,v) = break (=='=') nv

-- | Convert a single value from the 
--   application\/x-www-form-urlencoded encoding.
urlDecode :: String -> String
urlDecode = unEscapeString . replace '+' ' '

--
-- * Request content and form-data stuff
--

-- | Get input variables from the body, if any.
bodyInput :: [(String,String)] -- ^ CGI environment variables.
          -> ByteString        -- ^ Request body.
          -> [(String,Input)]  -- ^ Input variables and values.
bodyInput env inp =
   case lookup "REQUEST_METHOD" env of
      Just "POST" -> 
          let ctype = lookup "CONTENT_TYPE" env >>= parseContentType
           in decodeBody ctype $ takeInput env inp
      _ -> []

-- | Decode a POST body.
decodeBody :: Maybe ContentType -- ^ Content-type, if any
           -> ByteString        -- ^ Request body
           -> [(String,Input)]  -- ^ Input variables and values.
decodeBody ctype inp = 
    case ctype of
               Just (ContentType "application" "x-www-form-urlencoded" _) 
                   -> formInput (BS.unpack inp)
               Just (ContentType "multipart" "form-data" ps) 
                   -> multipartDecode ps inp
               Just _ -> [] -- FIXME: report that we don't handle this content type
               -- No content-type given, assume x-www-form-urlencoded
               Nothing -> formInput (BS.unpack inp)

-- | Take the right number of bytes from the input.
takeInput :: [(String,String)]  -- ^ CGI environment variables.
          -> ByteString         -- ^ Request body.
          -> ByteString         -- ^ CONTENT_LENGTH bytes from the request 
                                --   body, or the empty string if there is no
                                --   CONTENT_LENGTH.
takeInput env req = 
    case len of
           Just l  -> BS.take l req
           Nothing -> BS.empty
     where len = lookup "CONTENT_LENGTH" env >>= maybeRead

-- | Decode multipart\/form-data input.
multipartDecode :: [(String,String)] -- ^ Content-type parameters
                -> ByteString        -- ^ Request body
                -> [(String,Input)]  -- ^ Input variables and values.
multipartDecode ps inp =
    case lookup "boundary" ps of
         Just b -> case parseMultipartBody b inp of
                        Just (MultiPart bs) -> map bodyPartToInput bs
                        Nothing -> [] -- FIXME: report parse error
         Nothing -> [] -- FIXME: report that there was no boundary

bodyPartToInput :: BodyPart -> (String,Input)
bodyPartToInput (BodyPart hs b) = 
    case getContentDisposition hs of
              Just (ContentDisposition "form-data" ps) -> 
                  (lookupOrNil "name" ps,
                   Input { value = b,
                           filename = lookup "filename" ps,
                           contentType = ctype })
              _ -> ("ERROR",simpleInput "ERROR") -- FIXME: report error
    where ctype = fromMaybe defaultInputType (getContentType hs)


--
-- * Utilities
--

mkMultiMap :: Ord a => [(a,b)] -> Map a [b]
mkMultiMap xs = Map.fromListWith (++) [(x,[y]) | (x,y) <- xs]

-- | Replace all instances of a value in a list by another value.
replace :: Eq a =>
           a   -- ^ Value to look for
        -> a   -- ^ Value to replace it with
        -> [a] -- ^ Input list
        -> [a] -- ^ Output list
replace x y = map (\z -> if z == x then y else z)

maybeRead :: Read a => String -> Maybe a
maybeRead = fmap fst . listToMaybe . reads

-- | Get the value of an environment variable, or
--   the empty string of the variable is not set.
getEnvOrNil :: String -> IO String
getEnvOrNil v = getEnv v `Prelude.catch` const (return "")

-- | Same as 'lookup' specialized to strings, but 
--   returns the empty string if lookup fails.
lookupOrNil :: String -> [(String,String)] -> String
lookupOrNil n = fromMaybe "" . lookup n

