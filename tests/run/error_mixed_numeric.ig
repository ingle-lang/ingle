// error_mixed_numeric.ig — no implicit coercion: int + float is rejected.
fn main() -> int {
    return 1 + 2.0
}
