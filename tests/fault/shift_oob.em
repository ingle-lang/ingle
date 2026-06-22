// shift_oob.em (fault) — a shift amount outside [0, width) as the AGENT-render Fault. The amount
// comes from a call so the shift happens at runtime (OP_SHL), not folded at compile time.
fn width() -> int {
    return 64
}

fn main() -> int {
    return 1 << width()
}
