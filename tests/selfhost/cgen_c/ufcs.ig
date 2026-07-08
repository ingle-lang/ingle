// M5 fixture: UFCS (`recv.f(args)` → `f(recv, args)`) — Phase 3. The selfhost cgen_c emits the free
// call `em_fn_<i>(recv, args…)` with the receiver prepended, byte-identical to stage-0 `--emit=c`. A
// non-generic enum keeps this off the pre-existing generic-Option-match cgen_c gap (a separate OFI).
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
