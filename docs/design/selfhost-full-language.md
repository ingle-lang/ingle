---
title: "Selfhost Full-Language — Extending Ingle in Ingle"
nav_exclude: true
sitemap: false
description: "The campaign closing the gap between 'the compiler reproduces itself' and 'the full language is extended in Ingle' — witness generics, the erased memory model, lambda lifting, the un-dodging, the workflow flip, and bootstrap independence."
layout: default
---

# Selfhost Full-Language — Extending Ingle in Ingle

**Umbrella: OFI-218.** Opened 2026-07-22 (Karl's call: "the whole 9 yards"). This doc is the
campaign plan; [docs/OFI.md](../OFI.md) tracks the individual items; progress lands here in §8.

Successor to [self-hosting.md](self-hosting.md), which took us from zero to both fixed points
(the VM/bytecode fixed point and the native C-emit reproduction fixed point — `make selfhost`,
8 stages). This campaign takes us from *"the compiler reproduces itself inside a language
subset"* to *"the self-hosted compiler compiles the full language and is where new language
work happens."*

---

## 1. The finding, honestly stated

Where things stand (verified against the tree, 2026-07-22):

- **What is real:** the whole pipeline exists in Ingle (`selfhost/` — lexer, parser, checker,
  bytecode codegen, C-emit backend, serializer, unified driver; ~24.6k lines). The 8-stage gate
  proves byte-identity to stage-0 over the gated set, and the capstone reproduction fixed point
  is genuine: a self-built native compiler regenerates a byte-identical copy of itself with no
  stage-0 in the loop.
- **What is not yet real:** *extending the language in Ingle.* The self-hosted backends cover a
  **subset**. Tier 2 generic programs (HOFs, arrays-through-generics) crash; Tier 3 bounded/witness
  generics computed **silently wrong answers** (OFI-174). The compiler's own sources deliberately
  stay inside the covered subset — several constructs were dodged by rewriting the `.ig` source
  (OFI-173/176/177). New features land in C first and are mirrored (the OFI-184..187 pattern).
  The working loop is **"extend in C, port to Ingle, prove they match"** — not "extend in Ingle."

Two aspects deserved the alarm that opened this campaign:

1. **The silent-stub class.** `selfhost/cgen_c.ig` lowered constructs it couldn't emit to
   `INT_VAL(0)` — valid-but-wrong C instead of a loud failure. Four known instances: unhandled
   expression kinds (OFI-173), unmapped builtins (the `from_bytes` incident, OFI-185 review),
   qualified nullary construction (OFI-202), lambda arguments (OFI-206). A coverage gap that
   miscompiles instead of erroring contradicts everything the Fault campaign stands for.
   **Closed by Phase 0 (2026-07-22)** — see §8.
2. **The incentive drift.** Every source rewrite that dodges a backend hole makes staying inside
   the subset cheaper than closing it. Without a deliberate campaign the subset fossilizes and
   "C-first, mirror after" becomes permanent. This campaign is the forcing function.

What was *not* wrong: the bookkeeping. Every dodge is a numbered OFI recording both the
workaround and the still-open underlying bug, and writing a compiler inside the subset its own
young backend supports is how every self-hosted compiler bootstrapped (Go's compiler avoided Go
features for years). The state was honest; it just wasn't *finished* — and the finish line is
this campaign.

---

## 2. End conditions — what "the whole 9 yards" means

Three testable criteria. The campaign is done when all three hold.

1. **Full-language completeness.** The self-hosted compiler compiles the *entire* corpus —
   bounded/witness generics, HOFs, lambdas, everything stage-0 accepts — with correct behaviour
   on both its backends (VM bytecode and C-emit), rejects everything stage-0 rejects (checker
   verdict parity, zero tolerated misses), and its own sources use the full language with zero
   dodges.
2. **Ingle-first extension.** A new language feature lands in `selfhost/*.ig` as the canonical
   implementation, proven by the gates, with the C compiler mirroring *afterwards* (or not at
   all). Demonstrated by shipping one real feature that way (Phase 5: `panic` + `unwrap`/`expect`).
3. **Bootstrap independence.** A machine with only a C compiler builds `inglec` from a checked-in
   generated-C seed; the reproduction fixed point proves the chain with no `src/` in the loop.
   Stage-0 demoted from reference oracle to seed + tooling host.

---

## 3. Oracle succession — the one deep design problem

Today correctness is *defined* as "byte-identical to stage-0." That definition **cannot survive
the flip**: the moment a feature lands Ingle-first, stage-0 doesn't have it, so "matches stage-0"
stops meaning correct. OFI-174 already made the strategic call (precedent-checked against Go's
C→Go 1.5 transition): byte-identity is a *transitional oracle*, not the finish line. The campaign
replaces it in stages:

- **While stage-0 is feature-equal** (Phases 0–4): byte-identity stays the dev oracle — it is the
  best debugging instrument we have (`tools/cgdiff.sh` finds the first divergent instruction in
  one shot). Nothing changes.
- **After the flip** (Phase 5 on), correctness =
  1. the **golden behaviour corpus** (`tests/run/*.ig` + `.out` — run it, diff the output);
  2. the **VM ↔ C-emit differential** — our two *independent* self-hosted backends checking each
     other, inheriting the role the stage-0 VM↔native differential plays today;
  3. the **reproduction fixed point** (N1 emits its own C → N2 → byte-identical regeneration);
  4. the **fuzzers** (`make crucible` / `ceilings` / `ledger`) re-pointed at the selfhost-built
     compiler.

Byte-identity to stage-0 is then kept only where stage-0 remains feature-equal, and retired with
stage-0 itself.

---

## 4. Gap inventory (the complete, honest list)

The distance between here and criterion 1, by OFI. "Backend" abbreviations: VM = `selfhost/codegen.ig`
(bytecode), CE = `selfhost/cgen_c.ig` (C-emit).

| Gap | Backend | Class | Status |
|---|---|---|---|
| OFI-174 (a) witness-dictionary machinery — dicts as hidden leading args + instance-stored fields, `GET_FIELD`+`CALL_INDIRECT` dispatch, `WITNESS_NATIVE_BASE` natives, monomorphized bounded methods, the spawn path | VM (+CE parity) | Tier 3 — was silent wrong answers | OPEN — partial: hidden witness *fields* on bounded structs landed with the OFI-175 unblock (`codegen.ig:458`); dispatch + hidden args + natives remain. Phase 2 |
| OFI-174 (b) erased-generic-body retain/drop discipline (conditional INCREF on erased-T reads feeding closure calls; DROP of shifted elements) | VM+CE | Tier 2 — crashes (`generic_hof_strings` SIGSEGV) | OPEN. Phase 1 |
| OFI-174 (c) value-semantic deep-clone of aggregates through erased generics | VM+CE | Tier 2 — wrong (`map_array_value` empty) | OPEN. Phase 1 |
| OFI-174 (d) mono-pass mini type-inferencer (instance keys from variable/annotation types, not literal arg-kinds) | VM+CE | Tier 2 | OPEN. Phase 1 |
| OFI-206 pt 2 — lambda lifting in the C-emit (per-fn lambda-collect pre-pass, lifted `em_fn_<k>` bodies + `em_invoke` entries, captures — mirror the VM's `LambdaSpec`) | CE | loud error since Phase 0 (was silent stub) | OPEN. Phase 3 |
| OFI-202 — qualified nullary construction `Color.Red` | CE | loud error since Phase 0 (was silent stub) | OPEN. Phase 3 |
| OFI-203 — value-struct enum payloads (construction + single-name binding) | CE (VM diverges too) | blocks struct-inner destructuring byte-identity | OPEN. Phase 3 |
| OFI-173 — the two dodged lowerings: boxed-generic-array-element field read; method call on an indexed field element | CE | loud error since Phase 0 (was silent stub) | OPEN. Phase 3 (un-dodge in Phase 4) |
| OFI-176 — arg-staging for a fresh owned-array temp from an inline call | VM | codegen bug, dodged in source | OPEN. Phase 4 |
| OFI-177 — inner match-arm string binding leaks into an enclosing `return`'s drop set (deep nesting, slot-layout-dependent) | VM | codegen bug, dodged in source | OPEN. Phase 4 |
| OFI-199 — over-u64 literal silently wraps (stage-0 rejects) | parser | reject-parity | OPEN. Phase 4 |
| OFI-200 — literal-arm const-pool/source-map line delta | VM | byte-identity fidelity (runs correctly) | OPEN. Phase 4 |
| Checker not-yet-rejected verdicts (the Stage-3 tolerance counter — 16 files as of 2026-07-22, 0 false-rejects) | checker | reject-parity | OPEN. Phase 4 |
| OFI-187 remainder — `unwrap`/`expect`, blocked on a diverging `panic` primitive | language + all backends | missing primitive | OPEN. Phase 5 (the flip feature) |

**The dodge checklist** (source workarounds to revert in Phase 4, proving the holes closed):

- `selfhost/codegen.ig` `register_field_method` — inner `match` on the field type replaced by
  `ty_args_key`/`ty_key_name` string probing (OFI-177).
- `selfhost/codegen.ig` `Chunk.gen_struct_construct` — inline `ty_type_args(...)` call argument
  bound to a local first (OFI-176).
- Contracts representation — flat `[Expr]`/`[int]` arrays instead of `[Box<Expr>]` (OFI-173).
- FFI module — string bound to a local before `.bytes()` instead of the chained
  `self.ext_pquals[j].bytes()` (OFI-173).
- Any further sites surfaced by grep for the OFI markers during Phase 4 — the numbers above are
  the four *known* dodges, not a proven-complete list; Phase 4 starts with a sweep.

---

## 5. The phases

Each phase has a gate; a phase is done when its gate is green in `make verify` terms, not before.
Sequence matters (1 before 2 — the memory model is the substrate witness dispatch runs on), but
3 is independent of 1–2 and can interleave.

### Phase 0 — Truth and tripwires ✅ (2026-07-22)

Kill the silent-stub class: every unhandled construct in `cgen_c.ig` is now a hard
`cgc_internal_error` (println + `exit(70)`, mirroring stage-0's `internal_error` convention) —
the four sites: the `emit_expr` `case _`, the field-access fallback, the unresolved struct-literal
sid, the `emit_call` fallthrough. A coverage gap now **fails the build loudly** instead of
emitting valid-but-wrong C. (The VM backend's Tier-3 wrongness is a *mis-resolution*, not a stub
— there is no single choke point to trip; it is eliminated by the Phase-2 witness port itself,
and metered until then by `tools/cgdiff.sh -c`.) Re-measure the corpus (§8). Write this doc; file
OFI-218.

*Gate: `make selfhost` green with the tripwires in — proving the gated set genuinely avoids the
holes rather than papering over them.*

### Phase 1 — Tier 2: the erased-generic memory model

The substrate layer, in both selfhost backends:

- **Retain/drop discipline in erased bodies** — conditional INCREF on erased-T reads that feed
  closure calls; DROP of shifted elements (kills the `generic_hof_strings` SIGSEGV class — the
  OFI-015 use-after-free family).
- **Value-semantic deep-clone** of aggregates (arrays/structs) passed through erased generics
  (kills the `map_array_value` empty-array class).
- **The mono-pass mini type-inferencer** — instance keying from a variable's/annotation's type
  (`list.map<[int]>` vs `<[string]>`), not literal arg-kinds.
- Then `std/list` map/filter/reduce compile correctly through both selfhost backends.

Porting reference: stage-0's `gen_user_call` masking discipline, `own_into_slot` cloning, and the
`build_fn_instances` keying (the Tier-1/1b/1.5 work already mirrors the shape — this extends it).

*Gate: the Tier-2 corpus files (`generic_hof_strings`, `map_array_value`, `generic_hof*`,
`std/list`-through-generics) byte-identical AND run-correct on both selfhost backends.*

### Phase 2 — Tier 3: the witness-dictionary subsystem

The cliff — and the wrong-answers class, which is strategically worse than the crash class.
Port stage-0's machinery (reference: `build_witness`, `src/check.c:8423`, and its ~130
touch-points across check/codegen/cgen_c):

- Witness vtables per (type, interface), including `WITNESS_NATIVE_BASE` slots for built-in
  scalar/string Hash/Eq (no Ingle method to point at).
- Witnesses as **hidden leading args** on bounded generic free fns (caller builds `NEW_ENUM`
  dicts in callee order — the direct-call *and* the `spawn` path, `src/codegen.c:2382`).
- **Instance-stored witnesses** for bounded generic structs — hidden fields, correct `NEW_STRUCT`
  arity (the `generic_bounded_ctor` bug; hidden-field carrying already partially landed,
  `selfhost/codegen.ig:458` — finish and gate it).
- Bound-method dispatch: `GET_FIELD` the witness slot + `CALL_INDIRECT` (`a.compare(b)` on
  `T: Ord` — the `max(3,8)→3` bug).
- Monomorphized bounded methods keyed like stage-0.
- CE parity: `emit_generic_call`'s witness passing + the value-struct↔boxed bridge
  (`src/cgen_c.c:1369` is the reference).

*Gate: `bounded_generic`, `multibound_generic`, `hash_eq_bound`, `generic_bounded_ctor` and the
`error_bound_*` reject set all byte-identical + run-correct on both selfhost backends. This
closes the silent-wrong-answers class.*

### Phase 3 — C-emit completion: closures and the small holes

- **Lambda lifting** in `cgen_c.ig` (OFI-206 pt 2 — the plan is written): per-function
  lambda-collection pre-pass assigning lifted indices, emission of lifted `em_fn_<k>` bodies +
  their `em_invoke`/forward-decl entries, capture handling — mirroring the VM's `LambdaSpec`
  machinery. Unlocks lambda args to `map`/`and_then` and `std/list` HOFs on the native path.
- **OFI-202** — qualified nullary construction `Color.Red` routes through `emit_enum_ctor`.
- **OFI-203** — value-struct enum payloads: construction (`NEW_STRUCT`/`em_box_struct`) + the
  single-name binding (no invalid `v.f0` on a `Value`), both backends; un-blocks struct-inner
  nested-destructuring byte-identity.
- The two OFI-173 lowerings — boxed-generic-array-element field read; `.bytes()`/method call on
  an indexed field element.

Since Phase 0, every one of these is a loud error, so completion is *measurable*: the tripwire
stops firing.

*Gate: `lambdas.ig`, `fn_values.ig`, lambda-arg combinator fixtures, and new OFI-202/203
fixtures byte-identical on the C-emit; `make selfhost` count grows accordingly.*

### Phase 4 — Fidelity sweep and the great un-dodging

- Fix the two dodged VM-codegen bugs **properly**: OFI-177 (match-arm binding in the enclosing
  return's drop set — the scoped audit of when arm bindings leave the owning-drop set) and
  OFI-176 (fresh-array-temp argument staging — the PICK/DROP_UNDER discipline).
- **Revert the source workarounds** (the §4 dodge checklist, after a fresh sweep for unlisted
  ones): `register_field_method` gets its natural inner match back, `gen_struct_construct` its
  inline call, contracts their `[Box<Expr>]`, the FFI its chained `.bytes()`. The compiler's own
  source becomes a program that *uses* the hard features — the strongest regression corpus we
  could ask for, and the reproduction fixed point is re-proven on it.
- Checker **reject-parity**: drive the Stage-3 not-yet-rejected count to zero; OFI-199 (over-u64
  wrap detection, base-aware).
- **Byte-identity fidelity residue**: OFI-200 (literal-arm line attribution).
- Corpus to **full breadth**: every stage-0-accepted `tests/**` file byte-identical + run-correct
  on both selfhost backends; every stage-0-rejected file rejected.

*Gate: corpus at full breadth, zero tolerated verdicts, dodge checklist empty, both fixed points
green on un-dodged sources — **OFI-174 closes here.***

### Phase 5 — The flip: the first Ingle-first feature ✅ (2026-07-24, core — `panic`; `unwrap`/`expect` deferred)

Ship the diverging **`panic(msg)` primitive** (as a Fault, per the existing plan: builtin trap →
`em_panic` runtime hook, checker divergence so a `None` arm that panics type-checks) plus
**`unwrap`/`expect`** — implemented in the selfhost checker and both selfhost backends **first**,
proven by the §3 successor oracles (behaviour corpus + VM↔CE differential + fixed point), then
mirrored into stage-0. The mirror direction inverts, permanently. It is the right flip feature
precisely because it spans checker divergence analysis and every codegen path — a real test of
the new workflow, not a token one. (It also deletes Phase 0's own wart: `cgc_internal_error`'s
unreachable trailing return exists only because Ingle lacks divergence.)

Codify in this doc + [architecture.md](../architecture.md): **selfhost is canonical; stage-0 is
the mirror.** The parity rule (everything lands in both, byte-identical while feature-equal)
stays — only the *direction* flips.

*Gate: the feature green on the selfhost gates before a line of the C mirror exists.*

### Phase 6 — Bootstrap independence and stage-0 demotion ✅ (2026-07-24 — `make bootstrap`; fuzzer re-point + stage-0 archival remain follow-ons)

- Check in the **generated-C seed** (`bootstrap/seed/` — the self-hosted C-emit's output for the
  compiler itself, refreshed at releases; the Zig/OCaml move).
- **`make bootstrap`**: cc builds the seed → N1; N1 compiles `selfhost/*.ig` → N2; N2 regenerates
  byte-identically — the whole chain with **no `src/` in it**, in CI.
- Re-point `crucible`/`ceilings`/`ledger` at the selfhost-built compiler as the standing net.
- Stage-0 is thereafter the **mirror and tooling host**, no longer the reference.

*Gate: `make bootstrap` green on a tree that never compiles `src/` frontend code.*

---

## 6. Stage-0's endgame (decision: Karl)

Three options; phases 0–5 are unaffected by the choice, Phase 6 embodies it.

- **(a) Staged retirement — recommended.** Demote at Phase 6; then a *follow-on campaign* ports
  the tooling to the selfhost frontend — the LSP (`--lsp` shares the C frontend today), `--doctor`,
  the tape driver — after which `src/` is archived. Honest cost: the selfhost checker carries no
  source positions yet (the gap that forced Inglenook's squiggles into a subprocess), and the LSP
  surface is large; that port is Inglenook-scale, a campaign of its own. Until it lands, stage-0
  lives on as tooling host *behind* the language frontier — mirrored features reach the LSP late.
  Accepted as transitional pain; the flip (Phase 5) is what changes the workflow, retirement is
  cleanup.
- **(b) Frozen tooling host forever.** Cheapest, but the LSP goes permanently stale relative to
  the language — institutionalized phantom-diagnostics, hollowing out "the LSP as the
  verification differentiator." Rejected unless (a)'s follow-on proves unaffordable.
- **(c) Perpetual dual implementation.** The status quo tax, explicitly rejected — it is the
  thing this campaign ends.

Also aligned: the C-emit path that becomes canonical here is the same road the kernel campaign's
bare-metal codegen rides — strengthening selfhost strengthens the endgame.

**Follow-on (2026-07-25):** option (a) is now scoped and tracked as **OFI-224 — the v1.0 cutover**
([v1-cutover.md](v1-cutover.md)): make the bootstrapped compiler the default + installed `inglec`,
complete the §3 oracle succession, and archive `src/`. Its Fork 1 asks whether v1.0 ships *at* the
tooling-host stage (recommended) or waits for the LSP port — i.e. it ratifies the boundary this
section opened.

---

## 7. Risks and honest unknowns

- **The witness port is the cliff.** ~130 touch-points in stage-0 across three files; the largest
  single port since the checker (~8.8k lines). Stage it internally (free-fn hidden args → struct
  instance storage → natives → spawn) and keep `cgdiff` pointed at the tier corpus throughout.
- **The erased memory model is cross-cutting.** It touches every generic body; regressions will
  surface as refcount underflows far from the change. ASan + the reclaim double-drop detector +
  crucible run per increment, not per phase.
- **Un-dodging can deadlock on undiscovered bugs.** Reverting a workaround may surface a *new*
  slot-shape bug (OFI-177 was never minimally reproducible). Budget for filing + fixing, not
  coding around — that is the entire point of the campaign.
- **The flip's oracle handover must not drop rigor.** Phase 5 lands only after Phase 4's full
  breadth — flipping earlier would mean extending a compiler that still miscompiles corners of
  the existing language.
- **Fixed-point hygiene.** Every phase keeps `make selfhost` green at every landing — no
  "temporarily red while porting." Increments that can't hold the gate get feature-staged the way
  OFI-187 was (usage-gated injection).

---

## 8. Progress log

- **2026-07-24 — PHASE 6 COMPLETE: bootstrap independence — Ingle builds Ingle (`dcc281a`).** The capstone.
  `make bootstrap` rebuilds the compiler from a checked-in C seed (`bootstrap/seed/inglec_boot.c`, ~16k
  lines = the self-hosted C-emit's output for the whole self-hosted compiler) with the `src/` FRONTEND out
  of the loop: `cc(seed + runtime) → N1`; N1 compiles the current `selfhost/*.ig` → a self-reproducing N2;
  N1/N2 agree on every module; N1 compiles+runs a program end-to-end. Proven frontend-independent —
  `make clean && make bootstrap` compiles ONLY `runtime.c` + `cextern.c` (the runtime library, a
  dependency every Ingle binary links — not the compiler), never the frontend, and does not build the
  stage-0 binary (`bootstrap:` depends on `$(RT_LIB)` alone, not `$(BIN)`). Go-1.5 model: the seed need only
  COMPILE the current source, so routine selfhost edits don't force a seed regen; `make bootstrap-refresh`
  re-snapshots it deliberately. Added to `make verify`. Extending the language is now **edit `selfhost/*.ig`
  → `make bootstrap`**. See `bootstrap/README.md` + the architecture Decision entry. The deferred Phase-5
  sub-decision (subset-restriction vs free-feature-use) is resolved: the Rust/Go reality (seed-seeded
  rebuilds). **This is the end state the campaign set out to reach: the language is developed IN Ingle.**

- **2026-07-24 — PHASE 5 COMPLETE (core): `panic(msg)` — the first Ingle-first feature (`e98150b`).** THE
  FLIP. A diverging `panic` primitive was designed + implemented in the SELF-HOSTED compiler first (checker
  divergence via `stmt_is_panic` wired into the three return-flow walks + both selfhost backends), proven
  end-to-end on the successor oracles (VM `error[panic]` Fault, native `em_panic_val` abort, reproduction
  fixed point), THEN mirrored to stage-0 byte-identical (bytecode AND C-emit). Runtime substrate: `OP_PANIC`
  (opcode 91, OPS0, pops the message Value), `panic_fault` (FCAT_RUNTIME code "panic"), `em_panic_val`.
  Never release-elided (unlike assert); message is a runtime string (so `expect` can pass its param). Gates:
  `make test` 456/0, `make selfhost` 1507/0, `make opcheck` 92 opcodes. Behaviour corpus: `tests/run/panic.ig`
  (trap), `panic_diverges.ig` + native mirror (divergence-typing + happy path). **`unwrap`/`expect` deferred**
  as ergonomics: on both Option and Result they can't be prelude free-fns (no overloading, no enum methods),
  so they need a tag-based intrinsic (mapped: reuse the `?`/EXPR_TRY extract via `OP_GET_FIELD_OWNED` /
  `em_enum_take`, fail-arm = `panic`; ~4 codegen sites + move-checker receiver-consume) — a `?`-comparable
  effort that does NOT advance the extend-in-Ingle capability, so it waits.

- **2026-07-23 — Phase 4 CHECKER REJECT-PARITY (IN PROGRESS): 16 not-yet-rejected misses → 6 (10 checks
  closed, 0 false-rejects throughout).** The self-hosted checker (`selfhost/checker.ig`) accepted 16 programs stage-0 rejects.
  Enumerated them (stage-0 REJECT + selfhost ACCEPT over the corpus), mapped each against `src/check.c` via a
  read-only workflow, and closed the tractable ones — each verified corpus-wide for zero false-rejects (a false
  reject is the gated bug; a miss is just unfinished):
  - **OFI-199 over-i64 literal** (`88effcc`): an int literal with magnitude in (i64max, u64max] is stored as a
    negative `EInt.v`; the SLet handler rejects it outside a u64 context (u64 suffix kind 7 or annotation).
  - **OFI-168 extern-fn-as-value** + **escape-borrow** (return of a borrowed move-type param) + **borrow-
    conflict** (same value to a mut/move param aliased by another arg) (`41f669e`) — each reusing existing
    machinery (`fn_extern`, `is_boxed_move`, `fn_pqual`).
  - **OFI-167 direct-extern FFI** (`3baee0a`): modelled the default-profile hosted FFI registry
    (`ffi_registry_names` — the 42 `src/cextern.c` g_sigs entries not behind `#if`), so a DIRECT extern
    (native-only) is distinguished from a hosted one. Rejects calling a direct extern in the VM profile, and a
    direct extern with a non-scalar/Ptr param. Closes `error_direct_extern_vm` + `std/web.ig`.
  - **slice-escape** (`9535c6b`): `Slice<T>` rejected as a return/field/payload type (a borrowed view).
  - **slice-frozen** (`2c416ba`): a new `local_frozen` facet — `let s = a[lo..hi]` freezes `a`; a mutating
    array method on it is rejected.
  - **match-nested** (`796d0ad`): added ev_fstart/ev_ftype variant field-TYPE tables; a nested enum pattern
    (`case Wrap(Loc(pt))`) binding a struct/array inner payload is rejected (a TY_INFER inner field stays
    lenient).
  - **interp-brace** (`2d3ae52`): a string-interpolation hole whose contents fail to lex/parse re-parses to
    EError; the EStr loop now rejects an EError hole directly (an EError only ever comes from a failed parse,
    so never a false-reject) — no parser/AST change.
  Checker verdict-parity **640→650/656**; `make selfhost` **1501/0**; reproduction byte-identical throughout.
  **REMAINING 6 misses** (all harder / blocked, none a false-reject): 4 `examples/web/*.ig` need WHOLE-PROGRAM
  (merged) checking so the checker sees `std/web`'s imported direct externs. `check()` was factored into
  `check_decls(decls)` and a BFS import-merge was attempted in `check_dump.ig` (`f289fa7`) — it DID close all 4,
  but the checker's name resolution is not yet MODULE-SCOPED (OFI-073: two modules may legally share a
  variant/helper name — `variant_cross_module.ig` redefines `std/highlight`'s `Str`/`Number`/… variants), so a
  merged global scope collided them into **84 false-rejects** (every flare/selfhost/cross-module file). Reverted
  to single-file; merged checking waits on module-scoped resolution (the real blocker, a substantial feature).
  `error_enum_named` needs an ECall AST-schema change (arg-names on every ECall match + the dump) + a variant
  field-NAME table; `error_resource_clone_match` needs Result/Option generic-payload typing (the checker leaves
  them TY_INFER — the "dominant blocker"). These are the last reject-parity items before OFI-174 closes; each is
  a step-change in size from the 10 above.

- **2026-07-23 — Phase 4 CHECKER REJECT-PARITY (STILL IN PROGRESS): 6 misses → 1 (5 more checks closed, still
  0 false-rejects).** Two of the "harder / blocked" remainders fell to cheaper, provably-safe approaches than
  first assumed:
  - **4 web misses via CLOSURE-OR whole-program checking** (`2143fca`): rather than a merged global scope (the
    84-false-reject trap above), `check_dump.ig` now BFS-walks the entry's transitive import closure and checks
    each module ON ITS OWN, rejecting iff ANY module rejects. This lets the checker see `std/web.ig`'s own
    direct-extern violation (which single-file checking already rejects — it's a corpus match) without ever
    merging scopes. Provably false-reject-free: the corpus already proves every single module single-file-checks
    with 0 false-rejects, and OR-ing over the closure only ever turns an ACCEPT into a REJECT. (The module-scoped
    MERGED checker remains a future option, not a prerequisite — `emberc.ig` itself checks the entry single-file
    and codegens merged, so whole-program *type-flow* checking is a capability upgrade, not on the flip's path.)
  - **`error_enum_named` via a parser side-channel** (`ba47d76`): the checker now rejects the two purely-SYNTACTIC
    named-construction errors — a DUPLICATE named argument, and a MIX of positional and named (OFI-140). Stage-0
    rejects both in every call, so the check can never false-reject. `parse_args` records each arg's name and sets
    a `Parser.bad_call` flag on dup/mixed; `ps.parse_bad_call(src)` returns it (a plain `bool`, not a struct —
    sidesteps a cross-module struct field-access gap in the self-hosted C-emit, raised as **OFI-223**); `check()`
    ORs it in. Signalling out-of-band (not an AST node) keeps `--emit=ast` byte-identical to stage-0. The full
    field validation (no-such-field / missing-field / named-arg-on-a-plain-function) still needs the arg NAMES in
    an `ECall` AST field (~70 match sites) — deferred as **OFI-222**; no corpus program needs it beyond the subset.
  Checker verdict-parity **650→655/656**; `make selfhost` **1501/0**; parser AST **665/665**; reproduction +
  serializer fixed points byte-identical throughout. **REMAINING 1 miss:** `error_resource_clone_match` — needs
  Result/Option generic-payload typing (type-arg tracking on a local's annotation + variant payload substitution,
  so `case Ok(r)` over `res: Result<R, string>` types `r` as the resource `R` and the resource-out-of-borrow check
  fires). The checker scrutinee types to TY_INFER today (Result/Option are out of the enum table, OFI-204), so
  this is the deep type-model change — the last reject-parity item, and the one with real false-reject risk if
  rushed. OFI-174 closes when it lands.

- **2026-07-23 — Phase 4 OPENED: the C-emit ERASED-GENERIC OWNERSHIP facets (3 of 3), all corpus HOF files
  byte-identical.** The last diffs on `generic_hof_strings`/`stdlib_list`/`stdlib_list_sort` were three
  checker-STAMPED ownership decisions (`drop_mask`, `moves_local`) that the self-hosted C-emit re-parses
  without — so it re-derives each locally (mapped exhaustively first via a read-only workflow of `Explore`
  agents over `src/cgen_c.c` + `src/check.c`, cross-checked against the baseline):
  - **F1 — owning-temp staging of a fresh STRING temp at an erased-generic-T BORROW param** (`gtwice(|s|.., "hi")`,
    `reduce(words, "", …)`). check.c:3196 masks a fresh owning temp at a NOT-refcounted param (a generic-`T`
    under erasure — is_refcounted(T)=false); a concrete `string` param moves/adopts it instead. New per-fn
    generic-borrow-param bitmask (`build_fn_param_gen_mask`) + `is_fresh_string_temp` + a param-aware
    `arg_owning_temp_p` hooked into `emit_free_call`'s hoist+drop. (`bf27ba5`)
  - **F2 — move-on-last-use of an OWNED erased type-param LOCAL** (reduce's `var acc = init`). Stage-0's
    `moves_local==1` nils the slot; the selfhost over-retained via `own_into_slot`. New `sc_tyvar` scope flag
    (set on a generic-`T` param, propagated to `var acc = <tyvar read>`); `move_binding` nil-slot-moves an
    owned tyvar local. Mirrors the VM's `tp_slot_name`/`move_local_slot`. (`bf27ba5`)
  - **F3 — a `[T]`-returning call's element scalar kind, via gret** (`asc = sort(xs:[int])`). The selfhost left
    asc's element unresolved (`fn_ret_elem_kind[sort]=-1`), so `index_elem_refcounted(asc)` was true and
    `asc[i]` in a `+` got a spurious `own_into_slot`; stage-0 (checker knows asc is `[int]` in `main`) emits a
    plain borrowing `em_index`. `value_elem_kind` now consults the gret determining-arg table (as
    `value_elem_aek_boxed` already did) → element = the determining `[T]` arg's element kind. (`4fa1e62`)
  Gated fixture `tests/selfhost/cgen_c/erased_generic_ownership.ig` (all three, byte-identical, runs => 23).
  `make selfhost` **1489/0**; reproduction holds at every commit; all three corpus files run correct native +
  VM. cgdiff breadth **316→320** byte-identical. **KEY: both facets are checker STAMPS the self-hosted C-emit
  re-derives** — F2 is NOT a liveness pass (stage-0 isn't either: "an OWNED non-Copy type-param local read at a
  consuming position is a MOVE", the no-later-read guarantee is the checker's use-after-move detection, not
  cgen). **KEY: both facets are checker STAMPS the self-hosted C-emit re-derives.**

- **2026-07-23 — Phase 4 THE GREAT UN-DODGING (3 underlying C-emit gaps closed, every source dodge reverted).**
  With the holes closed, each selfhost-source workaround the outside audit flagged was reverted to the natural
  form, keeping `make selfhost` green at every landing (mapped the reference in `src/cgen_c.c`/`src/codegen.c`
  each time, then mirrored):
  - **OFI-173 — method call on an indexed struct-FIELD-array element** (`self.parts[0].len()`/`.split()`). The
    C-emit tripwired "unresolved callee". Fixed: `is_string_expr`'s EIndex arm recognises a string-array field
    element (via `field_elem_aek`/`field_elem_struct`), AND its EIdent arm no longer mistakes a boxed STRUCT
    binding for a string (`lookup_struct < 0`) so an array-returning METHOD-result receiver resolves as an
    array. Reverted all three `let sk = self.hof_srcs[hi]; sk.split()` bind-to-local dodges in codegen.ig.
    Fixture `indexed_field_method.ig`. (`b27148c`)
  - **OFI-202 — module-qualified enum-variant construction** (`ps.TyName("", "string")`). Neither backend
    compiled it. Fixed in BOTH: cgen_c.ig routes `alias.Variant(args)` to `emit_enum_ctor`; codegen.ig emits
    `OP_NEW_ENUM` via `resolve_ctor_vi` on the module-qualified path. Reverted the `string_ty()` ctor dodge
    (annotate_str_params uses `ps.TyName(...)` directly) and deleted the dead parser helper. (`a8f7cea`)
  - **OFI-165 — an inline owning-temp array to a struct METHOD's borrow param** (`m.take(clone_bools(src))`).
    The method path emitted inline with no drop. Fixed: the ident-receiver method path now stages owning-temp
    args like `emit_free_call` (hoist, call self inline, drop the temp). Reverted the named-snapshot dodge in
    checker.ig. Fixture `method_owning_temp_arg.ig`. (`0d13077`)
  - A fourth flagged item (codegen.ig `erased_tparam_name`) proved STALE — the C-emit now `own_into_slot`s a
    match-bound string returned from a loop; the helper form is now a plain style choice, comment corrected.
  Then the three C-emit gaps from the OFI-206 map work (my own dodges) were closed and their workarounds
  retired:
  - **OFI-220 — a borrowed ARRAY read stored into a new owner isn't retained** (`ks = kids` from an enum
    payload). `emit_assign_value` now `own_into_slot`s a non-drop array binding (clone; the borrow's owner
    keeps its reference). With it closed, `hof_srcs_of` reverted to `case TyFn(fps,..) { fparams = fps }` and
    the two dodge-helpers were deleted. Fixture `payload_array_store.ig`. (`55a0be4`)
  - **OFI-219 — nested arrays `[[T]]`.** Two scope facets (`sc_elem_is_array`, `sc_elem_elem_kind`) fix
    `grid[i].len()`→em_array_len (was em_str_len), `grid[i][j]` plain-scalar, and `grid[i]`→a `[T]` param as a
    borrow. Nested arrays are now first-class; the flat OFI-206 tables became a simplicity choice, not a
    workaround. Fixture `nested_array.ig`. (`235f58d`)
  - **OFI-221 — a bare `[]` call arg isn't context-typed** (defaults AEK 0 vs the param's 11/4). LEFT as-is:
    its workaround (passing typed-empty `let eb: [bool] = []` bindings) is idiomatic, not a tripwire/miscompile
    dodge, and the proper fix (a per-callee param-element-AEK table) is disproportionate to a narrow gap.
  `make selfhost` **1489→1501/0**; reproduction byte-identical at every commit; both fixed points green. Every
  SUBSTANTIVE source dodge in the selfhost tree is gone — the compiler expresses these constructs directly; the
  one remaining "workaround" (OFI-221) is a clean idiomatic form, not a dodge.
  **Phase 4 REMAINING:** drive the 16 checker reject-parity tolerances to 0 (OFI-199/200) — the last gate
  before OFI-174 closes; a few narrower C-emit ownership gaps remain latent (a string-returning-call `.len()`
  receiver isn't staged; boxed-generic-element field read; OFI-221 empty-array-arg) but no source dodges
  around them.

- **2026-07-22 — Phase 1 opened; diagnosis reshaped the map (favorably).**
  - **Tier 3 is substantially DONE on the VM backend already**: `bounded_generic`,
    `multibound_generic`, `hash_eq_bound`, `generic_bounded_ctor` all pass byte-identical today —
    the witness machinery that landed with the OFI-175 unblock went far beyond what OFI-174
    records. Phase 2's VM side is mostly verification + gating, not construction.
  - The live Tier-2 frontier is a **10-file cluster**, split by severity: 6 byte-divergent but
    run-correct (instance-numbering fidelity: `generic_hof_strings`, `generic_method`,
    `generic_nested_struct`, `generic_struct_pack`, `stdlib_list`, `stdlib_list_sort`); **4
    run-wrong, 3 of them silently** (`generic_literal_vs_lt` 220-not-149, `generic_nested` +
    `generic_nested_enum` print `<obj>`, `map_array_value` SIGTRAP).
  - **Every correctness failure traces to one root**: silent emit-nothing fallbacks in the VM
    backend's typed dispatch (`gen_field_access`'s discarded boolean; `gen_method_call`'s
    else-nothing paths), reached because type information does not flow through generic-instance
    field reads, generic-enum payload bindings, nested-array elements — and `mono_arg_key` keys
    any VARIABLE argument as `k0`, collapsing `map<[int]>`/`map<[string]>` into one instance.
  - **P1a landed (`d258867`)**: ten `cg_internal_error` tripwires close every silent-nothing site
    in `codegen.ig` — the VM twin of Phase 0. Gate 1477/0 armed; the 4 run-wrong files now exit
    70 naming the exact untypeable construct; the 6 numbering-only files correctly do not trip.
  - **P1b (next): the type-key flow substrate** — instance type-args through generic-struct field
    reads (`field_type_kind` substitution), generic-enum payload bindings, nested-array element
    codes, and a slot-aware `mono_arg_key`/instance keying matching stage-0's
    `build_fn_instances` exactly. That is what makes the tripwires stop firing and the 10 files
    byte-identical.
- **2026-07-22 — P1b·1–3 landed: the Tier-2 RUN-CORRECTNESS class is CLOSED.** All 10 cluster
  files now run correct through the self-hosted compiler; `map_array_value` is byte-identical too.
  - **P1b·1 (`5a801aa`)** — `map_array_value` end-to-end: an ARRAY value-type case in
    `scrutinee_call_payload` (+ `key_array_elem_code`, a no-slicing structural key mapper), the
    `gret_bare` table (a `[T]`-returning generic whose `T` binds from a BARE-`T` param reads the
    ARG's own type as the result element), and `field_receiver_targs` learning generic-struct
    LOCALS from the existing `mrecv` record. Also verified from the stage-0 map: **the OFI-063
    deep-clone needed NOTHING** — `own_into_slot` via `OP_INCREF` was already byte-identical
    (OFI-174's (b)/(c) claims were stale; the erased retain/drop discipline had landed).
  - **P1b·2 (`3b0061b`)** — nested-generic struct chains: `f_tpidx`/`st_ftpidx` + a
    `tparam_field_code` receiver-substitution in `expr_type_kind`, so `b.value.value` on
    `Box<Box<int>>` emits the stage-0 double-`GET_FIELD`. `generic_nested` => 7 (was `<obj>`),
    `generic_literal_vs_lt` => 149 (was silently 220).
  - **P1b·3 (`e5055ea`)** — the enum twin: `vf_tpidx`/`ev_ftpidx` + `erecv_name`/`erecv_targs`
    (annotation targs of enum-typed locals) + a match-cascade substitution branch.
    `generic_nested_enum` => 9. **The Phase-0 tripwire caught its own author**: the first version
    used `self.erecv_targs[ei].split("_")` — the exact OFI-173 indexed-field-element lowering the
    C-emit lacks — and the reproduction fixed point failed LOUDLY (1475/2) instead of shipping a
    miscompiled compiler; fixed with the documented bind-to-local pattern. Gate 1477/0.
  - **Remaining for full Phase-1 fidelity (P1b·4): the nested-key grammar + slot-aware keying.**
    `ty_args_key`/`ty_key_name` flatten nested type args (`Box<Box<int>>` records `"Box"`,
    losing `<int>`), so (a) depth-2 tparam fields can't prove their substitution is scalar — a
    safe extra `INCREF` (runtime no-op) remains on `generic_nested`/`generic_literal_vs_lt`;
    (b) `mono_arg_key` still keys variables as `k0`, collapsing `map<[int]>`/`map<[string]>`
    (the `generic_hof_strings`/`stdlib_list*` missing-instance deltas). The key-format migration
    must change the PRE-PASS (`FnInstColl`) and gen-pass coherently — instance-key strings are
    internal, but both passes must produce identical keys and stage-0's instance SET and ORDER.
- **2026-07-22 — P1b·4 VERIFIED CLASSIFICATION (ground truth from `cgdiff -v` + instance counts,
  not agent claims).** The 9 remaining divergent files split into four independent sub-problems:
  - **Cat A — missing instances (the `mono_arg_key` variable→`k0` collapse):** `generic_hof_strings`
    (stage-0 emits **3** `map` bodies, self-hosted **2**), `generic_method`, `stdlib_list`,
    `stdlib_list_sort`. CALL indices shift because the instance SET is smaller. Fix = key a variable
    arg by its slot type (`[int]`/`[string]` via `ty_key_name`, both `_`-free so **flat-grammar and
    `parse_inst_types`-safe at depth 1** — no parser change for the common case). **HIGH renumber
    risk** (splitting an instance renumbers every downstream slot) → full-corpus cgdiff before commit.
  - **Cat B-nested — extra INCREF from flattened receiver targs:** `generic_nested`,
    `generic_nested_struct`, `generic_nested_enum`. `field_is_refcounted` (codegen.ig:3768) returns
    TRUE for a bare `T` field (non-scalar/array/struct → conservatively refcounted); the depth-2
    `.value` can't prove `T=int` because `ty_args_key(Box<Box<int>>)` flattened to `"Box"`. Fix =
    a **nesting-preserving RECEIVER-targs grammar** — and crucially this is **DECOUPLED from
    `parse_inst_types`** (receiver targs are split by our own `.split("_")` in `tparam_field_code`/
    `enum_subject_tp_code`, never by the mono-instance parser), so it can use a richer nesting-aware
    format freely. **Zero renumber risk** (INCREF is a runtime no-op).
  - **Cat B-param — same INCREF, param receiver:** `generic_literal_vs_lt` `fn pick` (`b: Box<int>`;
    `return b.value`). Params don't record type-args (only struct-literal locals do, via `mrecv`).
    Fix = record param targs, resolve via the existing `tparam_field_code`. No renumber. **NOTE:**
    this file ALSO has a second, unrelated divergence in `main` — an owning-temp struct argument
    (`pick(a<b, Box<int>{…})`) staged in a different order: that is the **OFI-176 arg-masking family,
    Phase 4** — so `generic_literal_vs_lt` will NOT reach byte-identity in Phase 1; its Cat-B part
    closes here, the Cat-Phase-4 tail is deferred.
  - **Cat C — render kind:** `generic_struct_pack` alone (`TO_STRING 0` vs `4`/`3`) — a generic
    field's interpolation-hole width isn't carried onto the binding's `slot_kind`. Isolated, small.
  - **Sequencing:** B-nested + B-param + C first (no renumber, cgdiff-isolable), then Cat A last
    (the renumber-risk change) behind a full-corpus sweep. `map_array_value` (already byte-identical)
    is the regression anchor.
- **2026-07-22 — P1b·4a (B-param) + 4c (C) DONE; B-nested + A gated on the grammar-coupling analysis.**
  - **P1b·4a (`3bbdd46`)** — a type-param field of a CONCRETE-scalar receiver skips the conservative
    INCREF. Generic-struct params record their targs (`prcv_name`/`prcv_args`, read only by
    `field_receiver_targs`, never method-retargeting); `is_str_local_read` consults `tparam_field_code`
    and skips the INCREF only for a concrete scalar. **Soundness subtlety the gate caught:** an erased
    type-param name (`T` in a still-generic `unwrap<T>`) is NOT scalar — it stays conservatively
    refcounted (over-retain safe, under-retain = UAF); `is_scalar_typename` distinguishes a concrete
    scalar keyword from a type-param name. First cut regressed `generic_fn_infer`; fixed. `pick`
    byte-identical (the file's remaining `main` divergence is the OFI-176 arg-masking family, Phase 4).
  - **P1b·4c (`3acd564`)** — a type-param field interpolation hole `{a.value}` (a: `Box<u8>`) renders
    at the RESOLVED concrete width (u8=4) not the default 0. `resolved_tparam_field_name` factored as
    the ONE shared receiver-resolution (so `tparam_field_code`/`tparam_field_kind` can't drift);
    `scalar_kind_of_typename` is the string twin of `ty_scalar_kind`. `generic_struct_pack`
    byte-identical + run-correct.
- **2026-07-22 — PHASE 1 COMPLETE. The erased-generic memory model + instance keying is done.**
  Breadth 300→**310/552** byte-identical (`cgdiff -c`: PASS 310, DIFF 242, SKIP 107 of 659);
  `make selfhost` 1477/0 throughout; reproduction fixed point holds at every landing. The Tier-2
  run-correctness class was closed earlier (P1b·1–3); this stretch made the byte-identity land too.
  Of the 10-file target cluster (9 diverging + `map_array_value`), **7 are now byte-identical**:
  `generic_nested`, `generic_nested_struct`, `generic_nested_enum` (Stage A nested type-args),
  `generic_hof_strings`, `stdlib_list_sort` (Stage B variable-arg keying + transitive propagation),
  `generic_struct_pack` (P1b·4c render-kind), `map_array_value` (P1b·1).
  - **Stage A (`90d8f35`)** — `ty_key_full` nesting-preserving renderer (routed only through the
    type-arg-render role; `ty_key_name` untouched), depth-aware `split_targs`/`head_name`/`inner_args`,
    and the `field_receiver_targs` SUBSTITUTION (bare-`T` field + generic-struct field via
    `struct_tparam_index`/`subst_field_targs`, + `enum_subject_tp_targs` for enum payloads).
  - **Stage B (`7f962a4` + `a4717c1`)** — variable array args key by element (`map<[int]>` vs
    `map<[string]>`) via dual `arg_mono_key`/`arg_mono_key_scope` over parallel `amelem`/`selems`
    (populated by identical inference, so the passes agree); transitive param seeding
    (`seed_det_param` + `compile_fn`) so `sort<[int]>`'s `_sort_range(xs)` re-keys; and 2-level
    return-type propagation (`call_ret_elem`/`call_ret_amelem` via the `gret` tables) so
    `let left = _sort_range(xs)` → `_merge(left)` re-keys per instance.
  - **Method-return propagation (`99b0383`)** — `let b2 = b.replaced(8)` (Box.replaced→Box<T>)
    propagates the receiver's targs so `b2.get()` retargets to `Box.get<int>`.
  - **The 3 residual files run correct; their divergences are OTHER subsystems the later phases own:**
    - `generic_method` — instance keying now correct; residual = an owning-temp masking delta on
      `println(b2.get())` = the **OFI-176 arg-staging family → Phase 4**.
    - `generic_literal_vs_lt` — `pick` byte-identical (P1b·4a); residual = the `pick(a<b, Box{…})`
      owning-temp struct-arg masking = **OFI-176 → Phase 4**.
    - `stdlib_list` — instance SET now matches stage-0 exactly (27=27, run-correct `=> 76`); residual
      = a string-accumulator reduce lambda typed as int = the **lambda-instance-typing / OFI-206
      family → Phase 3**.
  These are not new work — they are the exact open OFIs (176, 206) that Phases 3–4 of this campaign
  close. Phase 1's own scope (the erased memory model) is finished.
- **2026-07-22 — the ENTIRE 10-file Tier-2 cluster is byte-identical. The 3 residuals closed head-on
  (Karl's directive: no workarounds).** Corpus breadth **310→316/552** (`cgdiff -c`: PASS 316, DIFF
  236, SKIP 107); `make selfhost` 1477/0; reproduction fixed point holds.
  - **OFI-176 owning-temp arg-masking (`b096190`)** — fixed to match stage-0's `drop_mask` discipline
    (check.c:3185-3199) exactly, verified against `is_refcounted`/`is_owning_temp`. `user_arg_masked`
    now masks a boxed struct-literal / boxed-struct-returning-call owning temp (not just arrays),
    skipping all-scalar multi-slot structs. And a native call with a refcounted owning temp from a
    bare-`T` method return (`println(s.get())`, s: Box<string>) is masked — via a new
    `return_bare_tpidx`/`mrb_tpidx` table + `method_bare_ret_kind` resolving `T` through the receiver.
    Closes `generic_literal_vs_lt` + `generic_method` (both were leaking the temp).
  - **OFI-206 HOF lambda-param inference (`85192f0`)** — the real unification stage-0's checker does,
    ported: a HOF table (`hof_name`/`hof_fpi`/`hof_srcs`) built from decls maps each lambda param to a
    sibling arg (reduce's `f:fn(U,T)->U` → "1w_0e"); at the call the string params are resolved and the
    lambda's params annotated (via a parser-side `ps.string_ty()` ctor), so a string-accumulator reduce
    lambda compiles as string CONCAT not int ADD. Closes `stdlib_list`.
  - **Two Phase-0 tripwire catches in my own new code** (loud, not silently-wrong): a qualified
    `ps.TyName(...)` variant construction the backend can't emit → a parser-side ctor; and a
    `hof_srcs[hi].split("_")` indexed-element method call (OFI-173 C-emit gap) → bind-to-local. The
    tripwire discipline paid for itself again.
- **2026-07-23 — Phase 3 opened: LAMBDA LIFTING in the C-emit landed (OFI-206 pt2, `d20d364`).** The
  self-hosted C-emit (`cgen_c.ig`) can now compile a lambda used as a VALUE — the single biggest
  C-emit capability gap. Mapped stage-0's machinery (a read-only agent over `src/cgen_c.c` +
  `src/check.c`) then ported it: a lambda lifts to a top-level `em_fn_N` numbered AFTER all declared
  fns/methods in body-traversal discovery order; a lambda value → `em_closure(&g_em, N, ncap, cap0…)`
  (scalar captures boxed, heap captures as-is); the lifted body is `em_fn_N(Value <captures…>, Value
  <own…>)`, all boxed, plus a forward decl + `em_invoke` case. New machinery: `CgcFv` capture walker
  (duplicated from the VM's `FvCtx`), `LamColl` collection walker (mirrors the emit traversal so the
  collected numbering == the `em_closure` counter), a 4th `emit_program` section, `CgcGen.cur_lambda`
  threaded per fn. **Byte-identical verified:** bare lambda, capturing lambda (`|z| z*n`), and the
  OFI-206 canonical `a.map(|x| x*2)`. Gated: `tests/selfhost/cgen_c/lambda_lift.ig`. `make selfhost`
  **1480/0**; reproduction fixed point holds (the new machinery compiles itself byte-identically).
  **Newly exposed (separate follow-on):** `generic_hof_strings`/`stdlib_list` still C-emit-diverge, but
  on DEEPER C-emit generic-HOF gaps (closure-call string-temp arg masking, return-type-through-generic
  `let` bindings, an OFI-173 field/method construct) that the lambda tripwire previously MASKED — the
  lambda lifting is correct; these are the next C-emit-completeness items.
- **2026-07-23 — Phase 3 continued: C-emit GENERIC RETURN-TYPE INFERENCE (the gret mirror), 3 facets.**
  A generic fn returning a bare `T`/`[T]` had an unknown static return type in the C-emit (`ty_scalar_kind(T)
  = -1`), so results bound as `Value` and their methods/indexing tripwired. Built the C-emit's gret machinery
  (`build_ret_det_arg`/`build_ret_det_elem` — per em_fn, the value arg determining the return type-param +
  whether it's the arg's element — threaded into `CgcGen`) and resolved three facets at each call site:
  - **scalar** (`e032b27`): `gret_scalar_kind` — reduce's `U` from `init` → `let total = reduce(…)` binds
    `int64_t` not `Value`.
  - **array element AEK** (`067661f` + `b128822`): inferred string-array literals record a boxed element AEK
    (`value_elem_aek_boxed`), and `is_string_expr` gains an `EIndex` arm → `xs[0].len()` → `em_str_len`; the
    `[T]`-returning-call case propagates the element AEK from the determining arg (`sort(words)` → `bylen`'s
    element = words's) → `bylen[0].len()` works.
  - **string** (`b128822`): `gret_is_string` — gtwice's `T` from `x="hi"` → `shout.len()` → `em_str_len`.
  Reproduction-safe as predicted (the compiler internals use no bare-`T`-returning generic calls). Gated
  fixtures `tests/selfhost/cgen_c/{lambda_lift,str_elem_method}.ig`. `make selfhost` **1483/0**; reproduction
  holds at every commit.

- **2026-07-23 — Phase 3: HOF LAMBDA PARAM TYPING across global lifting (the hard core of the OFI-206 tail).**
  The C-emit lifts every lambda to a global `em_fn_<k>` with NO checker to stamp its param types, so a lifted
  `|w| w.len()` couldn't know `w` is a string (→ tripwire) and a `map(words, |w| w.len())` binding couldn't
  know its element is an `int`. Fixed by recovering each lifted lambda's param typing FROM ITS HOF CALL SITE
  (where the enclosing scope is live) and routing it back to the global body: `hof_srcs_of`/`build_hof_srcs`
  precompute, per HOF fn, a flat stride-6 block `[lam_arg, np, p0_arg, p0_elem, p1_arg, p1_elem]` (each lambda
  param's source — the `[T]` input's element for map/filter/sort, the `U` init whole for reduce);
  `record_hof_lambdas` (called from `emit_free_call`) types each lambda arg from that block + the live scope
  and stashes a flat rec block keyed by the lambda's predicted em_fn slot; `emit_fn_body` returns the recs,
  `emit_program` accumulates them across declared bodies and feeds each lifted body its own `pstr`/`pkind`
  rows, which `emit_fn_body` applies to the lifted lambda's OWN params (a string param → owned+dropped, a
  scalar → its width-kind). Combined with the map caller-side element inference (`map_lam_ret`), the full
  `map(words, |w| w.len())` → `[int]` chain is byte-identical (a minimal repro + the new gated fixture
  `tests/selfhost/cgen_c/hof_lambda_param_typing.ig` — string/scalar/capturing map params + a filter). `make
  selfhost` **1483/0**; reproduction holds. **Three latent self-hosted C-emit gaps SURFACED and filed** (the
  compiler's own internal tables tripped them, each avoided by staying in the proven subset so reproduction
  stays byte-identical): **OFI-219** (a `[[T]]` element `xs[i]` mistyped as a string — flattened the tables to
  `[int]`), **OFI-220** (an enum-payload array assigned into a var isn't retained — kept the payload inside the
  `tyfn_*` helpers), **OFI-221** (a bare `[]` call arg isn't context-typed — passed typed-empty bindings). Each
  is real and worth a head-on fix, but orthogonal to HOFs and hit by no corpus program. **Remaining OFI-206
  tail (genuinely separate facets):** closure-call owning-temp string-arg staging (`gtwice(|s|…, "hi")` /
  `reduce(words, "", …)` — the OFI-176 family, C-emit side) and the `move`-out-on-return of an owned local
  (`stdlib_list_sort`) — the last diffs on `generic_hof_strings`/`stdlib_list`/`stdlib_list_sort`.

  - **THE COUPLING CONSTRAINT (why B-nested + A waited for the synthesis map):** `ty_args_key` is FLAT
    (`ty_key_name` collapses a nested generic to its head), and `mrecv_args` (its output) is used for
    BOTH field resolution AND method retargeting — the latter builds `"{Struct}.{m}<{mrecv_args}>"`
    keys looked up in `fn_inst_keys`, which `parse_inst_types` splits on plain `_`. So a
    nesting-preserving grammar for B-nested cannot simply change `ty_args_key`/`mrecv_args` — it must
    SEPARATE the receiver-field-resolution key (nesting-aware, depth-aware split) from the
    mono-instance key (flat, `parse_inst_types`-compatible), or method retargeting breaks corpus-wide.
    A mapping workflow (4 read-only strands + synthesis: grammar producers, pre-pass `FnInstColl`,
    gen-pass lookups, stage-0 `build_mono_instances` ordering) is resolving the exact separation +
    the Cat-A renumber-ordering guarantee before those edits land.

- **2026-07-22 — campaign opened (OFI-218).** Phase 0 landed: the four `cgen_c.ig` silent stubs
  are hard `cgc_internal_error` exits (70); doc written; measurement below.
- **2026-07-22 — Phase 0 baseline (the numbers the campaign moves):**
  - `make selfhost`: **1477/0 with the tripwires armed** — empirical proof the gated set never
    leaned on a silent stub. Tripwire proven live: a lambda-arg probe through `cgen_c_dump.ig`
    prints the OFI-206 internal error and exits 70 (previously: silent wrong C, exit 0).
  - Checker verdict-parity: **632/648** — 16 not-yet-rejected, 0 false-rejects. Phase 4 drives
    the 16 to zero.
  - VM-backend corpus differential (`tools/cgdiff.sh -c -q`): **PASS=300 DIFF=252 SKIP=107 of
    659 listed** (SKIP = stage-0-rejected or output-free files, which codegen legitimately never
    compiles — so breadth is 300/552 comparable). The last recorded number was 232/595; the
    OFI-184..206 era closed ~70 files while the corpus grew.
  - First-divergence cause histogram (stage-0 opcode at the first differing line): DROP 47 ·
    CONST 37 · JUMP 30 · unclassified 27 · GET_LOCAL 15 · CALL 12 · JUMP_IF_FALSE 11 ·
    NEW_STRUCT 9 · TO_STRING 8 · STRING 8 · UNBOX_STRUCT 7 · PICK 6 · CALL_C 6 · ADD 6 · tail 20.
    **Reading:** the DROP bucket — drop-set/ownership discipline — is the largest single class,
    confirming the Phase-1-before-Phase-2 ordering (the erased memory model is the substrate);
    NEW_STRUCT is the witness-arity class (Phase 2); PICK is the OFI-176 arg-staging family and
    CONST carries the OFI-200 line-attribution family (Phase 4).
