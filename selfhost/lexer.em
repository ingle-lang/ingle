// selfhost/lexer.em — the Ember lexer, written in Ember (Stage 1 of the self-hosting bootstrap,
// docs/design/self-hosting.md). It reproduces stage-0's tokenizer (src/lexer.c) byte-for-byte: the same
// token set, the same significant-NEWLINE rule, the same decimal-only numbers, the same raw string
// scanning, and the same BYTE-based line/column tracking. This is a LIBRARY: `lex(src) -> [Token]` is the
// entry point importers (the parser) use; `dump` prints the stream in `--emit=tokens` format. The dump
// driver is selfhost/lex_dump.em, whose output is diffed against `emberc --emit=tokens` over the whole
// corpus (tests/run-selfhost.sh).
//
// The lexer works over the source's raw bytes (src.bytes()), so a multi-byte UTF-8 char advances the
// column once per byte exactly as stage-0 does; lexemes are recovered with byte_slice (the byte-faithful
// slice, not the code-point substring). Tk is constructed only here and merely MATCHED by importers, so
// the cross-module bare-variant gap (OFI-156) does not apply.


// Tk is the token kind — one variant per stage-0 TokenType. The printed names (kind_name) mirror
// src/token.c TOKEN_NAMES exactly; keep this enum and that table in lockstep with stage 0.
enum Tk {
    TEof
    TError
    TNewline
    TInt
    TFloat
    TString
    TIdent
    TLet
    TVar
    TFn
    TReturn
    TStruct
    TEnum
    TInterface
    TImplements
    TMatch
    TCase
    TIf
    TElse
    TFor
    TIn
    TLoop
    TBreak
    TContinue
    TNursery
    TSpawn
    TMove
    TMut
    TSelf
    TTrue
    TFalse
    TImport
    TAs
    TExtern
    TType
    TWhere
    TRequires
    TEnsures
    TLParen
    TRParen
    TLBrace
    TRBrace
    TLBracket
    TRBracket
    TComma
    TDot
    TDotDot
    TColon
    TArrow
    TQuestion
    TAssign
    TEq
    TNeq
    TLt
    TLe
    TGt
    TGe
    TPlus
    TMinus
    TStar
    TSlash
    TPercent
    TBang
    TAnd
    TOr
    TPipe
    TAmp
    TCaret
    TTilde
    TShl
    TShr
}


struct Token {
    kind: Tk
    line: int
    col: int
    text: string
    byte: int          // byte offset of the token's start in the source (for strtod-style float over-read)
}


// kind_name maps a Tk to the TYPE name `--emit=tokens` prints — mirrors src/token.c TOKEN_NAMES.
fn kind_name(k: Tk) -> string {
    match k {
        case TEof { return "EOF" }
        case TError { return "ERROR" }
        case TNewline { return "NEWLINE" }
        case TInt { return "INT" }
        case TFloat { return "FLOAT" }
        case TString { return "STRING" }
        case TIdent { return "IDENT" }
        case TLet { return "LET" }
        case TVar { return "VAR" }
        case TFn { return "FN" }
        case TReturn { return "RETURN" }
        case TStruct { return "STRUCT" }
        case TEnum { return "ENUM" }
        case TInterface { return "INTERFACE" }
        case TImplements { return "IMPLEMENTS" }
        case TMatch { return "MATCH" }
        case TCase { return "CASE" }
        case TIf { return "IF" }
        case TElse { return "ELSE" }
        case TFor { return "FOR" }
        case TIn { return "IN" }
        case TLoop { return "LOOP" }
        case TBreak { return "BREAK" }
        case TContinue { return "CONTINUE" }
        case TNursery { return "NURSERY" }
        case TSpawn { return "SPAWN" }
        case TMove { return "MOVE" }
        case TMut { return "MUT" }
        case TSelf { return "SELF" }
        case TTrue { return "TRUE" }
        case TFalse { return "FALSE" }
        case TImport { return "IMPORT" }
        case TAs { return "AS" }
        case TExtern { return "EXTERN" }
        case TType { return "TYPE" }
        case TWhere { return "WHERE" }
        case TRequires { return "REQUIRES" }
        case TEnsures { return "ENSURES" }
        case TLParen { return "LPAREN" }
        case TRParen { return "RPAREN" }
        case TLBrace { return "LBRACE" }
        case TRBrace { return "RBRACE" }
        case TLBracket { return "LBRACKET" }
        case TRBracket { return "RBRACKET" }
        case TComma { return "COMMA" }
        case TDot { return "DOT" }
        case TDotDot { return "DOTDOT" }
        case TColon { return "COLON" }
        case TArrow { return "ARROW" }
        case TQuestion { return "QUESTION" }
        case TAssign { return "ASSIGN" }
        case TEq { return "EQ" }
        case TNeq { return "NEQ" }
        case TLt { return "LT" }
        case TLe { return "LE" }
        case TGt { return "GT" }
        case TGe { return "GE" }
        case TPlus { return "PLUS" }
        case TMinus { return "MINUS" }
        case TStar { return "STAR" }
        case TSlash { return "SLASH" }
        case TPercent { return "PERCENT" }
        case TBang { return "BANG" }
        case TAnd { return "AND" }
        case TOr { return "OR" }
        case TPipe { return "PIPE" }
        case TAmp { return "AMP" }
        case TCaret { return "CARET" }
        case TTilde { return "TILDE" }
        case TShl { return "SHL" }
        case TShr { return "SHR" }
    }
}


