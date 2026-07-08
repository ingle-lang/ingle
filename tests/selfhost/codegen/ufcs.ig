// M4 fixture: UFCS (`recv.f(args)` → `f(recv, args)`) — Phase 3. A non-struct value receiver whose
// method name resolves to a free function is a UFCS call; the selfhost codegen prepends the receiver as
// arg 0 and routes through the SAME free-call machinery as a bare `f(recv, args)`, byte-identical to
// stage-0 (which rewrites the AST in the checker). A non-generic enum keeps this off the pre-existing
// generic-Option-match cgen_c gap.
enum Opt { Sm(v: int)  Nn }


fn or_else(o: Opt, d: int) -> int {
    match o {
        case Sm(v) { return v }
        case Nn    { return d }
    }
}


fn main() {
    let a = Sm(5)
    let b = Nn
    println("{a.or_else(0)} {b.or_else(9)}")
}
