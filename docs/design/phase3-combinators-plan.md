---
title: Phase 3 — Option/Result Combinators (implementation plan)
nav_exclude: true
sitemap: false
description: "Sequenced plan to ship prelude Option/Result combinators (is_some, unwrap_or, map, …) callable via UFCS, byte-identical in both compilers."
layout: default
---

# Phase 3 — Option/Result Combinators

Part of the [ergonomics campaign](ergonomics-campaign.md), **OFI-187**. Ship the ergonomic
combinators — `is_some` / `is_none` / `unwrap_or` / `is_ok` / `is_err`, then `unwrap` / `expect` /
`map` / `and_then` / `ok_or` — callable method-style via the UFCS enabler already shipped at
`10040c4`: `o.unwrap_or(0)` desugars to `unwrap_or(o, 0)`.

**Hard rule (unchanged):** every piece lands in BOTH the C reference compiler AND `selfhost/*.ig`,
byte-identical, with all 8 `make verify` gates green and `make selfhost` at its full count. No
`selfhost-skip`. Do the C side and the selfhost mirror in the *same* change; re-run `make selfhost`
before moving on.

---

## Delivery decision: the PRELUDE, with a shadow rule

Settled after grounding every option against the live compiler (2026-07-09). The combinators live in
`PRELUDE_SOURCE` (`src/main.c`) — the same place `Option`/`Result` the *types* already live — **not**
in an imported `std/option.ig` module. Three verified facts drove this:

1. **No bloat.** Unused generic functions are tree-shaken — a generic `fn` that nothing calls emits
   **zero** code (verified: `--emit=c` count 0). A program that never touches `Option` carries none of
   the combinator code. The "prelude bloats every program" objection is false.
2. **UFCS cannot reach imports.** Imported std functions are locked behind their alias: `str.index_of(s,x)`
   works but `s.index_of(x)` fails ("no such string method"). So a `std/option.ig` module could only ever
   give `opt.unwrap_or(o,0)` — never the `o.unwrap_or(0)` we want. The prelude is global and the only home
   that yields the target ergonomics with the resolver change below.
3. **Squatting is solvable.** The only real objection to the prelude — a user defining their own
   `unwrap_or` — is fixed by a **user-definition-shadows-prelude** rule. Precedent already exists:
   `program_declares_enum` (`src/main.c`) lets a user enum win over the prelude's. We mirror it for
   functions (`program_declares_fn`).

---

## Verified gap analysis (against HEAD `10040c4`, 2026-07-09)

| Gap | Verdict | Cost |
|-----|---------|------|
| **B — checker rejects `Option<T>` params** | **NON-ISSUE.** A user `fn is_some<T>(o: Option<T>) -> bool` checks, runs, and works under UFCS on both backends today. `Option<int>` and `Option<T>` both resolve. My earlier "parameter types must be…" error was purely the `option.ig` name collision, reproduced and ruled out. | none |
| **C — prelude fns invisible to user code** | **REAL, small.** From a user module, `is_some(a)` → "call to an undefined function"; `a.is_some()` → "method call requires a struct value". `resolve_signature` (`src/check.c:2037`) searches current-module only. Both plain-call and UFCS need a global/prelude fallback. | small |
| **Shadow rule** | **REAL, small.** Needed so common names (`unwrap_or`, `map`) don't get squatted. Mirror `program_declares_enum` → `program_declares_fn`; suppress the duplicate-definition error and resolve to the user's. Selfhost modules only define `expect` as a *method* (no free-fn collision), so scope is tiny. | small |
| **A — selfhost C-emit can't construct/match prelude Option/Result** | **THE hard gap (OFI-203/204).** `let a: Option<int> = Some(5)` compiles to a stub `INT_VAL(0)` in `selfhost/cgen_c.ig` (stage-0 emits `em_enum(&g_em, 1, 0, 1, INT_VAL(5))`); a `match` on a generic `Option<T>` param misclassifies `Some/None` as a scalar binding. The VM backend (`selfhost/codegen.ig`) already handles both correctly. | large |

**Conclusion:** the campaign collapses to essentially **one hard milestone (Gap A)** plus three cheap
ones. Gap A is the foundation everything else (especially the constructing combinators `map`/`ok_or`)
stands on, so it goes first.

---

## Anchors (verified)

**C reference (the byte-identical oracle):**
- Construction: `src/cgen_c.c:1327-1335` (data-carrying variant), `:2430-2431` (zero-field). Emits
  `em_enum(&g_em, enum_id, tag, field_count, payload…)` from checker annotations `variant_enum_id` /
  `variant_tag` (`include/ast.h:167-171`).
