---
title: Sixten
author: Olle Fredriksson
date: 2020-05-08
description: What the Sixten programming language is all about.
image: sixten/image.png
draft: true
---

Sixten is a programming language I've worked on as a hobby project for around
six years now. The ideas and focus areas have crystallised and evolved over
time, although it started mostly as aimless exploration.

In this post I'd like to say a few words about what's special about Sixten, why
I'm doing it, and what I find important to focus on when implementing
programming languages.

## Unboxed data

When writing code in high-level languages I sometimes find myself missing the
low-level control over the memory layout of data that languages that are
"closer to the metal" give you, because it's often essential for performance to
avoid heap allocations in hot spots of your programs.

In Haskell you can use the UnboxedSums and UnboxedTuples extensions which allow
you to write code that uses unboxed values, but these types have a kind that is
not generally compatible with ordinary polymorphic types and functions, making
the support feel second class.

In Sixten the aim is to make the support for unboxed data first class.

Concretely, the benefits of this are

1. Being able to write code that doesn't do heap allocations, thus giving the
   programmer the tools they need to reduce garbage collection overheads.
1. Increasing cache locality since data is packed tighter together.
1. Saving memory wasted on indirections.

### Type representation polymorphism

Most high-level languages with parametrically polymorphic (or generic) data
types and functions, even if it is offered under a different name like
templates, fall into one of the following two categories:

1.  They use a uniform representation for polymorphic data, which is usually
    word-sized. If the data is bigger than a word it's represented as a pointer
    to the data.

2.  They use monomorphisation or template instantiation, meaning that new code
    is generated statically whenever a polymorphic function is used at a new
    type.

Neither of these approaches is perfect: With the uniform representation
approach we lose control over how our data is laid out in memory, and with the
template instantiation approach we lose modularity and polymorphic recursion:

With a uniform representation we cannot for example define polymorphic
intrusive linked lists, where the node data is stored next to the list's
"next pointer". Given the (Haskell) list definition

```haskell
data List a = Nil | Cons a (List a)
```

The representation in memory of the list `Cons x (Cons y Nil)` in languages
with a uniform representation is something like:

```haskell
     [x]           [y]
      ^             ^
      |             |
[Cons * *]--->[Cons * *]--->[Nil]
```

We cannot define a polymorphic list whose representation is intrusive:

```haskell
[Cons x *]--->[Cons y *]--->[Nil]
```

What we gain from using a uniform representation is modularity: A
polymorphic function, say `map : forall a b. (a -> b) -> List a -> List b`, can be
compiled once and used for any types `a` and `b`.

With monomorphisation, we are able to define intrusive lists, like in the
following C++-like code:

```c++
template<typename A>
class List
{
  A element;
  List<A>* next;
}
```

However, unless we know all the types that `A` will be instantiated with in
advance, we have to generate new code for every instantiation of the
function, meaning that we have partly lost modular compilation. We also
can't have polymorphic recursion since that would require an unbounded
number of instantiations. Template instantiation also leads to bigger code
since it generates multiple versions of the same function.

What is gained is the ability to more finely express how our data is laid
out in memory, which for instance means that we can write code that is
cache-aware and which uses fewer memory allocations.

Sixten gives us both: it allows us to control the memory layout of our data
all the while retaining modularity.

A definition of the list type in Sixten is

```haskell
data List a = Nil | Cons a (Ptr (List a))
```

The difference between Sixten and (for instance) Haskell is that everything is
unboxed by default, meaning that the `a` field in the `Cons` constructor is not
represented by a pointer to an `a`, but it _is_ an `a`. This also means that we
have to mark where we actually want pointers with the `Ptr` type constructor.
The `Cons` constructor has to hold a _pointer to_ the tail of the list because
we would otherwise create an infinite-size datatype, which is not allowed in
Sixten.

The novel feature that allows this is _type representation polymorphism_.
Types are compiled to their representation in Sixten. In the current
implementation of Sixten the representation consists only of the type's size in
memory, so e.g. `Int` is compiled to the integer `8` on a 64-bit system.  A
polymorphic function like `map : forall a b. (a -> b) -> List a -> List b`
implicitly takes the types `a` and `b` as arguments at runtime, and its
compiled form makes use of the type representation information to calculate
the memory offsets and sizes of its arguments and results that are needed to
be representation polymorphic.

Sixten's type representation polymorphism is closely related to research on
_intensional polymorphism_. What sets Sixten apart is the way type
representations are used in the compiled code. Sixten doesn't need to use type
representations to perform code selection, but rather compiles polymorphic
functions to _single_ implementations that leverage the information in the
type representation to be general enough to work for all types.
Type representations are also not structural in Sixten, but consist simply
of the size of the type.

TODO mention Swift

### Optional monomorphisation

This kind of polymorphism is potentially slower than specialised functions
since it passes around additional implicit arguments and does more calculation
at runtime. Some of this inefficiency should be offset by having better memory
layout than systems using uniform representations, meaning better cache
behaviour. Also note that type representation polymorphism does not preclude
creating specialised versions of functions known to be performance-critical,
meaning that we can choose to use monomorphisation when we want to.

TODO mention C#

## Dependent types

* Pi types
* Inductive families

Dependent types and unboxed data seem like a combination that could open up for
implementing some low-level tricks safely, such as strings or arrays that are stored
unboxed up to a certain size.

Quote conclusion of http://www.cs.nott.ac.uk/~psztxa/publ/ydtm.pdf

## Editor support

* incremental compiler built on a query-based architecture.
* Language server built in from the start.

## Fast type checking

* smalltt
* variable representations
* gluing
* parallel type checking

## Extern code

## Records

## GC

## Current status
