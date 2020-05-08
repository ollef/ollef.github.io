---
title: Cyclic queries
author: Olle Fredriksson
date: 2020-05-03
description: The problem with cycles in query-based compilers and how to solve it.
image: cyclic-queries/image.png
draft: true
---

## Background

I've worked hard in Sixty to avoid cyclic queries

Despite all this cyclic queries turned up during incremental compilation, which
had me quite confused for a while.

## The problem

For incremental compilation, Sixty will remember the result of each non-input
query together with a hash of each of its dependencies in a cache.  This is used in
subsequent runs of the compiler, to see if results can be used.  When a query
is performed, we see if we have an old result laying around, and if we do, we
fetch all its dependencies and check if their hashes match the remembered
hashes.  If they do, we can reuse the old value of the query without
recomputing it.

This is an idea borrowed from Build systems à la carte.

This can lead to cyclic queries, even if the query system can't have cycles when
run without the above incremental compilation support!

In Sixty, there are query rules that look roughly like this:

```haskell
TypeOf name ->
  if name has a type signature then
    fetch (ElaboratedTypeSignature name)
  else do
    (_, type_) <- fetch (ElaboratedDefinition name)
    return type_

ElaboratedDefinition name ->
  if name has a type signature then do
    fetch (CheckedDefinition name)
  else
    fetch (InferredDefinition name)

ElaboratedTypeSignature name ->
  ...

CheckedDefinition name ->
  type_ <- fetch (TypeOf name)
  ...

InferredDefinition name ->
  ...
```

Can you spot how this can become cyclic when doing incremental compilation like
above?

The problem occurs if you remove a type signature when there's a cached result,
say going from

```haskell
foo : Int
foo = 41
```

to

```haskell
foo = 41
```

We will have, among others, these entries in the cache before removing the type signature:

```haskell
TypeOf "foo" ->
  Cached
    { value = 'Int'
    , dependencies = [(ElaboratedTypeSignature "foo", someHash1)]
    }
ElaboratedDefinition "foo" ->
  Cached
    { value = '(41 : Int)'
    , dependencies = [(CheckedDefinition "foo", someHash2)]
    }
CheckedDefinition "foo" ->
  Cached
    { value = '(41 : Int)'
    , dependencies = [(TypeOf "foo", someHash3), ...]
    }
```

When we now remove the type signature and try to fetch `ElaboratedDefinition
"foo"`, we get a cache hit, so we check if its dependencies are up to date by
fetching `CheckedDefinition "foo"`, which in turn will check if _its_
dependencies are up to date by fetching `TypeOf "foo"`.  And we carry on
checking _its_ dependency `ElaboratedTypeSignature "foo"`, which will return
`Nothing` since there is no type signature anymore, which means that the hash
stored in `TypeOf "foo"`'s cache entry won't match, meaning that `TypeOf "foo"`
will be recomputed.

And _this_ is when the problem happens, because `foo` has no type signature
anymore, which means that `TypeOf` will take the second branch and fetch
`ElaboratedDefinition "foo"`. A cycle!

