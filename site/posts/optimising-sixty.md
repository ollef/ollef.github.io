---
title: "Optimising the Sixty compiler"
author: Olle Fredriksson
date: 2020-03-06
description: Optimising Sixty, the new Sixten compiler
image: code.jpg
draft: true
---

## Background

I'm working on a reimplementation of [Sixten](https://github.com/ollef/sixten),
a dependently typed programming language that supports unboxed data. The
reimplementation currently lives in a separate repository, and is called
[Sixty](https://github.com/ollef/sixty), though the intention is that it
should replace Sixten eventually.  The main reason for reimplementing it was to
try out some implementation techniques to make it faster, inspired by András
Kovács' [smalltt](https://github.com/AndrasKovacs/smalltt).

In this post I'd like to show some optimisations that I did to Sixty, though
I'm going to focus on the parts of the compiler that are _not_ the type checker,
as it's already quite fast.

The goal of the post is both to show what I'm working on and also to show some
of my workflow when profiling and optimising Haskell code.

## A benchmark

I was curious to see how Sixty, the new Sixten compiler, would handle large
programs.  The problem is that no one has ever written a large program in
Sixten so far.

As a substitute, I added a command to Sixty to generate nonsense programs of a
given size. The programs that we'll be using in this post consist of 100
modules, with just over 10 000 lines of code in total, that all look like
this:

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

Each module is 100 lines of code, of a third or so are newlines, and has
thirty definitions that refer to definitions from some of the other modules.
The definitions are simple enough to be type checked very quickly, so the
benchmark will make us focus our attention on parts of the compiler other than
the type checker.

## Baseline

This post starts on [this commit](https://github.com/ollef/sixty/tree/29094e006d4c88f51d744b0fd26f3e2e18af3ce0).

At this point we get the following time to run `sixty check` in the 100 module project on my laptop:

|          | Time    |
|----------|--------:|
| Baseline | 1.265 s |

## Initial profiling

I use three main tools to try to identify bottlenecks and other things to improve:

* [bench](http://www.haskellforall.com/2016/05/a-command-line-benchmark-tool.html)
    is a replacement for the Unix `time` command that I use to get more reliable
    timings, which is especially useful to compare the before and after time of
    some change.
* GHC's built-in profiling support, which gives us a detailed breakdown of where
  time is spent when running the program.

  When using Stack, we can build with profiling by issuing:

  ```
  stack install --profile
  ```

  Then we can run the program with profiling enabled:

  ```
  sixty check +RTS -p
  ```

  This produces a file `sixty.prof` that contains the profiling information.

  I also really like to use [ghc-prof-flamegraph](https://github.com/fpco/ghc-prof-flamegraph) to turn the profiling output into a flamegraph:

  ```
  ghc-prof-flamegraph sixty.prof
  ```
  

## Identifying parallelism bottlenecks



## Finding sequential bottlenecks

GHC has very good support for profiling.  To get started we need to build the
project with profiling enabled. With Stack, this is done by issuing:

```
stack install --profile
```

Then we can run the program with profiling enabled:

```
sixty check +RTS -p
```
