// tests/selfhost/calc.em — Stage A self-hosting spike (docs/design/self-hosting.md §4 "Stage A").
//
// This is a compiler in miniature: a complete lex -> parse -> eval pipeline for a tiny expression
// language, written in pure Ember. It exists to retire the central self-hosting risk before any real
// stage is ported — that the language can express, on BOTH backends, the exact shapes the reference
// compiler is built from. One small program exercises every prerequisite at once:
//
//   * byte-level string scanning (the lexer's staple) — char_code / .chars() / index
//   * a recursive sum-type AST — `enum Expr` walked with exhaustive `match`
//   * BOTH recursion shapes — single/two-child via `Box<Expr>` and n-ary via `[Expr]`
//   * a `Map<string,int>` symbol table — variable environment, lookup returns `Option`
//   * `Result` + `?` propagation — evaluation errors (unknown var, divide-by-zero) thread out cleanly
//
// The harness (tests/run-selfhost.sh) runs it on the bytecode VM and as a native binary and requires
// byte-identical stdout — the same differential discipline as tests/native, pointed at compiler-shaped
// code. Deterministic output, no I/O.

import "std/map" as mp


// Box<T> is the single-child heap indirection a recursive AST needs: an `enum` variant cannot embed
// itself by value (infinite size), so a recursive child is wrapped in this user struct and read back
// through `.value`. There is no built-in Box — the reference compiler will define its own exactly like
// this, so the spike proves the pattern it will depend on.
struct Box<T> {
    value: T
}


// Op is the binary operator, kept separate from Expr so the evaluator dispatches on it with its own
// small exhaustive match.
enum Op {
    OpAdd
    OpSub
    OpMul
    OpDiv
}


// Expr is the abstract syntax tree. `Neg`/`Bin` recurse through `Box<Expr>` (the single- and two-child
// shapes), `Sum` recurses through `[Expr]` (the n-ary shape) — the two ways an AST grows, both present
// so neither is left unproven.
enum Expr {
    Num(n: int)
    Var(name: string)
    Neg(inner: Box<Expr>)
    Bin(op: Op, left: Box<Expr>, right: Box<Expr>)
    Sum(args: [Expr])
}


// Tok is one lexical token. Number and identifier carry a payload; the rest are bare punctuation. TEof
// terminates the stream so the parser can peek past the end without a bounds check.
enum Tok {
    TNum(v: int)
    TIdent(name: string)
    TPlus
    TMinus
    TStar
    TSlash
    TLParen
    TRParen
    TComma
    TEof
}


// _is_digit / _is_alpha / _is_alnum classify a single code point by its ASCII value — the same
// byte-level tests a real lexer runs thousands of times.
fn _is_digit(c: string) -> bool {
    let k = char_code(c)
    return k >= 48 && k <= 57
}


fn _is_alpha(c: string) -> bool {
    let k = char_code(c)
    return (k >= 97 && k <= 122) || (k >= 65 && k <= 90) || c == "_"
}


fn _is_alnum(c: string) -> bool {
    return _is_alpha(c) || _is_digit(c)
}


// lex turns source text into a token stream. It scans the code points once, coalescing digit runs into
// one `TNum` and identifier runs into one `TIdent`, and skips ASCII whitespace. An unrecognised
// character is dropped (the parser reports the resulting structural error) — keeping the lexer total.
fn lex(src: string) -> [Tok] {
    let cs = src.chars()
    var toks: [Tok] = []
    var i = 0
    loop {
        if i >= cs.len() {
            break
        }
        let c = cs[i]
        if c == " " || c == "\t" || c == "\n" || c == "\r" {
            i = i + 1
        } else if _is_digit(c) {
            var n = 0
            loop {
                if i >= cs.len() || _is_digit(cs[i]) == false {
                    break
                }
                n = n * 10 + (char_code(cs[i]) - 48)
                i = i + 1
            }
            toks.append(TNum(n))
        } else if _is_alpha(c) {
            var name = ""
            loop {
                if i >= cs.len() || _is_alnum(cs[i]) == false {
                    break
                }
                name = name + cs[i]
                i = i + 1
            }
            toks.append(TIdent(name))
        } else if c == "+" {
            toks.append(TPlus)
            i = i + 1
        } else if c == "-" {
            toks.append(TMinus)
            i = i + 1
        } else if c == "*" {
            toks.append(TStar)
            i = i + 1
        } else if c == "/" {
            toks.append(TSlash)
            i = i + 1
        } else if c == "(" {
            toks.append(TLParen)
            i = i + 1
        } else if c == ")" {
            toks.append(TRParen)
            i = i + 1
        } else if c == "," {
            toks.append(TComma)
            i = i + 1
        } else {
            i = i + 1
        }
    }
    toks.append(TEof)
    return toks
}


