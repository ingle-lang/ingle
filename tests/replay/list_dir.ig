// A directory listing is a nondeterministic INPUT like a file read: --emit=replay must record
// each list_dir result and reproduce the run from the log without touching the filesystem.
// Two listings of the same tree land as two recorded events (no dedup — replay is a faithful log).
fn main() -> int {
    let a = list_dir("tests/run/list_dir_fixture")
    let b = list_dir("tests/run/list_dir_fixture")
    if a != b {
        return 1
    }
    return a.split("\n").len()
}
