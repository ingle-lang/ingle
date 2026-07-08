// error_match_nested.ig — one-level nesting (Phase 2d) has bounded inner payloads. A REFUTABLE
// enum-inner pattern (`Wrap(Loc(pt))`) is now supported (2d-ii), but only for SCALAR/STRING inner
// payloads — an inner variant whose payload is a STRUCT is rejected (bind the payload and use a
// nested `match`). (Literal-in-variant and depth>1 are rejected in the parser; a string/ref struct
// field and a wrong struct/variant name/arity are rejected too.)
struct Point { x: int  y: int }
enum Res { Loc(p: Point)  Nope }
enum Box { Wrap(r: Res)  Nil }
fn f(o: Box) -> int {
    match o {
        case Wrap(Loc(pt)) { return pt.x }
        case Wrap(Nope)    { return 0 }
        case Nil           { return 0 }
    }
}
fn main() { println("{f(Nil)}") }
