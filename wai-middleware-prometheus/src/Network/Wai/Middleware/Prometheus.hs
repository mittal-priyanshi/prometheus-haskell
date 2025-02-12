-- | This module provides "Network.Wai" middlware for exporting "Prometheus"
-- metrics and for instrumenting WAI applications.
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Network.Wai.Middleware.Prometheus
  ( prometheus
  , PrometheusSettings(..)
  , Default.def
  , instrumentHandlerValue
  , instrumentHandlerValueWithFilter
  , ignoreRawResponses
  , instrumentApp
  , instrumentIO
  , observeSeconds
  ) where

import qualified Data.Default as Default
import Data.Maybe (fromMaybe)
import Data.Ratio ((%))
import Data.List (intersperse)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Lazy as TL
import Data.Text.Encoding (decodeUtf8)
import Data.Text.Lazy.Encoding (encodeUtf8)
import qualified Network.HTTP.Types as HTTP
import qualified Network.Wai as Wai
import qualified Network.Wai.Internal as Wai (Response(ResponseRaw))
import qualified Prometheus as Prom
import System.Clock (Clock(..), TimeSpec, diffTimeSpec, getTime, toNanoSecs)


-- | Settings that control the behavior of the Prometheus middleware.
data PrometheusSettings = PrometheusSettings {
        prometheusEndPointPrefix             :: Text
        -- ^ The path that will be used for exporting metrics. The default value
        -- is ["metrics"] which corresponds to the path /metrics.
    }

instance Default.Default PrometheusSettings where
    def = PrometheusSettings {
        prometheusEndPointPrefix = "metrics"
    }

