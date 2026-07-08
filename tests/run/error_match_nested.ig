// error_match_nested.ig — one-level nested destructuring (Phase 2d) supports only an all-scalar
// value-struct inner pattern. A REFUTABLE enum inner pattern (`Wrap(Good(v))`) is rejected — bind
// the payload and use a nested `match` instead. (Literal-in-variant and depth>1 are rejected in
// the parser; a string/ref struct field and a wrong struct name/arity are rejected in the checker.)
enum Res { Good(v: int)  Bad }
enum Box { Wrap(i: Res)  Nil }
fn f(o: Box) -> int {
    match o {
        case Wrap(Good(v)) { return v }
        case Nil           { return 0 }
    }
}
fn main() { println("{f(Nil)}") }
