{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE BangPatterns #-}

module Network.Xoken.Node.P2P.PeerManager
    ( createSocket
    , setupSeedPeerConnection
    , terminateStalePeers
    ) where

import Control.Concurrent.Async (mapConcurrently)
import Control.Concurrent.Async.Lifted as LA (async)
import Control.Concurrent.MVar
import Control.Concurrent.STM.TSem
import Control.Concurrent.STM.TVar
import Control.Exception
import qualified Control.Exception.Lifted as LE (try)
import Control.Monad.Logger
import Control.Monad.Reader
import Control.Monad.STM
import Control.Monad.State.Strict
import qualified Data.Aeson as A (decode, encode)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as C
import qualified Data.ByteString.Lazy as BSL
import qualified Data.ByteString.Lazy.Char8 as LC
import Data.ByteString.Short as BSS
import Data.Char
import Data.Function ((&))
import Data.Functor.Identity
import Data.Int
import qualified Data.List as L
import qualified Data.Map.Strict as M
import Data.Maybe
import Data.Serialize
import Data.String.Conversions
import qualified Data.Text as T
import Data.Time.Clock.POSIX
import Data.Word
import qualified Database.Bolt as BT

import Control.Concurrent (threadDelay)
import Control.Concurrent.QSem
import Control.Monad.Loops
import Data.Default
import Data.IORef
import Data.Pool
import qualified Database.CQL.IO as Q
import Network.Socket
import qualified Network.Socket.ByteString as SB (recv)
import qualified Network.Socket.ByteString.Lazy as LB (recv, sendAll)
import Network.Xoken.Block.Common
import Network.Xoken.Block.Headers
import Network.Xoken.Constants
import Network.Xoken.Crypto.Hash
import Network.Xoken.Network.Common
import Network.Xoken.Network.Message
import Network.Xoken.Node.Env
import Network.Xoken.Node.GraphDB
import Network.Xoken.Node.P2P.BlockSync
import Network.Xoken.Node.P2P.ChainSync
import Network.Xoken.Node.P2P.Common
import Network.Xoken.Node.P2P.Types
import Network.Xoken.Node.P2P.UnconfTxSync
import Network.Xoken.Transaction.Common
import Network.Xoken.Util
import Streamly
import Streamly.Prelude ((|:), drain, nil)
import qualified Streamly.Prelude as S
import System.Logger as LG
import System.Logger.Message
import System.Random

createSocket :: AddrInfo -> IO (Maybe Socket)
createSocket = createSocketWithOptions []

createSocketWithOptions :: [SocketOption] -> AddrInfo -> IO (Maybe Socket)
createSocketWithOptions options addr = do
    sock <- socket AF_INET Stream (addrProtocol addr)
    mapM_ (\option -> when (isSupportedSocketOption option) (setSocketOption sock option 1)) options
    res <- try $ connect sock (addrAddress addr)
    case res of
        Right () -> return $ Just sock
        Left (e :: IOException) -> do
            liftIO $ Network.Socket.close sock
            throw $ SocketConnectException (addrAddress addr)

createSocketFromSockAddr :: SockAddr -> IO (Maybe Socket)
createSocketFromSockAddr saddr = do
    sock <- socket AF_INET Stream defaultProtocol
    res <- try $ connect sock saddr
    case res of
        Right () -> return $ Just sock
        Left (e :: IOException) -> do
            liftIO $ Network.Socket.close sock
            throw $ SocketConnectException (saddr)

setupSeedPeerConnection :: (HasXokenNodeEnv env m, MonadIO m) => m ()
setupSeedPeerConnection =
    forever $ do
        bp2pEnv <- getBitcoinP2P
        lg <- getLogger
        let net = bncNet $ bitcoinNodeConfig bp2pEnv
            seeds = getSeeds net
            hints = defaultHints {addrSocketType = Stream}
            port = getDefaultPort net
        debug lg $ msg $ show seeds
        let sd = map (\x -> Just (x :: HostName)) seeds
        addrs <- liftIO $ mapConcurrently (\x -> head <$> getAddrInfo (Just hints) (x) (Just (show port))) sd
        mapM_
            (\y ->
                 LA.async $ do
                     allpr <- liftIO $ readTVarIO (bitcoinPeers bp2pEnv)
                     let connPeers = L.filter (\x -> bpConnected (snd x)) (M.toList allpr)
                     if L.length connPeers > 10
                         then liftIO $ threadDelay (10 * 1000000)
                         else do
                             let toConn =
                                     case M.lookup (addrAddress y) allpr of
                                         Just pr ->
                                             if bpConnected pr
                                                 then False
                                                 else True
                                         Nothing -> True
                             if toConn == False
                                 then do
                                     debug lg $ msg ("Seed peer already connected, ignoring.. " ++ show (addrAddress y))
                                 else do
                                     rl <- liftIO $ newMVar True
                                     wl <- liftIO $ newMVar True
                                     ss <- liftIO $ newTVarIO Nothing
                                     imc <- liftIO $ newTVarIO 0
                                     res <- LE.try $ liftIO $ createSocket y
                                     rc <- liftIO $ newTVarIO Nothing
                                     st <- liftIO $ newTVarIO Nothing
                                     fw <- liftIO $ newTVarIO 0
                                     cf <- mapM (\x -> liftIO $ atomically $ newTSem 4) [0 .. 5]
                                     case res of
                                         Right (sock) -> do
                                             case sock of
                                                 Just sx -> do
                                                     fl <- doVersionHandshake net sx $ addrAddress y
                                                     let bp =
                                                             BitcoinPeer
                                                                 (addrAddress y)
                                                                 sock
                                                                 rl
                                                                 wl
                                                                 fl
                                                                 Nothing
                                                                 99999
                                                                 Nothing
                                                                 ss
                                                                 imc
                                                                 rc
                                                                 st
                                                                 fw
                                                                 cf
                                                     liftIO $
                                                         atomically $
                                                         modifyTVar'
                                                             (bitcoinPeers bp2pEnv)
                                                             (M.insert (addrAddress y) bp)
                                                     handleIncomingMessages bp
                                                 Nothing -> return ()
                                         Left (SocketConnectException addr) ->
                                             err lg $ msg ("SocketConnectException: " ++ show addr))
            (addrs)
        liftIO $ threadDelay (30 * 1000000)

--
--
terminateStalePeers :: (HasXokenNodeEnv env m, MonadIO m) => m ()
terminateStalePeers =
    forever $ do
        liftIO $ threadDelay (300 * 1000000)
        bp2pEnv <- getBitcoinP2P
        lg <- getLogger
        allpr <- liftIO $ readTVarIO (bitcoinPeers bp2pEnv)
        mapM_
            (\(_, pr) -> do
                 msgCt <- liftIO $ readTVarIO $ bpIngressMsgCount pr
                 if msgCt < 10
                     then do
                         debug lg $ msg ("Removing stale (connected) peer. " ++ show pr)
                         case bpSocket pr of
                             Just sock -> liftIO $ Network.Socket.close $ sock
                             Nothing -> return ()
                         liftIO $ atomically $ modifyTVar' (bitcoinPeers bp2pEnv) (M.delete (bpAddress pr))
                     else do
                         debug lg $ msg ("Peer is active, remain connected. " ++ show pr))
            (M.toList allpr)

--
--
setupPeerConnection :: (HasXokenNodeEnv env m, MonadIO m) => SockAddr -> m (Maybe BitcoinPeer)
setupPeerConnection saddr = do
    bp2pEnv <- getBitcoinP2P
    lg <- getLogger
    let net = bncNet $ bitcoinNodeConfig bp2pEnv
    allpr <- liftIO $ readTVarIO (bitcoinPeers bp2pEnv)
    let connPeers = L.filter (\x -> bpConnected (snd x)) (M.toList allpr)
    if L.length connPeers > 10
        then return Nothing
        else do
            let toConn =
                    case M.lookup saddr allpr of
                        Just pr ->
                            if bpConnected pr
                                then False
                                else True
                        Nothing -> True
            if toConn == False
                then do
                    debug lg $ msg ("Peer already connected, ignoring.. " ++ show saddr)
                    return Nothing
                else do
                    res <- LE.try $ liftIO $ createSocketFromSockAddr saddr
                    case res of
                        Right (sock) -> do
                            rl <- liftIO $ newMVar True
                            wl <- liftIO $ newMVar True
                            ss <- liftIO $ newTVarIO Nothing
                            imc <- liftIO $ newTVarIO 0
                            rc <- liftIO $ newTVarIO Nothing
                            st <- liftIO $ newTVarIO Nothing
                            fw <- liftIO $ newTVarIO 0
                            cf <- mapM (\x -> liftIO $ atomically $ newTSem 4) [0 .. 5]
                            case sock of
                                Just sx -> do
                                    debug lg $ LG.msg ("Discovered Net-Address: " ++ (show $ saddr))
                                    fl <- doVersionHandshake net sx $ saddr
                                    let bp = BitcoinPeer (saddr) sock rl wl fl Nothing 99999 Nothing ss imc rc st fw cf
                                    liftIO $ atomically $ modifyTVar' (bitcoinPeers bp2pEnv) (M.insert (saddr) bp)
                                    return $ Just bp
                                Nothing -> return (Nothing)
                        Left (SocketConnectException addr) -> do
                            err lg $ msg ("SocketConnectException: " ++ show addr)
                            return Nothing

-- Helper Functions
recvAll :: (MonadIO m) => Socket -> Int -> m B.ByteString
recvAll sock len = do
    if len > 0
        then do
            res <- liftIO $ try $ SB.recv sock len
            case res of
                Left (e :: IOException) -> throw SocketReadException
                Right mesg ->
                    if B.length mesg == len
                        then return mesg
                        else if B.length mesg == 0
                                 then throw ZeroLengthSocketReadException
                                 else B.append mesg <$> recvAll sock (len - B.length mesg)
        else return (B.empty)

hashPair :: Hash256 -> Hash256 -> Hash256
hashPair a b = doubleSHA256 $ encode a `B.append` encode b

pushHash :: HashCompute -> Hash256 -> Maybe Hash256 -> Maybe Hash256 -> Int8 -> Int8 -> Bool -> HashCompute
pushHash (stateMap, res) nhash left right ht ind final =
    case node prev of
        Just pv ->
            pushHash
                ( (M.insert ind emptyMerkleNode stateMap)
                , (insertSpecial
                       (Just pv)
                       (left)
                       (right)
                       True
                       (insertSpecial (Just nhash) (leftChild prev) (rightChild prev) False res)))
                (hashPair pv nhash)
                (Just pv)
                (Just nhash)
                ht
                (ind + 1)
                final
        Nothing ->
            if ht == ind
                then (updateState, (insertSpecial (Just nhash) left right True res))
                else if final
                         then pushHash
                                  (updateState, (insertSpecial (Just nhash) left right True res))
                                  (hashPair nhash nhash)
                                  (Just nhash)
                                  (Just nhash)
                                  ht
                                  (ind + 1)
                                  final
                         else (updateState, res)
  where
    insertSpecial sib lft rht flg lst = L.insert (MerkleNode sib lft rht flg) lst
    updateState = M.insert ind (MerkleNode (Just nhash) left right True) stateMap
    prev =
        case M.lookupIndex (fromIntegral ind) stateMap of
            Just i -> snd $ M.elemAt i stateMap
            Nothing -> emptyMerkleNode

updateMerkleSubTrees ::
       (HasDatabaseHandles m, HasLogger m, MonadIO m)
    => HashCompute
    -> Hash256
    -> Maybe Hash256
    -> Maybe Hash256
    -> Int8
    -> Int8
    -> Bool
    -> m (HashCompute)
updateMerkleSubTrees hashMap newhash left right ht ind final = do
    dbe <- getDB
    lg <- getLogger
    let (state, res) = pushHash hashMap newhash left right ht ind final
    if L.length res > 0
        then do
            let (create, match) =
                    L.partition
                        (\x ->
                             case x of
                                 (MerkleNode sib lft rht _) ->
                                     if isJust sib && isJust lft && isJust rht
                                         then False
                                         else if isJust sib
                                                  then True
                                                  else throw MerkleTreeComputeException)
                        (res)
            let finMatch =
                    L.sortBy
                        (\x y ->
                             if (leftChild x == node y) || (rightChild x == node y)
                                 then GT
                                 else LT)
                        match
            -- debug lg $ msg $ show create ++ show finMatch
            if L.length create == 1 && L.length finMatch == 0
                then return (state, [])
                else do
                    res <-
                        liftIO $ try $ withResource (pool $ graphDB dbe) (`BT.run` insertMerkleSubTree create finMatch)
                    case res of
                        Right () -> do
                            return (state, [])
                        Left (e :: SomeException) -> do
                            if T.isInfixOf (T.pack "ConstraintValidationFailed") (T.pack $ show e)
                                then do
                                    err lg $ msg $ val "Ignoring ConstraintValidationFailed, prev aborted block sync?"
                                    return (state, [])
                                else do
                                    err lg $ msg $ show e
                                    throw MerkleSubTreeDBInsertException
        else return (state, res)
        -- else block --

readNextMessage ::
       (HasBitcoinP2P m, HasLogger m, HasDatabaseHandles m, MonadIO m)
    => Network
    -> Socket
    -> Maybe IngressStreamState
    -> m ((Maybe Message, Maybe IngressStreamState))
readNextMessage net sock ingss = do
    p2pEnv <- getBitcoinP2P
    lg <- getLogger
    case ingss of
        Just iss -> do
            let blin = issBlockIngest iss
                maxChunk = (4 * 1024 * 100) - (B.length $ binUnspentBytes blin)
                len =
                    if (binTxPayloadLeft blin - (B.length $ binUnspentBytes blin)) < maxChunk
                        then (binTxPayloadLeft blin) - (B.length $ binUnspentBytes blin)
                        else maxChunk
            -- debug lg $ msg (" | Tx payload left " ++ show (binTxPayloadLeft blin))
            -- debug lg $ msg (" | Bytes prev unspent " ++ show (B.length $ binUnspentBytes blin))
            -- debug lg $ msg (" | Bytes to read " ++ show len)
            nbyt <- recvAll sock len
            let txbyt = (binUnspentBytes blin) `B.append` nbyt
            case runGetState (getConfirmedTx) txbyt 0 of
                Left e -> do
                    err lg $ msg $ ("(error) IngressStreamState: " ++ show iss)
                    err lg $ msg $ (encodeHex txbyt)
                    throw ConfirmedTxParseException
                Right (tx, unused) -> do
                    case tx of
                        Just t -> do
                            debug lg $
                                msg ("Confirmed-Tx: " ++ (show $ txHash t) ++ " unused: " ++ show (B.length unused))
                            nst <-
                                updateMerkleSubTrees
                                    (merklePrevNodesMap iss)
                                    (getTxHash $ txHash t)
                                    Nothing
                                    Nothing
                                    (merkleTreeHeight iss)
                                    (merkleTreeCurIndex iss)
                                    ((binTxTotalCount blin) == (1 + binTxProcessed blin))
                            let !bio =
                                    BlockIngestState
                                        { binUnspentBytes = unused
                                        , binTxPayloadLeft = binTxPayloadLeft blin - (B.length txbyt - B.length unused)
                                        , binTxTotalCount = binTxTotalCount blin
                                        , binTxProcessed = 1 + binTxProcessed blin
                                        , binChecksum = binChecksum blin
                                        }
                            return
                                ( Just $ MConfTx t
                                , Just $ IngressStreamState bio (issBlockInfo iss) (merkleTreeHeight iss) 0 nst)
                        Nothing -> do
                            debug lg $ msg (txbyt)
                            throw ConfirmedTxParseException
        Nothing -> do
            hdr <- recvAll sock 24
            case (decode hdr) of
                Left e -> do
                    err lg $ msg ("Error decoding incoming message header: " ++ e)
                    throw MessageParsingException
                Right (MessageHeader _ cmd len cks) -> do
                    if cmd == MCBlock
                        then do
                            byts <- recvAll sock (88) -- 80 byte Block header + VarInt (max 8 bytes) Tx count
                            case runGetState (getDeflatedBlock) byts 0 of
                                Left e -> do
                                    err lg $ msg ("Error, unexpected message header: " ++ e)
                                    throw MessageParsingException
                                Right (blk, unused) -> do
                                    case blk of
                                        Just b
                                            -- debug lg $
                                            --     msg ("DefBlock: " ++ show blk ++ " unused: " ++ show (B.length unused))
                                         -> do
                                            let !bi =
                                                    BlockIngestState
                                                        { binUnspentBytes = unused
                                                        , binTxPayloadLeft = fromIntegral (len) - (88 - B.length unused)
                                                        , binTxTotalCount = fromIntegral $ txnCount b
                                                        , binTxProcessed = 0
                                                        , binChecksum = cks
                                                        }
                                            return
                                                ( Just $ MBlock b
                                                , Just $
                                                  IngressStreamState
                                                      bi
                                                      Nothing
                                                      (computeTreeHeight $ binTxTotalCount bi)
                                                      0
                                                      (M.empty, []))
                                        Nothing -> throw DeflatedBlockParseException
                        else do
                            byts <-
                                if len == 0
                                    then return hdr
                                    else do
                                        b <- recvAll sock (fromIntegral len)
                                        return (hdr `B.append` b)
                            case runGet (getMessage net) byts of
                                Left e -> throw MessageParsingException
                                Right msg -> do
                                    return (Just msg, Nothing)

doVersionHandshake ::
       (HasBitcoinP2P m, HasLogger m, HasDatabaseHandles m, MonadIO m) => Network -> Socket -> SockAddr -> m (Bool)
doVersionHandshake net sock sa = do
    p2pEnv <- getBitcoinP2P
    lg <- getLogger
    g <- liftIO $ getStdGen
    now <- round <$> liftIO getPOSIXTime
    myaddr <-
        liftIO $
        head <$>
        getAddrInfo
            (Just defaultHints {addrSocketType = Stream})
            (Just "51.89.40.95") -- "192.168.0.106")
            (Just "3000")
    let nonce = fst (random g :: (Word64, StdGen))
        ad = NetworkAddress 0 $ addrAddress myaddr -- (SockAddrInet 0 0)
        bb = 1 :: Word32 -- ### TODO: getBestBlock ###
        rmt = NetworkAddress 0 sa
        ver = buildVersion net nonce bb ad rmt now
        em = runPut . putMessage net $ (MVersion ver)
    debug lg $ msg ("ADD: " ++ show ad)
    mv <- liftIO $ (newMVar True)
    liftIO $ sendEncMessage mv sock (BSL.fromStrict em)
    (hs1, _) <- readNextMessage net sock Nothing
    case hs1 of
        Just (MVersion __) -> do
            (hs2, _) <- readNextMessage net sock Nothing
            case hs2 of
                Just MVerAck -> do
                    let em2 = runPut . putMessage net $ (MVerAck)
                    liftIO $ sendEncMessage mv sock (BSL.fromStrict em2)
                    debug lg $ msg ("Version handshake complete: " ++ show sa)
                    return True
                __ -> do
                    err lg $ msg $ val "Error, unexpected message (2) during handshake"
                    return False
        __ -> do
            err lg $ msg $ val "Error, unexpected message (1) during handshake"
            return False

