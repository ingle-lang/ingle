// Non-binding or-patterns (`case a | b | c`) — Phase 2c. An arm matches if ANY
// alternative does. Alternatives are nullary variants or literals (non-binding);
// or-patterns combine with guards and contribute to exhaustiveness per alternative.
enum Color { Red  Green  Blue  White  Black }


fn tier(c: Color) -> string {
    match c {
        case Red | Green | Blue {
            return "primary"
        }
        case White | Black {
            return "mono"
        }
    }
}


fn kind(n: int) -> string {
    match n {
        case 1 | 2 | 3 {
            return "small"
        }
        case 10 | 20 | 30 {
            return "round"
        }
        case _ {
            return "other"
        }
    }
}


fn guarded(n: int) -> string {
    match n {
        case 1 | 2 | 3 if n > 2 {
            return "big-small"
        }
        case 1 | 2 | 3 {
            return "small"
        }
        case _ {
            return "other"
        }
    }
}


fn yesno(b: bool) -> string {
    match b {
        case true | false {
            return "known"
        }
    }
}


fn main() {
    println(tier(Color.Red))
    println(tier(Color.Green))
    println(tier(Color.Blue))
    println(tier(Color.White))
    println(tier(Color.Black))
    println(kind(2))
    println(kind(20))
    println(kind(7))
    println(guarded(3))
    println(guarded(1))
    println(guarded(99))
    println(yesno(true))
    println(yesno(false))
}
