// route_chain.ig (fault) — OFI-108: an Err that propagates through MORE THAN ONE `?` shows the
// full propagation route (decode→? in parse_port, then ? in main) on the unhandled-Err Fault,
// even though those frames have already unwound by the time it surfaces at main.
fn decode(s: string) -> Result<int, string> {
    return Err("not a base-10 integer: {s}")
}

fn parse_port(s: string) -> Result<int, string> {
    let n = decode(s)?
    return Ok(n)
}

fn main() -> Result<int, string> {
    let p = parse_port("8x80")?
    return Ok(p + 1)
}
