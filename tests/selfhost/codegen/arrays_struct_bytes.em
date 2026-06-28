// M4 codegen fixture: an array of (inline-packable) structs lowers to NEW_STRUCT_ARRAY (not NEW_ARRAY), an
// appended struct literal is built BOXED so ARRAY_APPEND can pack it, and a string's `.bytes()` lowers to
// the STR_BYTES opcode and yields an owned byte array (dropped at scope exit).

struct Tok {
    kind: int
    text: string
}


fn count_bytes(s: string) -> int {
    let bs = s.bytes()          // STR_BYTES -> an owned [u8]; dropped at exit
    return bs.len()
}


fn main() -> int {
    var toks: [Tok] = []        // NEW_STRUCT_ARRAY (Tok has only scalar/string fields)
    toks.append(Tok { kind: 1, text: "a" })
    toks.append(Tok { kind: 2, text: "bb" })
    return toks.len() + count_bytes("hello")
}
