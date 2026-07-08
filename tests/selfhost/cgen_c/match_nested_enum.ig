// M5 fixture: refutable enum-inner nested patterns (`case Wrap(Good(v))`) — Phase 2d-ii. The C-emit
// ANDs each enum-inner slot's tag onto the arm's condition (`v_tag == W && em_tag(em_enum_field(&g_em,
// v_sv, b)) == G`) and binds each inner scalar/string field via em_enum_field on the payload — no value
// struct, so byte-identical to stage-0 `inglec --emit=c` (gated, Stage 6 of make selfhost). Exercises a
// guard on an enum-inner arm, a string inner payload, and a plain fallback covering the outer variant.
enum Res { Good(v: int)  Bad(msg: string) }
enum Opt { Wrap(r: Res)  Empty }


fn describe(o: Opt) -> string {
    match o {
        case Wrap(Good(v)) if v > 100 {
            return "big"
        }
        case Wrap(Good(v)) {
            return "good"
        }
        case Wrap(Bad(msg)) {
            return msg
        }
        case Empty {
            return "empty"
        }
    }
}


fn main() {
    println(describe(Wrap(Good(5))))
    println(describe(Wrap(Bad("x"))))
    println(describe(Empty))
}
