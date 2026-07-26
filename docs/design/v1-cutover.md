---
title: "v1.0 Cutover — Retiring stage-0"
nav_exclude: true
sitemap: false
description: "The last mile to Ingle v1.0: make the self-hosted compiler the default + installed toolchain and archive the C frontend."
layout: default
---

# v1.0 — Retiring stage-0, committing to the self-hosted compiler

**Umbrella: OFI-224. Opened 2026-07-25.** The execution of [OFI-218](selfhost-full-language.md)
§6(a) "staged retirement." Read that doc first — this one does **not** re-plan self-hosting (which
is done); it plans the cleanup that turns *"Ingle can build Ingle"* into *"Ingle is built and shipped
by Ingle, and the C frontend is gone."* That completion is the v1.0 **birthday**.

---

## 1. The finding — the flip already landed; this is the last mile

Self-hosting is **not** the open question. As of 2026-07-24/25:

- **OFI-218 P0–P6 landed.** `make bootstrap` rebuilds the whole compiler from a checked-in C seed
  (`bootstrap/seed/inglec_boot.c`, 952 KB / 16,177 lines — the self-hosted C-emit of the whole
  compiler) with the `src/` frontend **entirely out of the loop**: it depends only on `$(RT_LIB)`
  (the C runtime), never on `$(BIN)` (`Makefile:608`, `tools/bootstrap.sh`). The verified fixed point
  is byte-identity of N1's emit vs N2's emit, module by module (`bootstrap.sh:64,71`).
- **A full real app compiles through it.** Inglenook (the IDE, `public/inglenook/`) compiles
  **pixel-identically** through the self-hosted C-emit and runs (Ollama chat included) — the proof the
  backend covers the language people actually write, not just the compiler's own subset.
- **The decision is already on record.** `docs/architecture.md` Decisions 1/2/3 record the
  frozen-stage-0 tag, the exact frontend/runtime split, and "the flip is realized."

So this campaign is a **cleanup**, not a rebuild: make the bootstrapped compiler the **default** and
**installed** `inglec`, sever the last `src/`-frontend couplings, resolve the residual coverage gaps,
and archive `src/`. None of it is hard new compiler engineering — it is mechanics plus a small number
of decisions that are genuinely Karl's.

---

## 2. What "retire src/" precisely means

`src/` holds three different things. Only the first is retired.

| Group | Files | Fate |
|-------|-------|------|
| **Compiler frontend** | `lexer.c parser.c check.c codegen.c cgen_c.c main.c` | **Retired** — the target of this campaign. Already dead weight in `make bootstrap`. |
| **The C runtime** | `runtime.c cextern.c graphics.c graphics_headless.c` | **Kept, forever.** The execution substrate, not the compiler — like Go keeps its runtime, Rust keeps LLVM (architecture.md Decision 2). |
| **The C tooling satellites** | `lsp.c prove.c docgen.c semindex.c` | **Separate decision** (§6, Fork 1). Not the language; can trail v1.0. |

And critically: **stage-0 is not deleted.** It survives as its frozen git tag `stage0-v0.3.42` — the
"re-bootstrap from C from zero" oracle, kept indefinitely (architecture.md Decision 1). "Retire the
frontend" means *take it off the build and install path*, not *erase the history*.

---

## 3. The true baseline (recon 2026-07-25)

Verified against the live tree, not memory.

**Green gates — G0 fresh baseline (2026-07-25, verified this session):**
- `make test` **458/0** (was 456; +2), `make opcheck` **92 opcodes / 396 corpus programs**.
- `make selfhost` **1517/0** — reproduction fixed point intact (the *current* compiler regenerates
  itself byte-identical over all 6 sources).
- `make bootstrap` — **was RED, now GREEN.** The checked-in seed had gone output-stale after the last
  8 `cgen_c.ig` hardening commits (see §8); `make bootstrap-refresh` re-snapshotted it (16,177→19,720
  lines) and restored the frontend-free fixed point. Committed `cd6698c`.
- Checker verdict parity **655/656** (1 miss, `error_resource_clone_match`); parser AST **665/665**.

**The build topology** (the surgery map):
- The default `build/inglec` is one **kitchen-sink** binary from `SOURCES := $(wildcard src/*.c)`
  (`Makefile:167`) — 29 files: frontend + VM + runtime + both graphics stubs + tooling, linked
  together. `$(BIN)` at `Makefile:182`.
