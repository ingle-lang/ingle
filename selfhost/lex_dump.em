// selfhost/lex_dump.em — the dump driver for the self-hosted lexer. It reads a source file and prints
// its token stream in stage-0's `--emit=tokens` format, so the output can be diffed byte-for-byte against
// `emberc --emit=tokens <file>` over the whole corpus (tests/run-selfhost.sh, the Stage 1 differential).
//
//   emberc --emit=run selfhost/lex_dump.em <file.em>
//
// The lexer itself lives in selfhost/lexer.em (a library); this is just the I/O shell around it.

import "lexer" as lex


fn main() -> int {
    let argv = args()
    if argv.len() < 1 {
        println("usage: emberc --emit=run selfhost/lex_dump.em <file.em>")
        return 1
    }
    lex.dump(lex.lex(read_file(argv[0])))
    return 0
}