messageHandler ::
       (HasXokenNodeEnv env m, HasLogger m, MonadIO m)
    => BitcoinPeer
    -> (Maybe Message, Maybe IngressStreamState)
    -> m (MessageCommand)
messageHandler peer (mm, ingss) = do
    bp2pEnv <- getBitcoinP2P
    lg <- getLogger
    case mm of
        Just msg -> do
            case (msg) of
                MHeaders hdrs -> do
                    liftIO $ takeMVar (headersWriteLock bp2pEnv)
                    res <- LE.try $ processHeaders hdrs
                    case res of
                        Right () -> return ()
                        Left BlockHashNotFoundException -> return ()
                        Left EmptyHeadersMessageException -> return ()
                        Left e -> do
                            err lg $ LG.msg ("[ERROR] Unhandled exception!" ++ show e)
                            throw e
                    liftIO $ putMVar (headersWriteLock bp2pEnv) True
                    return $ msgType msg
                MInv inv -> do
                    mapM_
                        (\x ->
                             if (invType x) == InvBlock
                                 then do
                                     debug lg $ LG.msg ("INV - new Block: " ++ (show $ invHash x))
                                     liftIO $ putMVar (bestBlockUpdated bp2pEnv) True -- will trigger a GetHeaders to peers
                                 else if (invType x == InvTx)
                                          then do
                                              debug lg $ LG.msg ("INV - new Tx: " ++ (show $ invHash x))
                                              processTxGetData peer $ invHash x
                                          else return ())
                        (invList inv)
                    return $ msgType msg
                MAddr addrs -> do
                    mapM_
                        (\(t, x) -> do
                             bp <- setupPeerConnection $ naAddress x
                             LA.async $
                                 case bp of
                                     Just p -> handleIncomingMessages p
                                     Nothing -> return ())
                        (addrList addrs)
                    return $ msgType msg
                MConfTx tx -> do
                    case ingss of
                        Just iss -> do
                            let bi = issBlockIngest iss
                            let binfo = issBlockInfo iss
                            case binfo of
                                Just bf -> do
                                    res <-
                                        LE.try $
                                        processConfTransaction
                                            tx
                                            (biBlockHash bf)
                                            (binTxProcessed bi)
                                            (fromIntegral $ biBlockHeight bf)
                                    case res of
                                        Right () -> return ()
                                        Left BlockHashNotFoundException -> return ()
                                        Left EmptyHeadersMessageException -> return ()
                                        Left KeyValueDBInsertException -> do
                                            err lg $ LG.msg $ val "[ERROR] KeyValueDBInsertException"
                                            throw KeyValueDBInsertException
                                        Left e -> do
                                            err lg $ LG.msg ("[ERROR] Unhandled exception!" ++ show e)
                                            throw e
                                    return $ msgType msg
                                Nothing -> throw InvalidStreamStateException
                        Nothing -> do
                            err lg $ LG.msg $ val ("[???] Unconfirmed Tx ")
                            return $ msgType msg
                MTx tx -> do
                    processUnconfTransaction tx
                    return $ msgType msg
                MBlock blk -> do
                    res <- LE.try $ processBlock blk
                    case res of
                        Right () -> return ()
                        Left BlockHashNotFoundException -> return ()
                        Left EmptyHeadersMessageException -> return ()
                        Left e -> do
                            err lg $ LG.msg ("[ERROR] Unhandled exception!" ++ show e)
                            throw e
                    return $ msgType msg
                MPing ping -> do
                    bp2pEnv <- getBitcoinP2P
                    let net = bncNet $ bitcoinNodeConfig bp2pEnv
                    let em = runPut . putMessage net $ (MPong $ Pong (pingNonce ping))
                    case (bpSocket peer) of
                        Just sock -> do
                            liftIO $ sendEncMessage (bpWriteMsgLock peer) sock (BSL.fromStrict em)
                            return $ msgType msg
                        Nothing -> return $ msgType msg
                _ -> do
                    return $ msgType msg
        Nothing -> do
            err lg $ LG.msg $ val "Error, invalid message"
            throw InvalidMessageTypeException

