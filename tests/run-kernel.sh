#!/bin/sh
# tests/run-kernel.sh — QEMU smoke test for the bare-metal kernel target (kernel milestone 1 /
# OFI-167; see docs/design/kernel-freestanding.md). Boots kernel/kernel.elf on QEMU `aarch64 virt`
# and asserts (1) the UART output, (2) the semihosting exit code — which the freestanding entry
# surfaces from Ember main's int RESULT (hello.em returns its loop counter, 3), so the exit code is
# a value COMPUTED BY EMBER on bare metal. Also regression-checks the `--freestanding` emit-time
# guards (spawn and hosted-registry externs are rejected with clear messages, not link errors).
# Kept OUT of the dependency-free default suite (tests/run.sh) — it needs the LLVM cross toolchain +
# qemu, like tests/run-graphics.sh / tests/run-db.sh. Invoked by `make test-kernel`, which builds
# the image first.
set -u

ELF="kernel/kernel.elf"
QEMU="${QEMU_AARCH64:-qemu-system-aarch64}"
EMBERC="${EMBERC:-build/emberc}"
EXPECT="Hello from Ember!"
EXPECT_EXIT=3    # hello.em's main returns its loop counter

fail=0

# --- emit-time guard regressions (no qemu needed) -------------------------------------------------
TMPDIR="${TMPDIR:-/tmp}"
GUARD="$TMPDIR/ember_kernel_guard_$$.em"

cat > "$GUARD" <<'EOF'
fn work(n: int) -> int { return n * 2 }
fn main() -> int {
    nursery {
        spawn work(21)
    }
    return 0
}
EOF
if "$EMBERC" --emit=c --freestanding "$GUARD" >/dev/null 2>&1; then
    echo "FAIL: spawn/nursery accepted under --freestanding (should be an emit-time error)"
    fail=1
else
    echo "PASS: spawn/nursery rejected under --freestanding"
fi

cat > "$GUARD" <<'EOF'
extern "c" { fn sin(x: f64) -> f64 }
fn main() -> int {
    let r = sin(1.0)
    return 0
}
EOF
if "$EMBERC" --emit=c --freestanding "$GUARD" >/dev/null 2>&1; then
    echo "FAIL: hosted-registry extern accepted under --freestanding (should be an emit-time error)"
    fail=1
else
    echo "PASS: hosted-registry extern rejected under --freestanding"
fi
rm -f "$GUARD"

# --- the boot ---------------------------------------------------------------------------------------
if ! command -v "$QEMU" >/dev/null 2>&1; then
    echo "run-kernel: $QEMU not found (brew install qemu) — skipping the boot" >&2
    exit "$fail"
fi
if [ ! -f "$ELF" ]; then
    echo "run-kernel: $ELF missing (run: make kernel)" >&2
    exit 1
fi

# A timeout guards against a hang if the semihosting exit ever regresses (the guest otherwise spins
# in a wfe loop). Prefer coreutils `timeout`, fall back to `gtimeout`, else run bare.
TIMEOUT=""
if command -v timeout >/dev/null 2>&1; then
    TIMEOUT="timeout 15"
elif command -v gtimeout >/dev/null 2>&1; then
    TIMEOUT="gtimeout 15"
fi

OUT=$($TIMEOUT "$QEMU" -M virt -cpu cortex-a53 -nographic -semihosting -kernel "$ELF" 2>/dev/null)
RC=$?

printf '%s\n' "$OUT"
echo "--- (qemu exit: $RC) ---"

if printf '%s' "$OUT" | grep -q "$EXPECT"; then
    echo "PASS: UART printed the message"
else
    echo "FAIL: expected '$EXPECT' in the UART output"
    fail=1
fi
if printf '%s' "$OUT" | grep -q '\.\.\.'; then
    echo "PASS: counted-loop output present (integer runtime path ran on bare metal)"
else
    echo "FAIL: expected '...' from the counted loop"
    fail=1
fi
if [ "$RC" -eq "$EXPECT_EXIT" ]; then
    echo "PASS: exit code $EXPECT_EXIT — Ember main's computed result reached the host"
else
    echo "FAIL: expected exit $EXPECT_EXIT (Ember main's loop counter), got $RC"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "kernel smoke test FAILED"
    exit 1
fi
echo "kernel smoke test OK"
