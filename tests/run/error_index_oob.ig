// error_index_oob.ig — an out-of-bounds index traps at runtime as the HUMAN-render Fault:
// the violated implicit contract (0 <= index < len), the concrete values, and the route.
fn get(xs: [int], i: int) -> int {
    return xs[i]
}

fn main() -> int {
    let xs = [10, 20, 30]
    return get(xs, 5)
}
