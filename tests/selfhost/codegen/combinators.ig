// Phase 3 (OFI-187): the Option/Result combinators via UFCS, byte-identical on both backends.
// is_some/is_none/unwrap_or/is_ok/is_err/ok_or take no function; map/and_then take a first-class
// function (here a named fn — the self-hosted C-emit closure support, OFI-206). All run identically
// on the VM and native.

fn dbl(x: int) -> int { return x * 2 }
fn half_even(x: int) -> Option<int> {
    if x % 2 == 0 { return Some(x / 2) }
    return None
}

fn main() {
    let a: Option<int> = Some(6)
    let b: Option<int> = None
    let r: Result<int, int> = Ok(7)
    let e: Result<int, int> = Err(9)
    println(a.unwrap_or(0))
    println(b.unwrap_or(99))
    if a.is_some() { println(1) } else { println(0) }
    if b.is_none() { println(1) } else { println(0) }
    if r.is_ok() { println(1) } else { println(0) }
    if e.is_err() { println(1) } else { println(0) }
    match a.ok_or(0)  { case Ok(v) { println(v) }   case Err(x) { println(0-1) } }
    match b.ok_or(8)  { case Ok(v) { println(v) }   case Err(x) { println(x) } }
    match a.map(dbl)  { case Some(v) { println(v) } case None { println(0-1) } }
    match a.and_then(half_even) { case Some(v) { println(v) } case None { println(0-1) } }
}
