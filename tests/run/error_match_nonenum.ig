// error_match_nonenum.ig — a PARENTHESISED/qualified variant pattern cannot match a non-enum
// (scalar) value. A bare identifier on a scalar is now a value binding (`case n`), but `case
// Some(y)` (payload bindings) is a variant pattern, which is meaningless on an int.
fn main() -> int {
    let x = 5
    match x {
        case Some(y) { return 1 }
        case _       { return 0 }
    }
    return 0
}