- **`src/main.c` is the sole C entry point** and dispatches everything: `--lsp` (`:1231`), `--doctor`
  (`:1234`), `--run-bytecode` (`:1237`), `--emit=` (`:1310`), `-o` native link (`:1314`),
  `--freestanding` (`:1296`).
- **~15 targets pass `$(SOURCES)` straight to `cc`** (release, asan/asan-par/asan-trace, parallel, mn,
  tsan-mn, asan-mn, mn-graphics, mn-net-graphics, graphics, web, net, net-graphics, db) — every flavor
  currently **recompiles the whole C frontend**.
- **`make install` → `release` ships the C-frontend binary** to `$(PREFIX)/bin/inglec` — the binary
  editors and the LSP launch.
- **No target builds the self-hosted compiler as an installable `$(BIN)`.** It exists only as the
  `selfhost` differential and the `bootstrap` proof (N1/N2 built in a `mktemp` dir, never installed).
- **Five runtime archives** (`RT_LIB`, `RT_LIB_PAR` default-built; `RT_LIB_NETGFX`, `RT_LIB_DB`,
  `RT_LIB_WEB` on-demand) are all frontend-independent and **stay untouched**.

**The oracles** (what survives the frontend going):
- **Fuzzers are self-contained — good news.** `crucible` uses five internal oracles (double-drop,
  VM-fault, ASan, RSS leak, VM↔native diff); `ledger` uses per-seed `//EXPECT:accept|reject`;
  `ceilings` uses WORKS-vs-CAPPED against `ceilings-known.txt`. **None diffs against stage-0.**
  Re-pointing them is an env-var change (`CRUCIBLE_EMB`/`_ASAN`/`_DT`, `EMB`) — once the bootstrapped
  compiler's flavored variants exist.
- **The silent-miscompile class is structurally closed.** P0/P1 turned the four `cgen_c.ig`
  `INT_VAL(0)` fallbacks and ten `codegen.ig` emit-nothing fallbacks into hard `internal_error`
  exits — a coverage hole now **fails the build** instead of shipping wrong code (OFI-173 general fix).
- **`make verify`** already runs `selfhost` + `bootstrap` as first-class gates
  (`tools/verify.sh: build parallel test selfhost bootstrap opcheck ceilings ledger crucible`).

**The tooling coupling:**
- **The LSP is the hard one.** `src/lsp.c` calls into the C frontend (`lexer_*`, `parser_*`) and is
  "in-tree, sharing the compiler frontend" (architecture.md Decision on the LSP). The blocker to
  porting it: **the self-hosted checker carries no source positions yet** — OFI-218 §6 calls that port
  *"Inglenook-scale, a campaign of its own."*
- `prove.c` / `docgen.c` / `semindex.c` coupling is lighter and to be audited in the tooling sub-campaign.

---

## 4. The honest punch-list to v1.0

Almost none of this is hard engineering — it is decisions and mechanics.

- **A. Complete the oracle succession.** OFI-218 §3 already decided it: byte-identity-to-stage-0 is a
  *transitional* oracle (Go C→Go 1.5 precedent). The four successors must all be **live against the
  bootstrapped compiler** before `src/` goes: (1) the golden behaviour corpus `tests/run/*.ig`+`.out`;
  (2) the VM↔C-emit differential (two independent self-hosted backends); (3) the reproduction fixed
  point (`make bootstrap`); (4) the fuzzers re-pointed. (3) and (4) are the only outstanding wiring —
  and (4) is trivial (§3).
- **B. Flip the default & install.** Add a target that builds a **persistent, installable**
  self-hosted `inglec` (today only N1-in-mktemp exists); point `all`/`release`/`install`/CI's `make`
  at it. Rebuild the ~15 flavored `$(SOURCES)` targets to compile the **selfhost** sources and link the
  matching `RT_LIB_*` — collapsing "N recompiled C frontends" into "one compiler, link a different
  runtime."
