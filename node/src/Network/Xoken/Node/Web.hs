{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Network.Xoken.Node.Web where

import Codec.Compression.GZip as GZ
import Conduit hiding (runResourceT)
import Control.Applicative ((<|>))
import Control.Arrow
import Control.Exception ()
import Control.Monad
import Control.Monad.Logger
import Control.Monad.Loops
import Control.Monad.Reader (MonadReader, ReaderT)
import qualified Control.Monad.Reader as R
import Control.Monad.Trans.Maybe
import Data.Aeson (ToJSON(..), (.=), object)
import Data.Aeson as A
import Data.Aeson.Encoding (encodingToLazyByteString, fromEncoding)
import qualified Data.Binary as DB (encode)
import Data.Bits
import qualified Data.ByteString as B
import Data.ByteString.Builder
import qualified Data.ByteString.Lazy as L
import qualified Data.ByteString.Lazy.Char8 as C
import Data.Word

import qualified Data.ByteString.UTF8 as BSU (toString)

import Data.ByteString.Base64 as B64
import Data.ByteString.Base64.Lazy as B64L

--import qualified Data.ByteString.Char8 as BSC (pack, unpack)
--import Data.ByteString.Lazy.UTF8 as BLU (pack, unpack)
import Data.Char
import Data.Default
import Data.Foldable
import Data.Function
import qualified Data.HashMap.Strict as H
import Data.Int
import Data.List
import qualified Data.Map.Strict as M
import Data.Maybe
import Data.Serialize as Serialize
import Data.String.Conversions
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Data.Text.Lazy as T.Lazy
import Data.Time.Clock
import Data.Vector (Vector, (!), cons)
import qualified Data.Vector as V
import Data.Version
import Data.Word
import Database.RocksDB as R
import GHC.Generics
import NQE
import Network.HTTP.Types
import Network.Simple.TCP as ST
import Network.Socket
import Network.Wai
import Network.Wai.Handler.Warp
import Network.Xoken.Node.Data
import Network.Xoken.Node.Data.Cached
import Network.Xoken.Node.Messages
import qualified Paths_xoken_node as P
import Text.Printf
import Text.Read (readMaybe)
import UnliftIO
import UnliftIO.Resource
import Web.Scotty.Internal.Types (ActionT(ActionT, runAM))
import qualified Web.Scotty.Trans as S
    ( Parsable
    , ScottyError
    , body
    , defaultHandler
    , finish
    , get
    , header
    , middleware
    , next
    , notFound
    , param
    , parseParam
    , post
    , raise
    , raw
    , rescue
    , scottyT
    , setHeader
    , showError
    , status
    , stream
    , stringError
    , text
    )
import Xoken
import Xoken.P2P

type WebT m = ActionT Except (ReaderT LayeredDB m)

type DeriveAddrs = XPubKey -> KeyIndex -> [(Address, PubKey, KeyIndex)]

type Offset = Word32

type Limit = Word32

data Except
    = ThingNotFound
    | ServerError
    | BadRequest
    | UserError String
    | StringError String
    deriving (Eq)

instance Show Except where
    show ThingNotFound = "not found"
    show ServerError = "you made me kill a unicorn"
    show BadRequest = "bad request"
    show (UserError s) = s
    show (StringError s) = "you killed the dragon with your bare hands"

instance Exception Except

instance S.ScottyError Except where
    stringError = StringError
    showError = T.Lazy.pack . show

instance ToJSON Except where
    toJSON e = object ["error" .= T.pack (show e)]

instance JsonSerial Except where
    jsonSerial _ = toEncoding
    jsonValue _ = toJSON

instance BinSerial Except where
    binSerial _ ex =
        case ex of
            ThingNotFound -> putWord8 0
            ServerError -> putWord8 1
            BadRequest -> putWord8 2
            UserError s -> putWord8 3 >> Serialize.put s
            StringError s -> putWord8 4 >> Serialize.put s
    binDeserial _ =
        getWord8 >>= \case
            0 -> return ThingNotFound
            1 -> return ServerError
            2 -> return BadRequest
            3 -> UserError <$> Serialize.get
            4 -> StringError <$> Serialize.get

data RPCReq =
    RPCReq
        { rPCReq_key :: Int
        , rPCReq_request :: T.Text
        }
    deriving (Show, Eq)

data RPCResp =
    RPCResp
        { rPCResp_key :: Int
        , rPCResp_response :: T.Text
        }
    deriving (Show, Eq)

data RPCCall =
    RPCCall
        { request :: RPCReq
        , response :: MVar RPCResp
        }

data PubSubMsg
    = Subscribe1
          { topic :: String
          }
    | Publish1
          { topic :: String
          , message :: String
          }
    | Notify1
          { topic :: String
          , message :: String
          }

data IPCMessage =
    IPCMessage
        { msgid :: Int
        , mtype :: String
        , params :: M.Map String String
        }
    deriving (Show, Generic)

data IPCServiceHandler =
    IPCServiceHandler
        { rpcQueue :: TChan RPCCall
        , pubSubQueue :: TChan PubSubMsg
        }

newIPCServiceHandler :: IO IPCServiceHandler
newIPCServiceHandler = do
    rpcQ <- atomically $ newTChan
    psQ <- atomically $ newTChan
    return $ IPCServiceHandler rpcQ psQ

instance ToJSON IPCMessage

instance FromJSON IPCMessage

data WebConfig =
    WebConfig
        { webPort :: !Int
        , webNetwork :: !Network
        , webDB :: !LayeredDB
        , webPublisher :: !(Publisher StoreEvent)
        , webStore :: !Store
        , webMaxLimits :: !MaxLimits
        , webReqLog :: !Bool
        }

data MaxLimits =
    MaxLimits
        { maxLimitCount :: !Word32
        , maxLimitFull :: !Word32
        , maxLimitOffset :: !Word32
        , maxLimitDefault :: !Word32
        , maxLimitGap :: !Word32
        }
    deriving (Eq, Show)

instance S.Parsable BlockHash where
    parseParam = maybe (Left "could not decode block hash") Right . hexToBlockHash . cs

instance S.Parsable TxHash where
    parseParam = maybe (Left "could not decode tx hash") Right . hexToTxHash . cs

data StartParam
    = StartParamHash
          { startParamHash :: !Hash256
          }
    | StartParamHeight
          { startParamHeight :: !Word32
          }
    | StartParamTime
          { startParamTime :: !UnixTime
          }

instance S.Parsable StartParam where
    parseParam s = maybe (Left "could not decode start") Right (h <|> g <|> t)
      where
        h = do
            x <- fmap B.reverse (decodeHex (cs s)) >>= eitherToMaybe . Serialize.decode
            return StartParamHash {startParamHash = x}
        g = do
            x <- readMaybe (cs s) :: Maybe Integer
            guard $ 0 <= x && x <= 1230768000
            return StartParamHeight {startParamHeight = fromIntegral x}
        t = do
            x <- readMaybe (cs s)
            guard $ x > 1230768000
            return StartParamTime {startParamTime = x}

instance MonadIO m => StoreRead (WebT m) where
    isInitialized = lift isInitialized
    getBestBlock = lift getBestBlock
    getBlocksAtHeight = lift . getBlocksAtHeight
    getBlock = lift . getBlock
    getTxData = lift . getTxData
    getSpender = lift . getSpender
    getSpenders = lift . getSpenders
    getOrphanTx = lift . getOrphanTx
    getUnspent = lift . getUnspent
    getBalance = lift . getBalance

askDB :: Monad m => WebT m LayeredDB
askDB = lift R.ask

runStream :: MonadUnliftIO m => s -> ReaderT s (ResourceT m) a -> m a
runStream s f = runResourceT (R.runReaderT f s)

defHandler :: Monad m => Network -> Except -> WebT m ()
defHandler net e = do
    proto <- setupBin
    case e of
        ThingNotFound -> S.status status404
        BadRequest -> S.status status400
        UserError _ -> S.status status400
        StringError _ -> S.status status400
        ServerError -> S.status status500
    protoSerial net proto e

maybeSerial ::
       (Monad m, JsonSerial a, BinSerial a)
    => Network
    -> Bool -- ^ binary
    -> Maybe a
    -> WebT m ()
maybeSerial _ _ Nothing = S.raise ThingNotFound
maybeSerial net proto (Just x) = S.raw $ serialAny net proto x

protoSerial :: (Monad m, JsonSerial a, BinSerial a) => Network -> Bool -> a -> WebT m ()
protoSerial net proto = S.raw . serialAny net proto

scottyBestBlock :: MonadLoggerIO m => Network -> WebT m ()
scottyBestBlock net = do
    cors
    n <- parseNoTx
    proto <- setupBin
    res <-
        runMaybeT $ do
            h <- MaybeT getBestBlock
            b <- MaybeT $ getBlock h
            return $ pruneTx n b
    maybeSerial net proto res

scottyBlock :: MonadLoggerIO m => Network -> WebT m ()
scottyBlock net = do
    cors
    block <- S.param "block"
    n <- parseNoTx
    proto <- setupBin
    res <-
        runMaybeT $ do
            b <- MaybeT $ getBlock block
            return $ pruneTx n b
    maybeSerial net proto res

scottyBlockHeight :: (MonadLoggerIO m, MonadUnliftIO m) => Network -> WebT m ()
scottyBlockHeight net = do
    cors
    height <- S.param "height"
    n <- parseNoTx
    proto <- setupBin
    hs <- getBlocksAtHeight height
    db <- askDB
    S.stream $ \io flush' -> do
        runStream db . runConduit $ yieldMany hs .| concatMapMC getBlock .| mapC (pruneTx n) .| streamAny net proto io
        flush'

xGetBlockHeight :: (MonadLoggerIO m, MonadUnliftIO m, StoreRead m) => Network -> Word32 -> m (L.ByteString)
xGetBlockHeight net height = do
    hs <- getBlocksAtHeight height
    if length hs == 0
        then return $ C.pack "{}"
        else do
            res <- getBlock (hs !! 0)
            case res of
                Just b -> return $ jsonSerialiseAny net (b)
                Nothing -> return $ C.pack "{}"

xGetBlocksHeights :: (MonadLoggerIO m, MonadUnliftIO m, StoreRead m) => Network -> [Word32] -> m (L.ByteString)
xGetBlocksHeights net heights = do
    hs <- concat <$> mapM getBlocksAtHeight (nub heights)
    res <- mapM getBlock hs
    let ar = catMaybes res
    let x = jsonSerialiseAny net (ar)
    return (x)

scottyBlockHeights :: (MonadLoggerIO m, MonadUnliftIO m) => Network -> WebT m ()
scottyBlockHeights net = do
    cors
    heights <- S.param "heights"
    n <- parseNoTx
    proto <- setupBin
    bs <- concat <$> mapM getBlocksAtHeight (nub heights)
    db <- askDB
    S.stream $ \io flush' -> do
        runStream db . runConduit $
            yieldMany (nub heights) .| concatMapMC getBlocksAtHeight .| concatMapMC getBlock .| mapC (pruneTx n) .|
            streamAny net proto io
        flush'

scottyBlockLatest :: (MonadLoggerIO m, MonadUnliftIO m) => Network -> WebT m ()
scottyBlockLatest net = do
    cors
    n <- parseNoTx
    proto <- setupBin
    db <- askDB
    getBestBlock >>= \case
        Just h ->
            S.stream $ \io flush' -> do
                runStream db . runConduit $ f n h 100 .| streamAny net proto io
                flush'
        Nothing -> S.raise ThingNotFound
  where
    f n h 0 = return ()
    f n h i =
        lift (getBlock h) >>= \case
            Nothing -> return ()
            Just b -> do
                yield $ pruneTx n b
                if blockDataHeight b <= 0
                    then return ()
                    else f n (prevBlock (blockDataHeader b)) (i - 1)

scottyBlocks :: (MonadLoggerIO m, MonadUnliftIO m) => Network -> WebT m ()
scottyBlocks net = do
    cors
    blocks <- S.param "blocks"
    n <- parseNoTx
    proto <- setupBin
    db <- askDB
    S.stream $ \io flush' -> do
        runStream db . runConduit $
            yieldMany (nub blocks) .| concatMapMC getBlock .| mapC (pruneTx n) .| streamAny net proto io
        flush'

scottyMempool :: (MonadLoggerIO m, MonadUnliftIO m) => Network -> WebT m ()
scottyMempool net = do
    cors
    proto <- setupBin
    db <- askDB
    S.stream $ \io flush' -> do
        runStream db . runConduit $ getMempoolStream .| streamAny net proto io
        flush'

scottyTransaction :: MonadLoggerIO m => Network -> WebT m ()
scottyTransaction net = do
    cors
    txid <- S.param "txid"
    proto <- setupBin
    res <- getTransaction txid
    maybeSerial net proto res

scottyRawTransaction :: MonadLoggerIO m => Network -> WebT m ()
scottyRawTransaction net = do
    cors
    txid <- S.param "txid"
    proto <- setupBin
    res <- fmap transactionData <$> getTransaction txid
    maybeSerial net proto res

scottyTxAfterHeight :: MonadLoggerIO m => Network -> WebT m ()
scottyTxAfterHeight net = do
    cors
    txid <- S.param "txid"
    height <- S.param "height"
    proto <- setupBin
    res <- cbAfterHeight 10000 height txid
    protoSerial net proto res

scottyTransactions :: (MonadLoggerIO m, MonadUnliftIO m) => Network -> WebT m ()
scottyTransactions net = do
    cors
    txids <- S.param "txids"
    proto <- setupBin
    db <- askDB
    S.stream $ \io flush' -> do
        runStream db . runConduit $ yieldMany (nub txids) .| concatMapMC getTransaction .| streamAny net proto io
        flush'

scottyBlockTransactions :: (MonadLoggerIO m, MonadUnliftIO m) => Network -> WebT m ()
scottyBlockTransactions net = do
    cors
    h <- S.param "block"
    proto <- setupBin
    db <- askDB
    getBlock h >>= \case
        Just b ->
            S.stream $ \io flush' -> do
                runStream db . runConduit $
                    yieldMany (blockDataTxs b) .| concatMapMC getTransaction .| streamAny net proto io
                flush'
        Nothing -> S.raise ThingNotFound

scottyRawTransactions :: (MonadLoggerIO m, MonadUnliftIO m) => Network -> WebT m ()
scottyRawTransactions net = do
    cors
    txids <- S.param "txids"
    proto <- setupBin
    db <- askDB
    S.stream $ \io flush' -> do
        runStream db . runConduit $
            yieldMany (nub txids) .| concatMapMC getTransaction .| mapC transactionData .| streamAny net proto io
        flush'

scottyRawBlockTransactions :: (MonadLoggerIO m, MonadUnliftIO m) => Network -> WebT m ()
scottyRawBlockTransactions net = do
    cors
    h <- S.param "block"
    proto <- setupBin
    db <- askDB
    getBlock h >>= \case
        Just b ->
            S.stream $ \io flush' -> do
                runStream db . runConduit $
                    yieldMany (blockDataTxs b) .| concatMapMC getTransaction .| mapC transactionData .|
                    streamAny net proto io
                flush'
        Nothing -> S.raise ThingNotFound

scottyAddressTxs :: (MonadLoggerIO m, MonadUnliftIO m) => Network -> MaxLimits -> Bool -> WebT m ()
scottyAddressTxs net limits full = do
    cors
    a <- parseAddress net
    s <- getStart
    o <- getOffset limits
    l <- getLimit limits full
    proto <- setupBin
    db <- askDB
    S.stream $ \io flush' -> do
        runStream db . runConduit $ f proto o l s a io
        flush'
  where
    f proto o l s a io
        | full = getAddressTxsFull o l s a .| streamAny net proto io
        | otherwise = getAddressTxsLimit o l s a .| streamAny net proto io

scottyAddressesTxs :: (MonadLoggerIO m, MonadUnliftIO m) => Network -> MaxLimits -> Bool -> WebT m ()
scottyAddressesTxs net limits full = do
    cors
    as <- parseAddresses net
    s <- getStart
    l <- getLimit limits full
    proto <- setupBin
    db <- askDB
    S.stream $ \io flush' -> do
        runStream db . runConduit $ f proto l s as io
        flush'
  where
    f proto l s as io
        | full = getAddressesTxsFull l s as .| streamAny net proto io
        | otherwise = getAddressesTxsLimit l s as .| streamAny net proto io

scottyAddressUnspent :: (MonadLoggerIO m, MonadUnliftIO m) => Network -> MaxLimits -> WebT m ()
scottyAddressUnspent net limits = do
    cors
    a <- parseAddress net
    s <- getStart
    o <- getOffset limits
    l <- getLimit limits False
    proto <- setupBin
    db <- askDB
    S.stream $ \io flush' -> do
        runStream db . runConduit $ getAddressUnspentsLimit o l s a .| streamAny net proto io
        flush'

scottyAddressesUnspent :: (MonadLoggerIO m, MonadUnliftIO m) => Network -> MaxLimits -> WebT m ()
scottyAddressesUnspent net limits = do
    cors
    as <- parseAddresses net
    s <- getStart
    l <- getLimit limits False
    proto <- setupBin
    db <- askDB
    S.stream $ \io flush' -> do
        runStream db . runConduit $ getAddressesUnspentsLimit l s as .| streamAny net proto io
        flush'

scottyAddressBalance :: MonadLoggerIO m => Network -> WebT m ()
scottyAddressBalance net = do
    cors
    a <- parseAddress net
    proto <- setupBin
    res <-
        getBalance a >>= \case
            Just b -> return b
            Nothing ->
                return
                    Balance
                        { balanceAddress = a
                        , balanceAmount = 0
                        , balanceUnspentCount = 0
                        , balanceZero = 0
                        , balanceTxCount = 0
                        , balanceTotalReceived = 0
                        }
    protoSerial net proto res

scottyAddressesBalances :: (MonadLoggerIO m, MonadUnliftIO m) => Network -> WebT m ()
scottyAddressesBalances net = do
    cors
    as <- parseAddresses net
    proto <- setupBin
    let f a Nothing =
            Balance
                { balanceAddress = a
                , balanceAmount = 0
                , balanceUnspentCount = 0
                , balanceZero = 0
                , balanceTxCount = 0
                , balanceTotalReceived = 0
                }
        f _ (Just b) = b
    db <- askDB
    S.stream $ \io flush' -> do
        runStream db . runConduit $ yieldMany as .| mapMC (\a -> f a <$> getBalance a) .| streamAny net proto io
        flush'

scottyXpubBalances :: (MonadUnliftIO m, MonadLoggerIO m) => Network -> MaxLimits -> WebT m ()
scottyXpubBalances net max_limits = do
    cors
    xpub <- parseXpub net
    proto <- setupBin
    derive <- parseDeriveAddrs net
    db <- askDB
    S.stream $ \io flush' -> do
        runStream db . runConduit $ xpubBals max_limits derive xpub .| streamAny net proto io
        flush'

scottyXpubTxs :: (MonadLoggerIO m, MonadUnliftIO m) => Network -> MaxLimits -> Bool -> WebT m ()
scottyXpubTxs net limits full = do
    cors
    x <- parseXpub net
    s <- getStart
    l <- getLimit limits full
    derive <- parseDeriveAddrs net
    proto <- setupBin
    db <- askDB
    as <- liftIO . runStream db . runConduit $ xpubBals limits derive x .| mapC (balanceAddress . xPubBal) .| sinkList
    S.stream $ \io flush' -> do
        runStream db . runConduit $ f proto l s as io
        flush'
  where
    f proto l s as io
        | full = getAddressesTxsFull l s as .| streamAny net proto io
        | otherwise = getAddressesTxsLimit l s as .| streamAny net proto io

scottyXpubUnspents :: (MonadLoggerIO m, MonadUnliftIO m) => Network -> MaxLimits -> WebT m ()
scottyXpubUnspents net limits = do
    cors
    x <- parseXpub net
    proto <- setupBin
    s <- getStart
    l <- getLimit limits False
    derive <- parseDeriveAddrs net
    db <- askDB
    S.stream $ \io flush' -> do
        runStream db . runConduit $ xpubUnspentLimit net limits l s derive x .| streamAny net proto io
        flush'

scottyXpubSummary :: (MonadLoggerIO m, MonadUnliftIO m) => Network -> MaxLimits -> WebT m ()
scottyXpubSummary net max_limits = do
    cors
    x <- parseXpub net
    derive <- parseDeriveAddrs net
    proto <- setupBin
    db <- askDB
    res <- liftIO . runStream db $ xpubSummary max_limits derive x
    protoSerial net proto res

scottyPostTx :: (MonadUnliftIO m, MonadLoggerIO m) => Network -> Store -> Publisher StoreEvent -> WebT m ()
scottyPostTx net st pub = do
    cors
    proto <- setupBin
    b <- S.body
    let bin = eitherToMaybe . Serialize.decode
        hex = bin <=< decodeHex . cs . C.filter (not . isSpace)
    tx <-
        case hex b <|> bin (L.toStrict b) of
            Nothing -> S.raise $ UserError "decode tx fail"
            Just x -> return x
    lift (publishTx net pub st tx) >>= \case
        Right () -> do
            protoSerial net proto (TxId (txHash tx))
        Left e -> do
            case e of
                PubNoPeers -> S.status status500
                PubTimeout -> S.status status500
                PubPeerDisconnected -> S.status status500
                PubReject _ -> S.status status400
            protoSerial net proto (UserError (show e))
            S.finish

scottyDbStats :: MonadLoggerIO m => WebT m ()
scottyDbStats = do
    cors
    LayeredDB {layeredDB = BlockDB {blockDB = db}} <- askDB
    stats <- lift (getProperty db Stats)
    case stats of
        Nothing -> do
            S.text "Could not get stats"
        Just txt -> do
            S.text $ cs txt

scottyEvents :: (MonadLoggerIO m, MonadUnliftIO m) => Network -> Publisher StoreEvent -> WebT m ()
scottyEvents net pub = do
    cors
    proto <- setupBin
    S.stream $ \io flush' ->
        withSubscription pub $ \sub ->
            forever $
            flush' >> receive sub >>= \se -> do
                let me =
                        case se of
                            StoreBestBlock block_hash -> Just (EventBlock block_hash)
                            StoreMempoolNew tx_hash -> Just (EventTx tx_hash)
                            _ -> Nothing
                case me of
                    Nothing -> return ()
                    Just e ->
                        let bs =
                                serialAny net proto e <>
                                if proto
                                    then mempty
                                    else "\n"
                         in io (lazyByteString bs)

scottyPeers :: MonadLoggerIO m => Network -> Store -> WebT m ()
scottyPeers net st = do
    cors
    proto <- setupBin
    ps <- getPeersInformation (storeManager st)
    protoSerial net proto ps

scottyHealth :: (MonadLoggerIO m, MonadUnliftIO m) => Network -> Store -> WebT m ()
scottyHealth net st = do
    cors
    proto <- setupBin
    h <- lift $ healthCheck net (storeManager st) (storeChain st)
    when (not (healthOK h) || not (healthSynced h)) $ S.status status503
    protoSerial net proto h

handleRPCReqResp :: (TChan RPCCall) -> MVar Socket -> Int -> String -> IO ()
handleRPCReqResp rpcQ sockMVar mid encReq = do
    printf "handleRPCReqResp(%d, %s)\n" mid (show encReq)
    resp <- newEmptyMVar
    let rpcCall = RPCCall (RPCReq mid (T.pack encReq)) (resp)
    atomically $ writeTChan (rpcQ) rpcCall
    rpcResp <- (readMVar resp)
    let resp = T.unpack (rPCResp_response rpcResp)
    let body = A.encode (IPCMessage mid "RPC_RESP" (M.singleton "encResp" resp))
    let ma = L.length body
    let xa = Prelude.fromIntegral (ma) :: Int16
    connSock <- takeMVar sockMVar
    sendLazy connSock (DB.encode (xa :: Int16))
    sendLazy connSock (body)
    putMVar sockMVar connSock
    return ()

decodeIPCRequest :: IPCServiceHandler -> MVar Socket -> L.ByteString -> IO ()
decodeIPCRequest ipcSvcHandler sockMVar req = do
    let ipcReq = A.decode req :: Maybe IPCMessage
    case ipcReq of
        Just x -> do
            printf "Decoded (%s)\n" (show x)
            case (mtype x) of
                "RPC_REQ" -> do
                    case (M.lookup "encReq" (params x)) of
                        Just enc -> do
                            _ <- async (handleRPCReqResp (rpcQueue ipcSvcHandler) (sockMVar) (msgid x) (enc))
                            return ()
                        Nothing -> printf "Invalid payload.\n"
                "SUB_REQ" -> do
                    case (M.lookup "subject" (params x)) of
                        Just su
                            -- _ <- async (handleSubscribeReqResp sockMVar (pubSubQueue handler) (msgid x) su)
                         -> do
                            return ()
                        Nothing -> printf "Invalid payload.\n"
                "PUB_REQ" -> do
                    case (M.lookup "subject" (params x)) of
                        Just su -> do
                            case (M.lookup "S.body" (params x)) of
                                Just bdy
                                    -- _ <- async (handlePublishReqResp sockMVar (pubSubQueue handler) (msgid x) su bdy)
                                 -> do
                                    return ()
                                Nothing -> printf "Invalid payload.\n"
                        Nothing -> printf "Invalid payload.\n"
                __ -> printf "Invalid message type.\n"
        Nothing -> printf "Decode 'IPCMessage' failed.\n" (show ipcReq)

handleConnection :: IPCServiceHandler -> Socket -> IO ()
handleConnection ipcSvcHandler connSock = do
    continue <- liftIO $ newIORef True
    whileM_ (liftIO $ readIORef continue) $ do
        lenBytes <- ST.recv connSock 2
        case lenBytes of
            Just l -> do
                let lenPrefix = runGet getWord16be l -- Char8.readInt l
                case lenPrefix of
                    Right a -> do
                        payload <- ST.recv connSock (fromIntegral (toInteger a))
                        case payload of
                            Just y -> do
                                sockMVar <- newMVar connSock
                                decodeIPCRequest ipcSvcHandler sockMVar (L.fromStrict y)
                                return ()
                            Nothing -> printf "Payload read error\n"
                    Left _b -> printf "Length prefix corrupted.\n"
            Nothing -> do
                printf "Connection closed.\n"
                writeIORef continue False

setupIPCServer :: (MonadLoggerIO m, MonadUnliftIO m) => WebConfig -> IPCServiceHandler -> m ()
setupIPCServer config ipcSvcHandler = do
    req_logger <-
        if (webReqLog config)
            then Just <$> logIt
            else return Nothing
    liftIO $ printf "Starting TCP (IPC) server..."
    _ <-
        serve (Host "127.0.0.1") (show (webPort config)) $ \(connSock, remoteAddr) -> do
            putStrLn $ "TCP connection established from " ++ show remoteAddr
            handleConnection ipcSvcHandler connSock
    return ()

goGetResource :: (MonadLoggerIO m, MonadUnliftIO m) => LayeredDB -> RPCCall -> Network -> m ()
goGetResource ldb rpcCall net = do
    let ind = rPCReq_key (request rpcCall)
    let bs = C.pack $ T.unpack (rPCReq_request (request rpcCall))
    let jsonStr = GZ.decompress $ B64L.decodeLenient bs
    liftIO $ print (jsonStr)
    let rpcReq = A.decode jsonStr :: Maybe RPCRequest
    case rpcReq of
        Just x -> do
            liftIO $ printf "RPC: (%s)\n" (method x)
            runner <- askRunInIO
            case (method x) of
                "get_block_height" -> do
                    val <- liftIO $ (runner . withLayeredDB ldb) $ xGetBlockHeight net (height x)
                    let resp = BSU.toString $ B64.encode $ L.toStrict $ GZ.compress (val)
                    liftIO $ (putMVar (response rpcCall) (RPCResp ind (T.pack (resp))))
                "get_blocks_heights" -> do
                    val <- liftIO $ (runner . withLayeredDB ldb) $ xGetBlocksHeights net (heights x)
                    let resp = BSU.toString $ B64.encode $ L.toStrict $ GZ.compress (val)
                    liftIO $ (putMVar (response rpcCall) (RPCResp ind (T.pack (resp))))

loopRPC :: (MonadLoggerIO m, MonadUnliftIO m) => LayeredDB -> (TChan RPCCall) -> Network -> m ()
loopRPC ldb queue net =
    forever $ do
        item <- liftIO $ atomically $ (readTChan queue)
        async (goGetResource ldb item net)
        return ()

runWeb :: (MonadLoggerIO m, MonadUnliftIO m) => WebConfig -> m ()
runWeb WebConfig { webDB = db
                 , webPort = port
                 , webNetwork = net
                 , webStore = st
                 , webPublisher = pub
                 , webMaxLimits = limits
                 , webReqLog = reqlog
                 } = do
    req_logger <-
        if reqlog
            then Just <$> logIt
            else return Nothing
    runner <- askRunInIO
    S.scottyT (port + 1) (runner . withLayeredDB db) $ do
        case req_logger of
            Just m -> S.middleware m
            Nothing -> return ()
        S.defaultHandler (defHandler net)
        S.get "/block/best" $ scottyBestBlock net
        S.get "/block/:block" $ scottyBlock net
        S.get "/block/height/:height" $ scottyBlockHeight net
        S.get "/block/heights" $ scottyBlockHeights net
        S.get "/block/latest" $ scottyBlockLatest net
        S.get "/blocks" $ scottyBlocks net
        S.get "/mempool" $ scottyMempool net
        S.get "/transaction/:txid" $ scottyTransaction net
        S.get "/transaction/:txid/raw" $ scottyRawTransaction net
        S.get "/transaction/:txid/after/:height" $ scottyTxAfterHeight net
        S.get "/transactions" $ scottyTransactions net
        S.get "/transactions/raw" $ scottyRawTransactions net
        S.get "/transactions/block/:block" $ scottyBlockTransactions net
        S.get "/transactions/block/:block/raw" $ scottyRawBlockTransactions net
        S.get "/address/:address/transactions" $ scottyAddressTxs net limits False
        S.get "/address/:address/transactions/full" $ scottyAddressTxs net limits True
        S.get "/address/transactions" $ scottyAddressesTxs net limits False
        S.get "/address/transactions/full" $ scottyAddressesTxs net limits True
        S.get "/address/:address/unspent" $ scottyAddressUnspent net limits
        S.get "/address/unspent" $ scottyAddressesUnspent net limits
        S.get "/address/:address/balance" $ scottyAddressBalance net
        S.get "/address/balances" $ scottyAddressesBalances net
        S.get "/xpub/:xpub/balances" $ scottyXpubBalances net limits
        S.get "/xpub/:xpub/transactions" $ scottyXpubTxs net limits False
        S.get "/xpub/:xpub/transactions/full" $ scottyXpubTxs net limits True
        S.get "/xpub/:xpub/unspent" $ scottyXpubUnspents net limits
        S.get "/xpub/:xpub" $ scottyXpubSummary net limits
        S.post "/transactions" $ scottyPostTx net st pub
        S.get "/dbstats" scottyDbStats
        S.get "/events" $ scottyEvents net pub
        S.get "/peers" $ scottyPeers net st
        S.get "/health" $ scottyHealth net st
        S.notFound $ S.raise ThingNotFound

getStart :: MonadUnliftIO m => WebT m (Maybe BlockRef)
getStart =
    runMaybeT $ do
        s <- MaybeT $ (Just <$> S.param "height") `S.rescue` const (return Nothing)
        do case s of
               StartParamHash {startParamHash = h} -> start_tx h <|> start_block h
               StartParamHeight {startParamHeight = h} -> start_height h
               StartParamTime {startParamTime = q} -> start_time q
  where
    start_height h = return $ BlockRef h maxBound
    start_block h = do
        b <- MaybeT $ getBlock (BlockHash h)
        let g = blockDataHeight b
        return $ BlockRef g maxBound
    start_tx h = do
        t <- MaybeT $ getTxData (TxHash h)
        return $ txDataBlock t
    start_time q = do
        b <- MaybeT getBestBlock >>= MaybeT . getBlock
        if q <= fromIntegral (blockTimestamp (blockDataHeader b))
            then do
                b <- MaybeT $ blockAtOrBefore q
                let g = blockDataHeight b
                return $ BlockRef g maxBound
            else return $ MemRef q

getOffset :: Monad m => MaxLimits -> ActionT Except m Offset
getOffset limits = do
    o <- S.param "offset" `S.rescue` const (return 0)
    when (maxLimitOffset limits > 0 && o > maxLimitOffset limits) . S.raise . UserError $
        "offset exceeded: " <> show o <> " > " <> show (maxLimitOffset limits)
    return o

getLimit :: Monad m => MaxLimits -> Bool -> ActionT Except m (Maybe Limit)
getLimit limits full = do
    l <- (Just <$> S.param "limit") `S.rescue` const (return Nothing)
    let m =
            if full
                then if maxLimitFull limits > 0
                         then maxLimitFull limits
                         else maxLimitCount limits
                else maxLimitCount limits
    let d = maxLimitDefault limits
    return $
        case l of
            Nothing ->
                if d > 0 || m > 0
                    then Just (min m d)
                    else Nothing
            Just n ->
                if m > 0
                    then Just (min m n)
                    else Just n

parseAddress net = do
    address <- S.param "address"
    case stringToAddr net address of
        Nothing -> S.next
        Just a -> return a

parseAddresses net = do
    addresses <- S.param "addresses"
    let as = mapMaybe (stringToAddr net) addresses
    unless (length as == length addresses) S.next
    return as

parseXpub :: (Monad m, S.ScottyError e) => Network -> ActionT e m XPubKey
parseXpub net = do
    t <- S.param "xpub"
    case xPubImport net t of
        Nothing -> S.next
        Just x -> return x

parseDeriveAddrs :: (Monad m, S.ScottyError e) => Network -> ActionT e m DeriveAddrs
parseDeriveAddrs net
    | getSegWit net = do
        t <- S.param "derive" `S.rescue` const (return "standard")
        return $
            case (t :: Text) of
                "segwit" -> deriveWitnessAddrs
                "compat" -> deriveCompatWitnessAddrs
                _ -> deriveAddrs
    | otherwise = return deriveAddrs

parseNoTx :: (Monad m, S.ScottyError e) => ActionT e m Bool
parseNoTx = S.param "notx" `S.rescue` const (return False)

pruneTx False b = b
pruneTx True b = b {blockDataTxs = take 1 (blockDataTxs b)}

cors :: Monad m => ActionT e m ()
cors = S.setHeader "Access-Control-Allow-Origin" "*"

serialAny ::
       (JsonSerial a, BinSerial a)
    => Network
    -> Bool -- ^ binary
    -> a
    -> L.ByteString
serialAny net True = runPutLazy . binSerial net
serialAny net False = encodingToLazyByteString . jsonSerial net

jsonSerialiseAny :: (JsonSerial a) => Network -> a -> L.ByteString
jsonSerialiseAny net = encodingToLazyByteString . jsonSerial net

streamAny ::
       (JsonSerial i, BinSerial i, MonadIO m)
    => Network
    -> Bool -- ^ protobuf
    -> (Builder -> IO ())
    -> ConduitT i o m ()
streamAny net True io = binConduit net .| mapC lazyByteString .| streamConduit io
streamAny net False io = jsonListConduit net .| streamConduit io

jsonListConduit :: (JsonSerial a, Monad m) => Network -> ConduitT a Builder m ()
jsonListConduit net = yield "[" >> mapC (fromEncoding . jsonSerial net) .| intersperseC "," >> yield "]"

binConduit :: (BinSerial i, Monad m) => Network -> ConduitT i L.ByteString m ()
binConduit net = mapC (runPutLazy . binSerial net)

streamConduit :: MonadIO m => (i -> IO ()) -> ConduitT i o m ()
streamConduit io = mapM_C (liftIO . io)

setupBin :: Monad m => ActionT Except m Bool
setupBin =
    let p = do
            S.setHeader "Content-Type" "application/octet-S.stream"
            return True
        j = do
            S.setHeader "Content-Type" "application/json"
            return False
     in S.header "accept" >>= \case
            Nothing -> j
            Just x ->
                if is_binary x
                    then p
                    else j
  where
    is_binary = (== "application/octet-S.stream")

instance MonadLoggerIO m => MonadLoggerIO (WebT m) where
    askLoggerIO = lift askLoggerIO

instance MonadLogger m => MonadLogger (WebT m) where
    monadLoggerLog loc src lvl = lift . monadLoggerLog loc src lvl

healthCheck :: (MonadUnliftIO m, StoreRead m) => Network -> Manager -> Chain -> m HealthCheck
healthCheck net mgr ch = do
    n <- timeout (5 * 1000 * 1000) $ chainGetBest ch
    b <-
        runMaybeT $ do
            h <- MaybeT getBestBlock
            MaybeT $ getBlock h
    p <- timeout (5 * 1000 * 1000) $ managerGetPeers mgr
    let k = isNothing n || isNothing b || maybe False (not . Data.List.null) p
        s =
            isJust $ do
                x <- n
                y <- b
                guard $ nodeHeight x - blockDataHeight y <= 1
    return
        HealthCheck
            { healthBlockBest = headerHash . blockDataHeader <$> b
            , healthBlockHeight = blockDataHeight <$> b
            , healthHeaderBest = headerHash . nodeHeader <$> n
            , healthHeaderHeight = nodeHeight <$> n
            , healthPeers = length <$> p
            , healthNetwork = getNetworkName net
            , healthOK = k
            , healthSynced = s
            }

-- | Obtain information about connected peers from peer manager process.
getPeersInformation :: MonadIO m => Manager -> m [PeerInformation]
getPeersInformation mgr = mapMaybe toInfo <$> managerGetPeers mgr
  where
    toInfo op = do
        ver <- onlinePeerVersion op
        let as = onlinePeerAddress op
            ua = getVarString $ userAgent ver
            vs = version ver
            sv = services ver
            rl = relay ver
        return
            PeerInformation {peerUserAgent = ua, peerAddress = as, peerVersion = vs, peerServices = sv, peerRelay = rl}

xpubBals ::
       (MonadResource m, MonadUnliftIO m, StoreRead m) => MaxLimits -> DeriveAddrs -> XPubKey -> ConduitT i XPubBal m ()
xpubBals limits derive xpub = go 0 >> go 1
  where
    go m = yieldMany (addrs m) .| mapMC (uncurry bal) .| gap (maxLimitGap limits)
    bal a p =
        getBalance a >>= \case
            Nothing -> return Nothing
            Just b' -> return $ Just XPubBal {xPubBalPath = p, xPubBal = b'}
    addrs m = map (\(a, _, n') -> (a, [m, n'])) (derive (pubSubKey xpub m) 0)
    gap n =
        let r 0 = return ()
            r i =
                await >>= \case
                    Just (Just b) -> yield b >> r n
                    Just Nothing -> r (i - 1)
                    Nothing -> return ()
         in r n

