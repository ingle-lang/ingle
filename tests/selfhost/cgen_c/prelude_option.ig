// Phase 3 (OFI-203/204): the self-hosted C-emit constructs AND matches the prelude Option/Result
// byte-identically to stage-0 — the foundation the Option/Result combinators build on.

fn describe(o: Option<int>) -> int {
    match o {
        case Some(v) { return v }
        case None    { return 0 }
    }
}

fn tag(r: Result<int, int>) -> int {
    match r {
        case Ok(v)  { return v }
        case Err(e) { return 0 - e }
    }
}

fn main() {
    let a: Option<int> = Some(5)
    let b: Option<int> = None
    let x: Result<int, int> = Ok(7)
    let y: Result<int, int> = Err(9)
    println(describe(a))
    println(describe(b))
    println(tag(x))
    println(tag(y))
}
