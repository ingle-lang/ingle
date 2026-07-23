// selfhost/check_dump.ig — the verdict driver for the self-hosted checker (M3a). It parses + checks a
// source file and prints the diagnostics (one per line); a final line reports ACCEPT (no diagnostics) or
// REJECT. The differential (tests/run-selfhost.sh) compares the verdict against stage-0's
// `inglec --emit=bytecode` (exit 0 = accept, 65 = a check error).
//
//   inglec --emit=run selfhost/check_dump.ig <file.ig>
//
// NOTE: this is a SINGLE-FILE checker — it does NOT merge imports. A whole-program (merged) check would let
// it see an imported declaration (e.g. a `std/web` direct extern, closing the 4 examples/web/*.ig misses),
// but the checker's name resolution is not yet MODULE-SCOPED (OFI-073): two modules may legally share a
// variant/helper name, and a merged global scope collides them → mass false-rejects (verified: merging
// yielded 84). Merged checking (via checker.ig's check_decls) waits on module-scoped resolution.

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