xpubUnspent ::
       (MonadResource m, MonadUnliftIO m, StoreStream m, StoreRead m)
    => Network
    -> MaxLimits
    -> Maybe BlockRef
    -> DeriveAddrs
    -> XPubKey
    -> ConduitT i XPubUnspent m ()
xpubUnspent net max_limits start derive xpub = xpubBals max_limits derive xpub .| go
  where
    go =
        awaitForever $ \XPubBal {xPubBalPath = p, xPubBal = b} ->
            getAddressUnspents (balanceAddress b) start .|
            mapC (\t -> XPubUnspent {xPubUnspentPath = p, xPubUnspent = t})

xpubUnspentLimit ::
       (MonadResource m, MonadUnliftIO m, StoreStream m, StoreRead m)
    => Network
    -> MaxLimits
    -> Maybe Limit
    -> Maybe BlockRef
    -> DeriveAddrs
    -> XPubKey
    -> ConduitT i XPubUnspent m ()
xpubUnspentLimit net max_limits limit start derive xpub =
    xpubUnspent net max_limits start derive xpub .| applyLimit limit

xpubSummary ::
       (MonadResource m, MonadUnliftIO m, StoreStream m, StoreRead m)
    => MaxLimits
    -> DeriveAddrs
    -> XPubKey
    -> m XPubSummary
