// UFCS (uniform function call syntax) — Phase 3. A free function whose first parameter matches the
// receiver may be called method-style: `opt.unwrap_or(0)` desugars to `unwrap_or(opt, 0)`. Works on
// any NON-STRUCT receiver (enums, scalars, strings); a struct keeps methods-only (a method wins). The
// checker rewrites the call to a plain free call, so generic inference, closures, and chaining all work.
fn unwrap_or(o: Option<int>, d: int) -> int {
    match o {
        case Some(v) { return v }
        case None    { return d }
    }
}


fn is_some(o: Option<int>) -> bool {
    match o {
        case Some(v) { return true }
        case None    { return false }
    }
}


fn map_opt(o: Option<int>, f: fn(int) -> int) -> Option<int> {
    match o {
        case Some(v) { return Some(f(v)) }
        case None    { return None }
    }
}


fn main() {
    let a: Option<int> = Some(5)
    let b: Option<int> = None
    println("{a.unwrap_or(0)} {b.unwrap_or(9)}")
    println("{a.is_some()} {b.is_some()}")
    println("{a.map_opt(|x| x * 10).unwrap_or(0)}")
}
