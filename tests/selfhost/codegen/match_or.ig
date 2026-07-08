// M4 fixture for the self-hosted bytecode backend: enum OR-PATTERNS (`case a | b | c`) — Phase 2c.
// The VM has no OP_OR / JUMP_IF_TRUE, so an or-pattern lowers to an OR-of-tests: each alternative's
// tag compare, JUMP_IF_FALSE to the next alternative, a matched alternative jumping forward to the
// shared body, and the last alternative's JUMP_IF_FALSE as the pattern-false path (threaded through
// gen_arm_tail). Enum alternatives carry no literal, so the bytecode is byte-identical to stage-0
// `inglec --emit=bytecode` (gated, Stage 4 of make selfhost) — unlike a scalar-literal or-pattern
// (OFI-200 line-map delta) or a GUARDED arm (also an OFI-200-class delta), both of which are gated
// via the byte-identical C-emit fixture (tests/selfhost/cgen_c/match_or.ig) instead.
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


fn band(c: Color) -> int {
    match c {
        case Red {
            return 10
        }
        case Green | Blue | White | Black {
            return 20
        }
    }
}


fn main() {
    println("{tier(Red)}")
    println("{tier(Black)}")
    println("{band(Red)}")
    println("{band(White)}")
}
