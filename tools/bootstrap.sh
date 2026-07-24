#!/bin/sh
# tools/bootstrap.sh — Phase 6 of the Selfhost Full-Language campaign (OFI-218): prove the Ingle
# compiler builds ITSELF from a checked-in C seed, with NO src/ FRONTEND in the loop. This is what
# makes the language self-sustaining — developed and extended in Ingle (edit selfhost/*.ig, rebuild
# through this chain), not gated on the C reference compiler.
#
# What is / isn't in the loop:
#   * NOT used: the src/ FRONTEND — lexer.c, parser.c, check.c, codegen.c, cgen_c.c, main.c. The
#     compiler is bootstrap/seed/inglec_boot.c (the C-emit of selfhost/cgen_c_dump.ig + its imports:
#     the whole self-hosted lexer→parser→checker→codegen→C-emit, ~16k lines of generated C).
#   * USED: cc, and libember_rt.a — the RUNTIME library (src/runtime.c + cextern.c). Every Ingle
#     binary links the runtime; it is not the compiler. This is the same split as any bootstrapped
#     toolchain (the seed is the compiler; libc/the runtime is a dependency).
#
# The chain (Go-1.5 model — the seed need not be byte-identical to the current source, only able to
# compile it; refresh it deliberately with `make bootstrap-refresh`, not on every edit):
#   1. cc(seed + runtime) -> N1                          a native Ingle→C compiler, no frontend
#   2. N1 compiles the CURRENT selfhost driver -> C2 ; cc(C2) -> N2
#   3. N2 compiles the CURRENT selfhost driver -> C3 ; assert C2 == C3   (self-reproducing)
#   4. N1 and N2 emit byte-identical C for EVERY selfhost module         (whole-source coverage)
#   5. N1 compiles + runs a program end-to-end                          (a WORKING compiler)

set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
export EMBER_STD="$ROOT/std"
SEED="$ROOT/bootstrap/seed/inglec_boot.c"
RT="$ROOT/build/libember_rt.a"
CC="${CC:-cc}"
CCFLAGS="-std=c17 -O2 -D_DEFAULT_SOURCE -I$ROOT/include"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fail() { echo "bootstrap: ✗ FAIL — $1" >&2; exit 1; }

[ -f "$SEED" ] || fail "seed not found: bootstrap/seed/inglec_boot.c"
[ -f "$RT" ]   || fail "runtime not built: $RT — run 'make' first (the bootstrap target builds it)"

# strip the trailing `=> 0` line a compiled driver prints (its own main() return); the reference
# `--emit=c` seed has no such line, so stripping it makes the two comparable.
emit() { (cd "$ROOT" && "$1" "$2" 2>/dev/null) | sed '/^=> 0$/d'; }

DRIVER="selfhost/cgen_c_dump.ig"

# 1. cc(seed + runtime) -> N1 — the ONLY C compiled is the seed; NO src/ frontend object is touched.
echo "bootstrap: [1/5] cc(seed + runtime) -> N1  (no src/ frontend in the loop)…"
$CC $CCFLAGS "$SEED" "$RT" -lm -o "$WORK/n1" || fail "could not compile the seed into N1"

# 2. N1 compiles the CURRENT self-hosted compiler source into C2, and cc builds a 2nd generation N2.
echo "bootstrap: [2/5] N1 compiles the current selfhost source -> N2…"
emit "$WORK/n1" "$DRIVER" > "$WORK/c2.c"
[ -s "$WORK/c2.c" ] || fail "N1 produced no output for $DRIVER (seed too old to compile current source? run 'make bootstrap-refresh')"
$CC $CCFLAGS "$WORK/c2.c" "$RT" -lm -o "$WORK/n2" || fail "could not compile N1's output into N2 (seed may be behind the current source — 'make bootstrap-refresh')"

# 3. N2 must reproduce the SAME compiler source — the self-reproduction fixed point, seed-driven.
echo "bootstrap: [3/5] N2 reproduces the compiler source (fixed point)…"
emit "$WORK/n2" "$DRIVER" > "$WORK/c3.c"
diff -q "$WORK/c2.c" "$WORK/c3.c" >/dev/null || fail "N1 and N2 diverge on $DRIVER — not a fixed point"
echo "bootstrap:       ✓ N1→N2 self-reproduces from the seed"

# 4. Whole-source coverage: N1 and N2 must agree on EVERY self-hosted module, not just the driver.
echo "bootstrap: [4/5] N1 and N2 agree on every selfhost module…"
for m in lexer parser checker codegen cgen_c serialize codegen_dump serialize_dump check_dump cgen_c_dump; do
    [ -f "$ROOT/selfhost/$m.ig" ] || continue
    a=$(emit "$WORK/n1" "selfhost/$m.ig")
    b=$(emit "$WORK/n2" "selfhost/$m.ig")
    [ "$a" = "$b" ] || fail "N1 and N2 diverge on selfhost/$m.ig"
done
echo "bootstrap:       ✓ byte-identical over every module"

# 5. End-to-end: N1 is a WORKING compiler — Ingle -> C -> cc -> run.
echo "bootstrap: [5/5] N1 compiles + runs a program end-to-end…"
printf 'fn main() -> int {\n    println("bootstrapped Ingle — built by Ingle, no C frontend")\n    return 0\n}\n' > "$WORK/hello.ig"
emit "$WORK/n1" "$WORK/hello.ig" > "$WORK/hello.c"
$CC $CCFLAGS "$WORK/hello.c" "$RT" -lm -o "$WORK/hello" || fail "could not compile a program via N1"
# a native binary prints a trailing `=> <main return>` line (the same convention as --emit=run); strip
# it to compare the program's own stdout.
out=$("$WORK/hello" 2>/dev/null | sed '/^=> 0$/d')
[ "$out" = "bootstrapped Ingle — built by Ingle, no C frontend" ] || fail "the bootstrapped compiler produced wrong output: [$out]"
echo "bootstrap:       ✓ $out"

# Informational: is the checked-in seed still byte-current with the source? (Not a failure if behind —
# the Go-1.5 model only needs the seed able to COMPILE the current source, proven above.)
if diff -q "$SEED" "$WORK/c2.c" >/dev/null 2>&1; then
    echo "bootstrap: seed is byte-current with selfhost/ (a faithful snapshot)."
else
    echo "bootstrap: NOTE — the seed is BEHIND the current selfhost source (still a valid bootstrap"
    echo "bootstrap:        floor: it compiled the current source above). Refresh at your convenience"
    echo "bootstrap:        with 'make bootstrap-refresh' to re-snapshot it."
fi

echo ""
echo "bootstrap: 🎉 SELF-HOSTING BOOTSTRAP GREEN — Ingle builds its own compiler from the checked-in"
echo "bootstrap:    C seed, cc, and the runtime alone. No src/ frontend in the loop. The language is"
echo "bootstrap:    developed and extended IN INGLE (edit selfhost/*.ig; rebuild through this chain)."
