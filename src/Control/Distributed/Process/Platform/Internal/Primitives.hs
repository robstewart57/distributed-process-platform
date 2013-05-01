{-# LANGUAGE DeriveDataTypeable     #-}
{-# LANGUAGE TemplateHaskell        #-}
{-# LANGUAGE TypeSynonymInstances   #-}
{-# LANGUAGE FlexibleInstances      #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  Control.Distributed.Process.Platform.Internal.Primitives
-- Copyright   :  (c) Tim Watson 2013, Parallel Scientific (Jeff Epstein) 2012
-- License     :  BSD3 (see the file LICENSE)
--
-- Maintainers :  Jeff Epstein, Tim Watson
-- Stability   :  experimental
-- Portability :  non-portable (requires concurrency)
--
-- This module provides a set of additional primitives that add functionality
-- to the basic Cloud Haskell APIs.
-----------------------------------------------------------------------------

module Control.Distributed.Process.Platform.Internal.Primitives
  ( -- * General Purpose Process Addressing
    Addressable(..)

    -- * Spawning and Linking
  , spawnLinkLocal
  , spawnMonitorLocal
  , linkOnFailure

    -- * Registered Processes
  , whereisRemote
  , whereisOrStart
  , whereisOrStartRemote

    -- * Selective Receive/Matching
  , matchCond

    -- * General Utilities
  , times

    -- * Remote Table
  , __remoteTable
  ) where

import Control.Concurrent (myThreadId, throwTo)
import Control.Distributed.Process
import Control.Distributed.Process.Closure (seqCP, remotable, mkClosure)
import Control.Distributed.Process.Serializable (Serializable)
import Control.Distributed.Process.Platform.Internal.Types
  ( Recipient(..)
  , RegisterSelf(..)
  , sendToRecipient
  , whereisRemote
  )
import Control.Monad (void)
import Data.Maybe (isJust, fromJust)

-- utility

-- | Apply the supplied expression /n/ times
times :: Int -> Process () -> Process ()
n `times` proc = runP proc n
  where runP :: Process () -> Int -> Process ()
        runP _ 0 = return ()
        runP p n' = p >> runP p (n' - 1)

-- | Provides a unified API for addressing processes
class Addressable a where
  -- | Send a message to the target asynchronously
  sendTo  :: (Serializable m) => a -> m -> Process ()
  -- | Resolve the reference to a process id, or @Nothing@ if resolution fails
  resolve :: a -> Process (Maybe ProcessId)

instance Addressable Recipient where
  sendTo = sendToRecipient
  resolve (Pid                p) = return (Just p)
  resolve (Registered         n) = whereis n
  resolve (RemoteRegistered s n) = whereisRemote n s

instance Addressable ProcessId where
  sendTo    = send
  resolve p = return (Just p)

instance Addressable String where
  sendTo  = nsend
  resolve = whereis

-- spawning, linking and generic server startup

-- | Node local version of 'Control.Distributed.Process.spawnLink'.
-- Note that this is just the sequential composition of 'spawn' and 'link'.
-- (The "Unified" semantics that underlies Cloud Haskell does not even support
-- a synchronous link operation)
spawnLinkLocal :: Process () -> Process ProcessId
spawnLinkLocal p = do
  pid <- spawnLocal p
  link pid
  return pid

-- | Like 'spawnLinkLocal', but monitor the spawned process
spawnMonitorLocal :: Process () -> Process (ProcessId, MonitorRef)
spawnMonitorLocal p = do
  pid <- spawnLocal p
  ref <- monitor pid
  return (pid, ref)

-- | CH's 'link' primitive, unlike Erlang's, will trigger when the target
-- process dies for any reason. This function has semantics like Erlang's:
-- it will trigger 'ProcessLinkException' only when the target dies abnormally.
linkOnFailure :: ProcessId -> Process ()
linkOnFailure them = do
  us <- getSelfPid
  tid <- liftIO $ myThreadId
  void $ spawnLocal $ do
    callerRef <- monitor us
    calleeRef <- monitor them
    reason <- receiveWait [
             matchIf (\(ProcessMonitorNotification mRef _ _) ->
                       mRef == callerRef) -- nothing left to do
                     (\_ -> return DiedNormal)
           , matchIf (\(ProcessMonitorNotification mRef' _ _) ->
                       mRef' == calleeRef)
                     (\(ProcessMonitorNotification _ _ r') -> return r')
         ]
    case reason of
      DiedNormal -> return ()
      _ -> liftIO $ throwTo tid (ProcessLinkException us reason)

-- | Returns the pid of the process that has been registered
-- under the given name. This refers to a local, per-node registration,
-- not @global@ registration. If that name is unregistered, a process
-- is started. This is a handy way to start per-node named servers.
whereisOrStart :: String -> Process () -> Process ProcessId
whereisOrStart name proc =
  do mpid <- whereis name
     case mpid of
       Just pid -> return pid
       Nothing ->
         do caller <- getSelfPid
            pid <- spawnLocal $
                 do self <- getSelfPid
                    register name self
                    send caller (RegisterSelf,self)
                    () <- expect
                    proc
            ref <- monitor pid
            ret <- receiveWait
               [ matchIf (\(ProcessMonitorNotification aref _ _) -> ref == aref)
                         (\(ProcessMonitorNotification _ _ _) -> return Nothing),
                 matchIf (\(RegisterSelf,apid) -> apid == pid)
                         (\(RegisterSelf,_) -> return $ Just pid)
               ]
            case ret of
              Nothing -> whereisOrStart name proc
              Just somepid ->
                do unmonitor ref
                   send somepid ()
                   return somepid

registerSelf :: (String, ProcessId) -> Process ()
registerSelf (name,target) =
  do self <- getSelfPid
     register name self
     send target (RegisterSelf, self)
     () <- expect
     return ()

$(remotable ['registerSelf])

-- | A remote equivalent of 'whereisOrStart'. It deals with the
-- node registry on the given node, and the process, if it needs to be started,
-- will run on that node. If the node is inaccessible, Nothing will be returned.
whereisOrStartRemote :: NodeId -> String -> Closure (Process ()) -> Process (Maybe ProcessId)
whereisOrStartRemote nid name proc =
     do mRef <- monitorNode nid
        whereisRemoteAsync nid name
        res <- receiveWait
          [ matchIf (\(WhereIsReply label _) -> label == name)
                    (\(WhereIsReply _ mPid) -> return (Just mPid)),
            matchIf (\(NodeMonitorNotification aref _ _) -> aref == mRef)
                    (\(NodeMonitorNotification _ _ _) -> return Nothing)
          ]
        case res of
           Nothing -> return Nothing
           Just (Just pid) -> unmonitor mRef >> return (Just pid)
           Just Nothing ->
              do self <- getSelfPid
                 sRef <- spawnAsync nid ($(mkClosure 'registerSelf) (name,self) `seqCP` proc)
                 ret <- receiveWait [
                      matchIf (\(NodeMonitorNotification ref _ _) -> ref == mRef)
                              (\(NodeMonitorNotification _ _ _) -> return Nothing),
                      matchIf (\(DidSpawn ref _) -> ref==sRef )
                              (\(DidSpawn _ pid) ->
                                  do pRef <- monitor pid
                                     receiveWait
                                       [ matchIf (\(RegisterSelf, apid) -> apid == pid)
                                                 (\(RegisterSelf, _) -> do unmonitor pRef
                                                                           send pid ()
                                                                           return $ Just pid),
                                         matchIf (\(NodeMonitorNotification aref _ _) -> aref == mRef)
                                                 (\(NodeMonitorNotification _aref _ _) -> return Nothing),
                                         matchIf (\(ProcessMonitorNotification ref _ _) -> ref==pRef)
                                                 (\(ProcessMonitorNotification _ _ _) -> return Nothing)
                                       ] )
                      ]
                 unmonitor mRef
                 case ret of
                   Nothing -> whereisOrStartRemote nid name proc
                   Just pid -> return $ Just pid

-- advanced messaging/matching

-- | An alternative to 'matchIf' that allows both predicate and action
-- to be expressed in one parameter.
matchCond :: (Serializable a) => (a -> Maybe (Process b)) -> Match b
matchCond cond =
   let v n = (isJust n, fromJust n)
       res = v . cond
    in matchIf (fst . res) (snd . res)

