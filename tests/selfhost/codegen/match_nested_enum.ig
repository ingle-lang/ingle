// M4 fixture: refutable enum-inner nested patterns (`case Wrap(Good(v))`) — Phase 2d-ii. The arm
// lowers to an AND-of-tests: the outer variant tag, then each enum-inner slot's tag, short-circuited
// with JUMP_IF_FALSE into one bool for a single `next` (byte-identical to the plain single-tag test
// when there is no enum-inner). Enum-inner carries no value struct, so unlike a struct-inner it IS
// byte-identical to stage-0 `inglec --emit=bytecode` (gated, Stage 4 of make selfhost). Unguarded —
// a guard is an OFI-200-class line-map delta, gated via the C-emit fixture instead.
enum Res { Good(v: int)  Bad(e: int) }
enum Opt { Wrap(r: Res)  Empty }


fn classify(o: Opt) -> int {
    match o {
        case Wrap(Good(v)) {
            return v
        }
        case Wrap(Bad(e)) {
            return 0 - e
        }
        case Empty {
            return 0
        }
    }
}


fn main() {
    println("{classify(Wrap(Good(5)))}")
    println("{classify(Wrap(Bad(3)))}")
    println("{classify(Empty)}")
}
