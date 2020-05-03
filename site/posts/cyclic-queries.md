---
title: Cyclic queries
author: Olle Fredriksson
date: 2020-05-03
description: The problem with cycles in query-based compilers and how to solve it.
image: cyclic-queries/image.png
draft: true
---

## Background

During dependency validation, we may accidentally create cyclic queries.
Removing type signatures