// keyword_kind maps an identifier spelling to its keyword Tk, or TIdent — mirrors the EMBER_KEYWORD
// rows of include/vocab.def (OFI-153 will generate this from vocab.def; hand-mirrored for now).
fn keyword_kind(w: string) -> Tk {
    if w == "requires" { return TRequires }
    if w == "ensures" { return TEnsures }
    if w == "return" { return TReturn }
    if w == "if" { return TIf }
    if w == "else" { return TElse }
    if w == "for" { return TFor }
    if w == "in" { return TIn }
    if w == "loop" { return TLoop }
    if w == "break" { return TBreak }
    if w == "continue" { return TContinue }
    if w == "match" { return TMatch }
    if w == "case" { return TCase }
    if w == "let" { return TLet }
    if w == "var" { return TVar }
    if w == "fn" { return TFn }
    if w == "struct" { return TStruct }
    if w == "enum" { return TEnum }
    if w == "interface" { return TInterface }
    if w == "extern" { return TExtern }
    if w == "type" { return TType }
    if w == "where" { return TWhere }
    if w == "nursery" { return TNursery }
    if w == "spawn" { return TSpawn }
    if w == "import" { return TImport }
    if w == "as" { return TAs }
    if w == "move" { return TMove }
    if w == "mut" { return TMut }
    if w == "implements" { return TImplements }
    if w == "self" { return TSelf }
    if w == "true" { return TTrue }
    if w == "false" { return TFalse }
    return TIdent
}


// should_terminate reports whether a token of kind k can END a statement, so a following newline becomes
// a significant NEWLINE token. Mirrors stage-0's should_terminate whitelist exactly.
fn should_terminate(k: Tk) -> bool {
    match k {
        case TInt { return true }
        case TFloat { return true }
        case TString { return true }
        case TIdent { return true }
        case TTrue { return true }
        case TFalse { return true }
        case TSelf { return true }
        case TReturn { return true }
        case TBreak { return true }
        case TContinue { return true }
        case TRParen { return true }
        case TRBracket { return true }
        case TRBrace { return true }
        case TQuestion { return true }
        case _ { return false }
    }
}


fn is_digit_b(c: int) -> bool {
    return c >= 48 && c <= 57
}


fn is_alpha_b(c: int) -> bool {
    return (c >= 97 && c <= 122) || (c >= 65 && c <= 90) || c == 95
}


fn is_alnum_b(c: int) -> bool {
    return is_alpha_b(c) || is_digit_b(c)
}


// Lexer is the scanner state: the source string (for byte_slice) and its raw bytes (for classification),
// the byte cursor `pos` with 1-based byte `line`/`col`, the unclosed-(/[ depth that suppresses newlines,
// the previously emitted kind (for the NEWLINE rule), and the growing token list.
struct Lexer {
    src: string
    bs: [u8]
    n: int
    pos: int
    line: int
    col: int
    depth: int
    prev: Tk
    terr_line: int        // override position for the next TError (-1 = use the token's own start);
    terr_col: int         // set by scan_string for an unterminated interpolation (points at the '{')


    fn peek(self) -> int {
        if self.pos >= self.n {
            return 0
        }
        return int(self.bs[self.pos])
    }


    fn peek2(self) -> int {
        if self.pos + 1 >= self.n {
            return 0
        }
        return int(self.bs[self.pos + 1])
    }


    fn advance(mut self) -> int {
        let c = self.peek()
        self.pos = self.pos + 1
        if c == 10 {
            self.line = self.line + 1
            self.col = 1
        } else {
            self.col = self.col + 1
        }
        return c
    }


