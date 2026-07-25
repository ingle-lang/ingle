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

**Green gates today** (cite the current numbers, not the doc's frozen snapshots):
- `make selfhost` **1517/0** (HEAD `b02eec7` body; the transitional self-hosting differential).
- `make test` **456/0**, `make opcheck` **92 opcodes** — *last recorded snapshots (Phase-5 log); may
  have moved.* → **G0 re-establishes these fresh.**
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
| **Blocks compiling real programs** | *(none)* | The self-hosted compiler builds itself **and** Inglenook. |
| **Silent-wrong-answer risk** | *(structurally closed)* | P0/P1 made coverage holes hard-fail (`internal_error`), not miscompile. Latent representational gaps (OFI-203 value-struct-in-enum payload, OFI-202 `Color.Red` value form, OFI-163 generic Option/Result payload refcount, OFI-164 inline-struct array literal) are **not corpus-reachable** — fail loudly if ever hit. |
| **Diagnostic / reject-parity** | OFI-223 (cross-module struct field, worked around), OFI-222 (partial named-arg validation), OFI-199 (over-u64 literal not rejected), the 1 verdict miss `error_resource_clone_match` | Ship as known-limitations or close opportunistically. None blocks extend-in-Ingle. |
| **Ergonomic / cosmetic** | `unwrap`/`expect` (deferred; `panic` already shipped), bool-render `0/1` vs `true/false` in interpolation, OFI-200 bytecode source-map delta, OFI-221 empty-array-arg AEK | Post-1.0 polish. |
| **Tooling** | LSP frontend coupling (Fork 1), fuzzer re-point (trivial) | The real v1.0 tooling decision. |

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
