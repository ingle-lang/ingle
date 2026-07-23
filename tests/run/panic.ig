// panic.ig — P5: `panic(msg)` is a diverging runtime trap. On the VM it raises a structured Fault
// (category runtime, code "panic"); on native it aborts via em_panic_val. Unlike `assert` it is
// NEVER release-elided — it is the mechanism `unwrap`/`expect` trap through.
fn main() -> int {
    panic("something went wrong")
}