    fn match_byte(mut self, b: int) -> bool {
        if self.peek() == b {
            let _ = self.advance()
            return true
        }
        return false
    }


    // skip_trivia consumes whitespace and `//` / `///` comments (both skipped to end of line — the doc
    // distinction does not affect the token stream), returning whether a newline was crossed.
    fn skip_trivia(mut self) -> bool {
        var crossed = false
        loop {
            let c = self.peek()
            if c == 32 || c == 9 || c == 13 {
                let _ = self.advance()
            } else if c == 10 {
                crossed = true
                let _ = self.advance()
            } else if c == 47 && self.peek2() == 47 {
                loop {
                    let d = self.peek()
                    if d == 0 || d == 10 {
                        break
                    }
                    let _ = self.advance()
                }
            } else {
                break
            }
        }
        return crossed
    }


    // scan_number assumes the first digit was already consumed. It reads the rest of the integer, an
    // optional fractional part (a '.' that is immediately followed by a digit), and an optional integer
    // width suffix [iu][0-9]+. Decimal only — no hex/binary/exponent/underscores, matching stage 0.
    fn scan_number(mut self) -> Tk {
        loop {
            if is_digit_b(self.peek()) {
                let _ = self.advance()
            } else {
                break
            }
        }
        if self.peek() == 46 && is_digit_b(self.peek2()) {
            let _ = self.advance()
            loop {
                if is_digit_b(self.peek()) {
                    let _ = self.advance()
                } else {
                    break
                }
            }
            return TFloat
        }
        let p = self.peek()
        if (p == 105 || p == 117) && is_digit_b(self.peek2()) {
            let _ = self.advance()
            loop {
                if is_digit_b(self.peek()) {
                    let _ = self.advance()
                } else {
                    break
                }
            }
        }
        return TInt
    }


    // scan_string assumes the opening quote was already consumed. It finds the matching close quote,
    // skipping `\`+char escapes, tracking `{`/`}` interpolation depth, and consuming a whole nested
    // string when a quote is met inside a hole — so the whole literal is one raw TOK_STRING. EOF before
    // the close is a TError (the corpus is well-formed, so this does not arise in the differential).
    fn scan_string(mut self) -> Tk {
        var depth = 0
        var brace_line = 0
        var brace_col = 0
        loop {
            let c = self.peek()
            if c == 0 {
                // EOF before the close. With an open interpolation hole, stage-0 points the error at
                // the OUTERMOST unmatched '{' (not the opening quote) — record that override here.
                if depth > 0 {
                    self.terr_line = brace_line
                    self.terr_col = brace_col
                }
                return TError
            }
            if c == 92 {
                let _ = self.advance()
                if self.peek() != 0 {
                    let _ = self.advance()
                }
            } else if c == 34 {
                if depth == 0 {
                    let _ = self.advance()
                    return TString
                }
                let _ = self.advance()
                loop {
                    let d = self.peek()
                    if d == 0 {
                        return TError
                    }
                    if d == 92 {
                        let _ = self.advance()
                        if self.peek() != 0 {
                            let _ = self.advance()
                        }
                    } else if d == 34 {
                        let _ = self.advance()
                        break
                    } else {
                        let _ = self.advance()
                    }
                }
            } else if c == 123 {
                if depth == 0 {
                    brace_line = self.line
                    brace_col = self.col
                }
                depth = depth + 1
                let _ = self.advance()
            } else if c == 125 {
                if depth > 0 {
                    depth = depth - 1
                }
                let _ = self.advance()
            } else {
                let _ = self.advance()
            }
        }
        return TError
    }


