// selfhost/parse_dump.ig — the dump driver for the self-hosted parser. It reads a source file, parses it,
// and prints the AST in stage-0's `--emit=ast` format, so the output can be diffed byte-for-byte against
// `inglec --emit=ast <file>` over the corpus (tests/run-selfhost.sh, the Stage 2 differential).
//
//   inglec --emit=run selfhost/parse_dump.ig <file.ig>
//
// The parser (and AST + printer) live in selfhost/parser.ig; this is the I/O shell around it.

import "parser" as ps


fn main() -> int {
    let argv = args()
    if argv.len() < 1 {
        println("usage: inglec --emit=run selfhost/parse_dump.ig <file.ig>")
        return 1
    }
    ps.dump(ps.parse(read_file(argv[0])))
    return 0
}
