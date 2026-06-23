// OFI-096 native differential: a bare expression-STATEMENT that discards a fresh OWNING temp must DROP it
// (mirroring the VM's OP_RELEASE) — the native backend used to emit only `(void)(E)` and leak. Run on the VM
// and as a compiled binary; identical stdout confirms VM==native and that the added drop is not a double-free
// (it would crash the binary → mismatch). The leak itself is silent to stdout (native ASan/LSan not wired) —
// verified separately by inspecting the emitted C + an RSS probe. STMT_LET discard is the always-worked control.
fn mk(s: string) -> string {
    return s + "!"
}

fn triple() -> [int] {
    return [1, 2, 3]
}

fn main() -> int {
    mk("a")            // STMT_EXPR: discarded fresh string → drop (the fix)
    triple()           // STMT_EXPR: discarded fresh array  → drop (the fix)
    let _ = mk("b")    // STMT_LET: discarded via let _      → drop (control)
    println("ok")
    return 0
}
