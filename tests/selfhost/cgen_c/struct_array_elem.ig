// M5j fixture for the self-hosted C-emit backend: STRUCT-ARRAY-ELEMENT typing (a lexer/parser hot path —
// they iterate arrays of AST-node / token structs). Reading an element of a `[Struct]` array, `let e =
// arr[i]`, retains the em_index result into an OWNED boxed-struct local (`({ Value vN = em_index(…); if
// (IS_OBJ(vN)) OBJ_RETAIN(…); vN; })`, dropped at scope exit); `e.field` then resolves as a boxed-struct
// field read (em_enum_field), and `arr[i].field` directly likewise. The element struct sid is tracked per
// binding (sc_elem_struct) from the `[Struct]` annotation on a param or a `var xs: [Struct] = []` local.
// Byte-identical to stage-0 `inglec --emit=c` (gated, Stage 6 of make selfhost).
struct Tok {
    kind: int
    text: string
}


fn sum_kinds(ts: [Tok]) -> int {
    var t = 0
    var i = 0
    loop {
        if i >= ts.len() {
            break
        }
        let e = ts[i]
        t = t + e.kind
        i = i + 1
    }
    return t
}


fn first_kind(ts: [Tok]) -> int {
    if ts.len() > 0 {
        let e = ts[0]
        return e.kind
    }
    return 0 - 1
}


fn main() -> int {
    var ts: [Tok] = []
    ts.append(Tok{kind: 3, text: "a"})
    ts.append(Tok{kind: 7, text: "bb"})
    return sum_kinds(ts) + first_kind(ts)
}
