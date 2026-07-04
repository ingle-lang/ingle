// tests/run/match_early_exit.ig — regression for OFI-118: a `match` whose scrutinee is a fresh OWNING
// temporary (e.g. the Option returned by a call) must release that scrutinee on EVERY exit from a case
// body, not only the fall-through. Before the fix, an early `return` / `break` / `continue` from inside a
// case jumped past the explicit subject drop, leaking the scrutinee enum once per match — which, in a UI's
// per-frame `match m.get(k) { case Some(v) { return v } … }` state reads, bled memory all session. This
// drives all three early-exit shapes; correctness here means the drop discipline still produces the right
// values (the leak itself is caught by ASan / Crucible / the codegen goldens, not stdout).
fn some(x: int) -> Option<int> {
    return Some(x)
}

fn none_below(x: int) -> Option<int> {
    if x < 0 {
        return None
    }
    return Some(x * 10)
}

// early_return: the OFI-118 shape — return straight out of the Some case (scrutinee is a call temp).
fn early_return(x: int) -> int {
    match some(x) {
        case Some(v) { return v + 1 }
        case None {}
    }
    return -1
}

// scan: break and continue out of a case body, the scrutinee a fresh temp each iteration.
fn scan(limit: int) -> int {
    var total = 0
    var i = 0
    loop {
        if i == limit { break }
        match none_below(i) {
            case Some(v) {
                if v == 30 {
                    total = total + 100
                    i = i + 1
                    continue            // continue out of a case body
                }
                if v == 70 {
                    break               // break out of a case body
                }
                total = total + v
            }
            case None {}
        }
        i = i + 1
    }
    return total
}

fn main() -> int {
    println("early={early_return(41)}")          // 42
    println("none={early_return(0)}")            // Some(0) -> 0 + 1 = 1
    println("scan={scan(10)}")                   // 0,10,20,(30->+100,skip),40,50,60,(70->break) = 180+100 = 280
    return 0
}
