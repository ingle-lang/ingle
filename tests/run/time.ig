// time.ig — smoke-locks std/time.now() (OFI-188, epoch seconds). The value is nondeterministic, so
// the golden checks only plausibility: a whole-second count comfortably after 2020-01-01 and before
// 2100 — enough to prove the libc time() FFI is wired and returns a sane clock.
import "std/time" as time

fn main() -> int {
    let t = time.now()
    println("after_2020={t > 1577836800}")
    println("before_2100={t < 4102444800}")
    return 0
}
