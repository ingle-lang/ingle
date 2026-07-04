#!/usr/bin/env bash
# tools/cgdiff.sh — the self-hosted bytecode-backend DIFFERENTIAL HARNESS.
#
# Compares the self-hosted codegen (selfhost/codegen.ig, driven by codegen_dump.ig) against the stage-0
# oracle `inglec --emit=bytecode`, on BOTH execution paths:
#   • VM     — `inglec --emit=run selfhost/codegen_dump.ig <file>`
#   • NATIVE — the self-hosted codegen compiled to a binary (`inglec -o … codegen_dump.ig`)
# Byte-identical disassembly (incl. the source-line column) is the bar, exactly as `make selfhost` Stage 4
# gates — but this is the fast DEV loop: point it at a probe and it shows the first divergence (function +
# offset + the differing instructions), so an unbuilt/miscompiled construct is found in one shot.
#
# Usage:
#   tools/cgdiff.sh <file.ig> [more.ig …]   # diff specific files; shows the first divergent hunk per file
#   tools/cgdiff.sh -d <dir>                # every *.ig under <dir>
#   tools/cgdiff.sh -c                      # corpus sweep (examples tests std selfhost) + cause histogram
#   tools/cgdiff.sh -q  …                   # quiet: one status line per file, no diff bodies
#   tools/cgdiff.sh -v  …                   # verbose: full diff per failing file (not just the first hunk)
#
# Stage-0-rejected or empty-output files are SKIPped (codegen only runs on programs the checker accepts).
# Exit 0 iff every compared file is byte-identical on both VM and native; 1 if any diverge; 2 on a harness
# error. EMBERC=… overrides the stage-0 binary. Written for bash 3.2 (macOS default) — no associative
# arrays / mapfile.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

EMBERC="${EMBERC:-./build/inglec}"
DRIVER="selfhost/codegen_dump.ig"
CACHE="${TMPDIR:-/tmp}/cgdiff_native_$$"
LIST="${TMPDIR:-/tmp}/cgdiff_list_$$"
CAUSE="${TMPDIR:-/tmp}/cgdiff_cause_$$"
HUNK_LINES="${CGDIFF_HUNK:-14}"
mode="files"; verbosity="normal"
: > "$LIST"; : > "$CAUSE"
trap 'rm -f "$CACHE" "$LIST" "$CAUSE"' EXIT

# -------- arg parse --------
while [ $# -gt 0 ]; do
    case "$1" in
        -d) mode="dir"; shift; find "${1:?-d needs a directory}" -name '*.ig' 2>/dev/null | sort >> "$LIST"; shift ;;
        -c) mode="corpus"; find examples tests std selfhost -name '*.ig' 2>/dev/null | sort >> "$LIST"; shift ;;
        -q) verbosity="quiet"; shift ;;
        -v) verbosity="verbose"; shift ;;
        -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) echo "cgdiff: unknown flag $1" >&2; exit 2 ;;
        *) echo "$1" >> "$LIST"; shift ;;
    esac
done

[ -x "$EMBERC" ] || { echo "cgdiff: stage-0 compiler not found at $EMBERC (run 'make' first)" >&2; exit 2; }
[ -s "$LIST" ] || { echo "cgdiff: no files given (try -h)" >&2; exit 2; }

# -------- build the native self-hosted codegen once --------
if ! "$EMBERC" -o "$CACHE" "$DRIVER" 2>/tmp/cgdiff_build.$$.err; then
    echo "cgdiff: FATAL — the self-hosted codegen failed to compile (native):" >&2
    grep -i 'error' /tmp/cgdiff_build.$$.err | head >&2
    rm -f /tmp/cgdiff_build.$$.err
    exit 2
fi
rm -f /tmp/cgdiff_build.$$.err

# the nearest `== fn NAME …` header at or above a 1-based line number in the oracle text
fn_at() { awk -v n="$2" 'NR<=n && /^== fn /{h=$0} END{print h}' <<<"$1"; }

pass=0; fail=0; skip=0
while IFS= read -r f; do
    [ -n "$f" ] || continue
    oracle=$("$EMBERC" --emit=bytecode "$f" 2>/dev/null)
    if [ $? -ne 0 ] || [ -z "$oracle" ]; then skip=$((skip+1)); continue; fi
    vm=$("$EMBERC" --emit=run "$DRIVER" "$f" 2>/dev/null | grep -v '^=> ')
    nat=$("$CACHE" "$f" 2>/dev/null | grep -v '^=> ')

    vm_ok=0; nat_ok=0
    [ "$vm" = "$oracle" ] && vm_ok=1
    [ "$nat" = "$oracle" ] && nat_ok=1

    if [ $vm_ok -eq 1 ] && [ $nat_ok -eq 1 ]; then
        pass=$((pass+1))
        [ "$verbosity" = "quiet" ] && printf 'PASS  %s\n' "$f"
        continue
    fi

    fail=$((fail+1))
    if [ $vm_ok -ne $nat_ok ]; then
        tag="DIFF  (VM=$([ $vm_ok = 1 ] && echo ok || echo DIFF) NATIVE=$([ $nat_ok = 1 ] && echo ok || echo DIFF))"
    else tag="DIFF"; fi
    mine="$nat"; [ $nat_ok -eq 1 ] && mine="$vm"

    d=$(diff <(printf '%s' "$mine") <(printf '%s' "$oracle"))
    oline=$(grep -oE '^[0-9]+a[0-9]+|^[0-9]+,?[0-9]*c[0-9]+' <<<"$d" | head -1 | grep -oE '[0-9]+$')
    op=$(grep -E '^>' <<<"$d" | grep -oE '[A-Z_]{3,}' | head -1)
    echo "${op:-?}" >> "$CAUSE"

    if [ "$mode" != "corpus" ] && [ "$verbosity" != "quiet" ]; then
        printf '\n\033[1m%s\033[0m  %s\n' "$tag" "$f"
        [ -n "${oline:-}" ] && printf '   in %s\n' "$(fn_at "$oracle" "$oline")"
        if [ "$verbosity" = "verbose" ]; then
            printf '%s\n' "$d" | sed 's/^/   /'
        else
            printf '%s\n' "$d" | head -n "$HUNK_LINES" | sed 's/^/   /'
            printf '   (< self-hosted   > stage-0 ; first %d lines, -v for full)\n' "$HUNK_LINES"
        fi
    else
        printf '%s  %s\n' "$tag" "$f"
    fi
done < "$LIST"

echo
printf 'cgdiff: PASS=%d DIFF=%d SKIP=%d  (of %d listed)\n' "$pass" "$fail" "$skip" "$(grep -c . "$LIST")"
if [ "$mode" = "corpus" ] && [ $fail -gt 0 ]; then
    echo "first-divergence cause histogram (stage-0 opcode at the first differing line):"
    sort "$CAUSE" | uniq -c | sort -rn | head -25
fi
[ $fail -eq 0 ] && exit 0 || exit 1
