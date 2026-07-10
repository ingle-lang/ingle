// Phase 3 (OFI-187): Option/Result combinators via UFCS, byte-identical on both backends.
// The five leaf combinators + ok_or (Option -> Result). map/and_then (which take a function
// parameter) require closures in the self-hosted C-emit — tracked separately.

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
    match a.ok_or(0) { case Ok(v) { println(v) } case Err(x) { println(0-1) } }
    match b.ok_or(8) { case Ok(v) { println(v) } case Err(x) { println(x) } }
}