// Parser is a recursive-descent cursor over the token stream, mirroring std/json.em's design: it
// advances `pos`, latches the first error in `err` (after which the productions wind down returning a
// placeholder), and guards recursion `depth` against the VM's 256-frame call cap (vm.c FRAMES_MAX) so a
// pathological nesting fails cleanly instead of aborting the interpreter.
struct Parser {
    toks: [Tok]
    pos: int
    err: string
    depth: int


    fn peek(self) -> Tok {
        if self.pos >= self.toks.len() {
            return TEof
        }
        return self.toks[self.pos]
    }


    fn advance(mut self) -> Tok {
        let t = self.peek()
        self.pos = self.pos + 1
        return t
    }


    fn fail(mut self, msg: string) {
        if self.err == "" {
            self.err = msg
        }
    }


    // expr parses an additive chain: term (('+' | '-') term)*. Left-associative, so it folds each new
    // term into the accumulated left operand.
    fn expr(mut self) -> Expr {
        var left = self.term()
        loop {
            if self.err != "" {
                return left
            }
            match self.peek() {
                case TPlus {
                    let _ = self.advance()
                    let right = self.term()
                    left = Bin(OpAdd, Box<Expr>{ value: left }, Box<Expr>{ value: right })
                }
                case TMinus {
                    let _ = self.advance()
                    let right = self.term()
                    left = Bin(OpSub, Box<Expr>{ value: left }, Box<Expr>{ value: right })
                }
                case _ {
                    break
                }
            }
        }
        return left
    }


    // term parses a multiplicative chain: factor (('*' | '/') factor)*.
    fn term(mut self) -> Expr {
        var left = self.factor()
        loop {
            if self.err != "" {
                return left
            }
            match self.peek() {
                case TStar {
                    let _ = self.advance()
                    let right = self.factor()
                    left = Bin(OpMul, Box<Expr>{ value: left }, Box<Expr>{ value: right })
                }
                case TSlash {
                    let _ = self.advance()
                    let right = self.factor()
                    left = Bin(OpDiv, Box<Expr>{ value: left }, Box<Expr>{ value: right })
                }
                case _ {
                    break
                }
            }
        }
        return left
    }


    // factor parses an atom: a number, a variable, a parenthesised sub-expression, a unary minus, or a
    // `sum(a, b, ...)` call — the latter the n-ary `[Expr]` producer.
    //
    // The depth cap is 100, not the VM's 256: each grammar level costs ~2 VM frames here (factor ->
    // _factor_inner -> factor …), so a parser hosted on the VM must guard at roughly FRAMES_MAX/2 or the
    // interpreter aborts with "call depth exceeded" on deep input — while the native binary, with no
    // such cap, would keep going, a silent VM/native divergence. Guarding in the Ember code keeps BOTH
    // backends in lockstep (both report the structural error) and the VM under its frame ceiling. This
    // is a direct lesson for the real self-hosted parser. (vm.c FRAMES_MAX = 256.)
    fn factor(mut self) -> Expr {
        self.depth = self.depth + 1
        if self.depth > 100 {
            self.fail("expression nested too deeply")
            self.depth = self.depth - 1
            return Num(0)
        }
        let result = self._factor_inner()
        self.depth = self.depth - 1
        return result
    }


    fn _factor_inner(mut self) -> Expr {
        match self.advance() {
            case TNum(v) {
                return Num(v)
            }
            case TIdent(name) {
                if name == "sum" {
                    return self.sum_call()
                }
                return Var(name)
            }
            case TMinus {
                let inner = self.factor()
                return Neg(Box<Expr>{ value: inner })
            }
            case TLParen {
                let inner = self.expr()
                match self.advance() {
                    case TRParen {
                        return inner
                    }
                    case _ {
                        self.fail("expected ')'")
                        return inner
                    }
                }
            }
            case _ {
                self.fail("expected a number, name, '-' or '('")
                return Num(0)
            }
        }
    }


    // sum_call parses the argument list of `sum(...)` after the `sum` identifier has been consumed,
    // collecting zero or more comma-separated expressions into a `[Expr]`.
    fn sum_call(mut self) -> Expr {
        match self.advance() {
            case TLParen {
                var args: [Expr] = []
                match self.peek() {
                    case TRParen {
                        let _ = self.advance()
                        return Sum(args)
                    }
                    case _ {
                        loop {
                            if self.err != "" {
                                return Sum(args)
                            }
                            args.append(self.expr())
                            match self.advance() {
                                case TComma {
                                }
                                case TRParen {
                                    return Sum(args)
                                }
                                case _ {
                                    self.fail("expected ',' or ')' in sum(...)")
                                    return Sum(args)
                                }
                            }
                        }
                        return Sum(args)
                    }
                }
            }
            case _ {
                self.fail("expected '(' after 'sum'")
                return Num(0)
            }
        }
    }
}


// parse runs the lexer and parser over a source string, returning the AST or the first error message.
fn parse(src: string) -> Result<Expr, string> {
    var p = Parser{ toks: lex(src), pos: 0, err: "", depth: 0 }
    let tree = p.expr()
    if p.err != "" {
        return Err(p.err)
    }
    match p.peek() {
        case TEof {
            return Ok(tree)
        }
        case _ {
            return Err("unexpected trailing input")
        }
    }
}


