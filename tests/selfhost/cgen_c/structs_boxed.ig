// M5e.2 fixture for the self-hosted C-emit backend: BOXED structs — a struct with any heap field (string /
// array / enum) is NOT a C value-type but a heap ObjStruct Value (refcounted, dropped by drop_value). Every
// struct still gets a `typedef struct {…} em_s<sid>;` and a runtime metadata row (a heap field is 16 bytes).
// A boxed struct: construction → `em_struct(&g_em, <sid>, <fcount>, fields…)` (fields in DECLARED order, an
// owned field MOVED in); field read `c.f` → `em_enum_field(&g_em, c, <idx>)` (a BORROW — retained in a
// consuming op); field write `c.f = v` → `em_set_field` (drops the old field, moves the new in); a boxed
// LOCAL is OWNED (dropped at scope exit) but a boxed PARAM is a BORROW (like an array — the owner keeps it);
// a method call `recv.m(args)` → `em_fn_<K>(recv, args…)` with self the borrowed heap Value (so a `mut self`
// mutation via em_set_field reaches the caller's object); `s.arrayfield.len()` / `s.arrayfield[i]` resolve
// through the struct table. Byte-identical to stage-0 `inglec --emit=c` (gated, Stage 6 of make selfhost).
// Owned-field READ escaping a case/return, nested boxed structs, and enum fields are later increments.
struct Lexer {
    src: string
    pos: int
    toks: [int]

    fn advance(mut self) -> int {
        self.pos = self.pos + 1
        return self.pos
    }

    fn remaining(self) -> int {
        return self.toks.len() - self.pos
    }

    fn peek(self, i: int) -> int {
        return self.toks[i]
    }
}


fn new_lexer(s: string) -> Lexer {
    return Lexer{src: s, pos: 0, toks: [10, 20, 30, 40]}
}


fn total(lx: Lexer) -> int {
    var t = 0
    var i = 0
    loop {
        if i >= lx.toks.len() {
            break
        }
        t = t + lx.toks[i]
        i = i + 1
    }
    return t
}


fn main() -> int {
    var lx = new_lexer("source")
    lx.pos = 1
    let a = lx.advance()
    let r = lx.remaining()
    let p = lx.peek(2)
    return a + r + p + total(lx) + lx.pos
}