readNextMessage' :: (HasXokenNodeEnv env m, MonadIO m) => BitcoinPeer -> m ((Maybe Message, Maybe IngressStreamState))
readNextMessage' peer = do
    bp2pEnv <- getBitcoinP2P
    lg <- getLogger
    let net = bncNet $ bitcoinNodeConfig bp2pEnv
    case bpSocket peer of
        Just sock
            -- liftIO $ takeMVar $ bpReadMsgLock peer
         -> do
            !prevIngressState <- liftIO $ readTVarIO $ bpIngressState peer
            (msg, ingressState) <- readNextMessage net sock prevIngressState
            case ingressState of
                Just iss -> do
                    mp <- liftIO $ readTVarIO $ blockSyncStatusMap bp2pEnv
                    let ingst = issBlockIngest iss
                    case msg of
                        Just (MBlock blk) -- setup state
                         -> do
                            let hh = headerHash $ defBlockHeader blk
                            let mht = M.lookup hh mp
                            case (mht) of
                                Just x -> return ()
                                Nothing -> do
                                    debug lg $ LG.msg $ ("InvalidBlockSyncStatusMapException - " ++ show hh)
                                    throw InvalidBlockSyncStatusMapException
                            let !iz =
                                    Just
                                        (IngressStreamState
                                             ingst
                                             (Just $ BlockInfo hh (snd $ fromJust mht))
                                             (computeTreeHeight $ binTxTotalCount ingst)
                                             0
                                             (M.empty, []))
                            liftIO $ atomically $ writeTVar (bpIngressState peer) $ iz
                            liftIO $ atomically $ modifyTVar' (bpBlockFetchWindow peer) (\z -> z - 1)
                        Just (MConfTx ctx) -> do
                            case issBlockInfo iss of
                                Just bi -> do
                                    tm <- liftIO $ getCurrentTime
                                    liftIO $ atomically $ writeTVar (bpLastTxRecvTime peer) $ Just tm
                                    if binTxTotalCount ingst == binTxProcessed ingst
                                        then do
                                            liftIO $ atomically $ writeTVar (bpIngressState peer) $ Nothing -- reset state
                                            liftIO $
                                                atomically $
                                                modifyTVar'
                                                    (blockSyncStatusMap bp2pEnv)
                                                    (M.insert (biBlockHash bi) $
                                                     (BlockReceiveComplete, biBlockHeight bi) -- mark block received
                                                     )
                                        else do
                                            liftIO $ atomically $ writeTVar (bpIngressState peer) $ ingressState -- retain state
                                            liftIO $
                                                atomically $
                                                modifyTVar'
                                                    (blockSyncStatusMap bp2pEnv)
                                                    (M.insert (biBlockHash bi) $
                                                     (RecentTxReceiveTime (tm, binTxProcessed ingst), biBlockHeight bi) -- track receive progress
                                                     )
                                Nothing -> throw InvalidBlockInfoException
                        otherwise -> throw UnexpectedDuringBlockProcException
                Nothing -> return ()
            -- liftIO $ putMVar (bpReadMsgLock peer) True
            return (msg, ingressState)
        Nothing -> throw PeerSocketNotConnectedException

