// error_mixed_arith.ig — locks no-coercion: int + bool is rejected.
fn main() -> int {
    return 1 + (2 > 3)
}
