{-# LANGUAGE ConstraintKinds  #-}
{-# LANGUAGE DataKinds        #-}
{-# LANGUAGE GADTs            #-}
{-# LANGUAGE TemplateHaskell  #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators    #-}
-- | If you want to run the node emulator without using the `Contract` monad, this module provides a simple MTL-based interface.
module Cardano.Node.Emulator.MTL (
  -- * Updating the blockchain
    queueTx
  , nextSlot
  , currentSlot
  , awaitSlot
  -- * Querying the blockchain
  , utxosAt
  , utxoAtTxOutRef
  , fundsAt
  , lookupDatum
  -- * Transactions
  , balanceTx
  , signTx
  , submitUnbalancedTx
  , submitTxConfirmed
  , payToAddress
  -- * Logging
  , logDebug
  , logInfo
  , logWarn
  , logError
  -- * Types
  , EmulatorState(EmulatorState)
  , esChainState
  , esAddressMap
  , EmulatorError(..)
  , EmulatorLogs
  , EmulatorMsg(..)
  , L.LogMessage(..)
  , MonadEmulator
  , EmulatorT
  , EmulatorM
  , emptyEmulatorState
  , emptyEmulatorStateWithInitialDist
  , getParams
  -- * Running Eff chain effects in MTL
  , handleChain
) where

import Cardano.Api qualified as C
import Cardano.Api.Shelley qualified as C
import Cardano.Node.Emulator qualified as E
import Cardano.Node.Emulator.MTL.LogMessages (EmulatorMsg (ChainEvent, GenericMsg, TxBalanceMsg),
                                              TxBalanceMsg (BalancingUnbalancedTx, FinishedBalancing, SigningTx, SubmittingTx))
import Control.Lens (makeLenses, view, (%~), (&), (<>~), (^.))
import Control.Monad (void)
import Control.Monad.Error.Class (MonadError, throwError)
import Control.Monad.Except (ExceptT)
import Control.Monad.Freer (Eff, Member, interpret, run, type (~>))
import Control.Monad.Freer.Extras (raiseEnd)
import Control.Monad.Freer.Extras.Log qualified as L
import Control.Monad.Freer.State (State, modify, runState)
import Control.Monad.Freer.Writer qualified as F (Writer, runWriter, tell)
import Control.Monad.Identity (Identity)
import Control.Monad.RWS.Class (MonadRWS, ask, get, put, tell)
import Control.Monad.RWS.Strict (RWST)
import Data.Aeson (ToJSON (toJSON))
import Data.Map (Map)
import Data.Map qualified as Map
import Data.Sequence (Seq)
import Ledger (CardanoAddress, CardanoTx (CardanoEmulatorEraTx), Datum, DatumHash, DecoratedTxOut, OnChainTx (Valid),
               PaymentPrivateKey (unPaymentPrivateKey), Slot, ToCardanoError, TxOutRef, UtxoIndex,
               ValidationErrorInPhase, eitherTx)
import Ledger.AddressMap qualified as AM
import Ledger.Index (createGenesisTransaction, insertBlock)
import Ledger.Tx (addCardanoTxSignature, decoratedTxOutValue, getCardanoTxData, getCardanoTxId, toCtxUTxOTxOut,
                  toDecoratedTxOut)
import Ledger.Tx.CardanoAPI (CardanoBuildTx (CardanoBuildTx), fromCardanoTxIn, toCardanoTxIn, toCardanoTxOutValue)


data EmulatorState = EmulatorState
  { _esChainState :: !E.ChainState
  , _esAddressMap :: !AM.AddressMap
  , _esDatumMap   :: !(Map DatumHash Datum)
  }
  deriving (Show)

makeLenses 'EmulatorState

data EmulatorError
  = BalancingError !E.BalancingError
  | ValidationError !ValidationErrorInPhase
  | ToCardanoError !ToCardanoError
  deriving (Show)

type EmulatorLogs = Seq (L.LogMessage EmulatorMsg)
type MonadEmulator m = (MonadRWS E.Params EmulatorLogs EmulatorState m, MonadError EmulatorError m)
type EmulatorT m = ExceptT EmulatorError (RWST E.Params EmulatorLogs EmulatorState m)
type EmulatorM = EmulatorT Identity

emptyEmulatorState :: EmulatorState
emptyEmulatorState = EmulatorState E.emptyChainState mempty mempty

emptyEmulatorStateWithInitialDist :: Map CardanoAddress C.Value -> EmulatorState
emptyEmulatorStateWithInitialDist initialDist =
  let tx = createGenesisTransaction initialDist
  in emptyEmulatorState
    & esChainState . E.chainNewestFirst %~ ([Valid tx] :)
    & esChainState . E.index %~ insertBlock [Valid tx]
    & esAddressMap %~ AM.updateAllAddresses (Valid tx)
    & esDatumMap <>~ getCardanoTxData tx

getParams :: MonadEmulator m => m E.Params
getParams = ask

handleChain :: MonadEmulator m => Eff [E.ChainControlEffect, E.ChainEffect] a -> m a
handleChain eff = do
  params <- ask
  EmulatorState chainState am dm <- get
  let ((((a, dm'), am') , newChainState), lg) = raiseEnd eff
        & interpret (E.handleControlChain params)
        & interpret (E.handleChain params)
        & interpret handleChainLogs
        & runState dm
        & runState am
        & runState chainState
        & F.runWriter
        & run
  tell lg
  put $ EmulatorState newChainState am' dm'
  pure a
  where
    handleChainLogs
      :: ( Member (State AM.AddressMap) effs
        , Member (State (Map DatumHash Datum)) effs
        , Member (F.Writer EmulatorLogs) effs
        )
      => L.LogMsg E.ChainEvent ~> Eff effs
    handleChainLogs (L.LMessage msg@(L.LogMessage _ e)) = do
      F.tell @EmulatorLogs (pure $ ChainEvent <$> msg)
      E.chainEventOnChainTx e & maybe (pure ()) (\tx -> do
        void $ modify $ AM.updateAllAddresses tx
        void $ modify $ ((<>) . eitherTx getCardanoTxData getCardanoTxData) tx
        )

-- | Queue the transaction, it will be processed when @nextSlot@ is called.
queueTx :: MonadEmulator m => CardanoTx -> m ()
queueTx tx = do
  logMsg L.Info $ TxBalanceMsg $ SubmittingTx tx
  handleChain (E.queueTx tx)

-- | Process the queued transactions and increase the slot number.
nextSlot :: MonadEmulator m => m ()
nextSlot = handleChain $ do
  void E.processBlock
  void $ E.modifySlot succ

-- | Get the current slot number of the emulated node.
currentSlot :: MonadEmulator m => m Slot
currentSlot = handleChain E.getCurrentSlot

-- | Call `nextSlot` until the current slot number equals or exceeds the given slot number.
awaitSlot :: MonadEmulator m => Slot -> m ()
awaitSlot s = do
  c <- currentSlot
  if s <= c then pure ()
  else do
    nextSlot
    awaitSlot s


-- | Query the unspent transaction outputs at the given address.
utxosAt :: MonadEmulator m => CardanoAddress -> m (Map TxOutRef DecoratedTxOut)
utxosAt addr = do
  es <- get
  pure $ Map.mapKeys fromCardanoTxIn $ Map.mapMaybe (toDecoratedTxOut . snd) $ es ^. esAddressMap . AM.fundsAt addr

-- | Resolve the transaction output reference.
utxoAtTxOutRef :: MonadEmulator m => TxOutRef -> m (Maybe DecoratedTxOut)
utxoAtTxOutRef ref = either (const $ pure Nothing) findTxOut (toCardanoTxIn ref)
  where
    findTxOut txIn = do
      es <- get
      let mTxOut = snd <$> Map.lookup txIn (AM.outRefMap (es ^. esAddressMap))
      pure $ mTxOut >>= toDecoratedTxOut

-- | Query the total value of the unspent transaction outputs at the given address.
fundsAt :: MonadEmulator m => CardanoAddress -> m C.Value
fundsAt addr = foldMap (view decoratedTxOutValue) <$> utxosAt addr

-- | Resolve a datum hash to an actual datum, if known.
lookupDatum :: MonadEmulator m => DatumHash -> m (Maybe Datum)
lookupDatum h = do
  es <- get
  pure $ Map.lookup h (es ^. esDatumMap)


-- | Balance an unbalanced transaction, using funds from the given wallet if needed, and returning any remaining value to the same wallet.
balanceTx
  :: MonadEmulator m
  => UtxoIndex -- ^ Just the transaction inputs, not the entire 'UTxO'.
  -> CardanoAddress -- ^ Wallet address
  -> CardanoBuildTx
  -> m CardanoTx
balanceTx utxoIndex changeAddr utx = do
  logMsg L.Info $ TxBalanceMsg $ BalancingUnbalancedTx utx utxoIndex
  params <- ask
  es <- get
  let
    ownUtxos = C.UTxO $ toCtxUTxOTxOut . snd <$> es ^. esAddressMap . AM.fundsAt changeAddr
    utxoProvider = E.utxoProviderFromWalletOutputs ownUtxos utx
  tx <- CardanoEmulatorEraTx <$> E.makeAutoBalancedTransactionWithUtxoProvider
      params
      utxoIndex
      changeAddr
      (either (throwError . BalancingError) pure . utxoProvider)
      (throwError . either ValidationError ToCardanoError)
      utx
  logMsg L.Info $ TxBalanceMsg $ FinishedBalancing tx
  pure tx

-- | Sign a transaction with the given signatures.
signTx
  :: (MonadEmulator m, Foldable f)
  => f PaymentPrivateKey -- ^ Signatures
  -> CardanoTx
  -> m CardanoTx
signTx keys tx = do
  logMsg L.Info $ TxBalanceMsg $ SigningTx tx
  pure $ foldr (addCardanoTxSignature . unPaymentPrivateKey) tx keys

-- | Balance a transaction, sign it with the given signatures, and finally queue it.
submitUnbalancedTx
  :: (MonadEmulator m, Foldable f)
  => UtxoIndex -- ^ Just the transaction inputs, not the entire 'UTxO'.
  -> CardanoAddress -- ^ Wallet address
  -> f PaymentPrivateKey -- ^ Signatures
  -> CardanoBuildTx
  -> m CardanoTx
submitUnbalancedTx utxoIndex changeAddr keys utx = do
  newTx <- balanceTx utxoIndex changeAddr utx
  signedTx <- signTx keys newTx
  queueTx signedTx
  pure signedTx

submitTxConfirmed
    :: (MonadEmulator m, Foldable f)
    => UtxoIndex -- ^ Just the transaction inputs, not the entire 'UTxO'.
    -> CardanoAddress
    -> f PaymentPrivateKey
    -> CardanoBuildTx
    -> m CardanoTx
submitTxConfirmed utxoIndex addr privateKeys utx = do
  tx <- submitUnbalancedTx utxoIndex addr privateKeys utx
  nextSlot
  pure tx

-- | Create a transaction that transfers funds from one address to another, and sign and submit it.
payToAddress :: MonadEmulator m => (CardanoAddress, PaymentPrivateKey) -> CardanoAddress -> C.Value -> m C.TxId
payToAddress (sourceAddr, sourcePrivKey) targetAddr value = do
  let buildTx = CardanoBuildTx $ E.emptyTxBodyContent
           { C.txOuts = [C.TxOut targetAddr (toCardanoTxOutValue value) C.TxOutDatumNone C.ReferenceScriptNone]
           }
  getCardanoTxId <$> submitUnbalancedTx mempty sourceAddr [sourcePrivKey] buildTx

-- | Log any message
logMsg :: MonadEmulator m => L.LogLevel -> EmulatorMsg -> m ()
logMsg l = tell . pure . L.LogMessage l

-- | Log a message at the 'Debug' level
logDebug :: (ToJSON a, MonadEmulator m) => a -> m ()
logDebug = logMsg L.Debug . GenericMsg . toJSON

-- | Log a message at the 'Info' level
logInfo :: (ToJSON a, MonadEmulator m) => a -> m ()
logInfo = logMsg L.Info . GenericMsg . toJSON

-- | Log a message at the 'Warning' level
logWarn :: (ToJSON a, MonadEmulator m) => a -> m ()
logWarn = logMsg L.Warning . GenericMsg . toJSON

-- | Log a message at the 'Error' level
logError :: (ToJSON a, MonadEmulator m) => a -> m ()
logError = logMsg L.Error . GenericMsg . toJSON
