// div_zero.ig (fault) — divide-by-zero as the AGENT-render Fault (implicit contract: a non-zero
// divisor). The divisor comes from a call so it is a real runtime OP_DIV, never constant-folded.
fn zero() -> int {
    return 0
}

fn main() -> int {
    return 10 / zero()
}