{-# NOINLINE requestLatency #-}
requestLatency :: Prom.Vector Prom.Label3 Prom.Histogram
requestLatency =
  Prom.unsafeRegister "wai/requests"
    $ Prom.vector ("handler", "method", "status_code")
    $ Prom.histogram info Prom.defaultBuckets
  where info = Prom.Info "http_request_duration_seconds"
                          "The HTTP request latencies in seconds."

-- | This function is used to populate the @handler@ label of all Prometheus metrics recorded by this library.
--
-- If you use this function you will likely want to override the default value
-- of 'prometheusInstrumentApp' to be false so that your app does not get double
-- instrumented.
--
-- WARNING: If you have 'ResponseRaw' values in your API, consider using
-- @instrumentHandlerValueWithFilter ignoreRawResponses@ instead.
instrumentHandlerValue ::
     (Wai.Request -> Text) -- ^ The function used to derive the "handler" value in Prometheus
  -> Wai.Application -- ^ The app to instrument
  -> Wai.Application -- ^ The instrumented app
instrumentHandlerValue = instrumentHandlerValueWithFilter Just

-- | A more flexible variant of 'instrumentHandlerValue'.  The filter can change some
-- responses, or drop others entirely.
instrumentHandlerValueWithFilter ::
     (Wai.Response -> Maybe Wai.Response) -- ^ Response filter
  -> (Wai.Request -> Text) -- ^ The function used to derive the "handler" value in Prometheus
  -> Wai.Application -- ^ The app to instrument
  -> Wai.Application -- ^ The instrumented app
instrumentHandlerValueWithFilter resFilter f app req respond = do
  start <- getTime Monotonic
  app req $ \res -> do
    case resFilter res of
      Nothing -> return ()
      Just res' -> do
        end <- getTime Monotonic
        let method = Just $ decodeUtf8 (Wai.requestMethod req)
        let status = Just $ T.pack (show (HTTP.statusCode (Wai.responseStatus res')))
        observeSeconds (f req) method status start end
    respond res

-- | 'Wai.ResponseRaw' values have two parts: an action that can be executed to construct a
-- 'Wai.Response', and a pure "backup" 'Wai.Response' in case the computation fails.  Since
-- the pure selectors like 'Wai.responseStatus' are pure and it makes no sense for them to
-- call the action, they just go to the backup response and pull the value from that:
--
-- @
-- responseStatus (ResponseRaw ...
--   (ResponseBuilder (Status 500 "blargh") ... ...))
-- == Status {statusCode = 500, statusMessage = "blargh"}
-- @
--
-- This is often not what you want.  For example, if you have an end-point for establishing
-- websocket connections that has a backup response with status 5xx, every websocket
-- connection request, whether successful or not, will register as an internal server error.
--
-- This helper therefore filters out all raw requests so they won't create any metrics.  Use
-- together with 'instrumentHandlerValueWithFilter'.
ignoreRawResponses :: Wai.Response -> Maybe Wai.Response
ignoreRawResponses (Wai.ResponseRaw {}) = Nothing
ignoreRawResponses res = Just res

-- | Instrument a WAI app with the default WAI metrics.
--
-- If you use this function you will likely want to override the default value
-- of 'prometheusInstrumentApp' to be false so that your app does not get double
-- instrumented.
instrumentApp ::
     Text -- ^ The label used to identify this app
  -> Wai.Application -- ^ The app to instrument
  -> Wai.Application -- ^ The instrumented app
instrumentApp handler app req respond =
  instrumentHandlerValue (const handler) app req respond

-- | Instrument an IO action with timing metrics. This function can be used if
-- you would like to get more fine grained metrics, for instance this can be
-- used to instrument individual end points.
--
-- If you use this function you will likely want to override the default value
-- of 'prometheusInstrumentApp' to be false so that your app does not get double
-- instrumented.
instrumentIO :: Text    -- ^ The label used to identify this IO operation
             -> IO a    -- ^ The IO action to instrument
             -> IO a    -- ^ The instrumented app
instrumentIO label io = do
    start  <- getTime Monotonic
    result <- io
    end    <- getTime Monotonic
    observeSeconds label Nothing Nothing start end
    return result

-- | Record an event to the middleware metric.
observeSeconds :: Text         -- ^ handler label
               -> Maybe Text   -- ^ method
               -> Maybe Text   -- ^ status
               -> TimeSpec     -- ^ start time
               -> TimeSpec     -- ^ end time
               -> IO ()
observeSeconds handler method status start end = do
    let latency :: Double
        latency = fromRational $ toRational (toNanoSecs (end `diffTimeSpec` start) % 1000000000)
    Prom.withLabel requestLatency
                   (handler, fromMaybe "" method, fromMaybe "" status)
                   (flip Prom.observe latency)

-- | Expose Prometheus metrics and instrument an application with some basic
-- metrics (e.g. request latency).
prometheus :: PrometheusSettings -> Wai.Middleware
prometheus PrometheusSettings{..} app req respond =
    if Wai.requestMethod req == HTTP.methodGet
    then
      case Wai.pathInfo req of
        (prometheusEndPointPrefix : xs) ->
          case xs of
            [] -> respondWithAvailableRoutes respond
            xss -> respondWithMetrics respond xss
        _ -> app req respond
    else
        app req respond

respondWithAvailableRoutes :: (Wai.Response -> IO Wai.ResponseReceived) -> IO Wai.ResponseReceived
respondWithAvailableRoutes respond = do
  ns <- Prom.availableNamespaces
  respond $
    Wai.responseLBS HTTP.status200 headers $
      encodeUtf8 $
        TL.fromStrict (T.unlines ns)
  where
    headers = [(HTTP.hContentType, "text/plain; version=0.0.4")]

respondWithMetrics :: (Wai.Response -> IO Wai.ResponseReceived)
                   -> [Text]
                   -> IO Wai.ResponseReceived
respondWithMetrics respond ns = do
    metrics <- Prom.exportMetricsAsText (T.concat $ intersperse "/" ns)
    respond $ Wai.responseLBS HTTP.status200 headers metrics
    where
        headers = [(HTTP.hContentType, "text/plain; version=0.0.4")]
