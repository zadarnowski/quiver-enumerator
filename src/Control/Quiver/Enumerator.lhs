> -- | Module:    Control.Quiver.Enumerator
> -- Description: A bidirectional bridge between pipes and iteratees
> -- Copyright:   © 2015 Patryk Zadarnowski <pat@jantar.org>
> -- License:     BSD3
> -- Maintainer:  pat@jantar.org
> -- Stability:   experimental
> -- Portability: portable
> --
> -- This library defines a set of functions that convert between
> -- the "Quiver" and "Data.Enumerator" paradigms. The conversion
> -- is bidirectional: an appropriately-typed stream processor
> -- can be converted into an 'Data.Enumerator.Iteratee' and back
> -- into a stream processor. In addition, a stream processor can
> -- be fed into an iteratee (or 'Data.Enumerator.Step'),
> -- resulting in 'Data.Enumerator.Enumerator'.
> --
> -- The library has been designed specifically for use with Snap,
> -- but I'm sure that many other interesting uses of it exist.

> {-# LANGUAGE RankNTypes #-}

> module Control.Quiver.Enumerator (
>   fromStream, toStream, toSingletonStream,
>   iterateeToConsumer,
>   stepToConsumer,
>   consumerToIteratee,
>   processorToEnumerator,
> ) where

> import Control.Exception (SomeException)
> import qualified Control.Quiver.Internal as Q
> import qualified Data.Enumerator as E


  Data Type Reference
  ===================

  Definitions of the relevant Quiver and Iteratee types, for reference:

    data Q.P a a' b b' f r =
        Consume a (a' -> Q.P a a' b b' f r) (Q.Producer b b' f r)
      | Produce b (b' -> Q.P a a' b b' f r) (Q.Consumer a a' f r)
      | Enclose (f (Q.P a a' b b' f r))
      | Deliver r

    type E.Enumerator a m b = E.Step a m b -> E.Iteratee a m b

    data E.Step a m b =
        E.Continue (E.Stream a -> E.Iteratee a m b)
      | E.Yield b (E.Stream a)
      | E.Error SomeException

    newtype E.Iteratee a m b = E.Iteratee { E.runIteratee :: m (E.Step a m b) }

    data E.Stream a =
        E.Chunks [a]
      | E.EOF

> -- | Converts a 'E.Stream' to an optional list.
> fromStream :: E.Stream a -> Maybe [a]
> fromStream (E.Chunks cs) = Just cs
> fromStream (E.EOF)       = Nothing

> -- | Converts an optional list to a 'E.Stream'.
> toStream :: Maybe [a] -> E.Stream a
> toStream (Just cs) = E.Chunks cs
> toStream (Nothing) = E.EOF

> -- | Converts an optional value to a singleton 'E.Stream'.
> toSingletonStream :: Maybe a -> E.Stream a
> toSingletonStream (Just c)  = E.Chunks [c]
> toSingletonStream (Nothing) = E.EOF

> -- | Converts an 'E.Iteratee' into a 'Q.Consumer'.
> iterateeToConsumer :: Functor m => E.Iteratee a m r -> Q.Consumer () a m (Either SomeException (r, Maybe [a]))
> iterateeToConsumer = Q.Enclose . fmap stepToConsumer . E.runIteratee

> -- | Converts a 'E.Step' into a 'Q.Consumer'.
> stepToConsumer :: Functor m => E.Step a m r -> Q.Consumer () a m (Either SomeException (r, Maybe [a]))
> stepToConsumer (E.Continue ik) = Q.consume () (iterateeToConsumer . ik . toSingletonStream . Just)
>                                               (Q.decouple $ iterateeToConsumer $ ik $ E.EOF)
> stepToConsumer (E.Yield r xs)  = Q.deliver (Right (r, fromStream xs))
> stepToConsumer (E.Error e)     = Q.deliver (Left e)

> -- | Converts a 'Q.Consumer' into an 'E.Iteratee'.
> consumerToIteratee :: Monad m => Q.Consumer a a' m r -> E.Iteratee a' m r
> consumerToIteratee = convert1 []
>  where
>   convert1 cs (Q.Consume _ k q) = convert2 k q cs
>   convert1 cs (Q.Produce _ _ q) = convert1 cs q
>   convert1 cs (Q.Enclose m)     = E.Iteratee (fmap (convert1 cs) m >>= E.runIteratee)
>   convert1 cs (Q.Deliver r)     = E.yield r (E.Chunks cs)
>   convert2 k _ (c:cs')          = convert1 cs' (k c)
>   convert2 k q []               = E.continue (convert3 k q)
>   convert3 k q (E.Chunks cs)    = convert2 k q cs
>   convert3 _ q (E.EOF)          = convert4 q
>   convert4 (Q.Consume _ _ q)    = convert4 q
>   convert4 (Q.Produce _ _ q)    = convert4 q
>   convert4 (Q.Enclose m)        = E.Iteratee (fmap convert4 m >>= E.runIteratee)
>   convert4 (Q.Deliver r)        = E.yield r E.EOF

> -- | Feed the output of a stream processor to a 'E.Step', effectively converting it into
> --   an 'E.Enumerator', generalised slightly to allow distinct input and output types.
> --   The chunks of the input stream are fed into the stream processor one element at
> --   the time, and its output is fed to the iteratee one element per chunk.
> processorToEnumerator :: Monad m => Q.P a a' b () m r1 -> E.Step b m r2 -> E.Iteratee a' m (r1, r2)
> processorToEnumerator = convert1 []
>  where

    Advance the iteratee until it blocks requesting more input:

>   convert1 cs p (E.Continue ks)       = convert2 cs ks p
>   convert1 cs p s                     = convert3 cs s p

    Advance the stream processor until it produces an input element for a blocked iteratee:

>   convert2 cs ks (Q.Consume _ k q)    = convert2c ks k q cs
>   convert2 cs ks (Q.Produce y k _)    = ks (E.Chunks [y]) E.>>== convert1 cs (k ())
>   convert2 cs ks (Q.Enclose m)        = E.Iteratee (fmap (convert2 cs ks) m >>= E.runIteratee)
>   convert2 cs ks (Q.Deliver r1)       = ks (E.EOF) E.>>== finish r1 (E.Chunks cs)

>   convert2c ks k _ (c:cs')            = convert2 cs' ks (k c)
>   convert2c ks k q []                 = E.continue (maybe (convert2' ks q) (convert2c ks k q) . fromStream)

    Advance the stream processor, once the iteratee has decoupled:

>   convert3 cs s (Q.Consume _ k q)     = convert3c s k q cs
>   convert3 cs s (Q.Produce _ _ q)     = convert3 cs s q
>   convert3 cs s (Q.Enclose m)         = E.Iteratee (fmap (convert3 cs s) m >>= E.runIteratee)
>   convert3 cs s (Q.Deliver r1)        = finish r1 (E.Chunks cs) s

>   convert3c s k _ (c:cs')             = convert3 cs' s (k c)
>   convert3c s k q []                  = E.continue (maybe (convert3' s q) (convert3c s k q) . fromStream)

    Same as @convert1@, but for a decoupled stream processor:

>   convert1' p (E.Continue ks)         = convert2' ks p
>   convert1' p s                       = convert3' s p

    Same as @convert2@, but for a decoupled stream processor:

>   convert2' ks (Q.Consume _ _ q)      = convert2' ks q
>   convert2' ks (Q.Produce y k _)      = ks (E.Chunks [y]) E.>>== convert1' (k ())
>   convert2' ks (Q.Enclose m)          = E.Iteratee (fmap (convert2' ks) m >>= E.runIteratee)
>   convert2' ks (Q.Deliver r1)         = ks (E.EOF) E.>>== finish r1 E.EOF

    Same as @convert3@, but for a decoupled stream processor:

>   convert3' s (Q.Consume _ _ q)       = convert3' s q
>   convert3' s (Q.Produce _ _ q)       = convert3' s q
>   convert3' s (Q.Enclose m)           = E.Iteratee (fmap (convert3' s) m >>= E.runIteratee)
>   convert3' s (Q.Deliver r1)          = finish r1 E.EOF s

    Convert the result of a final step; it must be 'Yield' or 'Error',
    as iteratees aren't allowed to block after receiving an EOF:

>   finish r1 xs (E.Yield r2 _)         = E.yield (r1, r2) xs
>   finish _  _  (E.Error e)            = E.throwError e
>   finish _  _  (E.Continue _)         = error "divergent iteratee"
