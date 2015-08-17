{-| This module is very closely modeled on Pipes.Prelude.

    Import qualified thus:

> import Streaming
> import qualified Streaming as S

    The @Streaming@ module exports types, functor-general operations and some other kit; 
    it may clash with @free@ and @pipes-group@, but not with standard base modules.

    Interoperation with @pipes@ is accomplished with this isomorphism, which
    uses @Pipes.Prelude.unfoldr@ from @HEAD@:

> Pipes.unfoldr Streaming.next        :: Stream (Of a) m r   -> Producer a m r
> Streaming.unfoldr Pipes.next        :: Producer a m r      -> Stream (Of a) m r                     

    Interoperation with `iostreams` is thus:

> Streaming.reread IOStreams.read     :: InputStream a       -> Stream (Of a) IO ()
> IOStreams.unfoldM Streaming.uncons  :: Stream (Of a) IO () -> IO (InputStream a)

    A simple exit to conduit would be, for example:

> Conduit.unfoldM Streaming.uncons    :: Stream (Of a) m ()  -> Source m a
-}
{-# LANGUAGE RankNTypes, BangPatterns, DeriveDataTypeable,
             DeriveFoldable, DeriveFunctor, DeriveTraversable #-}
             
module Streaming.Prelude (
    -- * Types
    Stream 
    , Of (..)
    , lazily
    , strictly

    -- * Introducing streams of elements
    -- $producers
    , yield
    , each
    , unfoldr
    , stdinLn
    , readLn
    , fromHandle
    , repeat
    , repeatM
    , replicateM
    
    -- * Consuming streams of elements
    -- $consumers
    , stdoutLn
    , stdoutLn'
    , mapM_
    , print
    , toHandle
    , drain

    -- * Stream transformers
    -- $pipes
    , map
    , mapM
    , maps'
    , maps
    , sequence
    , mapFoldable
    , filter
    , filterM
    , for
    , take
    , takeWhile
--    , takeWhile'
    , drop
    , dropWhile
    , concat
    -- , elemIndices
    -- , findIndices
    , scan
    , scanM
    , chain
    , read
    , show
    , cons

    -- * Splitting and inspecting streams of elements
    , next
    , uncons
    , splitAt
    , break
    , span
 --   , split
    
    -- * Folds
    -- $folds
    , fold
    , fold'
    , foldM
    , foldM'
    , sum
    , sum'
    , product
    , product'
    , toList
    , toListM
    , toListM'
    , foldrM
    , foldrT
    
    -- * Short circuiting folds
    -- , all
    -- , any
    -- , and
    -- , or
    -- , elem
    -- , notElem
    -- , find
    -- , findIndex
    -- , head
    -- , index
    -- , last
    -- , length
    -- , maximum
    -- , minimum
    -- , null

    -- * Zips
    , zip
    , zipWith
    
    -- * Interoperation
    , reread
    

  ) where
import Streaming.Internal

import Control.Monad hiding (filterM, mapM, mapM_, foldM, replicateM, sequence)
import Data.Data ( Data, Typeable )
import Data.Functor.Identity
import Control.Monad.Trans
import qualified Prelude as Prelude                      
import qualified Data.Foldable as Foldable
import Text.Read (readMaybe)
import Prelude hiding (map, mapM, mapM_, filter, drop, dropWhile, take, sum, product
                      , iterate, repeat, replicate, splitAt
                      , takeWhile, enumFrom, enumFromTo
                      , print, zipWith, zip, seq, show, read
                      , readLn, sequence, concat, span, break)

import qualified GHC.IO.Exception as G
import qualified System.IO as IO
import Foreign.C.Error (Errno(Errno), ePIPE)
import Control.Exception (throwIO, try)


-- | A left-strict pair; the base functor for streams of individual elements.
data Of a b = !a :> b
    deriving (Data, Eq, Foldable, Functor, Ord,
              Read, Show, Traversable, Typeable)
infixr 4 :>

lazily :: Of a b -> (a,b)
lazily = \(a:>b) -> (a,b)
{-# INLINE lazily #-}

strictly :: (a,b) -> Of a b
strictly = \(a,b) -> a :> b
{-# INLINE strictly #-}

{-| Break a sequence when a element falls under a predicate, keeping the rest of
    the stream as the return value.

>>> rest <- S.print $ S.break even $ each [1,1,2,3]
1
1
>>> S.print rest
2
3


-}

break :: Monad m => (a -> Bool) -> Stream (Of a) m r 
      -> Stream (Of a) m (Stream (Of a) m r)
break pred = loop where
  loop str = case str of 
    Return r         -> Return (Return r)
    Delay m          -> Delay $ liftM loop m
    Step (a :> rest) -> if (pred a) 
      then Return (Step (a :> rest))
      else Step (a :> loop rest)
{-# INLINEABLE break #-}

{-| Apply an action to all values flowing downstream

>>> let debug str = chain print str
>>> S.product (debug (S.each [2..4])) >>= print
2
3
4
24

-}
chain :: Monad m => (a -> m ()) -> Stream (Of a) m r -> Stream (Of a) m r
chain f str = for str $ \a -> do
    lift (f a)
    yield a
{-# INLINE chain #-}

{-| Make a stream of traversable containers into a stream of their separate elements

>>> Streaming.print $ concat (each ["hi","ho"])
'h'
'i'
'h'
'o'

>>> S.print $  S.concat (S.each [Just 1, Nothing, Just 2, Nothing])
1
2

>>> S.print $  S.concat (S.each [Right 1, Left "error!", Right 2])
1
2
-}

concat :: (Monad m, Foldable f) => Stream (Of (f a)) m r -> Stream (Of a) m r
concat str = for str each
{-# INLINE concat #-}
--
{-| The natural @cons@ for a @Stream (Of a)@. 

> cons a stream = yield a >> stream

Useful for interoperation 

-}

cons :: (Monad m) => a -> Stream (Of a) m r -> Stream (Of a) m r
cons a str = Step (a :> str)
{-# INLINE cons #-}


-- ---------------
-- drain
-- ---------------

-- | Reduce a stream, performing its actions but ignoring its elements.
drain :: Monad m => Stream (Of a) m r -> m r
drain = loop where
  loop stream = case stream of 
    Return r         -> return r
    Delay m          -> m >>= loop 
    Step (_ :> rest) -> loop rest

-- ---------------
-- drop
-- ---------------

-- | Ignore the first n elements of a stream, but carry out the actions
drop :: (Monad m) => Int -> Stream (Of a) m r -> Stream (Of a) m r
drop = loop where
  loop n stream 
    | n <= 0    = stream
    | otherwise = case stream of
      Return r       -> Return r
      Delay ma       -> Delay (liftM (loop n) ma)
      Step (a :> as) -> loop (n-1) as
{-# INLINEABLE drop #-}

-- ---------------
-- dropWhile
-- ---------------

-- | Ignore elements of a stream until a test succeeds.
dropWhile :: Monad m => (a -> Bool) -> Stream (Of a) m r -> Stream (Of a) m r
dropWhile pred = loop where 
  loop stream = case stream of
    Return r       -> Return r
    Delay ma       -> Delay (liftM loop ma)
    Step (a :> as) -> if pred a 
      then loop as
      else Step (a :> as)
{-# INLINEABLE dropWhile #-}

-- ---------------
-- each 
-- ---------------

{- | Stream the elements of a foldable container.

>>> S.print $ S.each [1..3]
1
2
3
-}
each :: (Monad m, Foldable.Foldable f) => f a -> Stream (Of a) m ()
each = Foldable.foldr (\a p -> Step (a :> p)) (Return ())
{-# INLINE each #-}

-- -----
-- enumFrom
-- ------

enumFrom :: (Monad m, Num n) => n -> Stream (Of n) m ()
enumFrom = loop where
  loop !n = Step (n :> loop (n+1))
{-# INLINEABLE enumFrom #-}

enumFromTo :: (Monad m, Num n, Ord n) => n -> n -> Stream (Of n) m ()
enumFromTo = loop where
  loop !n m = if n <= m 
    then Step (n :> loop (n+1) m)
    else Return ()
{-# INLINEABLE enumFromTo #-}

enumFromStepN :: (Monad m, Num a) => a -> a -> Int -> Stream (Of a) m ()
enumFromStepN start step = loop start where
    loop !s m = case m of 
      0 -> Return ()
      _ -> Step (s :> loop (s+step) (m-1))
{-# INLINEABLE enumFromStepN #-}

-- ---------------
-- filter 
-- ---------------

-- | Skip elements of a stream that fail a predicate
filter  :: (Monad m) => (a -> Bool) -> Stream (Of a) m r -> Stream (Of a) m r
filter pred = loop where
  loop !str = case str of
    Return r       -> Return r
    Delay m        -> Delay (liftM loop m)
    Step (a :> as) -> if pred a 
                         then Step (a :> loop as)
                         else loop as
{-# INLINEABLE filter #-}

-- ---------------
-- filterM
-- ---------------

-- | Skip elements of a stream that fail a monadic test
filterM  :: (Monad m) => (a -> m Bool) -> Stream (Of a) m r -> Stream (Of a) m r
filterM pred = loop where
  loop str = case str of
    Return r       -> Return r
    Delay m        -> Delay $ liftM loop m
    Step (a :> as) -> Delay $ do 
      bool <- pred a
      if bool 
        then return $ Step (a :> loop as)
        else return $ loop as
{-# INLINEABLE filterM #-}
-- ---------------
-- fold
-- ---------------

{- $folds
    Use these to fold the elements of a 'Stream'.  The general folds 'fold', fold\'',
    'foldM' and 'foldM\'' are arranged for use with 'Control.Foldl' All functions marked
    with a final '\'' (e.g. 'fold\'', 'sum\') carry the stream's return value -- or, in
    the case of 'maps\'' are tailored to take such an operation as argument.

>  maps' sum' :: (Monad m, Num n) => Stream (Stream (Of n)) m r -> Stream (Of n) m r
>  maps' (fold' mappend mempty id) :: :: (Monad m, Num n) => Stream (Stream (Of n)) m r -> Stream (Of n) m r
-}

{-| Strict fold of a 'Stream' of elements

> Control.Foldl.purely fold :: Monad m => Fold a b -> Stream (Of a) m () -> m b
-}
fold :: Monad m => (x -> a -> x) -> x -> (x -> b) -> Stream (Of a) m () -> m b
fold step begin done stream0 = loop stream0 begin
  where
    loop stream !x = case stream of 
      Return r         -> return (done x)
      Delay m          -> m >>= \s -> loop s x
      Step (a :> rest) -> loop rest (step x a)
{-# INLINABLE fold #-}

{-| Strict fold of a 'Stream' of elements that preserves the return value

> Control.Foldl.purely fold' :: Monad m => Fold a b -> Stream (Of a) m r -> m (b, r)
-}

fold' :: Monad m => (x -> a -> x) -> x -> (x -> b) -> Stream (Of a) m r -> m (b, r)
fold' step begin done s0 = loop s0 begin
  where
    loop stream !x = case stream of 
      Return r         -> return (done x, r)
      Delay m          -> m >>= \s -> loop s x
      Step (a :> rest) -> loop rest (step x a)
{-# INLINABLE fold' #-}

{-| Strict, monadic fold of the elements of a 'Stream (Of a)'

> Control.Foldl.impurely foldM :: Monad m => FoldM a b -> Stream (Of a) m () -> m b
-}
foldM
    :: Monad m
    => (x -> a -> m x) -> m x -> (x -> m b) -> Stream (Of a) m () -> m b
foldM step begin done s0 = do
    x0 <- begin
    loop s0 x0
  where
    loop stream !x = case stream of 
      Return r         -> done x 
      Delay m          -> m >>= \s -> loop s x
      Step (a :> rest) -> do
        x' <- step x a
        loop rest x'
{-# INLINABLE foldM #-}

{-| Strict, monadic fold of the elements of a 'Stream (Of a)'

> Control.Foldl.impurely foldM' :: Monad m => FoldM a b -> Stream (Of a) m r -> m (b, r)
-}
foldM'
    :: Monad m
    => (x -> a -> m x) -> m x -> (x -> m b) -> Stream (Of a) m r -> m (b, r)
foldM' step begin done str = do
    x0 <- begin
    loop str x0
  where
    loop stream !x = case stream of 
      Return r         -> done x >>= \b -> return (b, r)
      Delay m          -> m >>= \s -> loop s x
      Step (a :> rest) -> do
        x' <- step x a
        loop rest x'
{-# INLINABLE foldM' #-}

{-| A natural right fold for consuming a stream of elements. 
    See also the more general 'iterTM' in the 'Streaming' module 
    and the still more general 'destroy'

> foldrT (\a p -> Pipes.yield a >> p) :: Monad m => Stream (Of a) m r -> Producer a m r
> foldrT (\a p -> Conduit.yield a >> p) :: Monad m => Stream (Of a) m r -> Conduit a m r

-}

foldrT :: (Monad m, MonadTrans t, Monad (t m)) 
       => (a -> t m r -> t m r) -> Stream (Of a) m r -> t m r
foldrT step = loop where
  loop stream = case stream of
    Return r       -> return r
    Delay m        -> lift m >>= loop
    Step (a :> as) -> step a (loop as)
{-# INLINABLE foldrT #-}  

{-| A natural right fold for consuming a stream of elements.
    See also the more general 'iterT' in the 'Streaming' module and the
    still more general 'destroy'
-}
foldrM :: Monad m 
       => (a -> m r -> m r) -> Stream (Of a) m r -> m r
foldrM step = loop where
  loop stream = case stream of
    Return r       -> return r
    Delay m        -> m >>= loop
    Step (a :> as) -> step a (loop as)
{-# INLINABLE foldrM #-}  

-- ---------------
-- for
-- ---------------

-- | @for@ replaces each element of a stream with an associated stream. Note that the
-- associated stream may layer any functor. 
for :: (Monad m, Functor f) => Stream (Of a) m r -> (a -> Stream f m x) -> Stream f m r
for str0 act = loop str0 where
  loop str = case str of
    Return r         -> Return r 
    Delay m          -> Delay $ liftM loop m
    Step (a :> rest) -> do
      act a
      loop rest
{-# INLINEABLE for #-}

-- ---------------
-- iterate
-- ---------------

-- | Iterate a pure function from a seed value, streaming the results forever
iterate :: (a -> a) -> a -> Stream (Of a) m r
iterate f = loop where
  loop a' = Step (a' :> loop (f a'))
{-# INLINEABLE iterate #-}

-- | Iterate a monadic function from a seed value, streaming the results forever
iterateM :: Monad m => (a -> m a) -> m a -> Stream (Of a) m r
iterateM f = loop where
  loop ma  = Delay $ do 
    a <- ma
    return (Step (a :> loop (f a)))
{-# INLINEABLE iterateM #-}

-- ---------------
-- map
-- ---------------

-- | Standard map on the elements of a stream.
map :: Monad m => (a -> b) -> Stream (Of a) m r -> Stream (Of b) m r
map f = loop where
  loop stream = case stream of
    Return r -> Return r
    Delay m -> Delay (liftM loop m)
    Step (a :> as) -> Step (f a :> loop as)
{-# INLINEABLE map #-}

-- ---------------
-- mapFoldable
-- ---------------

{-| For each element of a stream, stream a foldable container of elements instead

>>> D.print $ D.mapFoldable show $ D.yield 12
'1'
'2'

-}
mapFoldable :: (Monad m, Foldable t) => (a -> t b) -> Stream (Of a) m r -> Stream (Of b) m r
mapFoldable f str = for str (\a -> each (f a)) -- as in pipes

-- | Replace each element of a stream with the result of a monadic action
mapM :: Monad m => (a -> m b) -> Stream (Of a) m r -> Stream (Of b) m r
mapM f = loop where
  loop str = case str of 
    Return r       -> Return r 
    Delay m        -> Delay $ liftM loop m
    Step (a :> as) -> Delay $ do 
      a' <- f a 
      return $ Step (a' :> loop as) 
{-# INLINEABLE mapM #-}


{-| Reduce a stream to its return value with a monadic action.

>>>  mapM_ Prelude.print $ each [1..3] >> return True
1
2
3
True

-}
mapM_ :: Monad m => (a -> m b) -> Stream (Of a) m r -> m r
mapM_ f = loop where
  loop str = case str of 
    Return r       -> return r 
    Delay m        -> m >>= loop
    Step (a :> as) -> do 
      f a 
      loop as 
{-# INLINEABLE mapM_ #-}
{-| Map free layers of a functor to a corresponding stream of individual elements. This
     simplifies the use of folds marked with a \'\'\' in @Streaming.Prelude@

> maps' sum' :: (Monad m, Num a) => Stream (Stream (Of a) m) m r -> Stream (Of a) m r
> maps' (Pipes.fold' (+) (0::Int) id) :: Monad m => Stream (Producer Int m) m r -> Stream (Of Int) m r

-}
maps' :: (Monad m, Functor f) 
          => (forall x . f x -> m (a, x)) 
          -> Stream f m r 
          -> Stream (Of a) m r
maps' phi = loop where
  loop stream = case stream of 
    Return r -> Return r
    Delay m -> Delay $ liftM loop m
    Step fs -> Delay $ liftM (Step . uncurry (:>)) (phi (fmap loop fs))
{-# INLINABLE maps' #-}

{-| The standard way of inspecting the first item in a stream of elements, if the
     stream is still \'running\'. The @Right@ case contains a 
     Haskell pair, where the more general @inspect@ would return a left-strict pair. 
     There is no reason to prefer @inspect@ since, if the @Right@ case is exposed, 
     the first element in the pair will have been evaluated to whnf.

> next :: Monad m => Stream (Of a) m r -> m (Either r (a, Stream (Of a) m r))
> inspect :: Monad m => Stream (Of a) m r -> m (Either r (Of a (Stream (Of a) m r)))

     Interoperate with @pipes@ producers thus:

> Pipes.unfoldr Stream.next :: Stream (Of a) m r -> Producer a m r
> Stream.unfoldr Pipes.next :: Producer a m r -> Stream (Of a) m r 
     
     Similarly: 

> IOStreams.unfoldM (liftM (either (const Nothing) Just) . next) :: Stream (Of a) IO b -> IO (InputStream a)
> Conduit.unfoldM (liftM (either (const Nothing) Just) . next)   :: Stream (Of a) m r -> Source a m r

     But see 'uncons'
-}
next :: Monad m => Stream (Of a) m r -> m (Either r (a, Stream (Of a) m r))
next = loop where
  loop stream = case stream of
    Return r         -> return (Left r)
    Delay m          -> m >>= loop
    Step (a :> rest) -> return (Right (a,rest))
{-# INLINABLE next #-}


{-| Inspect the first item in a stream of elements, without a return value. 
    @uncons@ provides convenient exit into another streaming type:

> IOStreams.unfoldM uncons :: Stream (Of a) IO b -> IO (InputStream a)
> Conduit.unfoldM uncons   :: Stream (Of a) m r -> Conduit.Source m a

-}
uncons :: Monad m => Stream (Of a) m () -> m (Maybe (a, Stream (Of a) m ()))
uncons = loop where
  loop stream = case stream of
    Return ()        -> return Nothing
    Delay m          -> m >>= loop
    Step (a :> rest) -> return (Just (a,rest))
{-# INLINABLE uncons #-}


-- | Fold a 'Stream' of numbers into their product
product :: (Monad m, Num a) => Stream (Of a) m () -> m a
product = fold (*) 1 id
{-# INLINE product #-}

{-| Fold a 'Stream' of numbers into their product with the return value

>  maps' product' :: Stream (Stream (Of Int)) m r -> Stream (Of Int) m r
-}
product' :: (Monad m, Num a) => Stream (Of a) m r -> m (a,r)
product' = fold' (*) 1 id
{-# INLINAE product' #-}

-- ---------------
-- read
-- ---------------

-- | Make a stream of strings into a stream of parsed values, skipping bad cases
read :: (Monad m, Read a) => Stream (Of String) m r -> Stream (Of a) m r
read stream = for stream $ \str -> case readMaybe str of 
  Nothing -> return ()
  Just r  -> yield r
{-# INLINE read #-}

-- ---------------
-- repeat
-- ---------------
{-| Repeat an element /ad inf./ .

>>> S.print $ S.take 3 $ S.repeat 1
1
1
1
-}

repeat :: a -> Stream (Of a) m r
repeat a = loop where loop = Step (a :> loop)
{-# INLINE repeat #-}


{-| Repeat a monadic action /ad inf./, streaming its results.

>>>  L.purely fold L.list $ S.take 2 $ repeatM getLine
hello
world
["hello","world"]

-}

repeatM :: Monad m => m a -> Stream (Of a) m r
repeatM ma = loop where
  loop = Delay $ do 
    a <- ma 
    return (Step (a :> loop))
{-# INLINEABLE repeatM #-}

-- ---------------
-- replicate 
-- ---------------

-- | Repeat an element several times
replicate :: Monad m => Int -> a -> Stream (Of a) m ()
replicate n a = loop n where
  loop 0 = Return ()
  loop m = Step (a :> loop (m-1))
{-# INLINEABLE replicate #-}

-- | Repeat an action several times, streaming the results.
replicateM :: Monad m => Int -> m a -> Stream (Of a) m ()
replicateM n ma = loop n where 
  loop 0 = Return ()
  loop n = Delay $ do 
    a <- ma 
    return (Step $ a :> loop (n-1))
{-# INLINEABLE replicateM #-}

{-| Read an @IORef (Maybe a)@ or a similar device until it reads @Nothing@.
    @reread@ provides convenient exit from the @io-streams@ library

> reread readIORef    :: IORef (Maybe a) -> Stream (Of a) IO ()
> reread Streams.read :: System.IO.Streams.InputStream a -> Stream (Of a) IO ()
-}
reread :: Monad m => (s -> m (Maybe a)) -> s -> Stream (Of a) m ()
reread step s = loop where 
  loop = Delay $ do 
    m <- step s
    case m of 
      Nothing -> return (Return ())
      Just a  -> return (Step (a :> loop))
{-# INLINEABLE reread #-}

{-| Strict left scan, streaming, e.g. successive partial results.

> Control.Foldl.purely scan :: Monad m => Fold a b -> Stream (Of a) m r -> Stream (Of b) m r

>>> Streaming.print $ Foldl.purely Streaming.scan Foldl.list $ each [3..5]
[]
[3]
[3,4]
[3,4,5]

-}
scan :: Monad m => (x -> a -> x) -> x -> (x -> b) -> Stream (Of a) m r -> Stream (Of b) m r
scan step begin done = loop begin
  where
    loop !x stream = do 
      yield (done x)
      case stream of 
        Return r -> Return r
        Delay m  -> Delay $ liftM (loop x) m
        Step (a :> rest) -> do
          let x' = step x a
          loop x' rest
{-# INLINABLE scan #-}

{-| Strict, monadic left scan

> Control.Foldl.impurely scanM :: Monad m => FoldM a m b -> Stream (Of a) m r -> Stream (Of b) m r

>>> let v =  L.impurely scanM L.vector $ each [1..4::Int] :: Stream (Of (U.Vector Int)) IO ()
>>> S.print v
fromList []
fromList [1]
fromList [1,2]
fromList [1,2,3]
fromList [1,2,3,4]

-}
scanM :: Monad m => (x -> a -> m x) -> m x -> (x -> m b) -> Stream (Of a) m r -> Stream (Of b) m r
scanM step begin done str = do
    x <- lift begin
    loop x str
  where
    loop !x stream = do 
      b <- lift (done x)
      yield b
      case stream of 
        Return r -> Return r
        Delay m  -> Delay $ liftM (loop x) m
        Step (a :> rest) -> do
          x' <- lift $ step x a
          loop x' rest
{-# INLINABLE scanM #-}

-- ---------------
-- sequence
-- ---------------

{-| Like the 'Data.List.sequence' but streaming. The result type is a
    stream of a\'s, /but is not accumulated/; the effects of the elements
    of the original stream are interleaved in the resulting stream. Compare:

> sequence :: Monad m =>       [m a]           -> m [a]
> sequence :: Monad m => Stream (Of (m a)) m r -> Stream (Of a) m r
-}
sequence :: Monad m => Stream (Of (m a)) m r -> Stream (Of a) m r
sequence = loop where
  loop stream = case stream of
    Return r          -> Return r
    Delay m           -> Delay $ liftM loop m
    Step (ma :> rest) -> Delay $ do
      a <- ma
      return (Step (a :> loop rest))
{-# INLINEABLE sequence #-}

-- ---------------
-- show
-- ---------------

show :: (Monad m, Show a) => Stream (Of a) m r -> Stream (Of String) m r
show = map Prelude.show
{-# INLINE show #-}
-- ---------------
-- sum 
-- ---------------

-- | Fold a 'Stream' of numbers into their sum
sum :: (Monad m, Num a) => Stream (Of a) m () -> m a
sum = fold (+) 0 id
{-# INLINE sum #-}

{-| Fold a 'Stream' of numbers into their sum with the return value

>  maps' sum' :: Stream (Stream (Of Int)) m r -> Stream (Of Int) m r
-}
sum' :: (Monad m, Num a) => Stream (Of a) m r -> m (a, r)
sum' = fold' (+) 0 id
{-# INLINE sum' #-}

-- ---------------
-- span
-- ---------------

-- | Stream elements until one fails the condition, return the rest.
span :: Monad m => (a -> Bool) -> Stream (Of a) m r 
      -> Stream (Of a) m (Stream (Of a) m r)
span pred = loop where
  loop str = case str of 
    Return r         -> Return (Return r)
    Delay m          -> Delay $ liftM loop m
    Step (a :> rest) -> if pred a 
      then Step (a :> loop rest)
      else Return (Step (a :> rest))
{-# INLINEABLE span #-}


{-| Split a succession of layers after some number, returning a streaming or
--   effectful pair. This function is the same as the 'splitsAt' exported by the
--   @Streaming@ module, but since this module is imported qualified, it can 
--   usurp a Prelude name. It specializes to:

>  splitAt :: (Monad m, Functor f) => Int -> Stream (Of a) m r -> Stream (Of a) m (Stream (Of a) m r)

-}
splitAt :: (Monad m, Functor f) => Int -> Stream f m r -> Stream f m (Stream f m r)
splitAt = splitsAt
{-# INLINE splitAt #-}

-- {-| Split a stream of elements on each occurrence of a value, omitting the value;
--     if it appears as the last item in the stream, an empty stream will follow.
-- -}
-- split :: (Monad m, Eq a) => a -> Stream (Of a) m r -> Stream (Stream (Of a) m) m r
-- split a stream = -- loop where
--   -- loop stream =
--   case stream of
--     Return r         -> Return r
--     Delay m          -> Delay (liftM (split a) m)
--     Step (a' :> rest) -> if a == a'
--       then Step $ do
--         e <- lift $ inspect $ split a rest
--         case e of
--             Left r ->  Return (Return r)
--             Right b -> b
--       else Step $ do
--         yield a'
--         e <- lift $ inspect $ split a rest
--         case e of
--             Left r ->  Return (Return r)
--             Right b -> b
          
-- ---------------
-- take
-- ---------------

-- | End stream after n elements; the original return value is lost.
-- 'splitAt' preserves this information. Note the function is functor-general.

take :: (Monad m, Functor f) => Int -> Stream f m r -> Stream f m ()
take = loop where
  loop n p = when (n > 0) $
    case p of Step fas -> Step (fmap (loop (n-1)) fas)
              Delay m -> Delay (liftM (loop n) m)
              Return r -> Return ()
{-# INLINEABLE take #-}

-- ---------------
-- takeWhile
-- ---------------

-- | End stream when an element fails a condition; the original return value is lost
-- 'span' preserves this information.
takeWhile :: Monad m => (a -> Bool) -> Stream (Of a) m r -> Stream (Of a) m ()
takeWhile pred = loop where
  loop str = case str of 
    Step (a :> as) -> when (pred a) (Step (a :> loop as))
    Delay m              -> Delay (liftM loop m)
    Return r              -> Return ()
{-# INLINEABLE takeWhile #-}



-- | Convert a pure @Stream (Of a)@ into a list of @as@
toList :: Stream (Of a) Identity () -> [a]
toList = loop
  where
    loop stream = case stream of
       Return _                 -> []
       Delay (Identity stream') -> loop stream'
       Step (a :> rest)         -> a : loop rest
{-# INLINABLE toList #-}

{-| Convert an effectful 'Stream (Of a)' into a list of @as@

    Note: Needless to say this function does not stream properly.
    It is basically the same as 'mapM' which, like 'replicateM',
    'sequence' and similar operations on traversable containers
    is a leading cause of space leaks.
    
-}
toListM :: Monad m => Stream (Of a) m () -> m [a]
toListM = fold (\diff a ls -> diff (a: ls)) id (\diff -> diff [])
{-# INLINE toListM #-}


{-| Convert an effectful 'Stream' into a list alongside the return value

>  maps' toListM' :: Stream (Stream (Of a)) m r -> Stream (Of [a]) m 
-}
toListM' :: Monad m => Stream (Of a) m r -> m ([a], r)
toListM' = fold' (\diff a ls -> diff (a: ls)) id (\diff -> diff [])
{-# INLINE toListM' #-}

{-| Build a @Stream@ by unfolding steps starting from a seed. 
    This is one natural way to consume a 'Pipes.Producer'. It is worth
    adding it to the functor-general 'unfold' to avoid dealing with 
    the left-strict pairing we are using in place of Haskell pairing.

> unfoldr Pipes.next :: Monad m => Producer a m r -> Stream (Of a) m r
> unfold (curry (:>) . Pipes.next) :: Monad m => Producer a m r -> Stream (Of a) m r

-}
unfoldr :: Monad m 
        => (s -> m (Either r (a, s))) -> s -> Stream (Of a) m r
unfoldr step = loop where
  loop s0 = Delay $ do 
    e <- step s0
    case e of
      Left r -> return (Return r)
      Right (a,s) -> return (Step (a :> loop s))
{-# INLINABLE unfoldr #-}

-- ---------------------------------------
-- yield
-- ---------------------------------------

{-| A singleton stream

>>> S.sum $ do {S.yield 1; lift $ putStrLn "hello"; S.yield 2; lift $ putStrLn "goodbye"; S.yield 3}
hello
goodbye
6

>>> S.sum $ S.take 3 $ forever $ do {lift $ putStrLn "enter a number" ; n <- lift $ readLn; S.yield n }
enter a number
100
enter a number
200
enter a number
300
600
 
enter a number
1
enter a number
1000
1001
-}
yield :: Monad m => a -> Stream (Of a) m ()
yield a = Step (a :> Return ())
{-# INLINE yield #-}

-- | Zip two 'Streams's 
zip :: Monad m
    => (Stream (Of a) m r)
    -> (Stream (Of b) m r)
    -> (Stream (Of (a,b)) m r)
zip = zipWith (,)
{-# INLINE zip #-}

-- | Zip two 'Streams's using the provided combining function
zipWith :: Monad m
    => (a -> b -> c)
    -> (Stream (Of a) m r)
    -> (Stream (Of b) m r)
    -> (Stream (Of c) m r)
zipWith f = loop
  where
    loop str0 str1 = case str0 of
      Return r          -> Return r
      Delay m           -> Delay $ liftM (\str -> loop str str1) m 
      Step (a :> rest0) -> case str1 of
        Return r          -> Return r
        Delay m           -> Delay $ liftM (loop str0) m
        Step (b :> rest1) -> Step (f a b :>loop rest0 rest1)
{-# INLINABLE zipWith #-}

-- --------------
-- IO fripperies 
-- --------------

{-| repeatedly stream lines as 'String' from stdin

>>> S.stdoutLn $ S.show (S.each [1..3])
1
2
3

-}
stdinLn :: MonadIO m => Stream (Of String) m ()
stdinLn = fromHandle IO.stdin
{-# INLINABLE stdinLn #-}

{-| Read values from 'IO.stdin', ignoring failed parses

>>>  S.sum $ S.take 2 $ forever S.readLn :: IO Int
3
#$%^&\^?
1000
1003
-}

readLn :: (MonadIO m, Read a) => Stream (Of a) m ()
readLn = for stdinLn $ \str -> case readMaybe str of 
  Nothing -> return ()
  Just n  -> yield n
{-# INLINABLE readLn #-}

{-| Read 'String's from a 'IO.Handle' using 'IO.hGetLine'

    Terminates on end of input
-}
fromHandle :: MonadIO m => IO.Handle -> Stream (Of String) m ()
fromHandle h = go
  where
    go = do
        eof <- liftIO $ IO.hIsEOF h
        unless eof $ do
            str <- liftIO $ IO.hGetLine h
            yield str
            go
{-# INLINABLE fromHandle #-}     

toHandle :: MonadIO m => IO.Handle -> Stream (Of String) m r -> m r
toHandle handle = loop where
  loop str = case str of
    Return r         -> return r
    Delay m          -> m >>= loop 
    Step (s :> rest) -> do 
      liftIO $ IO.hPutStrLn handle s
      loop rest
{-# INLINABLE toHandle #-} 

print :: (MonadIO m, Show a) => Stream (Of a) m r -> m r
print = loop where
  loop stream = case stream of 
    Return r         -> return r 
    Delay m          -> m >>= loop
    Step (a :> rest) -> do 
      liftIO (Prelude.print a)
      loop rest

-- -- | Evaluate all values flowing downstream to WHNF
-- seq :: Monad m => Stream (Of a) m r -> Stream (Of a) m r
-- seq str = for str $ \a -> yield $! a
-- {-# INLINABLE seq #-}

{-| Write 'String's to 'IO.stdout' using 'putStrLn'; terminates on a broken output pipe

>>> S.stdoutLn $ S.show (S.each [1..3])
1
2
3
-}
stdoutLn :: MonadIO m => Stream (Of String) m () -> m ()
stdoutLn = loop
  where
    loop stream = case stream of 
      Return _         -> return () 
      Delay m          -> m >>= loop
      Step (s :> rest) -> do
        x   <- liftIO $ try (putStrLn s)
        case x of
           Left (G.IOError { G.ioe_type  = G.ResourceVanished
                           , G.ioe_errno = Just ioe })
                | Errno ioe == ePIPE
                    -> return ()
           Left  e  -> liftIO (throwIO e)
           Right () -> loop rest
{-# INLINABLE stdoutLn #-}


{-| Write 'String's to 'IO.stdout' using 'putStrLn'

    This does not handle a broken output pipe, but has a polymorphic return
    value
-}

stdoutLn' :: MonadIO m => Stream (Of String) m r -> m r
stdoutLn' = loop where 
  loop stream = case stream of 
    Return r         -> return r 
    Delay m          -> m >>= loop
    Step (s :> rest) -> liftIO (putStrLn s) >> loop rest
{-# INLINE stdoutLn' #-}


-- -- * Producers
-- -- $producers
--   stdinLn  -- 
-- , readLn -- 
-- , fromHandle -- 
-- , repeatM -- 
-- , replicateM --
--
-- -- * Consumers
-- -- $consumers
-- , stdoutLn --
-- , stdoutLn' --
-- , mapM_ --
-- , print -- 
-- , toHandle --
-- , drain --
--
-- -- * Pipes
-- -- $pipes
-- , map -- 
-- , mapM --
-- , sequence -- 
-- , mapFoldable -- 
-- , filter --
-- , filterM --
-- , take --
-- , takeWhile --
-- , takeWhile' --
-- , drop --
-- , dropWhile -- 
-- , concat --
-- , elemIndices
-- , findIndices
-- , scan --
-- , scanM --
-- , chain --
-- , read --
-- , show -- 
-- , seq --
--
-- -- * Folds
-- -- $folds
-- , fold --
-- , fold' --
-- , foldM --
-- , foldM' --
-- , all
-- , any
-- , and
-- , or
-- , elem
-- , notElem
-- , find
-- , findIndex
-- , head
-- , index
-- , last
-- , length
-- , maximum
-- , minimum
-- , null
-- , sum --
-- , product --
-- , toList --
-- , toListM --
-- , toListM' --
--
-- -- * Zips
-- , zip --
-- , zipWith --
--