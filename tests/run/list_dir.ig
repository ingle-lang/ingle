// list_dir(path) -> string — the directory's entries, one per line, sorted byte-wise over the
// printed lines, subdirectories marked with a trailing '/'. Missing/unreadable (or empty)
// directories yield "" — the read_file convention: absent input degrades, it doesn't crash.
// The fixture tree (tests/run/list_dir_fixture/) is checked in, so the listing is a stable golden.
fn main() -> int {
    let listing = list_dir("tests/run/list_dir_fixture")
    println(listing)
    println(list_dir("tests/run/no_such_fixture_dir"))
    println(list_dir("tests/run/list_dir_fixture/beta"))
    return listing.split("\n").len()
}