xpubSummary max_limits derive x = do
    bs <- runConduit $ xpubBals max_limits derive x .| sinkList
    let f XPubBal {xPubBalPath = p, xPubBal = Balance {balanceAddress = a}} = (a, p)
        pm = H.fromList $ map f bs
        ex = foldl max 0 [i | XPubBal {xPubBalPath = [0, i]} <- bs]
        ch = foldl max 0 [i | XPubBal {xPubBalPath = [1, i]} <- bs]
        uc = sum [c | XPubBal {xPubBal = Balance {balanceUnspentCount = c}} <- bs]
        xt = [b | b@XPubBal {xPubBalPath = [0, _]} <- bs]
        rx = sum [r | XPubBal {xPubBal = Balance {balanceTotalReceived = r}} <- xt]
    return
        XPubSummary
            { xPubSummaryConfirmed = sum (map (balanceAmount . xPubBal) bs)
            , xPubSummaryZero = sum (map (balanceZero . xPubBal) bs)
            , xPubSummaryReceived = rx
            , xPubUnspentCount = uc
            , xPubSummaryPaths = pm
            , xPubChangeIndex = ch
            , xPubExternalIndex = ex
            }

-- | Check if any of the ancestors of this transaction is a coinbase after the
-- specified height. Returns 'Nothing' if answer cannot be computed before
-- hitting limits.
cbAfterHeight ::
       (MonadIO m, StoreRead m)
    => Int -- ^ how many ancestors to test before giving up
    -> BlockHeight
    -> TxHash
    -> m TxAfterHeight