- Variant table: `src/cgen_c.c:3728-3758` — `CgcVariant` built over **all** `DECL_ENUM` in declaration
  order (user modules, then prelude), so `Option`=enum_id 1, `Result`=2 in a one-user-enum program.
- Fallback name lookup: `resolve_variant` (`src/cgen_c.c:99-106`).
- Prelude merge: `load_modules` (`src/main.c:~300-371`) appends `PRELUDE_SOURCE` before checking.
- Resolver: `resolve_signature` (`src/check.c:2037-2045`, current-module only); UFCS rewrite calls it at
  `src/check.c:4205-4227`; qualified path `resolve_qualified_fn` (`:2051-2079`).
- Shadow precedent: `program_declares_enum` (`src/main.c:~213`).

**Selfhost (must reproduce byte-for-byte):**
- Gap A site: `build_enum_tab` (`selfhost/cgen_c.ig:1539-1601`, user enums only); `EnumTab.variant_flat`
  (`:1370-1402`); `emit_enum_ctor` (`:2357-2372`, indexes `v_owner[-1]` on miss); `SMatch` classification
  (`:3912-4125`, bare `variant_flat` at `:3989/4002/4029`); `payload_ty` (`:1463-1466`).
- The working VM model to mirror: `match_owner_enum` (`selfhost/codegen.ig:3393-3419`) +
  `resolve_case_vi` (`:3425-3438`) — scopes variant lookup to the scrutinee's enum, falls back to the
  global `ev_name` table (which includes prelude variants).
- Resolver: `resolve_free_fn` (`selfhost/codegen.ig:5106-5120`, current-module then global); UFCS
  `gen_ufcs` (`:5267-5308`).
- Match-classification half of Gap A: **already written** as a saved patch
  (`scratchpad/ofi204-match-classification.patch`, 177 lines) — was green at `make selfhost` 1411/0.
  Re-apply as the starting point of M1.

---

## Sequence

### M1 — Gap A: self-hosted C-emit builds AND matches prelude Option/Result (closes OFI-203/204)

The foundation. **Approach (lowest reproduction risk):** do *not* add prelude variants to
`build_enum_tab` — the selfhost modules' own typed `Option` matches (on `recv()`/`parse_int()` results)
resolve via the typed/field path and rely on `Some/Ok/Err` being absent from the fast `variant_flat`
path. Instead mirror the VM's scoped resolution into `cgen_c.ig`:

