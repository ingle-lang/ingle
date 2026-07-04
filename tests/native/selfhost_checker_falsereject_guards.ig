// Regression for the self-hosted checker (selfhost/checker.ig) false-reject family triaged 2026-06-27.
//
// Two distinct leniency holes were closed; every construct below is VALID Ingle that stage-0 accepts,
// so the self-hosted checker MUST accept it too. The selfhost gate's corpus scan picks this file up
// (it lives under tests/) and hard-fails if any of these regress to a REJECT.
//
//   1. A BARE (non-generic) `Option`/`Result` annotation must stay lenient (TY_INFER), not resolve to a
//      concrete-but-empty enum id — otherwise a `match` rejects every real Some/Ok/... pattern as "not
//      belonging" to the empty variant table. Fix: annotation_type only returns a concrete enum id for an
//      enum that actually has variants registered (enum_has_variants).
//
//   2. Arithmetic with one TY_INFER operand (field read, array index, or call result) and a bare numeric
//      literal must stay TY_INFER, not concretize to the literal's TY_INT/TY_FLOAT — otherwise a later
//      sized-context check (`-> u32`, `let x: f32 = ...`) wrongly fires. Fix: the EBinary fallthrough
//      returns TY_INFER when either operand is non-concrete instead of returning the known operand's type.

struct S {
    n: u32
    x: f32
}


fn match_bare_result(r: Result) -> int {
    match r {
        case Ok(v) { return 1 }
        case Err(e) { return 2 }
    }
}


fn match_bare_option(o: Option) -> int {
    match o {
        case Some(v) { return 1 }
        case None { return 2 }
    }
}


fn field_plus_lit_u32(s: S) -> u32 {
    return s.n + 1
}


fn field_plus_lit_let(s: S) -> int {
    let r: u32 = s.n + 1
    return 0
}


fn field_plus_lit_f32(s: S) -> f32 {
    return s.x + 1.5
}


fn call_result_u32() -> u32 {
    return 5
}


fn call_plus_lit_u32() -> u32 {
    return call_result_u32() + 1
}


fn index_plus_lit_u32(xs: [u32]) -> u32 {
    return xs[0] + 1
}


fn main() {
    println("selfhost checker false-reject guards: ok")
}
