// interpolation_escape.ig — \{ and \} are literal braces, not interpolation.
fn main() -> string {
    let n = 5
    return "set is \{ {n} \}"
}