    // scan_token reads one token starting at the cursor (trivia already skipped). `start` is the byte
    // offset of the token's first byte, used to recover identifier/keyword spellings.
    fn scan_token(mut self, start: int) -> Tk {
        let c = self.advance()
        if is_alpha_b(c) {
            loop {
                if is_alnum_b(self.peek()) {
                    let _ = self.advance()
                } else {
                    break
                }
            }
            return keyword_kind(byte_slice(self.src, start, self.pos))
        }
        if is_digit_b(c) {
            return self.scan_number()
        }
        if c == 34 {
            return self.scan_string()
        }
        if c == 40 { return TLParen }
        if c == 41 { return TRParen }
        if c == 123 { return TLBrace }
        if c == 125 { return TRBrace }
        if c == 91 { return TLBracket }
        if c == 93 { return TRBracket }
        if c == 44 { return TComma }
        if c == 58 { return TColon }
        if c == 63 { return TQuestion }
        if c == 43 { return TPlus }
        if c == 42 { return TStar }
        if c == 47 { return TSlash }
        if c == 37 { return TPercent }
        if c == 94 { return TCaret }
        if c == 126 { return TTilde }
        if c == 46 {
            if self.match_byte(46) { return TDotDot }
            return TDot
        }
        if c == 45 {
            if self.match_byte(62) { return TArrow }
            return TMinus
        }
        if c == 61 {
            if self.match_byte(61) { return TEq }
            return TAssign
        }
        if c == 33 {
            if self.match_byte(61) { return TNeq }
            return TBang
        }
        if c == 60 {
            if self.match_byte(60) { return TShl }
            if self.match_byte(61) { return TLe }
            return TLt
        }
        if c == 62 {
            if self.match_byte(62) { return TShr }
            if self.match_byte(61) { return TGe }
            return TGt
        }
        if c == 38 {
            if self.match_byte(38) { return TAnd }
            return TAmp
        }
        if c == 124 {
            if self.match_byte(124) { return TOr }
            return TPipe
        }
        return TError
    }


    // run is the main scan loop: skip trivia, synthesize a NEWLINE where a statement can end, then scan
    // one token — until EOF, which always terminates the stream with a single TEof. It returns the token
    // list directly (a local, not a struct field, so the caller can move it out cleanly).
    fn run(mut self) -> [Token] {
        var toks: [Token] = []
        loop {
            let crossed = self.skip_trivia()
            if crossed && self.depth == 0 && should_terminate(self.prev) {
                toks.append(Token{ kind: TNewline, line: self.line, col: self.col, text: "", byte: self.pos })
                self.prev = TNewline
            }
            // A NUL byte ends the stream: stage-0 reads the source as a NUL-terminated C string, so the
            // first NUL is end-of-input (peek() returns 0 at the NUL and past the buffer alike).
            if self.peek() == 0 {
                toks.append(Token{ kind: TEof, line: self.line, col: self.col, text: "", byte: self.pos })
                break
            }
            let sline = self.line
            let scol = self.col
            let start = self.pos
            let k = self.scan_token(start)
            // scan_string may have recorded an override position for an unterminated-interpolation TError.
            var tline = sline
            var tcol = scol
            if self.terr_line >= 0 {
                tline = self.terr_line
                tcol = self.terr_col
                self.terr_line = 0 - 1
            }
            toks.append(Token{ kind: k, line: tline, col: tcol, text: byte_slice(self.src, start, self.pos), byte: start })
            self.prev = k
            match k {
                case TLParen { self.depth = self.depth + 1 }
                case TLBracket { self.depth = self.depth + 1 }
                case TRParen {
                    if self.depth > 0 {
                        self.depth = self.depth - 1
                    }
                }
                case TRBracket {
                    if self.depth > 0 {
                        self.depth = self.depth - 1
                    }
                }
                case _ {
                }
            }
        }
        return toks
    }
}


fn itoa(n: int) -> string {
    if n == 0 {
        return "0"
    }
    var v = n
    var out = ""
    loop {
        if v == 0 {
            break
        }
        out = from_char_code(48 + v % 10) + out
        v = v / 10
    }
    return out
}


fn pad_left(s: string, w: int) -> string {
    var out = s
    loop {
        if out.len() >= w {
            break
        }
        out = " " + out
    }
    return out
}


fn pad_right(s: string, w: int) -> string {
    var out = s
    loop {
        if out.len() >= w {
            break
        }
        out = out + " "
    }
    return out
}


// dump prints the token stream in stage-0's exact `--emit=tokens` format: `%4d:%-3d  %-10s  %.*s`.
fn dump(toks: [Token]) {
    var i = 0
    loop {
        if i >= toks.len() {
            break
        }
        let t = toks[i]
        let line = pad_left(itoa(t.line), 4) + ":" + pad_right(itoa(t.col), 3) + "  " + pad_right(kind_name(t.kind), 10) + "  " + t.text
        println(line)
        i = i + 1
    }
}


// lex tokenizes a whole source string into a `[Token]` — the library entry point importers use (the
// parser calls this, then matches the tokens). The dump driver lives in selfhost/lex_dump.em.
fn lex(src: string) -> [Token] {
    var lx = Lexer{ src: src, bs: src.bytes(), n: src.len(), pos: 0, line: 1, col: 1, depth: 0, prev: TNewline, terr_line: 0 - 1, terr_col: 0 }
    return lx.run()
}
