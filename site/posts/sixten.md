---
title: Sixten
author: Olle Fredriksson
date: 2020-05-08
description: What the Sixten programming language is all about.
image: sixten/image.png
draft: true
---

Sixten is a project I've worked on for around six years now, although its design has gone through many iterations.

## Features

### Unboxed data

Something that I often find lacking in Haskell is control over the layout of
data. There are loads of indirections everywhere. UnboxedSums and UnboxedTuples
help, but you end up with types that are second-class and can't be used as an
argument to polymorphic functions.

In Sixten I want to allow specifying unboxed data in a first-class way.

* Stack allocation, lower heap allocation pressure.

### Optional monomorphisation

### Dependent types

* Pi types
* Inductive families

Dependent types and unboxed data seem like a combination that could open up for
implementing some low-level tricks safely, such as strings or arrays that are stored
unboxed up to a certain size.

### Editor support

* incremental compiler built on a query-based architecture.
* Language server built in from the start.

### Fast type checking

* smalltt
* variable representations
* gluing
* parallel type checking

### Extern code

### Records

### GC
(RC to start with)

## Current status
