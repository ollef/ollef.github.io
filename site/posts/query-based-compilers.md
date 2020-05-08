---
title: Query-based compiler architectures
author: Olle Fredriksson
date: 2020-05-08
description: What a query-based compiler is and what they are good for.
image: query-based-compilers/image.png
draft: true

---

## Background

TODO write that this is an old document that's been touched up? And that Salsa has appeared since then.

Compilers are no longer just black boxes that take a bunch of source files and
produce assembly code. We expect them to:

* Be incremental, meaning that if we recompile a project after having made a
  few changes we only recompile what is affected by the changes.
* Provide tooling such as language servers, supporting functionality like going
  to definition, finding the type of the expression at a specific location, and
  showing error messages on the fly.

This is what Anders Hejlsberg talks about in
[his video on modern compiler construction](https://www.youtube.com/watch?v=wSdV1M7n4gQ)
that some of you might have seen.

In this document I will talk a about how this is achieved in Sixten, an
experimental functional programming language created to give the programmer
more control over memory layout and boxing than traditional languages do.

## Traditional pipeline-based compiler architectures

A traditional compiler pipeline might look a bit like this:

```md
+-----------+            +-----+                +--------+               +--------+
|           |            |     |                |        |               |        |
|source text|---parse--->| AST |---typecheck-+->|core AST|---generate--->|assembly|
|           |            |     |       ^        |        |               |        |
+-----------+            +-----+       |        +--------+               +---------
                                       |
                                 read and write
                                     types
                                       |
                                       v
                                  +----------+
                                  |          |
                                  |type table|
                                  |          |
                                  +----------+
```

There are many variations, and often more steps and intermediate
representations than in the illustration, but the idea stays the same:

We push source text down a pipeline and run a fixed set of transformations
until we finally output assembly code or some other target language. Along the
way we often need to read and update some state. For example, we might update a
type table during type checking so we can later look up the type of entities
that the code refers to.

Traditional compiler pipelines are quite familiar to me and probably many
others, but how query-based compilers should be architected might not be as
well-known. Here I will describe one way to do it.

## Going from pipeline to queries

What does it take to get the type of a qualified name, such as `Data.List.map`?
In a pipeline-based architecture we would just look it up in the type table.
With queries, we have to think differently. Instead of relying on having
updated some piece of state, we do it as if it was done from scratch.

As a first iteration, we do it _completely_ from scratch. It might look a
little bit like this:

```haskell
fetchType :: QualifiedName -> IO Type
fetchType (QualifiedName moduleName name) = do
  fileName <- moduleFileName moduleName
  sourceCode <- readFile fileName
  parsedModule <- parseModule sourceCode
  resolvedModule <- resolveNames parsedModule
  let definition = lookup name resolvedModule
  inferDefinitionType definition
```

We first find out what file the name comes from, which might be `Data/List.hs`
for `Data.List`, then read the contents of the file, parse it, perhaps we do
name resolution to find out what the names in the code refer to given what is
imported, and last we look up the name-resolved definition and type check it,
returning its type.

All this for just for getting the type of an identifier? It seems
ridiculous because looking up the type of a name is something we'll do loads of
times during the type checking of a module. We're not done yet though.

Let's first refactor the code into smaller functions:

```haskell
fetchParsedModule :: ModuleName -> IO ParsedModule
fetchParsedModule moduleName = do
  fileName <- moduleFileName moduleName
  sourceCode <- readFile fileName
  parseModule moduleName

fetchResolvedModule :: ModuleName -> IO ResolvedModule
fetchResolvedModule moduleName = do
  parsedModule <- fetchParsedModule moduleName
  resolveNames parsedModule

fetchType :: QualifiedName -> IO Type
fetchType (QualifiedName moduleName name) = do
  resolvedModule <- fetchResolvedModule moduleName
  let definition = lookup name resolvedModule
  inferDefinitionType definition
```

Note that each of the functions do everything from scratch on their own,
i.e. they're each doing a (longer and longer) prefix of the work you'd do
in a pipeline.

One way to make this work efficiently would be to add a memoisation layer
around each function. That way, we do some expensive work the first time we
invoke a function with a specific argument, but subsequent calls are cheap as
they can return the cached result.

This is essentially what we'll do, but we will not use a separate cache per
function, but instead have a central cache, indexed by the query. This
functionality is in [Rock](https://github.com/ollef/rock), a library that
packages up some of what we need to create a query-based compiler.

## The Rock library

[Rock](https://github.com/ollef/rock) is an experimental library heavily inspired by
[Shake](https://github.com/ndmitchell/shake) and the [Build systems à la
carte paper](https://www.microsoft.com/en-us/research/publication/build-systems-la-carte/).
It essentially implements a build system framework, like `make`.

Build systems have a lot in common with modern compilers since we want them to
be incremental, i.e. to take advantage of previous build results when building
anew with few changes. But there's also a difference: Most build systems don't care
about the _types_ of their queries since they work at the level of files and
file systems.

_Build systems à la carte_ is closer to what we want. There the user writes a
bunch of computations, _tasks_, choosing a suitable type for keys and a type
for values. The tasks are formulated assuming they're run in an environment
where there is a function `fetch` of type `Key -> Task Value`, where `Task` is
a type for describing build system rules, that can be used to fetch the value
of a dependency with a specific key.  In our above example, the key type might
look like this:

```haskell
data Key
  = ParsedModuleKey ModuleName
  | ResolvedModuleKey ModuleName
  | TypeKey QualifiedName
```

The build system has control over what code runs when you do a `fetch`, so by
varying that it can do fine-grained dependency tracking, memoisation, and
incrementalism.

_Build systems à la carte_ explores what kind of build systems you get when you
vary what `Task` is allowed to do, e.g. if it's a `Monad` or `Applicative`. In
Rock, we're not exploring _that_, so our `Task` is a thin layer on top of `IO`.

A problem that pops up now, however, is that there's no satisfactory type for
`Value`.  We want `fetch (ParsedModuleKey "Data.List")` to return a
`ParsedModule`, while `fetch (TypeKey "Data.List.map")` should return
something of type `Type`.

### Dependent queries

What Rock does here is in line with Haxl. It allows you to index the key type
by the return type of the query. The `Key` type in our running example becomes
the following
[GADT](https://en.wikipedia.org/wiki/Generalized_algebraic_data_type):

```haskell
data Key a where
  ParsedModuleKey :: ModuleName -> Key ParsedModule
  ResolvedModuleKey :: ModuleName -> Key ResolvedModule
  TypeKey :: QualifiedName -> Key Type
```

The `fetch` function then has type `forall a. Key a -> Task a`, so we get a
`ParsedModule` when we run `fetch (ParsedModuleKey "Data.List")`, like we
wanted, because the return type depends on the key we use.

The rules of our compiler, i.e. its "Makefile", then becomes the following
function, reusing the functions from above:

```haskell
rules :: Key a -> Task a
rules key = case key of
  ParsedModuleKey moduleName ->
    fetchParsedModule moduleName

  ResolvedModuleKey moduleName ->
    fetchResolvedModule moduleName

  TypeKey qualifiedName ->
    fetchType qualifiedName
```

### Caching

Rock caches the result of each fetch by storing the key-value pairs of already
performed fetches in a [dependent
map](https://hackage.haskell.org/package/dependent-map). This way, we only ever
perform each query once during a single run of the compiler.

### Incremental builds by reusing state

The last piece of the puzzle is incrementalism. Like Shake, Rock keeps a
fine-grained table over what dependencies a task used when it was executed,
i.e.  what keys it fetched and what the values were, such that it's able to
determine when it's safe to reuse the cache from an old build even though
there might be changes in other parts of the dependency graph.

This fine-grained dependency tracking also allows reusing the cache when a
dependency of a task changes in a way that has no effect. For example,
whitespace changes might only trigger a re-parse, but since the AST is the
same, the cache can be reused from there on.

TODO reverse dependency tracking

## Closing thoughts

At the time of writing it's still early days for Sixten's query based
architecture.  The Rock library is also still in early development, lacking
especially in documentation.
