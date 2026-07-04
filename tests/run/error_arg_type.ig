// error_arg_type.ig — argument type must match the parameter (no coercion).
fn takes_int(x: int) -> int { return x }
fn main() -> int { return takes_int(true) }
