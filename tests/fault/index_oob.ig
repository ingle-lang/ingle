// index_oob.ig (fault) — an out-of-bounds index reported as the AGENT-render Fault: a violated
// implicit contract (0 <= index < len) carrying the concrete index/len values and the route.
fn get(xs: [int], i: int) -> int {
    return xs[i]
}

fn main() -> int {
    let xs = [10, 20, 30]
    return get(xs, 5)
}
