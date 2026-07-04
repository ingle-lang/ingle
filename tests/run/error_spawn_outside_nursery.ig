// error_spawn_outside_nursery.ig — spawn is only valid inside a nursery.
fn work() -> int { return 0 }
fn main() -> int {
    spawn work()
    return 0
}