- **C. Close the CLI capability gap.** The self-hosted drivers (`emberc.ig`, `cgen_c_dump.ig`) expose a
  **narrower** CLI than `main.c` — no `--lsp`, `--doctor`, `--run-bytecode`, in-process `--emit=run`
  VM, or `--freestanding`. Decide (Fork 2): unify these into one Ingle-driven `inglec`, or keep a thin
  C tooling entry that hosts them.
  - **Verified at G1 — the two self-hosted drivers split check from C-emit, and neither does both.**
    `cgen_c_dump.ig` (what the seed / `build/inglec-self` runs) is parse→C-emit and **trusts its input**:
    it emitted valid-looking C for `let x: int = "hello"` (a type error stage-0 rejects with exit 65) and
    exited 0. `emberc.ig` *does* run the checker (rejected the same program, exit 65) but emits **bytecode**,
    not C. So the G4 default `inglec` cannot be the bare C-emit driver — `inglec -o` must be
    **check → C-emit → cc** and must reject exactly what stage-0 rejects. Both halves exist
    (`selfhost/checker.ig`, `selfhost/cgen_c.ig`); the work is fusing them into one driver. Bounded
    integration, not new algorithms — but it *is* real G4 work, not a one-variable flip.
- **D. Sever the LSP/tooling coupling** (the hard dependency). Either port the LSP/`--doctor`/prover
  onto the self-hosted frontend (needs selfhost-checker source positions first) or retain stage-0 as a
  **frozen tooling host behind the language frontier**. Fork 1.
- **E. Resolve residual coverage gaps (triaged below).** Nothing blocks compiling real programs; ship
  the remainder as documented v1.0 known-limitations.
