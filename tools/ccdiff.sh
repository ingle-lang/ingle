#!/usr/bin/env bash
# tools/ccdiff.sh — the M5 self-hosted C-EMIT backend DIFFERENTIAL HARNESS (the native counterpart of
# tools/cgdiff.sh). Compares the self-hosted C-emitter (selfhost/cgen_c.ig, driven by cgen_c_dump.ig)
# against the stage-0 oracle `inglec --emit=c`, on BOTH execution paths:
#   • VM     — `inglec --emit=run selfhost/cgen_c_dump.ig <file>`
#   • NATIVE — the self-hosted C-emitter compiled to a binary (`inglec -o … cgen_c_dump.ig`)
# Byte-identical C output is the bar — exactly the proven differential methodology of every other stage,
# now for the native backend that turns the bootstrap into a self-built native compiler.
#
# Usage:  tools/ccdiff.sh <file.ig> [more.ig …]   # diff specific files; first divergent hunk per file
#         tools/ccdiff.sh -d <dir>                # every *.ig under <dir>
#         tools/ccdiff.sh -v <file>               # full diff
#
# Stage-0-rejected / empty-output files are SKIPped. Exit 0 iff every compared file is byte-identical on
# both VM and native. EMBERC=… overrides the stage-0 binary.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

EMBERC="${EMBERC:-./build/inglec}"
DRIVER="selfhost/cgen_c_dump.ig"
CACHE="${TMPDIR:-/tmp}/ccdiff_native_$$"
LIST="${TMPDIR:-/tmp}/ccdiff_list_$$"
HUNK_LINES="${CCDIFF_HUNK:-16}"
verbosity="normal"
: > "$LIST"
trap 'rm -f "$CACHE" "$LIST"' EXIT

while [ $# -gt 0 ]; do
    case "$1" in
        -d) shift; find "${1:?-d needs a directory}" -name '*.ig' 2>/dev/null | sort >> "$LIST"; shift ;;
        -v) verbosity="verbose"; shift ;;
        -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) echo "ccdiff: unknown flag $1" >&2; exit 2 ;;
        *) echo "$1" >> "$LIST"; shift ;;
    esac
done

[ -x "$EMBERC" ] || { echo "ccdiff: stage-0 compiler not found at $EMBERC (run 'make' first)" >&2; exit 2; }
[ -s "$LIST" ] || { echo "ccdiff: no files given (try -h)" >&2; exit 2; }

if ! "$EMBERC" -o "$CACHE" "$DRIVER" 2>/tmp/ccdiff_build.$$.err; then
    echo "ccdiff: FATAL — the self-hosted C-emitter failed to compile (native):" >&2
    grep -i 'error' /tmp/ccdiff_build.$$.err | head >&2
    rm -f /tmp/ccdiff_build.$$.err
    exit 2
fi
rm -f /tmp/ccdiff_build.$$.err

pass=0; fail=0; skip=0
while IFS= read -r f; do
    [ -n "$f" ] || continue
    oracle=$("$EMBERC" --emit=c "$f" 2>/dev/null)
    if [ $? -ne 0 ] || [ -z "$oracle" ]; then skip=$((skip+1)); continue; fi
    vm=$("$EMBERC" --emit=run "$DRIVER" "$f" 2>/dev/null | grep -v '^=> ')
    nat=$("$CACHE" "$f" 2>/dev/null | grep -v '^=> ')

    vm_ok=0; nat_ok=0
    [ "$vm" = "$oracle" ] && vm_ok=1
    [ "$nat" = "$oracle" ] && nat_ok=1
    if [ $vm_ok -eq 1 ] && [ $nat_ok -eq 1 ]; then
        pass=$((pass+1)); continue
    fi

    fail=$((fail+1))
    if [ $vm_ok -ne $nat_ok ]; then
        tag="DIFF  (VM=$([ $vm_ok = 1 ] && echo ok || echo DIFF) NATIVE=$([ $nat_ok = 1 ] && echo ok || echo DIFF))"
    else tag="DIFF"; fi
    mine="$nat"; [ $nat_ok -eq 1 ] && mine="$vm"
    d=$(diff <(printf '%s' "$mine") <(printf '%s' "$oracle"))
    printf '\n\033[1m%s\033[0m  %s\n' "$tag" "$f"
    if [ "$verbosity" = "verbose" ]; then
        printf '%s\n' "$d" | sed 's/^/   /'
    else
        printf '%s\n' "$d" | head -n "$HUNK_LINES" | sed 's/^/   /'
        printf '   (< self-hosted   > stage-0 ; first %d lines, -v for full)\n' "$HUNK_LINES"
    fi
done < "$LIST"

echo
printf 'ccdiff: PASS=%d DIFF=%d SKIP=%d  (of %d listed)\n' "$pass" "$fail" "$skip" "$(grep -c . "$LIST")"
[ $fail -eq 0 ] && exit 0 || exit 1
