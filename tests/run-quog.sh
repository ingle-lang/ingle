#!/bin/sh
# run-quog.sh — Quog integration test. Dogfoods the whole CLI end to end in a scratch repo with a
# FIXED clock (QUOG_NOW) so commit ids are reproducible, then compares the full transcript to a
# golden. Needs the db build (std/sqlite is VM-only, OFI-143):  make db  then  tests/run-quog.sh
# Bless a reviewed transcript with:  tests/run-quog.sh --update
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BIN="$ROOT/build/inglec-db"
QUOG="$ROOT/public/quog/quog.ig"
GOLDEN="$ROOT/tests/quog/session.out"

UPDATE=0
[ "${1:-}" = "--update" ] && UPDATE=1

if [ ! -x "$BIN" ]; then
    echo "error: $BIN not found — run 'make db' first" >&2
    exit 2
fi

WORK=$(mktemp -d)
TRANSCRIPT=$(mktemp)                        # OUTSIDE the repo, so quog never versions its own output
export QUOG_NOW=1000000000                 # a fixed epoch → deterministic commit ids
q() { ( cd "$WORK" && "$BIN" --emit=run "$QUOG" "$@" ); }

{
    printf 'alpha\nbeta\ngamma\n' > "$WORK/README.md"
    mkdir -p "$WORK/src"
    printf 'fn main() {}\n' > "$WORK/src/main.ig"

    echo '$ quog init';                  q init
    echo '$ quog save "initial import"'; q save "initial import"
    echo '$ quog status';                q status

    printf 'alpha\nBETA\ngamma\ndelta\n' > "$WORK/README.md"   # modify
    printf 'notes\n' > "$WORK/TODO.md"                          # add

    echo '$ quog status';                q status
    echo '$ quog diff';                  q diff
    echo '$ quog save "edit readme, add todo"'; q save "edit readme, add todo"
    echo '$ quog log';                   q log
    echo '$ quog undo';                  q undo
    echo '$ quog log';                   q log
} > "$TRANSCRIPT" 2>&1

rc=0
if [ "$UPDATE" = "1" ]; then
    mkdir -p "$(dirname "$GOLDEN")"
    cp "$TRANSCRIPT" "$GOLDEN"
    echo "quog: golden updated ($GOLDEN)"
elif diff -u "$GOLDEN" "$TRANSCRIPT"; then
    echo "quog: PASS — integration transcript matches golden"
else
    echo "quog: FAIL — transcript differs from golden" >&2
    rc=1
fi

rm -rf "$WORK" "$TRANSCRIPT"
exit $rc
