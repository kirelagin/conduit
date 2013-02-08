{-# LANGUAGE CPP #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE RankNTypes #-}
-- | Note: This module is experimental, and might be modified at any time.
-- Caveat emptor!
module Data.Conduit.Class
    ( module Data.Conduit.Class
    , C.ResumableSource
    , C.runResourceT
    , C.Flush (..)
    , C.ResourceT
    , C.unwrapResumable
    ) where

import Prelude (Monad (..), Functor (..), ($), const, IO, Maybe, Either, Bool, (.), either, mapM_)
import Data.Void (Void)
import Control.Applicative (Applicative (..))
import qualified Data.Conduit as C
import Data.Conduit.Internal (Pipe)
import Control.Monad.Trans.Class (MonadTrans (..))
import Control.Monad.Trans.Resource (allocate, release, MonadThrow, MonadResource, ResourceT)
import Control.Monad.Trans.Control (liftWith, restoreT, MonadTransControl)
import Control.Monad.IO.Class (MonadIO (liftIO))
import Data.Monoid (Monoid (..))

import Control.Monad.Trans.Identity ( IdentityT)
import Control.Monad.Trans.List     ( ListT    )
import Control.Monad.Trans.Maybe    ( MaybeT   )
import Control.Monad.Trans.Error    ( ErrorT, Error)
import Control.Monad.Trans.Reader   ( ReaderT  )
import Control.Monad.Trans.State    ( StateT   )
import Control.Monad.Trans.Writer   ( WriterT  )
import Control.Monad.Trans.RWS      ( RWST     )

import qualified Control.Monad.Trans.RWS.Strict    as Strict ( RWST   )
import qualified Control.Monad.Trans.State.Strict  as Strict ( StateT )
import qualified Control.Monad.Trans.Writer.Strict as Strict ( WriterT )

-- | Provides a stream of output values, without consuming any input or
-- producing a final result.
--
-- Since 0.6.0
type Source m o = SourceM o m ()

newtype SourceM o m r = SourceM { unSourceM :: Pipe () () o () m r }
    deriving (Functor, Applicative, Monad, MonadTrans, MonadIO, MonadThrow)

instance Monad m => Monoid (SourceM o m ()) where
    mempty = return ()
    mappend = (>>)

-- | Consumes a stream of input values and produces a stream of output values,
-- without producing a final result.
--
-- Since 0.6.0
type Conduit i m o = ConduitM i o m ()

newtype ConduitM i o m r = ConduitM { unConduitM :: Pipe i i o () m r }
    deriving (Functor, Applicative, Monad, MonadTrans, MonadIO, MonadThrow)

instance Monad m => Monoid (ConduitM i o m ()) where
    mempty = return ()
    mappend = (>>)

-- | Consumes a stream of input values and produces a final result, without
-- producing any output.
--
-- Since 0.6.0
newtype Sink i m r = Sink { unSink :: Pipe i i Void () m r }
    deriving (Functor, Applicative, Monad, MonadTrans, MonadIO, MonadThrow)

instance Monad m => Monoid (Sink i m ()) where
    mempty = return ()
    mappend = (>>)

class (Monad m, Monad (StreamMonad m)) => MonadStream m where
    type Upstream m
    type StreamTerm m -- FIXME remove in the future
    type Downstream m
    type StreamMonad m :: * -> *
    type Leftover m -- FIXME remove in the future

    -- | Wait for a single input value from upstream, terminating immediately if no
    -- data is available.
    --
    -- Since 0.5.0
    await :: m (Maybe (Upstream m))

    -- | This is similar to @await@, but will return the upstream result value as
    -- @Left@ if available.
    --
    -- Since 0.5.0
    awaitE :: m (Either (StreamTerm m) (Upstream m))

    -- | Provide a single piece of leftover input to be consumed by the next pipe
    -- in the current monadic binding.
    --
    -- /Note/: it is highly encouraged to only return leftover values from input
    -- already consumed from upstream.
    --
    -- Since 0.5.0
    leftover :: Leftover m -> m ()

    -- | Send a single output value downstream. If the downstream @Pipe@
    -- terminates, this @Pipe@ will terminate as well.
    --
    -- Since 0.5.0
    yield :: Downstream m -> m ()

    -- | Similar to @yield@, but additionally takes a finalizer to be run if the
    -- downstream @Pipe@ terminates.
    --
    -- Since 0.5.0
    yieldOr :: Downstream m -> StreamMonad m () -> m ()

    liftStreamMonad :: StreamMonad m a -> m a

    -- | Add some code to be run when the given @Pipe@ cleans up.
    --
    -- Since 0.4.1
    addCleanup :: (Bool -> StreamMonad m ()) -- ^ @True@ if @Pipe@ ran to completion, @False@ for early termination.
               -> m r
               -> m r

instance Monad m => MonadStream (Pipe l i o u m) where
    type Upstream (Pipe l i o u m) = i
    type StreamTerm (Pipe l i o u m) = u
    type Downstream (Pipe l i o u m) = o
    type StreamMonad (Pipe l i o u m) = m
    type Leftover (Pipe l i o u m) = l

    await = C.await
    {-# INLINE [1] await #-}

    awaitE = C.awaitE
    {-# INLINE [1] awaitE #-}

    leftover = C.leftover
    {-# INLINE [1] leftover #-}

    yield = C.yield
    {-# INLINE yield #-}

    yieldOr = C.yieldOr
    {-# INLINE yieldOr #-}

    liftStreamMonad = lift

    addCleanup = C.addCleanup

instance Monad m => MonadStream (SourceM o m) where
    type Upstream (SourceM o m) = ()
    type StreamTerm (SourceM o m) = ()
    type Downstream (SourceM o m) = o
    type StreamMonad (SourceM o m) = m
    type Leftover (SourceM o m) = ()

    await = SourceM await
    {-# INLINE await #-}

    awaitE = SourceM awaitE
    {-# INLINE awaitE #-}

    leftover = SourceM . leftover
    {-# INLINE leftover #-}

    yield = SourceM . yield
    {-# INLINE yield #-}

    yieldOr a = SourceM . yieldOr a
    {-# INLINE yieldOr #-}

    liftStreamMonad = lift
    {-# INLINE liftStreamMonad #-}

    addCleanup c (SourceM p) = SourceM (addCleanup c p)
    {-# INLINE addCleanup #-}

instance Monad m => MonadStream (ConduitM i o m) where
    type Upstream (ConduitM i o m) = i
    type StreamTerm (ConduitM i o m) = ()
    type Downstream (ConduitM i o m) = o
    type StreamMonad (ConduitM i o m) = m
    type Leftover (ConduitM i o m) = i

    await = ConduitM await
    {-# INLINE await #-}

    awaitE = ConduitM awaitE
    {-# INLINE awaitE #-}

    leftover = ConduitM . leftover
    {-# INLINE leftover #-}

    yield = ConduitM . yield
    {-# INLINE yield #-}

    yieldOr a = ConduitM . yieldOr a
    {-# INLINE yieldOr #-}

    liftStreamMonad = lift
    {-# INLINE liftStreamMonad #-}

    addCleanup c (ConduitM p) = ConduitM (addCleanup c p)
    {-# INLINE addCleanup #-}

instance Monad m => MonadStream (Sink i m) where
    type Upstream (Sink i m) = i
    type StreamTerm (Sink i m) = ()
    type Downstream (Sink i m) = Void
    type StreamMonad (Sink i m) = m
    type Leftover (Sink i m) = i

    await = Sink await
    {-# INLINE await #-}

    awaitE = Sink awaitE
    {-# INLINE awaitE #-}

    leftover = Sink . leftover
    {-# INLINE leftover #-}

    yield = Sink . yield
    {-# INLINE yield #-}

    yieldOr a = Sink . yieldOr a
    {-# INLINE yieldOr #-}

    liftStreamMonad = lift
    {-# INLINE liftStreamMonad #-}

    addCleanup c (Sink p) = Sink (addCleanup c p)
    {-# INLINE addCleanup #-}

-- | Perform some allocation and run an inner @Pipe@. Two guarantees are given
-- about resource finalization:
--
-- 1. It will be /prompt/. The finalization will be run as early as possible.
--
-- 2. It is exception safe. Due to usage of @resourcet@, the finalization will
--    be run in the event of any exceptions.
--
-- Since 0.5.0
bracketP :: (MonadStream m, MonadResource (StreamMonad m))
         => IO a -- ^ allocate
         -> (a -> IO ()) -- ^ free
         -> (a -> m r) -- ^ inside
         -> m r
bracketP alloc free inside = do
    (key, seed) <- liftStreamMonad $ allocate alloc free
    addCleanup (const $ release key) (inside seed)

#define GOALL(C, T) instance C => MonadStream (T) where { type Upstream (T) = Upstream m; type StreamMonad (T) = StreamMonad m; type StreamTerm (T) = StreamTerm m; type Downstream (T) = Downstream m; type Leftover (T) = Leftover m; await = lift await; awaitE = lift awaitE; leftover = lift . leftover; yield = lift . yield; yieldOr a = lift . yieldOr a; liftStreamMonad = lift . liftStreamMonad; addCleanup c r = liftWith (\run -> run $ addCleanup c r) >>= restoreT . return}
#define GO(T) GOALL(MonadStream m, T m)
#define GOX(X, T) GOALL((MonadStream m, X), T m)
GO(IdentityT)
GO(ListT)
GO(MaybeT)
GOX(Error e, ErrorT e)
GO(ReaderT r)
GO(StateT s)
GOX(Monoid w, WriterT w)
GOX(Monoid w, RWST r w s)
GOX(Monoid w, Strict.RWST r w s)
GO(Strict.StateT s)
GOX(Monoid w, Strict.WriterT w)
GO(ResourceT)
#undef GO
#undef GOX
#undef GOALL

-- | Wait for input forever, calling the given inner @Pipe@ for each piece of
-- new input. Returns the upstream result type.
--
-- Since 0.5.0
awaitForever :: MonadStream m
             => (Upstream m -> m r')
             -> m (StreamTerm m)
awaitForever inner =
    self
  where
    self = awaitE >>= either return (\i -> inner i >> self)
{-# INLINE [1] awaitForever #-}

infixr 0 $$
infixl 1 $=
infixr 2 =$
infixr 2 =$=
infixr 0 $$+
infixr 0 $$++
infixr 0 $$+-

($$) :: Monad m => Source m a -> Sink a m b -> m b
SourceM src $$ Sink sink = src C.$$ sink
{-# INLINE ($$) #-}

($=) :: Monad m => Source m a -> Conduit a m b -> Source m b
SourceM src $= ConduitM con = SourceM $ src C.$= con
{-# INLINE ($=) #-}

(=$=) :: Monad m => Conduit a m b -> Conduit b m c -> Conduit a m c
ConduitM l =$= ConduitM r = ConduitM $ l C.=$= r
{-# INLINE (=$=) #-}

(=$) :: Monad m => Conduit a m b -> Sink b m c -> Sink a m c
ConduitM l =$ Sink r = Sink $ l C.=$ r
{-# INLINE (=$) #-}

($$+) :: Monad m => Source m a -> Sink a m b -> m (C.ResumableSource m a, b)
SourceM src $$+ Sink sink = src C.$$+ sink
{-# INLINE ($$+) #-}

($$++) :: Monad m => C.ResumableSource m a -> Sink a m b -> m (C.ResumableSource m a, b)
rsrc $$++ Sink sink = rsrc C.$$++ sink
{-# INLINE ($$++) #-}

($$+-) :: Monad m => C.ResumableSource m a -> Sink a m b -> m b
rsrc $$+- Sink sink = rsrc C.$$+- sink
{-# INLINE ($$+-) #-}

sourceList :: MonadStream m => [Downstream m] -> m ()
sourceList = mapM_ yield
{-# INLINE sourceList #-}

type MonadSource m a = forall source. (MonadStream source, a ~ Downstream source, StreamMonad source ~ m) => source ()
type MonadConduit a m b = forall conduit. (MonadStream conduit, a ~ Upstream conduit, b ~ Downstream conduit, StreamMonad conduit ~ m) => conduit ()
type MonadSink a m b = forall sink. (MonadStream sink, a ~ Upstream sink, StreamMonad sink ~ m) => sink b

liftStreamIO :: (MonadStream m, MonadIO (StreamMonad m)) => IO a -> m a
liftStreamIO = liftStreamMonad . liftIO