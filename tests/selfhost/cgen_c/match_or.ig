// M5 fixture for the self-hosted C-emit backend: non-binding OR-PATTERNS (`case a | b | c`) — Phase 2c.
// An arm matches if ANY alternative does; alternatives are nullary variants or literals (non-binding).
// The C-emit is a `||` disjunction of the per-alternative tests (variant-tag `==` or `em_eq_op` literal
// compare), threaded through the existing if/else-if chain (unguarded) or the `matched`-flag blocks
// (guarded), byte-identical to stage-0 `inglec --emit=c` (gated, Stage 6 of make selfhost). Enum values
// are constructed BARE (`Red`, not `Color.Red`) — qualified nullary construction is a separate cgen_c gap.
enum Color { Red  Green  Blue  White  Black }


fn tier(c: Color) -> int {
    match c {
        case Red | Green | Blue {
            return 1
        }
        case White | Black {
            return 2
        }
    }
}


fn kind(n: int) -> int {
    match n {
        case 1 | 2 | 3 {
            return 10
        }
        case 20 | 30 {
            return 20
        }
        case _ {
            return 0
        }
    }
}


fn guarded(n: int) -> int {
    match n {
        case 1 | 2 | 3 if n > 2 {
            return 99
        }
        case 1 | 2 | 3 {
            return 5
        }
        case _ {
            return 0
        }
    }
}


fn main() {
    println("{tier(Red)}")
    println("{tier(Black)}")
    println("{kind(2)}")
    println("{kind(30)}")
    println("{kind(7)}")
    println("{guarded(3)}")
    println("{guarded(1)}")
}
