// error_try_non_result.ig — `?` only applies to Result/Option.
fn f(n: int) -> int {
    let x = n?
    return x
}
fn main() -> int { return 0 }
