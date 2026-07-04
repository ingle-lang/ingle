---
title: Get started
nav_order: 1
description: Install the inglec compiler and run your first Ingle program. Ingle is a statically-typed systems language — memory-safe without a garbage collector, compiled to C.
---

# Ingle

**A statically-typed, brace-delimited systems language — safe without a garbage collector.**

Ingle is in the lineage of C, C#, and Rust: ownership with move/borrow checking and deterministic
reference counting (no GC, no pauses, no reference cycles), a real type system with generics and
exhaustive pattern matching, structured concurrency, and verification built into the language. The
reference compiler is written in C with no third-party dependencies, and builds and runs on macOS and Linux.

> Status: **active development** (pre-1.0). The language and compiler evolve together.

## Read

- [Home](/) — the landing page.
- [Language reference](/language) — what runs today.
- [The Ingle Book](/guide/) — the long-form guided tour.
- [For LLMs](/for-llms) — the priors cheat-sheet; paste it into a model before asking it to write Ingle.
- [Flare](/flare) — the declarative UI layer.
- [Architecture](/architecture) — compiler & toolchain decisions.
- [Manifesto](https://github.com/ingle-lang/ingle-lang/blob/main/MANIFESTO.md) — the design philosophy and the decisions behind the language.

## Get it

The source, build instructions, and examples are on GitHub:
**[github.com/ingle-lang/ingle-lang](https://github.com/ingle-lang/ingle-lang)**

```sh
git clone https://github.com/ingle-lang/ingle-lang
cd ingle-lang
make            # builds the compiler
make test       # runs the test suite
make install    # installs to ~/.ingle
```

```ember
fn main() -> int {
    println("Hello, Ingle!")
    return 0
}
```

Ingle is released under the [MIT License](https://github.com/ingle-lang/ingle-lang/blob/main/LICENSE).
