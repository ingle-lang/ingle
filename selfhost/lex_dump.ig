// selfhost/lex_dump.ig — the dump driver for the self-hosted lexer. It reads a source file and prints
// its token stream in stage-0's `--emit=tokens` format, so the output can be diffed byte-for-byte against
// `inglec --emit=tokens <file>` over the whole corpus (tests/run-selfhost.sh, the Stage 1 differential).
//
//   inglec --emit=run selfhost/lex_dump.ig <file.ig>
//
// The lexer itself lives in selfhost/lexer.ig (a library); this is just the I/O shell around it.

import "lexer" as lex


fn main() -> int {
    let argv = args()
    if argv.len() < 1 {
        println("usage: inglec --emit=run selfhost/lex_dump.ig <file.ig>")
        return 1
    }
    lex.dump(lex.lex(read_file(argv[0])))
    return 0
}
