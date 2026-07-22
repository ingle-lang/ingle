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

### Phase 5 — The flip: the first Ingle-first feature

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

### Phase 6 — Bootstrap independence and stage-0 demotion

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