handleIncomingMessages :: (HasXokenNodeEnv env m, MonadIO m) => BitcoinPeer -> m ()
handleIncomingMessages pr = do
    lg <- getLogger
    debug lg $ msg $ "handling messages from: " ++ show (bpAddress pr)
    continue <- liftIO $ newIORef True
    whileM_ (liftIO $ readIORef continue) $ do
        bp2pEnv <- getBitcoinP2P -- TODO: move it out?
        res <- LE.try $ readNextMessage' pr
        LA.async $
            case res of
                Right ((msg, state)) -> do
                    let sema =
                            case msgType $ fromJust msg of
                                MCConfTx ->
                                    case state of
                                        Just st -> bpTxConcurrency pr !! ((binTxProcessed $ issBlockIngest st) `mod` 4)
                                        Nothing -> (bpTxConcurrency pr !! 0)
                                otherwise -> (bpTxConcurrency pr !! 5)
                    liftIO $ atomically $ waitTSem sema
                    res <- LE.try $ messageHandler pr (msg, state)
                    case res of
                        Right (msgCmd) -> do
                            liftIO $ atomically $ signalTSem sema
                            logMessage pr msgCmd
                        Left (e :: SomeException) -> do
                            err lg $ LG.msg $ (val "[ERROR] @ messageHandler ") +++ (show e)
                            liftIO $ atomically $ signalTSem sema
                Left (e :: SomeException) -> do
                    err lg $ LG.msg $ (val "[ERROR] Closing peer connection ") +++ (show e)
                    case (bpSocket pr) of
                        Just sock -> liftIO $ Network.Socket.close sock
                        Nothing -> return ()
                    liftIO $ atomically $ modifyTVar' (bitcoinPeers bp2pEnv) (M.delete (bpAddress pr))
                    liftIO $ writeIORef continue False

