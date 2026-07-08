// Refutable enum-inner nested patterns (`case Some(Ok(v))`) — Phase 2d-ii. A variant's payload
// field that is an ENUM can be destructured one level with an inner variant pattern, which is
// REFUTABLE (the inner tag may not match). The compiler lowers the arm to an AND of the outer and
// inner tags; exhaustiveness is one-level nested (an outer variant is covered when all of its
// single enum payload's inner variants are). Composes with guards and a plain fallback; the inner
// payloads may be scalar or string. (Generic Option<Result> is exercised by the checker suite; the
// runtime uses erased enum ops, so non-generic enums cover it here and dodge the nested-generic
// construction-inference gap.)
enum Res { Good(v: int)  Bad(msg: string) }
enum Opt { Wrap(r: Res)  Empty }


fn describe(o: Opt) -> string {
    match o {
        case Wrap(Good(v)) if v > 100 {
            return "big"
        }
        case Wrap(Good(v)) {
            return "good {v}"
        }
        case Wrap(Bad(msg)) {
            return msg
        }
        case Empty {
            return "empty"
        }
    }
}


enum Tri { A(n: int)  B(n: int)  C(n: int) }
enum Box { Hold(t: Tri)  Nil }


fn pick(b: Box) -> int {
    match b {
        case Hold(A(n)) {
            return n
        }
        case Hold(B(n)) {
            return n * 10
        }
        case Hold(other) {
            return 0 - 1
        }
        case Nil {
            return 0
        }
    }
}


fn main() {
    println(describe(Wrap(Good(5))))
    println(describe(Wrap(Good(200))))
    println(describe(Wrap(Bad("oops"))))
    println(describe(Empty))
    println("{pick(Hold(A(7)))}")
    println("{pick(Hold(B(7)))}")
    println("{pick(Hold(C(7)))}")
    println("{pick(Nil)}")
}
