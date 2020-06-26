---
title: Query-based compiler architectures
author: Olle Fredriksson
date: 2020-06-25
description: What a query-based compiler is and what they are good for.
image: query-based-compilers/top.png
draft: false

---

Note: This is an old post originally from the documentation of the
[Sixten](https://github.com/ollef/sixten) programming language, that I've
touched up and fleshed out. After the time that it was written I've found out about
[Salsa](https://github.com/salsa-rs/salsa), a Rust library with very similar
goals to my Rock library, which is definitely worth checking out as well!

## Background

Compilers are no longer just black boxes that take a bunch of source files and
produce assembly code. We expect them to:

* Be incremental, meaning that if we recompile a project after having made a
  few changes we only recompile what is affected by the changes.
* Provide editor tooling, e.g. through a [language server](https://langserver.org/), supporting functionality like going
  to definition, finding the type of the expression at a specific location, and
  showing error messages on the fly.

This is what Anders Hejlsberg talks about in
[his video on modern compiler construction](https://www.youtube.com/watch?v=wSdV1M7n4gQ)
that some of you might have seen.

In this post I will cover how this is achieved in [Sixten](https://github.com/ollef/sixten)
by building the compiler around a query system.

For those of you that don't know, Sixten is an
experimental functional programming language created to give the programmer
more control over memory layout and boxing than most other high-level languages do.
The most recent development of Sixten is being done in the
[Sixty](https://github.com/ollef/sixty) repository, and is completely
query-based.  Here's a little video giving a taste of what its language server
can do, showing type-based completions:

<script id="asciicast-V7rsch6mLtFPTrWmlCTAMDzcn" src="https://asciinema.org/a/V7rsch6mLtFPTrWmlCTAMDzcn.js" data-rows="12" async></script>

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

Traditional compiler pipelines are probably quite familiar to many of us, but
how query-based compilers should be architected might not be as well-known.
Here I will describe one way to do it.

## Going from pipeline to queries

What does it take to get the type of a qualified name, such as `"Data.List.map"`?
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

We first find out what file the name comes from, which might be `Data/List.vix`
for `Data.List`, then read the contents of the file, parse it, perhaps we do
name resolution to find out what the names in the code refer to given what is
imported, and last we look up the name-resolved definition and type check it,
returning its type.

All this for just for getting the type of an identifier? It seems
ridiculous because looking up the type of a name is something we'll do loads of
times during the type checking of a module. Luckily we're not done yet.

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
in a pipeline. I've found this to be a common pattern in my query-based compilers.

One way to make this efficient would be to add a memoisation layer
around each function. That way, we do some expensive work the first time we
invoke a function with a specific argument, but subsequent calls are cheap as
they can return the cached result.

This is essentially what we'll do, but we won't use a separate cache per
function, but instead have a central cache, indexed by the query. This
functionality is provided by [Rock](https://github.com/ollef/rock), a library
that packages up some functionality for creating query-based compilers.

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

The build system has control over what code runs when we do a `fetch`, so by
varying that it can do fine-grained dependency tracking, memoisation, and
incremental updates.

_Build systems à la carte_ is also about exploring what kind of build systems
we get when we vary what `Task` is allowed to do, e.g. if it's a `Monad` or
`Applicative`. In Rock, we're not exploring _that_, so our `Task` is a thin
layer on top of `IO`.

A problem that pops up now, however, is that there's no satisfactory type for
`Value`.  We want `fetch (ParsedModuleKey "Data.List")` to return a
`ParsedModule`, while `fetch (TypeKey "Data.List.map")` should return
something of type `Type`.

### Indexed queries

Rock allows us to index the key type
by the return type of the query. The `Key` type in our running example becomes
the following
[GADT](https://en.wikipedia.org/wiki/Generalized_algebraic_data_type):

```haskell
data Key a where
  ParsedModuleKey :: ModuleName -> Key ParsedModule
  ResolvedModuleKey :: ModuleName -> Key ResolvedModule
  TypeKey :: QualifiedName -> Key Type
```

The `fetch` function gets the type `forall a. Key a -> Task a`, so we get a
`ParsedModule` when we run `fetch (ParsedModuleKey "Data.List")`, like we
wanted, because the return type depends on the key we use.

Now that we know what `fetch` should look like, it's also worth revealing what
the `Task` type looks like in Rock, more concretely. As mentioned, it's a thin layer
around `IO`, providing a way to `fetch` `key`s (like `Key` above):

```haskell
newtype Task key a = Task { unTask :: ReaderT (Fetch key) IO a }
newtype Fetch key = Fetch (forall a. key a -> IO a)
```

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

The most basic way to run a `Task` in Rock is to directly call the `rules`
function when a `Task` fetches a key. This results in an inefficient build
system that recomputes every query from scratch.

But the `Rock` library lets us layer more functionality onto our `rules`
function, and one thing that we can add is memoisation.  If we do that Rock
caches the result of each fetched key by storing the key-value pairs of already
performed fetches in a [dependent
hashmap](https://hackage.haskell.org/package/dependent-hashmap). This way, we
perform each query at most once during a single run of the compiler.

### Verifying dependencies and reusing state

Another kind of functionality that can be layered onto the `rules` function is
incremental updates. When it's used, Rock keeps track of what dependencies a task
used when it was executed (much like Shake) in a table, i.e.  what keys it
fetched and what the values were. Using this information it's able to determine when it's
safe to reuse the cache _from a previous run of the compiler_ even though there
might be changes in other parts of the dependency graph.

This fine-grained dependency tracking also allows reusing the cache when a
dependency of a task changes in a way that has no effect. For example,
whitespace changes might trigger a re-parse, but since the AST is the
same, the cache can be reused in queries that depend on the parse result.

### Reverse dependency tracking

Verifying dependencies can be too slow for real-time tooling like language
servers, because large parts of the dependency graph have to be traversed just
to check that most of it is unchanged even for tiny changes.

For example, if we make changes to a source file with many large imports,
we need to walk the dependency trees of all of the imports just to update the editor
state for that single file.
This is because dependency verification by itself needs to walk all the way to
the root queries for all the dependencies of a given query, which can often be
a large proportion of the whole dependency tree.

To fix this, Rock can also be made to track _reverse_ dependencies between queries.
When e.g. a language server detects that a single file has changed, the reverse
dependency tree is used invalidate the cache just for the queries that depend
on that file by walking the reverse dependencies starting from the changed file.

Since the imported modules don't depend on that file, they don't need re-checked, resulting
in much snappier tooling!

## Closing thoughts

Most modern languages need to have a strategy for tooling, and building compilers
around query systems seems like an extremely promising approach to me.

With queries the compiler writer doesn't have to handle updates to and
invalidation of a bunch of ad-hoc caches, which can be the result when adding
incremental updates to a traditional compiler pipeline.  In a query-based
system it's all handled centrally once and for all, which means there's less of
a chance it's wrong.

Queries are excellent for tooling because they allow us to ask for the value of
any query at any time without worrying about order or temporal effects, just
like a well-written Makefile. The system will compute or retrieve cached values
for the query and its dependencies automatically in an incremental way.

Query-based compilers are also surprisingly easy to parallelise. Since we're
allowed to make any query at any time, and they're memoised the first time
they're run, we can fire off queries in parallel without having to think much.
In Sixty, the default behaviour is for all input modules to be type checked in
parallel.


Lastly, I hope that this post will have inspired you to use a query-based
compiler architecture, and given you an idea of how it can be done.
