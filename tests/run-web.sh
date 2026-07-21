#!/bin/sh
# tests/run-web.sh — regression harness for the Flare -> HTML web backend (OFI-212 / W3).
#
# Flare's SSR path needs the web runtime (build/emberc-web: EMBER_GRAPHICS so it type-checks, plus
# EMBER_GFX_HEADLESS so graphics_headless.c replaces raylib — no window, no display, no dependency).
# This runner is invoked by `make test-web`. Each tests/web/*.ig is run with --emit=run and its stdout
# (minus the harness `=> N` return trailer) is compared to a sibling .out golden. SSR output is fully
# deterministic (no window, no mouse, estimate-based text metrics), so the match is EXACT.
#
# Usage:
#   tests/run-web.sh            run all web cases
#   tests/run-web.sh --update   regenerate the goldens from current output

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BIN="$ROOT/build/emberc-web"
export EMBER_STD="$ROOT/std"

UPDATE=0
if [ "${1:-}" = "--update" ]; then
    UPDATE=1
fi

if [ ! -x "$BIN" ]; then
    echo "skip: $BIN not built — run 'make web' first"
    exit 0
fi

pass=0
fail=0
updated=0

for src in "$ROOT"/tests/web/*.ig; do
    [ -e "$src" ] || continue
    golden="${src%.ig}.out"
    actual=$("$BIN" --emit=run "$src" 2>/dev/null | grep -vE '^=> ')

    if [ "$UPDATE" -eq 1 ]; then
        printf '%s\n' "$actual" > "$golden"
        updated=$((updated + 1))
        continue
    fi

    if [ ! -f "$golden" ]; then
        echo "FAIL $(basename "$src") — no golden (run with --update)"
        fail=$((fail + 1))
        continue
    fi

    if [ "$actual" = "$(cat "$golden")" ]; then
        pass=$((pass + 1))
    else
        echo "FAIL $(basename "$src")"
        fail=$((fail + 1))
    fi
done

if [ "$UPDATE" -eq 1 ]; then
    echo "updated $updated web golden(s)"
    exit 0
fi

echo "web: passed $pass, failed $fail"
[ "$fail" -eq 0 ]
