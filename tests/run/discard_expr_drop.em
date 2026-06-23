// OFI-096: a bare expression-STATEMENT that yields a fresh OWNING temp (a string / array / struct the
// checker flags via release_temp) must DROP it on the native backend, mirroring the VM's OP_RELEASE — the
// native used to emit only `(void)(E)` and leak it, a silent VM≠native divergence. This runs on BOTH
// backends; the native differential stage confirms VM==native output AND that the added drop is not a
// double-free (it would crash). The let-discard path (STMT_LET) already dropped correctly and is the control.
fn mk(s: string) -> string {
    return s + "!"
}

fn triple() -> [int] {
    return [1, 2, 3]
}

fn main() -> int {
    mk("a")            // discarded fresh string  → STMT_EXPR drop (the fix)
    triple()           // discarded fresh array   → STMT_EXPR drop (the fix)
    let _ = mk("b")    // discarded via let _      → STMT_LET drop (control, always worked)
    println("ok")
    return 0
}