1. Add a parallel `ev_*` variant table + `match_owner_enum` / `resolve_case_vi` to the C-emit Emitter,
   built the same way `codegen.ig` builds them (declaration order, user then prelude → same enum_ids as
   the C reference's `CgcVariant`).
2. **Construction:** in `emit_enum_ctor`, try `variant_flat` (declared user enums) then fall back to an
   arity-aware `resolve_ctor_vi` for prelude variants → emit `em_enum(&g_em, enum_id, tag, argc, …)` /
   `em_enum(&g_em, enum_id, tag, 0)` identical to `src/cgen_c.c:1328/2431`.
3. **Match:** replace bare `variant_flat` calls in `SMatch` with `resolve_case_vi(name, owner_enum)`
   (owner computed once per match). Re-apply the saved match-classification patch here.
4. **Refcount-on-escape:** a generic `Option<T>` payload binding that escapes (returned/stored) needs
   stage-0's `IS_OBJ`-retain wrapper (OFI-204 note) — mirror `payload_ty`/`payload_refc` off the `ev_*`
   type fields, not `pf_ty[-1]`.

**Gates:** new fixtures `tests/selfhost/cgen_c/prelude_option_construct.ig` (constructs `Some/None/Ok/Err`)
and `prelude_option_match.ig` (matches a generic `Option<int>`/`Result<int,int>` param) must be
byte-identical to stage-0. Existing `tests/selfhost/cgen_c/*.ig` (module reproduction) must be
**unchanged**. `make selfhost` full count, `make verify` 8/8. Behavioral `tests/run/prelude_option.ig`.
Also confirm the VM side (`selfhost/codegen.ig`) — recon flags it clean for scalar `Option<int>`; verify
the OFI-203 value-struct-payload sub-case stays out of scope (combinators use scalar/boxed generic
payloads only).

**Verification discipline:** this is the tape-and-dogfood milestone. When a fixture diverges, diff
stage-0 `--emit=c` vs `--emit=run selfhost/cgen_c_dump.ig` on the *same* source path and read the C, arm
by arm — do not guess.

### M2 — Gap C + shadow rule: prelude free functions are globally visible

1. **Global resolution (both compilers):** `resolve_signature` (C) and `resolve_free_fn` (selfhost) gain
   an `is_global_module` fallback — current module first, then the global/prelude module. This makes
   both `is_some(a)` (plain call) and `a.is_some()` (UFCS) resolve to a prelude combinator. (This is the
   change made+reverted last session; re-derive cleanly.)
2. **Shadow rule (both compilers):** add `program_declares_fn` mirroring `program_declares_enum`; when a
   user module defines a function whose name also exists only in the prelude, the user's wins and no
   duplicate-definition error fires. Current-module-first resolution already routes calls to the user's.

**Gates:** fixture `tests/run/prelude_fn_visible.ig` (`o.unwrap_or(0)` resolves to a prelude combinator)
+ `tests/run/prelude_fn_shadow.ig` (a user `fn unwrap_or` shadows the prelude, its result used). Both
backends byte-identical; a selfhost fixture for each; `make verify` 8/8.

### M3 — the combinators themselves

Add to `PRELUDE_SOURCE`, cheapest first, gating each on both backends before the next:

- **Cheap (bool, non-constructing):** `is_some`, `is_none` (`Option<T>`), `is_ok`, `is_err`
  (`Result<T,E>`). Pure match → bool. Trivial once M1+M2 land.
- **`unwrap_or<T: Copy>(o, d)`** — `Copy` bound required (a match binding is a borrow; a non-`Copy`
  payload can't escape). Verified working at user level.
- **`unwrap<T>(o)` / `expect<T>(o, msg)`** — trap on `None`/`Err`. Route through the **Fault** machinery
  (implicit contract → `contract_violation` event), consistent with the other builtin traps. Medium.
- **Constructing / higher-order (lean hard on M1):** `map<T,U>(o, f)` and `and_then` take a
  function/closure param and **construct** `Some(f(v))`; `ok_or<T,E>(o, e)` turns `Option`→`Result`,
  constructing `Ok`/`Err`. These are why M1 (construction) must be rock-solid first.

**Gates:** one `tests/run/combinators_*.ig` per group (VM+native diff via the harness) plus a
`tests/selfhost/{codegen,cgen_c}/combinators.ig` byte-identical fixture. `make verify` 8/8; Crucible/ASan
cover the refcounting of constructed/escaping payloads.

### M4 — docs, tests, OFI closure

- `docs/language.md`: combinator reference + the shadow rule + prelude-global-functions note.
- `docs/grammar.ebnf`: unchanged (UFCS already covers call syntax) — confirm.
- Close **OFI-187** (combinators), **OFI-203** (value-struct enum payload, if M1 resolves it),
  **OFI-204** (generic-param match C-emit). Update `docs/OFI.md` and the campaign memory.

---

## Risk register

- **R1 (highest) — M1 breaks module reproduction.** Adding prelude variants to the fast path changes how
  the selfhost modules' own typed `Option` matches emit. *Mitigation:* keep `build_enum_tab` untouched;
  resolve prelude variants only via the `ev_*` fallback where `variant_flat` returns −1; assert the
  existing `tests/selfhost/cgen_c/*.ig` corpus stays byte-identical after every edit.
- **R2 — enum_id/tag ordinals misalign.** The `ev_*` table must number enums in declaration order (user
  then prelude), variants by ordinal within the enum, `field_count` = payload arity (not type-param
  count), and a generic instance (`Option<int>`) must use the BASE enum's id. Any deviation misaligns
  `em_enum` args. *Mitigation:* build `ev_*` identically to `codegen.ig`'s pass; diff against the C
  reference's `CgcVariant` order.
- **R3 — refcount leak/double-free on escaping generic payloads.** *Mitigation:* mirror stage-0's
  `IS_OBJ`-retain wrapper exactly; Crucible + ASan gate it.
- **R4 — shadow-rule cross-module surprise.** A user `unwrap_or` with a *different* signature than the
  prelude's. *Mitigation:* current-module-first resolution + `program_declares_fn` suppresses only the
  clash; the prelude version is simply not emitted for that program (DCE). No overload resolution added.

## Definition of done

`o.unwrap_or(0)` / `o.map(f)` / `r.is_ok()` etc. work identically on VM and native; every combinator is
gated by a byte-identical selfhost fixture; a user may still define their own `unwrap_or`; all 8
`make verify` gates green; OFI-187/203/204 closed; docs updated. Only then do we push.