cbAfterHeight d h t
    | d <= 0 = return $ TxAfterHeight Nothing
    | otherwise = do
        x <- fmap snd <$> tst d t
        return $ TxAfterHeight x
  where
    tst e x
        | e <= 0 = return Nothing
        | otherwise = do
            let e' = e - 1
            getTransaction x >>= \case
                Nothing -> return Nothing
                Just tx ->
                    if any isCoinbase (transactionInputs tx)
                        then return $ Just (e', blockRefHeight (transactionBlock tx) > h)
                        else case transactionBlock tx of
                                 BlockRef {blockRefHeight = b}
                                     | b <= h -> return $ Just (e', False)
                                 _ -> r e' . nub $ map (outPointHash . inputPoint) (transactionInputs tx)
    r e [] = return $ Just (e, False)
    r e (n:ns) =
        tst e n >>= \case
            Nothing -> return Nothing
            Just (e', s) ->
                if s
                    then return $ Just (e', True)
                    else r e' ns

-- Snatched from:
-- https://github.com/cblp/conduit-merge/blob/master/src/Data/Conduit/Merge.hs
mergeSourcesBy :: (Foldable f, Monad m) => (a -> a -> Ordering) -> f (ConduitT () a m ()) -> ConduitT i a m ()
mergeSourcesBy f = mergeSealed . fmap sealConduitT . toList
  where
    mergeSealed sources = do
        prefetchedSources <- lift $ traverse ($$++ await) sources
        go . V.fromList . nubBy (\a b -> f (fst a) (fst b) == EQ) $
            sortBy (f `on` fst) [(a, s) | (s, Just a) <- prefetchedSources]
    go sources
        | V.null sources = pure ()
        | otherwise = do
            let (a, src1) = V.head sources
                sources1 = V.tail sources
            yield a
            (src2, mb) <- lift $ src1 $$++ await
            let sources2 =
                    case mb of
                        Nothing -> sources1
                        Just b -> insertNubInSortedBy (f `on` fst) (b, src2) sources1
            go sources2

insertNubInSortedBy :: (a -> a -> Ordering) -> a -> Vector a -> Vector a
insertNubInSortedBy f x xs
    | null xs = xs
    | otherwise =
        case find_idx 0 (length xs - 1) of
            Nothing -> xs
            Just i ->
                let (xs1, xs2) = V.splitAt i xs
                 in xs1 <> x `cons` xs2
  where
    find_idx a b
        | f (xs ! a) x == EQ = Nothing
        | f (xs ! b) x == EQ = Nothing
        | f (xs ! b) x == LT = Just (b + 1)
        | f (xs ! a) x == GT = Just a
        | b - a == 1 = Just b
        | otherwise =
            let c = a + (b - a) `div` 2
                z = xs ! c
             in if f z x == GT
                    then find_idx a c
                    else find_idx c b

getMempoolStream :: (Monad m, StoreStream m) => ConduitT i TxHash m ()
getMempoolStream = getMempool .| mapC snd

getAddressTxsLimit ::
       (Monad m, StoreStream m) => Offset -> Maybe Limit -> Maybe BlockRef -> Address -> ConduitT i BlockTx m ()
getAddressTxsLimit offset limit start addr = getAddressTxs addr start .| applyOffsetLimit offset limit

getAddressTxsFull ::
       (Monad m, StoreStream m, StoreRead m)
    => Offset
    -> Maybe Limit
    -> Maybe BlockRef
    -> Address
    -> ConduitT i Transaction m ()
getAddressTxsFull offset limit start addr =
    getAddressTxsLimit offset limit start addr .| concatMapMC (getTransaction . blockTxHash)

getAddressesTxsLimit ::
       (MonadResource m, MonadUnliftIO m, StoreStream m)
    => Maybe Limit
    -> Maybe BlockRef
    -> [Address]
    -> ConduitT i BlockTx m ()
getAddressesTxsLimit limit start addrs = mergeSourcesBy (flip compare `on` blockTxBlock) xs .| applyLimit limit
  where
    xs = map (`getAddressTxs` start) addrs

getAddressesTxsFull ::
       (MonadResource m, MonadUnliftIO m, StoreStream m, StoreRead m)
    => Maybe Limit
    -> Maybe BlockRef
    -> [Address]
    -> ConduitT i Transaction m ()
getAddressesTxsFull limit start addrs =
    getAddressesTxsLimit limit start addrs .| concatMapMC (getTransaction . blockTxHash)

getAddressUnspentsLimit ::
       (Monad m, StoreStream m) => Offset -> Maybe Limit -> Maybe BlockRef -> Address -> ConduitT i Unspent m ()
getAddressUnspentsLimit offset limit start addr = getAddressUnspents addr start .| applyOffsetLimit offset limit

getAddressesUnspentsLimit ::
       (Monad m, StoreStream m) => Maybe Limit -> Maybe BlockRef -> [Address] -> ConduitT i Unspent m ()
getAddressesUnspentsLimit limit start addrs =
    mergeSourcesBy (flip compare `on` unspentBlock) (map (`getAddressUnspents` start) addrs) .| applyLimit limit

applyOffsetLimit :: Monad m => Offset -> Maybe Limit -> ConduitT i i m ()
applyOffsetLimit offset limit = applyOffset offset >> applyLimit limit

applyOffset :: Monad m => Offset -> ConduitT i i m ()
applyOffset = dropC . fromIntegral

applyLimit :: Monad m => Maybe Limit -> ConduitT i i m ()
applyLimit Nothing = mapC id
applyLimit (Just l) = takeC (fromIntegral l)

conduitToQueue :: MonadIO m => TBQueue (Maybe a) -> ConduitT a Void m ()
conduitToQueue q =
    await >>= \case
        Just x -> atomically (writeTBQueue q (Just x)) >> conduitToQueue q
        Nothing -> atomically $ writeTBQueue q Nothing

queueToConduit :: MonadIO m => TBQueue (Maybe a) -> ConduitT i a m ()
queueToConduit q =
    atomically (readTBQueue q) >>= \case
        Just x -> yield x >> queueToConduit q
        Nothing -> return ()

dedup :: (Eq i, Monad m) => ConduitT i i m ()
dedup =
    let dd Nothing =
            await >>= \case
                Just x -> do
                    yield x
                    dd (Just x)
                Nothing -> return ()
        dd (Just x) =
            await >>= \case
                Just y
                    | x == y -> dd (Just x)
                    | otherwise -> do
                        yield y
                        dd (Just y)
                Nothing -> return ()
     in dd Nothing

-- | Publish a new transaction to the network.
publishTx :: (MonadUnliftIO m, StoreRead m) => Network -> Publisher StoreEvent -> Store -> Tx -> m (Either PubExcept ())
publishTx net pub st tx =
    withSubscription pub $ \s ->
        getTransaction (txHash tx) >>= \case
            Just _ -> return $ Right ()
            Nothing -> go s
  where
    go s =
        managerGetPeers (storeManager st) >>= \case
            [] -> return $ Left PubNoPeers
            OnlinePeer {onlinePeerMailbox = p, onlinePeerAddress = a}:_ -> do
                MTx tx `sendMessage` p
                let t =
                        if getSegWit net
                            then InvWitnessTx
                            else InvTx
                sendMessage (MGetData (GetData [InvVector t (getTxHash (txHash tx))])) p
                f p s
    t = 5 * 1000 * 1000
    f p s =
        liftIO (timeout t (g p s)) >>= \case
            Nothing -> return $ Left PubTimeout
            Just (Left e) -> return $ Left e
            Just (Right ()) -> return $ Right ()
    g p s =
        receive s >>= \case
            StoreTxReject p' h' c _
                | p == p' && h' == txHash tx -> return . Left $ PubReject c
            StorePeerDisconnected p' _
                | p == p' -> return $ Left PubPeerDisconnected
            StoreMempoolNew h'
                | h' == txHash tx -> return $ Right ()
            _ -> g p s

logIt :: (MonadLoggerIO m, MonadUnliftIO m) => m Middleware
logIt = do
    runner <- askRunInIO
    return $ \app req respond -> do
        t1 <- getCurrentTime
        app req $ \res -> do
            t2 <- getCurrentTime
            let d = diffUTCTime t2 t1
                s = responseStatus res
            runner $ $(logInfoS) "Web" $ fmtReq req <> " [" <> fmtStatus s <> " / " <> fmtDiff d <> "]"
            respond res

fmtReq :: Request -> Text
fmtReq req =
    let method = requestMethod req
        version = httpVersion req
        path = rawPathInfo req
        query = rawQueryString req
     in T.decodeUtf8 $ method <> " " <> path <> query <> " " <> cs (show version)

fmtDiff :: NominalDiffTime -> Text
fmtDiff d = cs (printf "%0.3f" (realToFrac (d * 1000) :: Double) :: String) <> " ms"

fmtStatus :: Status -> Text
fmtStatus s = cs (show (statusCode s)) <> " " <> cs (statusMessage s)
