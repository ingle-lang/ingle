// OFI-099: the linear `Ptr` must-consume obligation is minted through a USER function whose declared
// return type is `Ptr` — not only by a DIRECT extern-call result. A one-line wrapper `fn opener() -> Ptr`
// whose result is left unclosed must STILL be flagged 'opened but not closed', or a handle leaks through it.
// (Found already-fixed when OFI-099 was verified on 2026-06-23; this regression locks the property so it
// can't silently re-open — symmetric to the direct-call leak test error_ptr_discarded.ig.)
extern "c" {
    fn fopen(path: string, mode: string) -> Ptr
    fn fclose(move f: Ptr) -> i64
}

fn opener() -> Ptr {
    return fopen("/tmp/ember_ofi099", "w")
}

fn main() -> int {
    let p = opener()      // a fresh handle obligation through the wrapper — never closed → leak
    return 0
}
