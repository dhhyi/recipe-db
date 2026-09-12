{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Exception (SomeException, displayException, throwIO, try)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson (object, (.=))
import qualified Data.ByteString.Base16 as B16
import qualified Data.ByteString.Base64 as B64
import qualified Data.ByteString.Char8 as BC
import qualified Data.ByteString.Lazy as BL
import Data.Char (toLower)
import Data.Maybe (fromMaybe)
import qualified Crypto.Hash.MD5 as MD5
import qualified Data.Text.Lazy as TL
import Network.HTTP.Client
  ( HttpException (HttpExceptionRequest),
    HttpExceptionContent (StatusCodeException),
    Manager,
    httpLbs,
    newManager,
    parseRequest,
    responseBody,
    responseStatus,
  )
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Network.HTTP.Types.Status (Status, status204, status400, status500, statusCode, statusIsSuccessful)
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import Web.Scotty (ActionM, ScottyM, get, json, queryParamMaybe, scotty, setHeader, status, text)

-- extension -> mime type, mirroring the previous Perl implementation's table
extToMime :: String -> String
extToMime ext = case map toLower ext of
  "png" -> "image/png"
  "jpg" -> "image/jpeg"
  "jpeg" -> "image/jpeg"
  "gif" -> "image/gif"
  "bmp" -> "image/bmp"
  "webp" -> "image/webp"
  _ -> "image/x-icon"

fileExt :: String -> String
fileExt url = reverse (takeWhile (/= '.') (reverse url))

md5Hex :: String -> String
md5Hex = BC.unpack . B16.encode . MD5.hash . BC.pack

fetchAndEncode :: Manager -> String -> IO String
fetchAndEncode manager url = do
  req <- parseRequest url
  resp <- httpLbs req manager
  if statusIsSuccessful (responseStatus resp)
    then do
      let encoded = BC.unpack (B64.encode (BL.toStrict (responseBody resp)))
      return ("data:" ++ extToMime (fileExt url) ++ ";base64," ++ encoded)
    else throwIO (HttpExceptionRequest req (StatusCodeException (fmap (const ()) resp) mempty))

-- RFC 9457 Problem Details body, mirroring the previous Perl implementation's error shape.
problem :: Status -> TL.Text -> TL.Text -> TL.Text -> ActionM ()
problem st title detail code = do
  status st
  json $
    object
      [ "type" .= ("about:blank" :: TL.Text),
        "title" .= title,
        "status" .= statusCode st,
        "detail" .= detail,
        "code" .= code
      ]
  setHeader "Content-Type" "application/problem+json"

app :: FilePath -> Manager -> ScottyM ()
app db manager = do
  get "/health" $ status status204

  get "/image-inline/" $ do
    maybeUrl <- queryParamMaybe "url"
    case maybeUrl of
      Nothing -> problem status400 "Bad Request" "Missing url parameter" "missing-query-param"
      Just url -> do
        let urlStr = TL.unpack url
            cacheFile = db </> md5Hex urlStr
        cached <- liftIO $ doesFileExist cacheFile
        if cached
          then do
            content <- liftIO $ readFile cacheFile
            setHeader "Content-Type" "text/plain"
            text (TL.pack content)
          else do
            result <- liftIO (try (fetchAndEncode manager urlStr) :: IO (Either SomeException String))
            case result of
              Left err ->
                problem status500 "Internal Server Error" (TL.pack (displayException err)) "fetch-error"
              Right dataUri -> do
                liftIO $ writeFile cacheFile dataUri
                setHeader "Content-Type" "text/plain"
                text (TL.pack dataUri)

main :: IO ()
main = do
  db <- fromMaybe "db" <$> lookupEnv "DATA_LOCATION"
  createDirectoryIfMissing True db
  manager <- newManager tlsManagerSettings
  scotty 3000 (app db manager)
