# `bootstrap/` — Ingle builds Ingle

This directory makes the Ingle toolchain **self-sustaining**: the compiler is rebuilt from a
checked-in artifact written *by* Ingle, with **no `src/` C frontend in the loop**. It is the capstone
(Phase 6) of the Selfhost Full-Language campaign (OFI-218) — the point at which the language is
developed and extended *in Ingle*, not gated on the C reference compiler.

## What's here

- **`seed/inglec_boot.c`** — the **seed**: the C emitted by the self-hosted C-emit backend for the
  *whole* self-hosted compiler (`selfhost/cgen_c_dump.ig` and everything it imports — the Ingle
  lexer → parser → checker → codegen → C-emit, ~16k lines of generated C). Compiled with `cc` and
  linked against the runtime, it **is** a native Ingle→C compiler. It is generated output — do not
  edit it by hand (`make bootstrap-refresh` re-snapshots it).

## `make bootstrap` — the chain (no frontend)

```
cc(seed + runtime) ─────────────► N1          a native Ingle→C compiler
N1  compiles selfhost source ───► C2 ─cc─► N2  a 2nd-generation compiler
N2  compiles selfhost source ───► C3           assert C2 == C3  (self-reproducing)
N1, N2 agree on every module                   whole-source coverage
N1  compiles + runs hello.ig                   a working compiler, end-to-end
```

The **only** C compiled is the seed and the **runtime** library (`src/runtime.c` + `src/cextern.c` →
`build/libember_rt.a`). Every Ingle binary links the runtime — it is a dependency, not the compiler,
exactly like libc under any bootstrapped toolchain. The compiler **frontend** in `src/`
(`lexer.c`, `parser.c`, `check.c`, `codegen.c`, `cgen_c.c`, `main.c`) is **never** built for this
target — verified by `make clean && make bootstrap` compiling only `runtime.c` + `cextern.c`.

## Extending the language, in Ingle

1. Edit the compiler — which is written in Ingle: `selfhost/checker.ig`, `selfhost/codegen.ig` (VM
   backend), `selfhost/cgen_c.ig` (C-emit backend).
2. `make bootstrap` — the checked-in seed builds N1; **N1 compiles your edited Ingle sources** into a
   new, self-reproducing compiler. No C frontend was touched.

This is the flipped workflow the campaign set out to reach: Ingle is the source of truth for the
language, and it builds itself. (`panic` — the first Ingle-first feature — was added exactly this way:
written in `selfhost/*.ig` first, then mirrored to `src/`.)

## The seed and the Go-1.5 model

`make bootstrap` follows the Go-1.5 bootstrap model: the seed need not be **byte-identical** to the
current source — only able to **compile** it (which the chain proves). So a routine selfhost edit does
**not** require regenerating the 16k-line seed; the existing seed stays a valid bootstrap floor as long
as it can compile the newer source. `make bootstrap` reports whether the seed is byte-current and, if
behind, invites a refresh — but does not fail.

**`make bootstrap-refresh`** re-snapshots `seed/inglec_boot.c` from the current selfhost sources. It is
a deliberate "raise the floor" step (at releases, or when a new language feature the old seed can't
compile lands), not a per-edit chore. It regenerates the seed with the reference compiler; `make
bootstrap` then re-verifies the fixed point with no frontend.

## Stage-0's role after this

With bootstrap independence in place, the C reference compiler (`src/`) is no longer on the critical
path to *building* Ingle. It remains the **mirror and tooling host** (the parity rule keeps `src/` and
`selfhost/` byte-identical while feature-equal; the LSP and other tooling still ride the C frontend
today). Its eventual retirement — porting the tooling to the Ingle frontend, then archiving `src/` — is
a follow-on, tracked in [`docs/design/selfhost-full-language.md`](../docs/design/selfhost-full-language.md).
