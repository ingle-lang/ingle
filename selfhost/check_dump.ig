// selfhost/check_dump.ig — the verdict driver for the self-hosted checker (M3a). It parses + checks a
// source file and prints the diagnostics (one per line); a final line reports ACCEPT (no diagnostics) or
// REJECT. The differential (tests/run-selfhost.sh) compares the verdict against stage-0's
// `inglec --emit=bytecode` (exit 0 = accept, 65 = a check error).
//
//   inglec --emit=run selfhost/check_dump.ig <file.ig>

import "checker" as ck


fn main() -> int {
    let argv = args()
    if argv.len() < 1 {
        println("usage: inglec --emit=run selfhost/check_dump.ig <file.ig>")
        return 1
    }
    if ck.check(read_file(argv[0])) {
        println("REJECT")
    } else {
        println("ACCEPT")
    }
    return 0
}
