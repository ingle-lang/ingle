# tests/selfhost — the self-hosting bootstrap differential

This tier backs the staged plan in [`docs/design/self-hosting.md`](../../docs/design/self-hosting.md):
porting the Ember compiler into Ember, one differential-green stage at a time, with the C reference
compiler (stage 0) kept as the oracle the whole way.

Each `*.em` here is a **compiler-shaped program** — recursive ASTs, symbol tables, the lex/parse/eval
shapes the reference compiler is built from. The runner ([`tests/run-selfhost.sh`](../run-selfhost.sh),
invoked by `make selfhost`) runs every case **twice** and requires byte-identical stdout:

- on the bytecode VM — `emberc --emit=run X.em`
- as a native binary — `emberc -o <bin> X.em` then run it

This is the same drift guard `tests/native` applies to the native backend, here pointed at the
self-hosting prerequisites. It is a **differential, not a golden snapshot** — there are no `.out`
files — which is why the golden loop in `tests/run.sh` skips the `selfhost` stage and this tier has its
own target. `make selfhost` is wired into `make verify` and CI.

## Stage A — prerequisite spikes (current)

The first milestone (M0): retire the residual "is the shape expressible end-to-end, at scale, on both
backends?" risk before any real stage is ported.

| File | What it proves |
|---|---|
| [`calc.em`](calc.em) | A complete `lex → parse → eval` pipeline in miniature: byte-level string scanning, a recursive `enum` AST with **both** `Box<Expr>` (single/two-child) and `[Expr]` (n-ary) recursion, exhaustive `match`, a `Map<string,int>` variable environment, and `Result` + `?` error propagation. |
| [`symtab.em`](symtab.em) | The checker's data structures at scale: a string interner (2000 distinct symbols, deduped over repeats), a keyword `Set`, and a `[Map<string,int>]` scope stack with shadowing. |
| [`recursion_scale.em`](recursion_scale.em) | The AST shapes at the size a compiler produces: a 150-deep `Box` spine (kept under the VM's 256-frame call cap, `vm.c` `FRAMES_MAX`), an 8000-wide `[Tree]` node, and a depth-16 balanced tree (65 536 leaves). |

As later stages land (self-hosted lexer, parser, checker, bytecode backend) they add their own cases
and, where the oracle is stage 0's `--emit` output rather than a VM/native diff, the runner grows a
second comparison mode. See the design doc's stage-by-stage plan.
