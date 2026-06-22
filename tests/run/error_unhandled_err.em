// error_unhandled_err.em — an Err propagated out of main is the HUMAN-render unhandled-error
// Fault, and the program exits non-zero (was: exit 0 with `=> <obj>`).
fn parse(s: string) -> Result<int, string> {
    return Err("not a base-10 integer: {s}")
}

fn main() -> Result<int, string> {
    let n = parse("8x80")?
    return Ok(n + 1)
}
