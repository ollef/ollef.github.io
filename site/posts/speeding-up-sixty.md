---
title: "Speeding up the Sixty compiler"
author: Olle Fredriksson
date: 2020-03-06
description: Optimising Sixty, the new Sixten compiler
image: speeding-up-sixty/9-d5bad6f606450d0a2c8926072e7b4845d982b81f-threadscope.png
draft: true
---

## Background

I'm working on a reimplementation of [Sixten](https://github.com/ollef/sixten),
a dependently typed programming language that supports unboxed data. The
reimplementation currently lives in a separate repository, and is called
[Sixty](https://github.com/ollef/sixty), though the intention is that it
going to replace Sixten eventually.  The main reason for reimplementing it was to
try out some implementation techniques to make the type checker faster,
inspired by András Kovács' [smalltt](https://github.com/AndrasKovacs/smalltt).

In this post I'd like to show some optimisations that I did, guided by
profiling.  I will also show the workflow and tools that I use when profiling Haskell
code.

## A benchmark

I was curious to see how Sixty would handle programs with many modules.  The
problem is that no one has ever written any large programs in the Sixten
language so far.

As a substitute, I added a command to generate nonsense programs of a given
size. The programs that are used in this post consist of just over 10 000 lines
divided into 100 modules that all look like this:

```haskell
module Module60 exposing (..)

import Module9
import Module24
import Module35
import Module16
import Module46
import Module37
import Module50
import Module47
import Module46
import Module3

f1 : Type
f1 = Module46.f10 -> Module46.f20

f2 : Type
f2 = Module50.f24 -> Module47.f13

[...]

f30 : Type
f30 = Module37.f4 -> Module24.f24
```

Each module is about 100 lines of code, of which a third or so are newlines,
and has thirty definitions that refer to definitions from other modules.
The definitions are simple enough to be type checked very quickly, so the
benchmark will make us focus our attention on parts of the compiler other than
the type checker. I'd also like to write about the type checker itself, but
will save that for another post.

## Profiling

I use three main tools to try to identify bottlenecks and other things to improve:

* [bench](http://www.haskellforall.com/2016/05/a-command-line-benchmark-tool.html)
    is a replacement for the Unix `time` command that I use to get more reliable
    timings, which is especially useful for comparing the speed of a program
    before and after some change.
* GHC's built-in profiling support, which gives us a detailed breakdown of where
  time is spent when running the program.

  When using Stack, we can build with profiling by issuing:

  ```sh
  stack install --profile
  ```

  Then we can run the program with profiling enabled:

  ```sh
  sixty check +RTS -p
  ```

  This produces a file `sixty.prof` that contains the profiling information.

  I also really like to use [ghc-prof-flamegraph](https://github.com/fpco/ghc-prof-flamegraph) to turn the profiling output into a flamegraph:

  ```sh
  ghc-prof-flamegraph sixty.prof
  ```

* [Threadscope](https://wiki.haskell.org/ThreadScope) is a visual tool for debugging
    the parallelism in a Haskell program. It also shows when the garbage collector runs,
    so can be used when tuning garbage collector parameters.

## Baseline and initial profiling

The baseline used in this post starts on [this
commit](https://github.com/ollef/sixty/tree/29094e006d4c88f51d744b0fd26f3e2e18af3ce0).

At this point we get the following time to run `sixty check` in the 100 module project on my machine:

|          | Time    |
|----------|--------:|
| Baseline | 1.30 s  |

Here's a flamegraph of the profiling output at this point:

[![](../images/speeding-up-sixty/0-29094e006d4c88f51d744b0fd26f3e2e18af3ce0.svg)](../images/speeding-up-sixty/0-29094e006d4c88f51d744b0fd26f3e2e18af3ce0.svg)

Two things stick out to me in the flamegraph:

* Parsing takes about 45 % of the time.
* Operations on [`Data.Dependent.Map`](https://hackage.haskell.org/package/dependent-map) take about 15 % of the time, and a large part of that is calls to `Query.gcompare` when the map is doing key comparisons during lookups and insertions.

Here's what a run looks like in ThreadScope:

[![](../images/speeding-up-sixty/0-29094e006d4c88f51d744b0fd26f3e2e18af3ce0-threadscope.png)](../images/speeding-up-sixty/0-29094e006d4c88f51d744b0fd26f3e2e18af3ce0-threadscope.png)

Here's a more zoomed in ThreadScope picture:

[![](../images/speeding-up-sixty/0-29094e006d4c88f51d744b0fd26f3e2e18af3ce0-threadscope-detail.png)](../images/speeding-up-sixty/0-29094e006d4c88f51d744b0fd26f3e2e18af3ce0-threadscope-detail.png)

I note the following in the ThreadScope output:

* One core is doing almost all of the work, with other cores only occasionally performing very short tasks.
* Garbage collection runs extremely often and takes just over 20 % of the time.

## Optimisation 1: Better RTS flags

As we saw in the ThreadScope output, garbage collection ran often and took a
large part of the total runtime of the type checker.

In [this
commit](https://github.com/ollef/sixty/tree/f8d4ee7ee0d3d617c6d30401592f5639be60b14a)
I most notably introduce the RTS option `-A50m`,
which sets the default allocation area size used by the garbage collector to
50 MB, instead of the default 1 MB, which means that GC can run less often,
potentially at the cost of worse cache behaviour and memory use.  The value
`50m` was found to be the best on my machine by experimentation.

The result of this change is this:

|           | Time    | Delta |
|-----------|--------:|------:|
| Baseline  | 1.30 s  |       |
| RTS flags | 1.08 s  | -17 % |

A look at the ThreadScope output shows that the change has a very noticeable
effect of decreasing the number of garbage collections:

[![](../images/speeding-up-sixty/1-f8d4ee7ee0d3d617c6d30401592f5639be60b14a-threadscope.png)](../images/speeding-up-sixty/1-f8d4ee7ee0d3d617c6d30401592f5639be60b14a-threadscope.png)

Also note that the proportion of time used by the GC went from 20 % to 3 %.

## Optimisation 2: A couple of Rock library improvements

[Rock](https://github.com/ollef/rock) is a library that's used to implement
query-based compilation in Sixty. I made two improvements to it to get these timings:

|           | Time    | Delta |
|-----------|--------:|------:|
| Baseline  | 1.30 s  |       |
| RTS flags | 1.08 s  | -17 % |
| Rock      | 0.613 s | -43 % |

The changes made were:

* Using `IORef`s and atomic operations instead of `MVar`s:
  Rock uses a cache, which is potentially accessed and updated from different
  threads, to e.g. keep track of what queries have already been executed.
  Before this change this state was stored in an `MVar`, but since it's only
  doing fairly simple updates, the atomic operations of
  `IORef` are sufficient.
* Being a bit more clever about the automatic parallelisation:
  At this point in time Rock used a
  [Haxl](https://github.com/facebook/Haxl)-like automatic parallelisation scheme, running
  queries done in an `Applicative` context in parallel.
  The change here is to only trigger parallel query execution if both queries
  are not already cached.  Before this change even the cache lookup part of the
  queries was done in parallel, which is likely far too fine-grained to pay
  off.

[comment]: <> ([![](../images/speeding-up-sixty/1-f8d4ee7ee0d3d617c6d30401592f5639be60b14a.svg)](../images/speeding-up-sixty/1-f8d4ee7ee0d3d617c6d30401592f5639be60b14a.svg))

We can see quite clearly in ThreadScope that the parallelisation has a seemingly good effect
for part of the runtime, but not all of it:

[![](../images/speeding-up-sixty/2-54b87689f345173dbed3510a396641cd8c5e43f2-threadscope.png)](../images/speeding-up-sixty/2-54b87689f345173dbed3510a396641cd8c5e43f2-threadscope.png)

## Optimisation 3: Manual query parallelisation

To improve the parallelism, I removed the automatic parallelism support from
the Rock library, and started doing it manually instead.

The following results are from simply processing all input modules in parallel,
using pooling to keep the number of threads the same as the number
of threads on the machine it's run on:

|                          | Time    | Delta |
|--------------------------|--------:|------:|
| Baseline                 | 1.30 s  |       |
| RTS flags                | 1.08 s  | -17 % |
| Rock                     | 0.613 s | -43 % |
| Manual parallelisation   | 0.451 s | -26 % |

Being able to do this is an advantage of using a query-based architecture.
The modules can be processed in any order, and any non-processed dependencies that are missing
are processed and cached on an as-needed basis.

ThreadScope shows that the CPU core utilisation is improved, even
though the timings aren't as much better as one might expect from seeing the change:

[![](../images/speeding-up-sixty/4-7ca773e347dae952d4c7249a0310f10077a2474b-threadscope.png)](../images/speeding-up-sixty/4-7ca773e347dae952d4c7249a0310f10077a2474b-threadscope.png)

It's also interesting to look at the flamegraph, because the proportion of time
that goes to parsing has gone down to about 17 % (without having made any
changes to the parser), which can be seen in the top-right part of the image:

[![](../images/speeding-up-sixty/4-7ca773e347dae952d4c7249a0310f10077a2474b.svg)](../images/speeding-up-sixty/4-7ca773e347dae952d4c7249a0310f10077a2474b.svg)

This might indicate that that part of the compiler parallelises well.

## Optimisation 4: Parser lookahead

Here's an experiment that only helped a little. As we just saw, parsing still
takes quite a large proportion of the total time spent, almost 17~%, so I
wanted to make it faster.

The parser is written using parsing combinators, and the "inner loop" of e.g.
the term parser is a choice between a bunch of different alternatives. Something like this:

```haskell
term :: Parser Term
term =
  parenthesizedTerm    -- (t)
  <|> letExpression    -- let x = t in t
  <|> caseExpression   -- case t of branches
  <|> lambdaExpression -- \x. t
  <|> forallExpression -- forall x. t
  <|> var              -- x
```

These alternatives are tried in order in the parser, which means that to reach
e.g. the `forall` case, the parser will have tried to parse the first token of
each of the four preceding alternatives. But note that the first character of
each alternative rules out all other cases, save for (sometimes) the `var`
case.

So the idea was to rewrite the parser like this:

```haskell
term :: Parser Term
term = do
  firstChar <- lookAhead anyChar
  case firstChar of
    '(' ->
      parenthesizedTerm

    'l' ->
      letExpression
      <|> var

    'c' ->
      caseExpression
      <|> var

    '\\' ->
      lambdaExpression

    'f' ->
      forallExpression
      <|> var

    _ ->
      var
```

Now we just have to look at the first character to rule out the first four
alternatives when parsing a `forall`.

Here are the results:

|                          | Time    | Delta |
|--------------------------|--------:|------:|
| Baseline                 | 1.30 s  |       |
| RTS flags                | 1.08 s  | -17 % |
| Rock                     | 0.613 s | -43 % |
| Manual parallelisation   | 0.451 s | -26 % |
| Parser lookahead         | 0.442 s |  -2 % |

Not great, but it's something.

## Optimisation 5: Dependent hashmap

The following flamegraph shows that at this point, around 68 % of the time goes
to operations on
[`Data.Dependent.Map`](https://hackage.haskell.org/package/dependent-map):

[![](../images/speeding-up-sixty/5-8ea6700415f1c46fb300571382ef438ae6082e8e.svg)](../images/speeding-up-sixty/5-8ea6700415f1c46fb300571382ef438ae6082e8e.svg)

Note that this was 15 % when we started out, so this has become the bottleneck
only because we've fixed several others.

`Data.Dependent.Map` implements a kind of dictionary data structure that allows
the type of values depend on the value of the key, which is crucial for caching
the result of queries, where each query may return a different type.

`Data.Dependent.Map` is implemented as a clone of `Data.Map` from the
`containers` package, adding this kind of key-value dependency, so it's
implemented as a binary tree and uses comparisons on the key type when doing
insertions and lookups.

In the flamegraph above we can also see that around 21 % of the time goes to
comparing the `Query` type. The reason for this slowness is that queries often
contain strings, because they're often on the form "get the type of [name]",
and strings are slow to compare because you need to traverse at least part of
the string for each comparison.

It would be a better idea to use a hash map, because then the string usually
only has to be traversed once to compute the hash, but the problem is that
there is no _dependent_ hash map library in Haskell. Until now that is. I
implemented a [dependent version of the standard
`Data.HashMap`](https://github.com/ollef/dependent-hashmap) type from the
`unordered-containers` as a thin wrapper around it.
The results are as follows:

|                          | Time    | Delta |
|--------------------------|--------:|------:|
| Baseline                 | 1.30 s  |       |
| RTS flags                | 1.08 s  | -17 % |
| Rock                     | 0.613 s | -43 % |
| Manual parallelisation   | 0.451 s | -26 % |
| Parser lookahead         | 0.442 s |  -2 % |
| Dependent hashmap        | 0.257 s | -42 % |

Having a look at the flamegraph after this change, we can see that `HashMap`
operations still take about 20 % of the total run time, but also that the main
bottleneck is now the parser:

[![](../images/speeding-up-sixty/6-722533c5d71871ca1aa6235fe79a53f33da99c36.svg)](../images/speeding-up-sixty/6-722533c5d71871ca1aa6235fe79a53f33da99c36.svg)

## Optimisation 6: `ReaderT`-based Rock library

Here's one that wasn't obvious from the profiling, but that I mostly did by
ear.

I mentioned that the Rock library supported automatic parallelisation, but that
I switched to doing it manually. A remnant from that was that the `Task` type
in Rock, was implemented in a way that made supporting that possible. `Task` is
a monad that allows fetching and which all query rules, and therefore the whole
Sixty compiler, are written in.

Before this change, `Task` was implemented roughly as follows:

```haskell
newtype Task query a = Task { unTask :: IO (Result query a) }

data Result query a where
  Done :: a -> Result query a
  Fetch :: query a -> (a -> Task query b) -> Result query b
```

So to make a `Task` that fetches a query `q`, you need to create an `IO` action
that returns a `Fetch q pure`. When doing automatic parallelisation, this allowed
introspecting whether a `Task` wanted to do a fetch, such that independent fetches
could be identified and run in parallel.

But actually, since we no longer support automatic parallelisation, this type can now be
implemented just as well as follows:

```haskell
newtype Task query a = Task { unTask :: ReaderT (Fetch query) IO a }

newtype Fetch query = Fetch (forall a. query a -> IO a)
```

The `ReaderT`-based implementation turns out to be a bit faster:

|                          | Time    | Delta |
|--------------------------|--------:|------:|
| Baseline                 | 1.30 s  |       |
| RTS flags                | 1.08 s  | -17 % |
| Rock                     | 0.613 s | -43 % |
| Manual parallelisation   | 0.451 s | -26 % |
| Parser lookahead         | 0.442 s |  -2 % |
| Dependent hashmap        | 0.257 s | -42 % |
| `ReaderT` in Rock        | 0.245 s |  -5 % |

[comment]: <> ([![](../images/speeding-up-sixty/7-048d2cec50e9994a0b159a2383580e3df5dd2a7e.svg)](../images/speeding-up-sixty/7-048d2cec50e9994a0b159a2383580e3df5dd2a7e.svg))

## Optimisation 7: Separate lexer

|                          | Time    | Delta |
|--------------------------|--------:|------:|
| Baseline                 | 1.30 s  |       |
| RTS flags                | 1.08 s  | -17 % |
| Rock                     | 0.613 s | -43 % |
| Manual parallelisation   | 0.451 s | -26 % |
| Parser lookahead         | 0.442 s |  -2 % |
| Dependent hashmap        | 0.257 s | -42 % |
| `ReaderT` in Rock        | 0.245 s |  -5 % |
| Separate lexer           | 0.154 s | -37 % |

[![](../images/speeding-up-sixty/8-11c46c5b03f26a66347d5f387bd4cdfd5f6de4a2.svg)](../images/speeding-up-sixty/8-11c46c5b03f26a66347d5f387bd4cdfd5f6de4a2.svg)

## Optimisation 8: Faster hashing

|                          | Time    | Delta |
|--------------------------|--------:|------:|
| Baseline                 | 1.30 s  |       |
| RTS flags                | 1.08 s  | -17 % |
| Rock                     | 0.613 s | -43 % |
| Manual parallelisation   | 0.451 s | -26 % |
| Parser lookahead         | 0.442 s |  -2 % |
| Dependent hashmap        | 0.257 s | -42 % |
| `ReaderT` in Rock        | 0.245 s |  -5 % |
| Separate lexer           | 0.154 s | -37 % |
| Faster hashing           | 0.146 s |  -5 % |

[![](../images/speeding-up-sixty/9-d5bad6f606450d0a2c8926072e7b4845d982b81f.svg)](../images/speeding-up-sixty/9-d5bad6f606450d0a2c8926072e7b4845d982b81f.svg)
[![](../images/speeding-up-sixty/9-d5bad6f606450d0a2c8926072e7b4845d982b81f-threadscope.png)](../images/speeding-up-sixty/9-d5bad6f606450d0a2c8926072e7b4845d982b81f-threadscope.png)

## Conclusion
