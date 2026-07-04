// M5i fixture for the self-hosted C-emit backend: four more pieces surfaced by dogfooding the lexer —
// (1) struct-element arrays: an empty `[Struct]` is `em_struct_array(&g_em, <sid>, 0)` (append unchanged);
// (2) an owned string/enum struct FIELD passed to a call is MOVED in (`f(own_into_slot(&g_em,
// em_enum_field(…)))`); a scalar field is a borrow; (3) a native runtime builtin →
// `em_native(&g_em, <id>, <argc>, (Value[]){ args })` (byte_slice = id 22, an owned-string result); (4)
// `let x = s.field` of a SCALAR field types as a C scalar (int64_t), not a Value. Byte-identical to stage-0
// `inglec --emit=c` (gated, Stage 6 of make selfhost).
struct Token {
    kind: int
    text: string
}


fn describe(s: string) -> int {
    return s.len()
}


fn first3(s: string) -> string {
    return byte_slice(s, 0, 3)
}


fn tok_weight(t: Token) -> int {
    let k = t.kind
    return describe(t.text) + k
}


fn count(src: string) -> int {
    var ts: [Token] = []
    ts.append(Token{kind: 1, text: first3(src)})
    ts.append(Token{kind: 2, text: "end"})
    return ts.len()
}


fn main() -> int {
    let a = tok_weight(Token{kind: 5, text: "abc"})
    let b = count("hello world")
    let c = describe(first3("xyzzy"))
    return a + b + c
}