// eval walks the AST against a variable environment, returning the integer result or the first failure.
// `?` propagates a sub-expression error (unknown variable, divide-by-zero) straight to the caller — the
// exact Result-threading the type checker and codegen will lean on.
fn eval(e: Expr, env: mp.Map<string, int>) -> Result<int, string> {
    match e {
        case Num(n) {
            return Ok(n)
        }
        case Var(name) {
            match env.get(name) {
                case Some(v) {
                    return Ok(v)
                }
                case None {
                    return Err("unknown variable: {name}")
                }
            }
        }
        case Neg(inner) {
            let v = eval(inner.value, env)?
            return Ok(0 - v)
        }
        case Bin(op, left, right) {
            let a = eval(left.value, env)?
            let b = eval(right.value, env)?
            match op {
                case OpAdd {
                    return Ok(a + b)
                }
                case OpSub {
                    return Ok(a - b)
                }
                case OpMul {
                    return Ok(a * b)
                }
                case OpDiv {
                    if b == 0 {
                        return Err("division by zero")
                    }
                    return Ok(a / b)
                }
            }
        }
        case Sum(args) {
            var total = 0
            var i = 0
            loop {
                if i >= args.len() {
                    break
                }
                let v = eval(args[i], env)?
                total = total + v
                i = i + 1
            }
            return Ok(total)
        }
    }
}


// run is the end-to-end driver: parse then evaluate, rendering either the integer or the error so both
// success and failure paths print deterministically.
fn run(src: string, env: mp.Map<string, int>) -> string {
    match parse(src) {
        case Err(msg) {
            return "error: {msg}"
        }
        case Ok(tree) {
            match eval(tree, env) {
                case Ok(v) {
                    return "{v}"
                }
                case Err(msg) {
                    return "error: {msg}"
                }
            }
        }
    }
}


// check asserts a computed result against its expected value. A mismatch returns Err, which — because
// main returns Result — exits the program non-zero (a Fault on the VM), so the harness scores it FAIL.
// This is what gives the differential an oracle at Stage A: VM == native proves the two backends AGREE,
// and these checks prove they agree on the RIGHT answer, not a shared-wrong one. The expected values are
// independently hand-derived, not blessed from compiler output.
fn check(label: string, got: string, want: string) -> Result<int, string> {
    if got != want {
        return Err("CHECK FAILED [{label}]: expected ({want}) got ({got})")
    }
    return Ok(0)
}


// deep_minus builds a string of `n` leading '-' followed by 'x' — input that drives the parser's unary
// recursion past its depth guard, exercising the guard branch (and proving it fires identically on both
// backends rather than letting the VM overflow its frame cap).
fn deep_minus(n: int) -> string {
    var s = ""
    var i = 0
    loop {
        if i >= n {
            break
        }
        s = s + "-"
        i = i + 1
    }
    return s + "x"
}


fn main() -> Result<int, string> {
    var env = mp.Map<string, int>{ buckets: [], count: 0 }
    env.set("x", 10)
    env.set("y", 3)
    env.set("width", 8)

    let r0 = run("1 + 2 * 3", env)                  // precedence: 7
    println(r0)
    let _ = check("precedence", r0, "7")?
    let r1 = run("(1 + 2) * 3", env)                // grouping: 9
    println(r1)
    let _ = check("grouping", r1, "9")?
    let r2 = run("-x + 2 * y", env)                 // variables + unary: -4
    println(r2)
    let _ = check("var+unary", r2, "-4")?
    let r3 = run("100 / (y - 3)", env)              // divide-by-zero
    println(r3)
    let _ = check("div-zero", r3, "error: division by zero")?
    let r4 = run("sum(1, 2, 3, x, y)", env)         // n-ary [Expr]: 19
    println(r4)
    let _ = check("n-ary sum", r4, "19")?
    let r5 = run("sum()", env)                      // empty n-ary: 0
    println(r5)
    let _ = check("empty sum", r5, "0")?
    let r6 = run("width * width - sum(x, y)", env)  // mixed: 51
    println(r6)
    let _ = check("mixed", r6, "51")?
    let r7 = run("x + z", env)                      // unknown variable
    println(r7)
    let _ = check("unknown var", r7, "error: unknown variable: z")?
    let r8 = run("2 +", env)                        // parse error
    println(r8)
    let _ = check("parse error", r8, "error: expected a number, name, '-' or '('")?
    let r9 = run("--x", env)                        // double negation: 10
    println(r9)
    let _ = check("double neg", r9, "10")?
    let rd = run(deep_minus(150), env)              // past the depth-100 guard
    println(rd)
    let _ = check("depth guard", rd, "error: expression nested too deeply")?

    println("selfhost calc: OK")
    return Ok(0)
}
