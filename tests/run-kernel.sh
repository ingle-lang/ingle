#!/bin/sh
# tests/run-kernel.sh — QEMU smoke test for the bare-metal kernel target (kernel milestones 1-2;
# OFI-167; see docs/design/kernel-freestanding.md). Boots kernel/kernel.elf on QEMU `aarch64 virt`
# and asserts (1) the UART output — including a string built + INTERPOLATED by the runtime, proving
# the freestanding heap (arrays/strings) works — and (2) the semihosting exit code, which the
# freestanding entry surfaces from Ember main's int RESULT (hello.em sums an array to 42), so it is a
# value COMPUTED BY EMBER, with aggregates, on bare metal. Also regression-checks the `--freestanding`
# emit-time guards (spawn and hosted-registry externs are rejected with clear messages, not link
# errors). Kept OUT of the dependency-free default suite (tests/run.sh) — it needs the LLVM cross
# toolchain + qemu, like tests/run-graphics.sh / tests/run-db.sh. Invoked by `make test-kernel`.
set -u

ELF="kernel/kernel.elf"
QEMU="${QEMU_AARCH64:-qemu-system-aarch64}"
EMBERC="${EMBERC:-build/emberc}"
EXPECT="Hello from Ember"
EXPECT_INTERP="= 42"   # the interpolated array sum — proves heap strings + interpolation + arrays
EXPECT_EXIT=42         # hello.em sums [10,20,12] and returns it

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

# Force GICv2 (kernel M4 targets the GICv2 MMIO CPU interface); the machine flags are shared by every
# boot below.
QMACH="-machine virt,gic-version=2 -cpu cortex-a53 -nographic -semihosting"

OUT=$($TIMEOUT "$QEMU" $QMACH -kernel "$ELF" 2>/dev/null)
RC=$?

printf '%s\n' "$OUT"
echo "--- (qemu exit: $RC) ---"

if printf '%s' "$OUT" | grep -q "$EXPECT"; then
    echo "PASS: UART printed the message (println + runtime print path on bare metal)"
else
    echo "FAIL: expected '$EXPECT' in the UART output"
    fail=1
fi
if printf '%s' "$OUT" | grep -q "$EXPECT_INTERP"; then
    echo "PASS: interpolated array sum present (freestanding heap: arrays + strings + interpolation)"
else
    echo "FAIL: expected '$EXPECT_INTERP' (the interpolated sum) in the UART output"
    fail=1
fi
if [ "$RC" -eq "$EXPECT_EXIT" ]; then
    echo "PASS: exit code $EXPECT_EXIT — Ember main's computed result reached the host"
else
    echo "FAIL: expected exit $EXPECT_EXIT (Ember main's loop counter), got $RC"
    fail=1
fi

# --- fault-vector regression (kernel milestone 3) ---------------------------------------------------
# faultdemo.elf deliberately executes a BRK; the exception vector table must catch it and print a
# kernel panic (rather than hang silently, as a fault did before the vectors existed).
FAULT_ELF="kernel/faultdemo.elf"
if [ -f "$FAULT_ELF" ]; then
    FOUT=$($TIMEOUT "$QEMU" $QMACH -kernel "$FAULT_ELF" 2>/dev/null)
    printf '%s\n' "$FOUT"
    echo "--- (fault demo) ---"
    if printf '%s' "$FOUT" | grep -q "EMBER KERNEL PANIC"; then
        echo "PASS: CPU exception caught by the vector table and reported (not a silent hang)"
    else
        echo "FAIL: expected a kernel panic banner from the fault demo"
        fail=1
    fi
    # EC=0x3c is a BRK (AArch64) — confirm the syndrome was decoded, not just a generic message.
    if printf '%s' "$FOUT" | grep -q "EC=0x3c"; then
        echo "PASS: exception syndrome decoded (EC=0x3c, a BRK)"
    else
        echo "FAIL: expected EC=0x3c (BRK) in the panic report"
        fail=1
    fi
fi

# --- timer/interrupt demo (kernel milestone 4) ------------------------------------------------------
# timerdemo.elf brings up the GIC + generic timer and polls a tick counter that only advances from the
# IRQ handler; it must print climbing ticks and exit 5 (the tick count) — proving async interrupts.
TIMER_ELF="kernel/timerdemo.elf"
if [ -f "$TIMER_ELF" ]; then
    TOUT=$($TIMEOUT "$QEMU" $QMACH -kernel "$TIMER_ELF" 2>/dev/null)
    TRC=$?
    printf '%s\n' "$TOUT"
    echo "--- (timer demo, qemu exit: $TRC) ---"
    if printf '%s' "$TOUT" | grep -q "tick 5"; then
        echo "PASS: timer IRQ delivered 5 ticks (asynchronous interrupts work on bare metal)"
    else
        echo "FAIL: expected 'tick 5' from the timer demo (no interrupts delivered?)"
        fail=1
    fi
    if [ "$TRC" -eq 5 ]; then
        echo "PASS: timer demo exit 5 — the IRQ-driven tick count reached the host"
    else
        echo "FAIL: expected timer demo exit 5, got $TRC"
        fail=1
    fi
fi

if [ "$fail" -ne 0 ]; then
    echo "kernel smoke test FAILED"
    exit 1
fi
echo "kernel smoke test OK"
