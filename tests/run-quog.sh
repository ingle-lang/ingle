#!/bin/sh
# run-quog.sh — Quog integration test. Dogfoods the whole CLI end to end in a scratch repo with a
# FIXED clock (QUOG_NOW) so commit ids are reproducible, then compares the full transcript to a
# golden. Needs the db build:  make db  then  tests/run-quog.sh
# Bless a reviewed transcript with:  tests/run-quog.sh --update
#
# By default quog runs through the VM (build/inglec-db --emit=run quog.ig). If QUOG_NATIVE_BIN points
# at a prebuilt standalone binary (see `make test-quog-native`), the SAME golden is exercised against
# that native binary instead — the regression guard for OFI-143's native std/sqlite path. The native
# binary must behave identically to the VM (contracts are release-elided natively, but this transcript
# trips none).
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BIN="$ROOT/build/inglec-db"
QUOG="$ROOT/public/quog/quog.ig"
GOLDEN="$ROOT/tests/quog/session.out"

UPDATE=0
[ "${1:-}" = "--update" ] && UPDATE=1

WORK=$(mktemp -d)
TRANSCRIPT=$(mktemp)                        # OUTSIDE the repo, so quog never versions its own output
export QUOG_NOW=1000000000                 # a fixed epoch → deterministic commit ids
if [ -n "${QUOG_NATIVE_BIN:-}" ]; then
    if [ ! -x "$QUOG_NATIVE_BIN" ]; then
        echo "error: QUOG_NATIVE_BIN=$QUOG_NATIVE_BIN not found — run 'make quog' first" >&2
        exit 2
    fi
    q() { ( cd "$WORK" && "$QUOG_NATIVE_BIN" "$@" ); }
else
    if [ ! -x "$BIN" ]; then
        echo "error: $BIN not found — run 'make db' first" >&2
        exit 2
    fi
    q() { ( cd "$WORK" && "$BIN" --emit=run "$QUOG" "$@" ); }
fi

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

    echo '$ quog save "resync"';         q save "resync"
    echo '$ quog branch experiment';     q branch experiment
    echo '$ quog switch experiment';     q switch experiment
    printf 'experimental\n' > "$WORK/EXP.md"
    echo '$ quog save "experiment work"'; q save "experiment work"
    echo '$ quog switch main';           q switch main
    echo '$ quog status';                q status
    echo '$ quog switch experiment';     q switch experiment
    echo '$ quog log';                   q log
    echo '$ quog undo';                  q undo
    echo '$ quog branch';                q branch
    echo '$ quog merge experiment';      q merge experiment
    echo '$ quog log';                   q log
    printf 'a scratch edit\n' >> "$WORK/README.md"
    echo '$ quog discard';               q discard
    echo '$ quog restore';               q restore
    echo '$ quog verify';                q verify
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