- **F. Re-home `bootstrap-refresh`.** It is the **one** piece of bootstrap machinery that hard-depends
  on `$(BIN)` (`Makefile:615-617`: `$(BIN) --emit=c … > seed`). Post-cutover the seed must be
  re-snapshotted by the self-hosted compiler itself — `bootstrap.sh` already produces the byte-identical
  replacement (`c2.c` = N1's own emit), so this is a rewire, not a chicken-and-egg.

### Coverage triage — where the residual open OFIs land

| Bucket | Items | Verdict |
|--------|-------|---------|
| **C-emit coverage frontier (measured at G4)** | OFI-173 (25), OFI-202 (15), OFI-206 (6) | **The real remaining work.** The self-hosted C-emit builds itself + Inglenook, but **47 of ~267 corpus programs hard-fail the emit (exit 70, loud)** — see §4a. Bounded to 3 ranked OFIs; closing them makes G4 (flip the default) honest. |
| **Silent-wrong-answer risk** | *(structurally closed — confirmed at G4)* | P0/P1 made coverage holes hard-fail (`internal_error` exit 70), not miscompile — **verified**: all 47 emit gaps abort loudly, zero produced runnable-but-wrong C. Latent representational gaps (OFI-203 value-struct-in-enum payload, OFI-163 generic Option/Result payload refcount, OFI-164 inline-struct array literal) fail loudly if ever hit. |
| **Diagnostic / reject-parity** | OFI-223 (cross-module struct field, worked around), OFI-222 (partial named-arg validation), OFI-199 (over-u64 literal not rejected), the 1 verdict miss `error_resource_clone_match` | Ship as known-limitations or close opportunistically. None blocks extend-in-Ingle. |
| **Ergonomic / cosmetic** | `unwrap`/`expect` (deferred; `panic` already shipped), bool-render `0/1` vs `true/false` in interpolation, OFI-200 bytecode source-map delta, OFI-221 empty-array-arg AEK | Post-1.0 polish. |
| **Tooling** | LSP frontend coupling (Fork 1), fuzzer re-point (trivial) | The real v1.0 tooling decision. |

### 4a. The C-emit coverage frontier (measured 2026-07-25, G4)

Running the fused checked compiler `selfhost/compile_c.ig` (see §5 G4) over the whole corpus gives the
first honest map of what the self-hosted **native** path can and cannot compile:

- **Checker — cutover-ready.** Over the accept corpus (examples + `tests/run`, 220 programs stage-0
  accepts): **0 false-rejects** — the self-hosted checker never rejects a valid program. Over the 90
  fixtures stage-0 rejects *at check time*: **87/90 match**; the 3 under-rejections are the documented
  `error_resource_clone_match` (needs Result/Option generic-payload typing) + two contract-`ensures`
  edge cases — all *under*-rejection (accept-too-much), the safe direction, and all documented.
- **C-emit — 47 of ~267 corpus programs hard-fail (exit 70, loud — no silent miscompile).** The
  failures collapse to **three known, ranked OFIs**, not 47 independent bugs:

  | Root cause | Programs | What trips it |
  |---|---|---|
  | **OFI-173** — method call on an array-element / struct-field receiver | **25** | `xs[i].clone()`, `self.items.remove_last()` — the C-emit can't resolve the receiver's type to pick the method |
  | **OFI-202** — qualified-variant / newtype construction | **15** | `UserId(5)`, `Color.Red` — construction call form unhandled |
  | **OFI-206** — lambda lifting | **6** | a lambda passed to `map`/`and_then`/… as an argument |
  | (nested boxed field access) | 1 | `match_nested` — `.x` on a boxed-generic element |

  **Refinement (after diving into OFI-173).** The error-message buckets above are *not* clean root causes —
  the "unresolved callee" text conflates four different problems. Re-partitioning against `--emit=c` (not
  `--emit=check`) and reading the actual callees:
  - **clone.ig is a SHARED limitation, not a self-hosted gap** — stage-0's *C-emit* also rejects value-struct
    `.clone()` (OFI-082); only 1 of the 47 is shared, so **46 are real self-hosted-only gaps**.
  - The 25 "unresolved callee (OFI-173)" cases decompose into: **`remove_last`/`pop` (3, now DONE)**;
    **newtype construction `UserId(…)`/`Pct(…)` (7 → really OFI-202)**; **witness/bounded-method
    `a.compare()`/`k.eq()` (5 → OFI-174 Tier-3)**; and **method-on-element / return-typing (~10 → the deep
    OFI-173 core)**.
  - **The unifying root cause is RETURN-TYPE PROPAGATION.** The checker-less C-emit doesn't track what type a
    method call or element read *returns*, so a downstream use — `s.len()` on a popped value, a method on an
    element, a newtype ctor, witness dispatch — can't resolve. `remove_last` was the one genuinely-isolated
    branch (add `em_array_pop`); the rest need the emit to carry types the checker would otherwise stamp.
    That is the OFI-174 C-emit-completeness campaign, not a handful of method branches.
  - **Order by isolation/lever:** `remove_last` (done) → OFI-202 construction (newtype + qualified variant +
    boxed-generic field, ~20 cases, mostly self-contained) → OFI-206 lambda lifting (6) → the return-typing
    core + OFI-174 witnesses (the deep, cross-cutting part).
  Harness: `scratchpad/parity.sh` + `parity3.sh` (real-vs-shared partition).

---

## 5. The gates (G0–G6 burn-down)

- **G0 — Baseline.** Fresh full-gate run; record true `make test` / `selfhost` / `opcheck` /
  `bootstrap` / `verify` numbers (the recorded 456/0, 92 may be stale).
- **G1 — The bootstrapped compiler is a first-class, installable artifact.** A make target builds a
  persistent self-hosted `inglec` (not N1-in-mktemp); `bootstrap-refresh` re-homed onto the self-hosted
  compiler (F).
- **G2 — Oracle succession complete.** All four successor oracles live against the bootstrapped
  compiler; fuzzers re-pointed (A).
- **G3 — Coverage triage resolved.** Every open self-hosting OFI explicitly closed **or** documented as
  a v1.0 known-limitation; the silent-stub→`internal_error` tripwire re-confirmed; `unwrap`/`expect` and
  the 1 reject-parity miss decided.
- **G4 — The default & install flip.** `make` builds the bootstrapped compiler as `$(BIN)`; the ~15
  flavored targets rebuilt from selfhost sources + matching `RT_LIB_*`; `make install`/`release` and
  CI's `make` step ship the self-hosted binary (B, C). **← the bootstrapped compiler is now *the*
  toolchain.**
- **G5 — Tooling decision executed** (Fork 1). Either the LSP/prover ported onto the self-hosted
  frontend, or v1.0 ships with stage-0 retained as a frozen tooling host behind the frontier.
- **G6 — `src/` frontend archived.** The 6 frontend `.c` files off the default build; stage-0 preserved
  only as `stage0-v0.3.42`. **← the birthday.**

---

## 6. Decisions for Karl (the real forks)

**Fork 1 — what does "v1.0" *mean*?** Is the birthday declared at **G6** (full `src/` archival, which
requires porting the LSP — an Inglenook-scale sub-campaign gated on adding source positions to the
selfhost checker), or at **G4/G5(b)** (the bootstrapped compiler is the default + installed build/run
toolchain, with stage-0's frontend retained **only** as a frozen tooling host behind the frontier)?
→ **Recommendation: declare v1.0 at G4/G5(b); make G6/the LSP port a v1.1 follow-on.** Holding the
birthday hostage to the LSP port is gold-plating — Go shipped 1.5 with C tooling all around it, Rust
1.0 shipped on LLVM. "Ingle builds and ships Ingle" is the milestone; "zero C anywhere" is not.

**Fork 2 — one CLI or two?** Unify `--lsp`/`--doctor`/`--run-bytecode`/`--emit=run`/`--freestanding`
into one Ingle-driven `inglec`, or keep a thin C tooling entry hosting them? → Tied to Fork 1: under
G5(b), keep the thin C tooling entry for v1.0 (it *is* the frozen tooling host); unify in v1.1 alongside
the LSP port.

**Fork 3 — delete vs archive the frontend `.c`?** → **Recommendation: `git mv` the 6 files to a frozen
`stage0/` dir (or `filter-out` from `SOURCES`), don't `rm`.** The tag already preserves history; a
navigable frozen tree is cheap insurance and keeps the mirror/reference role alive with zero build cost.

---

## 7. Recommendation + sizing

**We're one deliberate cutover campaign from the birthday, and the scary work is already behind us.**
The self-hosted compiler reproduces itself, compiles a full real app pixel-identically, and the
silent-miscompile class is structurally closed.

- **G0–G4 = "v1.0 core"** — a few focused sessions. Dominated by build-system surgery (the ~15 flavored
  targets, the install flip) and decisions, **not** new compiler features. Ends with the bootstrapped
  compiler as *the* toolchain for building and shipping Ingle.
- **G5(b) + docs = the birthday** — declare v1.0 once G4 lands and the known-limitations list is written.
- **G6 (LSP port + full archival) = v1.1** — the one genuinely large piece, correctly deferred.

The single thing **not** to do: block v1.0 on porting the LSP or on closing every latent generics corner.
Ship the birthday on *"reproduces itself + compiles real apps + an honest known-limitations list"* —
exactly where Go 1.5 and Rust 1.0 stood.

---

## 8. Risks

- **The ~15 flavored `$(SOURCES)` targets are the largest surgery.** Each `-DEMBER_*` flavor recompiles
  the frontend today; each needs a new production path (bootstrapped compiler + link the matching
  `RT_LIB_*`). Mitigate: `make bootstrap`'s `cc(seed)+RT_LIB` recipe is the template — this is
  re-plumbing, not invention.
- **`make selfhost`'s meaning inverts.** With no separate C reference to diff against, the byte-identity
  differential is superseded by `make bootstrap` (the reproduction fixed point) as the primary
  structural guard. Sequence: stand up the successor oracles (G2) *before* demoting the differential.
- **The seed becomes irreplaceable-from-C.** After G6, only a prior self-hosted N-generation binary can
  refresh the seed. If a future selfhost edit needs a feature the current seed can't compile, there's no
  C fallback — so seed-refresh cadence (refresh whenever a change raises the language floor) becomes part
  of the release process. Mirrors Go's requirement that 1.4 build 1.5.
- **The bootstrap fixed point is seed-*strict*, not tolerant — found live at G0.** `make bootstrap` was
  RED this session: its step-3/4 checks compare the **seed-built N1's** emit against N2's, so *any*
  output-changing `cgen_c.ig` commit reds the gate until `make bootstrap-refresh` runs (the header
  comment's "Go-1.5 tolerance" covers only step 2, "seed can compile current source" — the reproduction
  checks are stricter). The last 8 hardening commits changed the emit and never refreshed; `make
  selfhost` stayed green throughout, so nothing flagged the drift. **G1 decision:** either (a) enforce
  refresh-on-`cgen_c`-change — cheapest is a CI/`verify` check that fails when the seed is behind, so the
  drift can't land silently (recommended: post-cutover a strict, always-current seed is *safer* — a
  from-scratch bootstrap is then never more than the current source, with no multi-generation
  convergence risk and no C fallback needed), or (b) relax the fixed point to the tolerant `N2==N3` form
  (two current-logic generations agree) so a stale seed never reds the gate. Recommend (a): keep the
  strict seed, add the tripwire.

---

## 9. Cross-references

- [OFI-218 / `selfhost-full-language.md`](selfhost-full-language.md) — the parent campaign; §3 (oracle
  succession), §6 (stage-0's endgame — this doc is §6(a)).
- `docs/architecture.md` Decisions 1/2/3 — frozen stage-0 tag, frontend/runtime split, "the flip is
  realized."
- `docs/OFI.md` OFI-224 (this campaign), OFI-173/174 (the silent-stub class, now closed), OFI-223/222/199
  (residual reject-parity), OFI-182 (the macOS GL/worker deadlock — an app risk, not a cutover blocker).
- `bootstrap/README.md`, `tools/bootstrap.sh`, `Makefile:604-618` — the frontend-free rebuild loop.

---

## 10. Progress log

- **2026-07-25 — OFI-224 opened.** Recon complete (bootstrap loop / build topology / oracle & fuzzer
  ownership / tooling coupling / coverage triage verified against the live tree). Reframed: the flip
  landed under OFI-218; this is the staged-retirement cleanup.
- **2026-07-25 — Fork 1 RATIFIED (Karl): v1.0 = G4/G5(b).** The birthday is declared when the
  bootstrapped compiler is the default + installed build/run toolchain with stage-0 frozen as a tooling
  host behind the frontier; the LSP port + full `src/` archival (G6) are a **v1.1** follow-on. Forks 2/3
  fold into that (keep the thin C tooling entry for v1.0; `git mv` the frontend to a frozen tree rather
  than `rm`). Starting **G0** — fresh baseline.
- **2026-07-25 — G0 COMPLETE.** Fresh gate baseline: `make test` **458/0**, `make opcheck` **92/396**,
  `make selfhost` **1517/0** (reproduction fixed point intact). `make bootstrap` was **RED** — the
  checked-in seed had gone output-stale after the last 8 `cgen_c.ig` hardening commits; `make
  bootstrap-refresh` restored it (16,177→19,720 lines) and the frontend-free fixed point is **GREEN**
  again (seed committed `cd6698c`). Finding recorded in §8: the fixed point is seed-*strict*, so a
  seed-drift tripwire is a G1 item. All gates now green; baseline established. Next: **G1**.
- **2026-07-25 — G1 COMPLETE.** (1) `make inglec-self` → `build/inglec-self`, the persistent
  frontend-free self-hosted compiler (881 KB from seed + runtime alone); reproduces the seed
  byte-for-byte and runs real programs identically to the VM (`examples/06_calculator` native ==
  stage-0 VM). (2) `bootstrap-refresh` re-homed off `$(BIN)` → `tools/bootstrap-reseed.sh`, a
  two-generation frontend-free reseed (the F item — seed refresh now survives frontend retirement).
  (3) CI tripwire: Linux CI runs `make bootstrap` after `selfhost` (closes the G0 drift gap). Commit
  `7e3a2d8`. **Findings for later gates:** (a) *G4* — no single self-hosted driver does check+C-emit
  (`cgen_c_dump` trusts input, `emberc` checks but emits bytecode); the default `inglec` must fuse
  `selfhost/checker.ig` + `selfhost/cgen_c.ig` and match stage-0's accept/reject. (b) *G3* — the
  self-hosted C-emit omits a `drop_value` stage-0 emits (a missed free = leak-direction, sound; not a
  crash) — one entry for the coverage catalog. Next: **G2** (oracle succession) or **G4** (the flip)
  — G4's check+emit fusion is the critical-path item.
- **2026-07-25 — G4 IN PROGRESS: the fused check+C-emit driver built.** New `selfhost/compile_c.ig` =
  `cgen_c_dump.ig`'s load-and-emit path with `emberc.ig`'s `ck.check` gate fused in front (the load_modules
  machinery is duplicated for now; driver consolidation is later Fork-2 work). Built via stage-0 into a
  1.09 MB checked compiler. Spot-verified: **rejects** a type error `let x: int = "hello"` with exit 65
  (parity with stage-0), **accepts** a valid `var`-loop program (emits C → compiles → runs `sum=16`), and
  its C emit is **byte-identical** to the unchecked driver's (the check is a pure front gate, no emit
  change).
- **2026-07-25 — G4 parity + coverage MEASURED (see §4a).** Checker: **0 false-rejects** over 220
  accept programs; **87/90** check-reject parity (3 documented under-rejections). C-emit: **47 of ~267
  corpus programs hard-fail loudly (exit 70)** — no silent miscompiles — bounded to **OFI-173 (25) →
  OFI-202 (15) → OFI-206 (6)**. **This is the real remaining engineering to a G4-honest v1.0**: the
  check gate is done, the C-emit coverage is the OFI-174 C-emit completeness work, now corpus-measured
  and ranked. Recommended next: close **OFI-173** (method-call-on-element resolution — clears 53% of
  the gap in one lever). `selfhost/compile_c.ig` committed.
- **2026-07-25 — OFI-173 dived in: `remove_last` DONE + the frontier re-characterised (see §4a).**
  Implemented `arr.remove_last()` → `em_array_pop` in the self-hosted C-emit (`c0c163f`, gated
  `cgen_c_run/array_remove_last.ig`, `make selfhost` 1522/0, bootstrap green after frontend-free reseed).
  **Key correction:** the "53% in one lever" estimate was wrong — the OFI-173 error-message bucket
  conflates `remove_last` (isolated, done), newtype construction (OFI-202), witness dispatch (OFI-174),
  and the deep **return-type-propagation** core. Only `remove_last` was a clean isolated branch; the rest
  need the checker-less C-emit to carry return/element types (the OFI-174 completeness campaign). Also:
  clone.ig is a *shared* stage-0 limitation (46 real gaps, not 47). This is the honest cost/benefit
  inflection: the full C-emit close is a major campaign, not mechanics — decision point recorded for Karl.
- **2026-07-25 — Karl chose (A). OFI-202 newtype construction DONE (46 → 38 gaps).** `Name(x)` erases to
  its base value (`build_newtypes` + emit_call branch, `5a2c4c7`, byte-identical fixture
  `cgen_c/newtype_construct.ig`, `make selfhost` 1525/0, bootstrap green). newtype_basic/soundness run
  native==VM; newtype_ops's only residual is the pre-existing bool-render cosmetic gap. **Qualified nullary
  variant (`Color.Red`, 2 files) attempted then REVERTED** — the emit itself is one line (`em_enum(id,tag,0)`)
  but the *ownership* side spreads: the value must be recognised as owned-enum by `is_enum_expr` AND the
  SLet retain-dance classifier AND (unfound) more sites, or the binding under-retains and crashes. Not
  worth 2 files now; deferred with the deeper element-typing frontier. **Remaining 38:** boxed-generic
  ELEMENT field access (`arr[i].x`, ~12 — the return/element-typing core), witness/bounded-method
  (`a.compare()`, ~5 → OFI-174), lambda lifting (~6 → OFI-206), qualified variant (2, deferred), misc.
  The cheap-isolated wins (remove_last, newtype ctor) are now banked; **what's left is the return-/
  element-type propagation core** — the genuinely deep, cross-cutting part of the OFI-174 campaign.
- **2026-07-25 — one more incremental win: inferred struct-array element access (38 → 37).** `var arr =
  [P{…}]` (no annotation) now infers its element struct sid from the first element (`value_elem_struct`
  EArray case, `d3a88b1`, gated `cgen_c_run/inferred_struct_array.ig`, run==VM, 1528/0, bootstrap green).
  **Observation: the incremental fixes now clear ~1 file each** (remaining cases each need a *different*
  slice of the same missing type info), while the deep fix — the self-hosted **checker stamping resolved
  types into a side table the C-emit consumes** (possible now that `compile_c.ig` runs both in one
  process) — would unblock the return-typing cases *together*. **Recommendation: the remaining ~37 are
  best closed by that checker-type-threading campaign, approached deliberately, not one file at a time.**
  Banked so far this session: G0 (bootstrap un-redded), G1 (frontend-free artifact + reseed + CI
  tripwire), G4 check gate (0 false-rejects), and 3 C-emit fixes (46 → 37 native gaps) — all gate-green.
