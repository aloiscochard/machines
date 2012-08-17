{-# LANGUAGE Rank2Types, GADTs, FlexibleInstances #-}
-----------------------------------------------------------------------------
-- |
-- Module      :  Data.Machine
-- Copyright   :  (C) 2012 Edward Kmett, Runar Bjarnason, Paul Chiusano
-- License     :  BSD-style (see the file LICENSE)
--
-- Maintainer  :  Edward Kmett <ekmett@gmail.com>
-- Stability   :  provisional
-- Portability :  portable
--
----------------------------------------------------------------------------
module Data.Machine
  (
  -- * Plans
    Plan(..)
  , yield
  , await
  , Handle
  , Fitting
  , awaits
  , stop

  -- * Machines
  , Machine(..)
  , runMachine
  , evaluate
  , fitting
  , pass

  -- ** Compiling stream transducers
  , construct
  , before
  , repeatedly
  , sink

  -- * Processs
  , Process
  , after

  , supply
  , prepended
  , filtered
  , dropping
  , taking
  , droppingWhile
  , takingWhile
  , buffered

  -- ** Automata
  , Automaton(..)
  , Mealy(..)
  , Moore(..)

  -- * Sources
  , Source
  , source
  , repeated
  , cycled
  , cap

  -- * Tees
  , Tee
  , Merge(..)
  , tee
  , addL, addR
  , capL, capR
  ) where

import Control.Applicative
import Control.Category
import Control.Monad (ap, MonadPlus(..), replicateM_, when)
import Data.Foldable
import Prelude hiding ((.),id)

-------------------------------------------------------------------------------
-- Plans
-------------------------------------------------------------------------------

-- | You can 'construct' a 'Plan', turning it into a 'Machine'
--
-- It is perhaps easier to think of 'Plan' in its un-cps'ed form, which would
-- look like:
--
-- @
-- data Plan k i o a
--   = Done a
--   | Yield o (Plan k i o a)
--   | Await (k i (Plan k i o a)) (Plan k i o a)
--   | Fail
-- @
newtype Plan k i o a = Plan
  { runPlan :: forall r.
      (a -> r) ->           -- Done a
      (o -> r -> r) ->      -- Yield o (Plan k i o a)
      (k i r -> r -> r) ->  -- Await (k i (Plan k i o a)) (Plan k i o a)
      r ->                  -- Fail
      r
  }

instance Functor (Plan k i o) where
  fmap f (Plan m) = Plan $ \k -> m (k . f)

instance Applicative (Plan k i o) where
  pure a = Plan (\kp _ _ _ -> kp a)
  (<*>) = ap

instance Alternative (Plan k i o) where
  empty = Plan $ \_ _ _ kf -> kf
  Plan m <|> Plan n = Plan $ \kp ke kr kf -> m kp ke (\kir _ -> kr kir (n kp ke kr kf)) kf

instance Monad (Plan k i o) where
  return a = Plan (\kp _ _ _ -> kp a)
  Plan m >>= f = Plan (\kp ke kr kf -> m (\a -> runPlan (f a) kp ke kr kf) ke kr kf)
  fail _ = Plan (\_ _ _ kf -> kf)

instance MonadPlus (Plan k i o) where
  mzero = empty
  mplus = (<|>)

-- | Output a result.
yield :: o -> Plan k i o ()
yield o = Plan (\kp ke _ _ -> ke o (kp ()))

-- | Wait for input.
--
-- @'await' = 'awaits' 'id'@
await :: Plan (->) i o i
await = Plan (\kp _ kr kf -> kr kp kf)

-- | Many combinators are parameterized on the choice of 'Handle',
-- this acts like an input stream selector.
--
-- @
-- 'L' :: 'Handle' 'Merge' (a,b) a
-- 'R' :: 'Handle' 'Merge' (a,b) b
-- @
type Handle k i o = forall r. (o -> r) -> k i r

-- |
-- @type 'Handle' = 'Fitting' (->)@
type Fitting k k' o i = forall r. k o r -> k' i r

-- | Wait for a particular input.
--
-- @
-- awaits 'L'  :: 'Plan' 'Merge' (a,b) o a
-- awaits 'R'  :: 'Plan' 'Merge' (a,b) o b
-- awaits 'id' :: 'Plan' (->) i o i
-- @
awaits :: Functor (k i) => Handle k i j -> Plan k i o j
awaits f = Plan $ \kp _ kr kf -> kr (fmap kp (f id)) kf

-- | @'stop' = 'empty'@
stop :: Plan k i o a
stop = empty

-- | Stop feeding input into model and extract an answer
evaluate :: Machine k a b -> [b]
evaluate Stop          = []
evaluate (Yield o k)   = o : evaluate k
evaluate (Await _ _ f) = evaluate f

-------------------------------------------------------------------------------
-- Transduction Machines
-------------------------------------------------------------------------------

-- | A 'Machine' reads from a number of inputs and may yield results before stopping.
data Machine k i o
  = Yield o (Machine k i o)
  | forall r. Await (r -> Machine k i o) (k i r) (Machine k i o)
  | Stop

instance Functor (Machine k i) where
  fmap f (Yield o xs) = Yield (f o) (fmap f xs)
  fmap f (Await k kir e) = Await (fmap f . k) kir (fmap f e)
  fmap _ Stop = Stop

-- |
-- Connect different kinds of pipes.
--
-- @'fitting' 'id' = 'id'@
--
-- @
-- 'fitting' 'L' :: 'Process' a c -> 'Tee' a b c
-- 'fitting' 'R' :: 'Process' b c -> 'Tee' a b c
-- 'fitting' 'id' :: 'Process' a b -> 'Process' a b
-- @
fitting :: (forall a. k i a -> k' i' a) -> Machine k i o -> Machine k' i' o
fitting f (Yield o k)     = Yield o (fitting f k)
fitting _ Stop            = Stop
fitting f (Await g kir h) = Await (fitting f . g) (f kir) (fitting f h)

runMachine :: Functor (k i) => Machine k i o -> (o -> r -> r) -> (k i r -> r -> r) -> r -> r
runMachine m ke kr kf  = go m where
  go (Yield o k)     = ke o (go k)
  go (Await f kir r) = kr (fmap (go . f) kir) (go r)
  go Stop            = kf
{-# INLINE runMachine #-}

-- | Compile a machine to a model.
construct :: Plan k i o a -> Machine k i o
construct m = runPlan m (const Stop) Yield (Await id) Stop

-- | Generates a model that runs a machine until it stops, then start it up again.
--
-- @'repeatedly' m = 'construct' ('forever' m)@
repeatedly :: Plan k i o a -> Machine k i o
repeatedly m = r where r = runPlan m (const r) Yield (Await id) Stop

-- | Evaluate a machine until it stops, and then yield answers according to the supplied model.
before :: Machine k i o -> Plan k i o a -> Machine k i o
before f m = runPlan m (const f) Yield (Await id) Stop

instance Category (Machine (->)) where
  id = Await (`Yield` id) id Stop
  Stop          . _              = Stop
  Yield a as    . sf             = Yield a (as . sf)
  Await f kir _ . Yield b bs     = fmap f kir b . bs
  Await _ _ k   . Stop           = k . Stop
  sf            . Await g kir fg = Await (\a -> sf . g a) kir (sf . fg)

class Automaton k where
  auto :: k a b -> Process a b

instance Automaton (->) where
  auto f = repeatedly $ do
    i <- await
    yield (f i)

type Process = Machine (->)

-- | 'Mealy' machines
newtype Mealy a b = Mealy { runMealy :: a -> (b, Mealy a b) }

instance Automaton Mealy where
  auto = construct . loop where
    loop (Mealy f) = await >>= \a -> case f a of
      (b, m) -> do
         yield b
         loop m

-- | 'Moore' machines
data Moore a b = Moore b (a -> Moore a b)

instance Automaton Moore where
  auto = construct . loop where
    loop (Moore b f) = do
      yield b
      await >>= loop . f

prepended :: Foldable f => f a -> Process a a
prepended = before id . traverse_ yield

filtered :: (a -> Bool) -> Process a a
filtered p = repeatedly $ do
  i <- await
  when (p i) $ yield i

-- | A process that drops the first @n@, then repeats the rest.
dropping :: Int -> Process a a
dropping n = before id $ replicateM_ n await

-- | A process that passes through the first @n@ elements from its input then stops
taking :: Int -> Process a a
taking n = construct . replicateM_ n $ await >>= yield

-- | A process that passes through elements until a predicate ceases to hold, then stops
takingWhile :: (a -> Bool) -> Process a a
takingWhile p = repeatedly $ await >>= \v -> if p v then yield v else stop

-- | A process that drops elements while a predicate holds
droppingWhile :: (a -> Bool) -> Process a a
droppingWhile p = before id loop where
  loop = await >>= \v -> if p v then loop else yield v

{-
-- | Bolt a 'Process' on the end of any 'Machine'.
pipe :: Process b c -> Machine k a b -> Machine k a c
pipe Stop            _                = Stop
pipe (Yield a as)    sf               = Yield a (pipe as sf)
pipe (Await f kir _) (Yield b bs)     = pipe (fmap f kir b) bs
pipe (Await _ _ g)   Stop             = pipe g Stop
pipe sf              (Await g kir fg) = Await (fmap (pipe sf) g) kir (pipe sf fg)
-}

after :: Machine k a b -> Process b c -> Machine k a c
after _ Stop                            = Stop
after sf (Yield a as)    = Yield a (after sf as)
after (Yield b bs) (Await f kir _)  = after bs (fmap f kir b)
after Stop (Await _ _ g)   = after Stop g
after (Await g kir fg) sf = Await (fmap (`after` sf) g) kir (after fg sf)

-- | Chunk up the input into `n` element lists.
-- The last list may be shorter.
buffered :: Int -> Process a [a]
buffered = repeatedly . go [] where
  go [] 0  = stop
  go acc 0 = yield (reverse acc)
  go acc n = do
    i <- await <|> yield (reverse acc) *> stop
    go (i:acc) $! n-1

-- | Feed a 'Process' some input.
supply :: [a] -> Process a b -> Process a b
supply []     r             = r
supply _      Stop          = Stop
supply (x:xs) (Await f kir _) = supply xs (fmap f kir x)
supply xs     (Yield o k)    = Yield o (supply xs k)

-- |
-- @
-- 'pass' 'id' :: 'Process' a a
-- 'pass' 'L' :: 'Tee' a b a
-- 'pass' 'R' :: 'Tee' a b b
-- @
pass :: Functor (k i) => Handle k i o -> Machine k i o
pass input = repeatedly $ do
  a <- awaits input
  yield a

-------------------------------------------------------------------------------
-- Source
-------------------------------------------------------------------------------

-- | A 'Source' never reads from its input.
type Source b = forall k a. Machine k a b

-- | Repeat the same value, over and over.
repeated :: o -> Source o
repeated = repeatedly . yield

-- | Loop through a 'Foldable' container over and over.
cycled :: Foldable f => f b -> Source b
cycled xs = repeatedly (traverse_ yield xs)

-- | Generate a 'Source' from any 'Foldable' container.
source :: Foldable f => f b -> Source b
source xs = construct (traverse_ yield xs)

-- |
-- You can fitting a 'Source' with a 'Process'.
--
-- This is equivalent to capping the 'Process'.
--
-- @'cap' = 'pipe'@
--
cap :: Process a b -> Source a -> Source b
cap l r = after r l

-------------------------------------------------------------------------------
-- Sink
-------------------------------------------------------------------------------

-- |
-- A 'Sink' in this model is a 'Process' (or 'Tee', etc) that produces a single answer.
--
-- \"Is that your final answer?\"
sink :: (forall o. Plan k i o a) -> Machine k i a
sink m = runPlan m (\a -> Yield a Stop) id (Await id) Stop

-------------------------------------------------------------------------------
-- Tees
-------------------------------------------------------------------------------

data Merge i c where
  L :: (a -> c) -> Merge (a, b) c
  R :: (b -> c) -> Merge (a, b) c

instance Functor (Merge i) where
  fmap f (L k) = L (f . k)
  fmap f (R k) = R (f . k)

type Tee a b = Machine Merge (a, b)

-- | Compose a pair of pipes onto the front of a Tee.
tee :: Process a a' -> Process b b' -> Tee a' b' c -> Tee a b c
tee a b (Yield c sf) = Yield c $ tee a b sf
tee _ _ Stop        = Stop
tee (Yield a sf) b (Await f (L kf) _) = tee sf b (fmap f kf a)
tee Stop b (Await _ L{} ff) = tee Stop b ff
tee (Await g kg fg) b (Await f (L kf) ff) =
  Await id (L (\a -> tee (fmap g kg a) b (Await f (L kf) ff))) (tee fg b (Await f (L kf) ff))
tee a (Yield b sf) (Await f (R kf) _) = tee a sf (fmap f kf b)
tee a Stop (Await _ R{} ff) = tee a Stop ff
tee a (Await g kg fg) (Await f (R kf) ff) =
  Await id (R (\b -> tee a (fmap g kg b) (Await f (R kf) ff))) (tee a fg (Await f (R kf) ff))

-- | Precompose a pipe onto the left input of a tee.
addL :: Process a b -> Tee b c d -> Tee a c d
addL p = tee p id

{-
addL a              (Yield c sf)        = Yield c $ addL a sf
addL _              Stop               = Stop
addL (Yield a sf)    (Await f (L kf) _)  = addL sf (fmap f kf a)
addL Stop           (Await _ L{} ff)    = addL Stop ff
addL (Await g kg fg) (Await f (L kf) ff) =
  Await id (L (\a -> addL (fmap g kg a) (Await f (L kf) ff))) (addL fg (Await f (L kf) ff))
addL a              (Await f (R kf) ff) = Await (addL a . f . kf) (R id) (addL a ff)
-}

-- | Precompose a pipe onto the right input of a tee.
addR :: Process b c -> Tee a c d -> Tee a b d
addR = tee id

-- | Tie off one input of a tee by connecting it to a known source.
capL :: Source a -> Tee a b c -> Process b c
capL s t = fitting capped (addL s t)

-- | Tie off one input of a tee by connecting it to a known source.
capR :: Source b -> Tee a b c -> Process a c
capR s t = fitting capped (addR s t)

-- | Natural transformation used by 'capL' and 'capR'.
capped :: Merge (a, a) b -> a -> b
capped (R r) = r
capped (L r) = r

{-
class Handled k where
  handleMatches :: Handle k i o -> k i r -> Bool

instance Handled (->) where
  handleMatches _ _ = True

instance Handled Merge where
  handleMatches h L{} = case h id of L{} -> True; _ -> False
  handleMatches h R{} = case h id of R{} -> True; _ -> False
-}
