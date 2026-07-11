// std/time — wall-clock time. Whole seconds since the Unix epoch, for timestamps (commit and
// op-log times in Quog, log lines, cache ages). A thin FFI over libc `time()`; part of OFI-188
// (a fiber-parking `sleep` and record/replay capture of the clock are the remainder). DEFAULT
// build — no dependency, no build flag.
extern "c" {
    fn em_now_unix() -> i64
}


// now returns the current wall-clock time as whole seconds since the Unix epoch (1970-01-01 00:00
// UTC). It is a genuine nondeterministic input — two calls a second apart differ — so anything that
// must replay bit-for-bit should record it, not re-read it.
fn now() -> int {
    return em_now_unix()
}
