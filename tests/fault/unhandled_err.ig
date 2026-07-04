// unhandled_err.ig (fault) — an Err that main propagates out with `?` is reported as the
// AGENT-render FCAT_UNHANDLED_ERR Fault (carrying the error value), and the program exits
// non-zero — instead of the old wart of exiting 0 with a bare `=> <obj>`.
fn parse(s: string) -> Result<int, string> {
    return Err("not a base-10 integer: {s}")
}

fn main() -> Result<int, string> {
    let n = parse("8x80")?
    return Ok(n + 1)
}
