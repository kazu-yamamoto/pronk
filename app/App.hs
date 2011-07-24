{-# LANGUAGE BangPatterns, DeriveDataTypeable, OverloadedStrings,
    RecordWildCards #-}

module Main (main) where

import Control.Applicative ((<$>))
import Control.DeepSeq (rnf)
import Control.Exception (evaluate, finally)
import Control.Monad (forM_, unless)
import Data.Aeson ((.=), encode, object)
import Data.Maybe (catMaybes)
import Data.Text (Text, pack)
import Data.Text.Encoding (encodeUtf8)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Network.HTTP.LoadTest (NetworkError(..), Req(..))
import Network.HTTP.LoadTest.Analysis (analyseBasic, analyseFull)
import Network.HTTP.LoadTest.Environment (environment)
import Network.HTTP.LoadTest.Report (buildTime, reportBasic, reportEvents,
                                     reportFull)
import Network.Socket (withSocketsDo)
import System.CPUTime (getCPUTime)
import System.Console.CmdArgs
import System.Exit (ExitCode(ExitFailure), exitWith)
import System.IO (hPutStrLn, stderr, stdout)
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy as L
import qualified Data.Text.Format as T
import qualified Network.HTTP.Enumerator as E
import qualified Network.HTTP.LoadTest as LoadTest

data Args = Args {
      concurrency :: Int
    , method :: Maybe String
    , num_requests :: Int
    , requests_per_second :: Double
    , timeout :: Double
    , url :: String

    , from_file :: Maybe FilePath
    , literal :: Maybe String

    , bootstrap :: Bool
    , json :: Maybe FilePath
    } deriving (Eq, Show, Typeable, Data)

defaultArgs :: Args
defaultArgs = Args {
                concurrency = 1
                &= groupname "Load testing"
                &= help "Number of requests to issue concurrently"
              , method = def &= typ "METHOD"
                &= help "HTTP method to use (GET, POST, ...)"
              , num_requests = 1
                &= help "Total number of requests to issue"
              , requests_per_second = def
                &= help "Maximum request rate to sustain"
              , timeout = 60 &= typ "SECS"
                &= help "Time to wait before killing a connection"
              , url = def &= argPos 0

              , from_file = def &= typ "FILE"
                &= groupname "Supplying a request body"
                &= help "Use file contents as request body"
              , literal = def &= typ "STRING"
                &= help "Use given text as request body"

              , bootstrap = def
                &= groupname "Analysis of results"
                &= help "Statistically robust analysis of results"
              , json = def &= typ "FILE"
                &= help "Save analysis in JSON format"
              } &= verbosity

fromArgs :: Args -> E.Request IO -> LoadTest.Config
fromArgs Args{..} req =
    LoadTest.Config {
      LoadTest.concurrency = concurrency
    , LoadTest.numRequests = num_requests
    , LoadTest.requestsPerSecond = requests_per_second
    , LoadTest.timeout = timeout
    , LoadTest.request = Req req
    }

main :: IO ()
main = withSocketsDo $ do
  as@Args{..} <- cmdArgs $ defaultArgs &= program "pronk"
  validateArgs as
  cfg <- fromArgs as <$> createRequest as
  run <- timed "tested" $ LoadTest.run cfg
  case run of
    Left [NetworkError err] ->
      T.hprint stderr "Error: {}\n" [show err] >> exitWith (ExitFailure 1)
    Left errs -> do
      T.hprint stderr "Errors:\n" ()
      forM_ errs $ \(NetworkError err) -> T.hprint stderr "  {}\n" [show err]
      exitWith (ExitFailure 1)
    Right results -> do
      whenNormal $ T.print "analysing results\n" ()
      analysis <- timed "analysed" $ do
                    r <- if bootstrap
                         then Right <$> analyseFull results
                         else return . Left . analyseBasic $ results
                    evaluate $ rnf r
                    return r
      env <- environment
      let dump = object [ "config" .= cfg
                        , "environment" .= env
                        , "analysis" .= analysis ]
      case json of
        Just "-" -> L.putStrLn (encode dump)
        Just f   -> L.writeFile f (encode dump)
        _        -> return ()
      whenNormal $ do
        reportEvents stdout results
        either (reportBasic stdout) (reportFull whenLoud stdout)
               analysis

validateArgs :: Args -> IO ()
validateArgs Args{..} = do
  let p !? what | p         = Nothing
                | otherwise = Just what
      infix 1 !?
      problems = catMaybes [
         concurrency > 0 !? "--concurrency must be positive"
       , num_requests > 0 !? "--num-requests must be positive"
       , requests_per_second >= 0 !? "--requests-per-second cannot be negative"
       , timeout >= 0 !? "--timeout cannot be negative"
       ]
  forM_ problems $ hPutStrLn stderr . ("Error: " ++)
  unless (null problems) $ exitWith (ExitFailure 1)

createRequest :: Args -> IO (E.Request IO)
createRequest Args{..} = do
  req0 <- E.parseUrl url
  let check Nothing       = return "POST"
      check (Just "POST") = return "POST"
      check (Just "PUT")  = return "PUT"
      check _      = do
        hPutStrLn stderr "Error: only POST or PUT may have a body"
        exitWith (ExitFailure 1)
  case (from_file, literal) of
    (Nothing,Nothing) -> return req0 { E.method = maybe "GET" B.pack method }
    (Just f,Nothing) -> do
      s <- B.readFile f
      meth <- check method
      return req0 { E.method = meth
                  , E.requestBody = E.RequestBodyBS s }
    (Nothing,Just s) -> do
      meth <- check method
      return req0 { E.method = meth
                  , E.requestBody = E.RequestBodyBS . encodeUtf8 . pack $ s
                  }
    _ -> do
      hPutStrLn stderr "Error: --literal and --from-file are mutually exclusive"
      exitWith (ExitFailure 1)

timed :: Text -> IO a -> IO a
timed desc act = do
  startCPU <- getCPUTime
  startWall <- getPOSIXTime
  act `finally` do
    endCPU <- getCPUTime
    endWall <- getPOSIXTime
    let elapsedCPU  = fromIntegral (endCPU - startCPU) / 1e12
        elapsedWall = realToFrac $ endWall - startWall
        ratio = elapsedCPU / elapsedWall
    whenNormal $
      -- Try to work around the 64-bit Mac getCPUTime bug
      -- http://hackage.haskell.org/trac/ghc/ticket/4970
      if ratio > 0 && ratio < 32
      then T.print "{} in {} ({}% CPU)\n"
               (desc, buildTime 4 elapsedWall,
                T.fixed 1 $ 100 * elapsedCPU / elapsedWall)
      else T.print "{} in {}\n"
               (desc, buildTime 4 elapsedWall)
