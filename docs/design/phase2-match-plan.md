---
title: Phase 2 — Match Richness (implementation plan)
nav_exclude: true
sitemap: false
description: "Sequenced plan to add literal patterns, guards, or-patterns, and one-level nesting to match, in both compilers."
layout: default
---

# Phase 2 — Match Richness

Part of the [ergonomics campaign](ergonomics-campaign.md), OFI-186. **Scope decided (Karl, pragmatic
subset):** literal patterns; guards; **non-binding** or-patterns; **one-level** nesting only
(`Some(Point(x, y))` — reject `Some(0)` and deeper with a clear "not supported yet"). Lifts to
full-grade later without a rewrite.

Grounded by a 5-stage machinery map (parser → checker → VM codegen → C-emit → selfhost). Every C
`Pattern`/`MatchCase` field added **must** be mirrored in `selfhost/parser.ig` and threaded through
`checker.ig` + `codegen.ig` + `cgen_c.ig`, or `make selfhost` breaks. Do the C side and the selfhost
mirror in the *same* change; re-run `make selfhost` before moving on.

## Anchors (verified against HEAD, post-Phase-1)
- C AST: `Pattern` + `MatchCase` in `include/ast.h` (~361-383).
- C parser: `parse_pattern` + match-case loop in `src/parser.c`.
- C checker: `STMT_MATCH` + exhaustiveness bitmap in `src/check.c` (~6288-6453).
- VM codegen: `src/codegen.c` (~2023-2110) — tag test → POP discipline around `OP_JUMP_IF_FALSE`.
- C-emit: `src/cgen_c.c` (~2576-2646) — hand-built if/else-if chain (NOT a C `switch`, to preserve
  `break`/`continue` in the channel-drain idiom); string compare via runtime string-eq, not C `==`.
- Selfhost: `parser.ig:97-108` (`Pattern`/`Case`), `checker.ig:1810-1924`, `codegen.ig:8728-8861`,
  `cgen_c.ig:3844-3939`.

## Sequence
- **§1 — discriminant seam (do first):** add `PatternKind { PAT_VARIANT, PAT_WILDCARD, PAT_LITERAL,
  PAT_OR, PAT_NESTED }` + a `kind` field; set it at every construction site; keep `wildcard` flag also
  set so existing reads are untouched. No behavior change. Mirror in selfhost. Gate: `make test` +
  `make selfhost` byte-identical.
- **2a — literals (CHEAP):** `Pattern` literal payload; parser detects INT/STRING/TRUE/FALSE before the
  ident path; checker widens scrutinee to int/string/bool + a **covered-value set**; VM reuses `OP_EQ`;
  cgen_c value compare (string via runtime eq, and the `em_tag` header emitted only if a variant arm
  exists). Exhaustiveness: bool via true+false, int/string require `_`.
- **2b — guards (CHEAP codegen, MODERATE checker):** `Expr *guard` on `MatchCase`; parse `if` after the
  pattern; check bool; **guarded arm never counts toward coverage**; move/consume fold treats a guarded
  arm as some-path (`any_c`) not every-path (`acc_c`). VM: one `OP_JUMP_IF_FALSE`; cgen_c: wrap body in `if`.
- **2c — or-patterns (MODERATE):** `PAT_OR` flat `alts[]`; parse `|` in the case loop; checker validates
  each alt + unions coverage (non-binding, so no shared-binding contract needed in the subset); VM emits
  an OR-of-tests (new jump shape — gate with `make opcheck`); cgen_c emits `||`.
- **2d — one-level nesting (EXPENSIVE):** parallel `binding_patterns[]`; parser recurses one level;
  checker recurses into the field type; both codegens recurse the extraction + failure-edge unwind.
  Reject depth>1 and literal-in-variant with a clear error.

## Cross-cutting: exhaustiveness
One checker helper, extended per feature. Enum bitmap (today) → covered-value set (2a) → guarded arms
don't cover (2b) → coverage union (2c) → "wildcard required unless provably complete" at each nesting
level (2d; no full reachability matrix — gold-plating until a program needs it). Error text is golden —
write it deliberately: `variant X not covered` / `add '_'` / `guarded arms cannot make a match
exhaustive` / `nested pattern incomplete`.

## Hazards
1. **Selfhost byte-identical** — the #1 risk; C + selfhost mirror in one change, re-gate each feature.
2. **Exhaustiveness semantics** (guards + nested) — most likely wrong-by-omission; test-first.
3. **VM stack/jump discipline** — or-patterns (OR-of-tests) + guards (2nd failure edge) are new
   control-flow around the POP contract; `make opcheck` + `EMBER_TAPE` a dogfood app, don't guess.

Definition of done per feature: both compilers handle it; `tests/match_<feature>.ig` (VM+native+selfhost);
`make test` + `make selfhost` + `make opcheck` green; docs updated; any flaw → numbered OFI.
