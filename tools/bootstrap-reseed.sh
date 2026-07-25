#!/bin/sh
# tools/bootstrap-reseed.sh — refresh the checked-in bootstrap seed WITHOUT the src/ frontend
# (OFI-224 G1, the F item). This is the cutover-forward replacement for the old `bootstrap-refresh`
# one-liner (`inglec --emit=c … > seed`), which depended on the C reference compiler $(BIN) and dies
# once the frontend is retired. Here the ONLY compiler used is the current seed itself, plus cc and the
# runtime — exactly the bootstrap loop's dependency set.
#
# Why TWO generations (not one direct emit of the seed):
#   The seed embodies whatever cgen_c.ig logic it was last snapshotted from. If selfhost/cgen_c.ig has
#   since changed its OUTPUT, a single emit from the seed-built compiler (N1) reflects the OLD logic —
#   it would re-snapshot a stale seed. So we go one generation further: N1 compiles the CURRENT source
#   into N2 (which embodies the current logic), and N2's emit is the byte-current fixed-point seed.
#   When the seed is already current this is a no-op (N1 == N2's logic), so it is safe to run anytime.
#
#   1. cc(seed + runtime) -> N1
#   2. N1 emits the CURRENT selfhost driver -> c2 ; cc(c2) -> N2      (N2 embodies current source)
#   3. N2 emits the CURRENT selfhost driver -> c3                     (the fixed-point seed)
#   4. install c3 as bootstrap/seed/inglec_boot.c
#   5. verify: a fresh N1' from the NEW seed re-emits c3 byte-identically (one-step fixed point)

set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
export EMBER_STD="$ROOT/std"
SEED="$ROOT/bootstrap/seed/inglec_boot.c"
RT="$ROOT/build/libember_rt.a"
CC="${CC:-cc}"
CCFLAGS="-std=c17 -O2 -D_DEFAULT_SOURCE -I$ROOT/include"
DRIVER="selfhost/cgen_c_dump.ig"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fail() { echo "bootstrap-reseed: ✗ FAIL — $1" >&2; exit 1; }

[ -f "$SEED" ] || fail "seed not found: bootstrap/seed/inglec_boot.c"
[ -f "$RT" ]   || fail "runtime not built: $RT — run 'make' (or 'make bootstrap') first"

# strip the trailing `=> 0` a compiled driver prints (its own main() return) so the emitted C matches
# the reference `--emit=c` form.
emit() { (cd "$ROOT" && "$1" "$2" 2>/dev/null) | sed '/^=> 0$/d'; }

echo "bootstrap-reseed: [1/4] cc(seed + runtime) -> N1  (no src/ frontend)…"
$CC $CCFLAGS "$SEED" "$RT" -lm -o "$WORK/n1" || fail "could not compile the seed into N1"

echo "bootstrap-reseed: [2/4] N1 compiles the current selfhost source -> N2…"
emit "$WORK/n1" "$DRIVER" > "$WORK/c2.c"
[ -s "$WORK/c2.c" ] || fail "N1 produced no output — the seed is too old to compile the current source"
$CC $CCFLAGS "$WORK/c2.c" "$RT" -lm -o "$WORK/n2" || fail "could not compile N1's output into N2"

echo "bootstrap-reseed: [3/4] N2 emits the byte-current seed…"
emit "$WORK/n2" "$DRIVER" > "$WORK/c3.c"
[ -s "$WORK/c3.c" ] || fail "N2 produced no output"

echo "bootstrap-reseed: [4/4] verify the new seed is a one-step fixed point…"
$CC $CCFLAGS "$WORK/c3.c" "$RT" -lm -o "$WORK/n1prime" || fail "could not compile the new seed"
emit "$WORK/n1prime" "$DRIVER" > "$WORK/c4.c"
diff -q "$WORK/c3.c" "$WORK/c4.c" >/dev/null || fail "the reseeded compiler does not self-reproduce (c3 != c4)"

if diff -q "$SEED" "$WORK/c3.c" >/dev/null 2>&1; then
    echo "bootstrap-reseed: seed already byte-current — no change."
else
    cp "$WORK/c3.c" "$SEED"
    echo "bootstrap-reseed: ✓ seed refreshed frontend-free ($(wc -l < "$SEED" | tr -d ' ') lines). Run 'make bootstrap' to re-verify."
fi
