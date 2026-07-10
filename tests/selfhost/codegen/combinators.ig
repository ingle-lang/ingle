// Phase 3 (OFI-187, OFI-205): the Option/Result combinators, called method-style via UFCS. Both backends
// compile them byte-identically — the self-hosted drivers inject the used combinators (usage-gated), and
// generic-payload/param values are own_into_slot/INCREF'd like stage-0 (erased-generic ownership).

fn main() {
    let a: Option<int> = Some(5)
    let b: Option<int> = None
    let r: Result<int, int> = Ok(7)
    let e: Result<int, int> = Err(9)
    println(a.unwrap_or(0))
    println(b.unwrap_or(99))
    if a.is_some() { println(1) } else { println(0) }
    if b.is_none() { println(1) } else { println(0) }
    if r.is_ok() { println(1) } else { println(0) }
    if e.is_err() { println(1) } else { println(0) }
}