--
-- handleIncomingMessages :: (HasXokenNodeEnv env m, MonadIO m) => BitcoinPeer -> m ()
-- handleIncomingMessages pr = do
--     bp2pEnv <- getBitcoinP2P
--     lg <- getLogger
--     debug lg $ msg $ "reading from: " ++ show (bpAddress pr)
--     res <-
--         LE.try $
--         S.drain $ asyncly $ S.repeatM (readNextMessage' pr) & S.mapM (messageHandler pr) & S.mapM (logMessage pr)
--     case res of
--         Right () -> return ()
--         Left (e :: SomeException) -> do
--             err lg $ msg $ (val "[ERROR] Closing peer connection ") +++ (show e)
--             case (bpSocket pr) of
--                 Just sock -> liftIO $ Network.Socket.close sock
--                 Nothing -> return ()
--             liftIO $ atomically $ modifyTVar' (bitcoinPeers bp2pEnv) (M.delete (bpAddress pr))
--             return ()
--
logMessage :: (HasXokenNodeEnv env m, HasLogger m, MonadIO m) => BitcoinPeer -> MessageCommand -> m ()
logMessage peer mg = do
    lg <- getLogger
    liftIO $ atomically $ modifyTVar' (bpIngressMsgCount peer) (\z -> z + 1)
    debug lg $ LG.msg $ "processed: " ++ show mg
    return ()
