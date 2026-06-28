// M4d boxed-struct fixture: a struct with a refcounted (string) field is BOXED — construction is
// NEW_STRUCT (with INCREF on each string field consumed), `r.field` is GET_LOCAL+GET_FIELD, an owned
// boxed-struct `let` is DROP'd at exit (a struct PARAM is a borrow — not dropped). A string field READ
// that is consumed (returned, concatenated) is INCREF'd, like a string local.
struct Tok {
    kind: int
    text: string
}


struct Rec {
    id: int
    name: string
    age: int
}


fn make(k: int, t: string) -> Tok {
    return Tok { kind: k, text: t }
}


fn kind_of(tk: Tok) -> int {
    return tk.kind
}


fn text_of(tk: Tok) -> string {
    return tk.text
}


fn tagged(tk: Tok) -> string {
    return tk.text + "!"
}


fn name_of(r: Rec) -> string {
    return r.name
}


fn two(k: int) -> int {
    let a = Tok { kind: k, text: "x" }
    let b = Tok { kind: k, text: "y" }
    return a.kind + b.kind
}
