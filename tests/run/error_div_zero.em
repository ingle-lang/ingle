// error_div_zero.em — division by zero traps at runtime as the HUMAN-render Fault (implicit
// contract: a non-zero divisor). The divisor comes from a call so it is a real runtime divide.
fn zero() -> int {
    return 0
}

fn main() -> int {
    return 10 / zero()
}
