// selfhost/check_dump.em — the verdict driver for the self-hosted checker (M3a). It parses + checks a
// source file and prints the diagnostics (one per line); a final line reports ACCEPT (no diagnostics) or
// REJECT. The differential (tests/run-selfhost.sh) compares the verdict against stage-0's
// `emberc --emit=bytecode` (exit 0 = accept, 65 = a check error).
//
//   emberc --emit=run selfhost/check_dump.em <file.em>

import "checker" as ck


fn main() -> int {
    let argv = args()
    if argv.len() < 1 {
        println("usage: emberc --emit=run selfhost/check_dump.em <file.em>")
        return 1
    }
    if ck.check(read_file(argv[0])) {
        println("REJECT")
    } else {
        println("ACCEPT")
    }
    return 0
}
