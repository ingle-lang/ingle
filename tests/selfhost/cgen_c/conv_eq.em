// M5g fixture for the self-hosted C-emit backend: the string `==` / `!=` BORROW rule and numeric
// CONVERSIONS — two pieces surfaced by dogfooding the real lexer through cgen_c.em. (1) `+` CONSUMES its
// operands (an owned operand is moved in via own_into_slot), but `==` / `!=` only COMPARE — so an owned
// operand (a string param compared against many keyword literals, the lexer's hot path) is RETAINED, not
// moved (it is read again in the next comparison). (2) a numeric-width conversion `int(x)` / `i32(x)` /
// `u8(x)` / `f64(x)` → `em_conv(x, <kind>)`, and a `let a = i32(n)` binds a SIZED C scalar (int32_t),
// re-boxed on read. Byte-identical to stage-0 `emberc --emit=c` (gated, Stage 6 of make selfhost).
fn keyword(s: string) -> int {
    if s == "if" {
        return 1
    }
    if s == "else" {
        return 2
    }
    if s == "while" {
        return 3
    }
    if s != "return" {
        return 0
    }
    return 4
}


fn widths(n: int) -> int {
    let a = i32(n)
    let b = u8(n)
    let c = i16(n)
    let d = i8(n)
    return int(a) + int(b) + int(c) + int(d)
}


fn main() -> int {
    let k = keyword("if") + keyword("else") + keyword("return") + keyword("x")
    return k + widths(100)
}
