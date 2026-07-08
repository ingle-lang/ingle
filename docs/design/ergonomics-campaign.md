---
title: The Ergonomics & Ecosystem Campaign
nav_exclude: true
sitemap: false
description: "Phased plan to close the surface-ergonomics, stdlib-breadth, and tooling gaps — ranked LLM-first."
layout: default
---

# The Ergonomics & Ecosystem Campaign

*Opened 2026-07-06.* An external audit (Cowork) enumerated the real functionality gaps in
Ingle. Every concrete claim was verified against `HEAD` and held up — the gaps are genuine, and
they sit in three places: **surface ergonomics**, **standard-library breadth**, and the
**ecosystem tooling the manifesto promised itself** (§4.7). None are type-system holes; the core
semantics (ownership, move/borrow, refcount-no-GC, both backends byte-identical, structured
concurrency) are sound.

## The organizing principle: re-rank LLM-first

The audit ranked by *"what blocks a human developer in their first hour."* Ingle's north star is
**least surprise for the model** — so the correct sort key is *"what will an LLM zero-shot emit
that Ingle then rejects?"* That reorders the list: the highest-leverage items are the ones where
the model's training priors (Rust / Swift / C) collide with Ingle's grammar — richer `match`,
compound assignment, non-decimal literals, `Option`/`Result` combinators — not the package
registry a human would reach for first.

Two items also strengthen the **verification moat** rather than merely adding surface: wall-clock
time and a seedable RNG both plug into the existing nondeterminism record/replay machinery
(vm.c captures `random`/`clock` today), so they are determinism-friendly by construction.

## Phases

Ordered by leverage × cost. Each phase is independently shippable and lands with tests + docs.

### Phase 1 — Front-end desugar ergonomics *(lexer/parser only, zero type-system change)*
The cheapest, highest-frequency "the model emits this and gets rejected" cases.

- **OFI-184 — Compound assignment** `+= -= *= /= %= &= |= ^=`. Pure parse-time desugar to
  `target = target <op> rhs`; no checker/codegen change. (`<<=`/`>>=` deferred — they collide with
  the generic-close `>>`-split and need the type parser extended; `++`/`--` intentionally omitted —
  expression-position mutation is a surprise generator and `for x in range` removes the need.)
- **OFI-185 — Non-decimal integer literals + digit separators** `0xFF`, `0b1010`, `0o755`,
  `1_000_000`. Lexer `scan_number` + a base-aware parser conversion. Striking to lack in a systems
  language — every bitmask is written in decimal today.

### Phase 2 — Pattern-matching richness *(parser + checker + codegen)*
The single biggest LLM-surprise in the language: `match` is enum-variant-only today.

- **OFI-186 —** literal patterns (`case 0`, `case "x"`, `case true`), guards
  (`case n if n > 0`), or-patterns (`case A | B`), and nested destructuring
  (`case Some(Point(x, y))`), with exhaustiveness updated to match. Biggest single expressiveness
  win; touches all three stages, so it is its own phase.

### Phase 3 — Prelude & stdlib methods *(no grammar change)*
Highest ROI-per-line: library code on types the language already has.

- **OFI-187 — `Option`/`Result` combinators**: `unwrap`, `unwrap_or`, `unwrap_or_else`, `expect`,
  `is_some`/`is_none`/`is_ok`/`is_err`, `map`, `and_then`, `ok_or`. Methods on the prelude enums —
  directly serves the Result-centric design instead of forcing `match` for a defaultable read.
- **OFI-191 — `std/encoding.ig`**: base64 + hex encode/decode. Pure-Ingle, no runtime change.

### Phase 4 — Runtime facilities *(builtins + runtime)*
Genuine functional holes, especially given the concurrency story.

- **OFI-188 — Time + sleep**: wall-clock/epoch time, and `sleep` that **parks the fiber, not the
  OS thread** (M:N scheduler). Wall-clock time joins the nondet capture set → replay-safe.
- **OFI-189 — Seedable / ranged RNG**: `seed`, `rand_int(lo, hi)`. Fits the determinism moat
  (reproducible runs); also unblocks OFI-041's PRNG motivation.
- **OFI-190 — Filesystem breadth + path helpers**: `exists`, `delete`, `rename`, `mkdir`, `stat`,
  `append`; `join`, `basename`, `ext`, `dirname`. Plumbing the formatter, package manager, and
  Inglenook all need.

### Phase 5 — Tooling *(the §4.7 promise)*
The manifesto promises "build system, package manager, formatter, and test runner in the box, from
day one." Ordered by LLM-first leverage — the formatter first, the registry last.

- **OFI-192 — Formatter** `inglec fmt`. *The* LLM-first tool: one canonical layout → deterministic
  diffs → one true way to write it. Closes the most visible slice of §4.7 for the least cost.
- **OFI-193 — Build + test runner**: a canonical `inglec test` over `tests/` and a project
  build entry, replacing the ad-hoc golden-file `run.sh` as the user-facing surface.
- **OFI-194 — Package manager**: manifest + resolution + fetch. Real and promised, but the
  *lowest-leverage* Tier-1 item for an LLM-first language (a model generating self-contained
  programs rarely reaches for a registry) — so it follows adoption, not precedes it.

### Phase 6 — Bigger language changes *(design-gated — Karl's call before building)*
Real value, but they touch grammar/philosophy, so each gets a decision first.

- **OFI-195 — `if`/`match` as expressions** (`let x = if c { a } else { b }`). Block-as-expression
  grammar change, not a desugar.
- **OFI-196 — Tuples / multiple return** (`return (a, b)`, `let (x, y) = …`). Tension: LLM-first
  wants them; the "name your types" ethos resists anonymous products. Real type-system cost.
- **OFI-197 — `select`/timeout over channels**. The one sync primitive the channel-first model
  actually needs (mutex/atomics/semaphore left out — channels cover them).
- **OFI-198 — Auto-derived structural equality**. `==` on a struct is a compile error today;
  LLMs write `a == b` on structs constantly. Recommendation: derive *structural equality only*
  (not general operator overloading) to kill the surprise without opening that can of worms.

## Deferred (audit agrees these are lower priority)
Regex (`std/regex.ig`, later), printf-width string formatting, richer collections
(deque/queue/priority-queue/ordered-map + min/max/clamp/sum), source-level debugger (tape +
record-replay + Fault already cover most of it), `pub`/`private` visibility, HTTP server / sockets,
CSV/crypto/UUID, fixed-size arrays `[T; N]`, top-level mutable globals, WASM/WASI (strategic, but a
campaign of its own).

## Deliberate non-gaps (documented, not addressed)
no `null` (`Option`), no exceptions (`Result` + `?`), no GC (ownership + refcount), no inheritance
(interfaces), no `while` (`loop`/`for`), trapping integer overflow, no `async`/`await` colouring,
no `char` type (UTF-8 + `[u8]`), nominal-only type aliases. All trace to the manifesto.
