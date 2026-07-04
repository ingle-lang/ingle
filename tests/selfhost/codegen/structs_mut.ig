// M4d mutable-struct fixture: a `var` (mutated) struct is BOXED even when all-scalar (so a field can be
// assigned) — construction is NEW_STRUCT, `p.f = v` is GET_LOCAL+<value>+SET_FIELD, `p.f` is GET_FIELD.
struct P {
    x: int
    y: int
}


struct Tok {
    kind: int
    text: string
}


fn update() -> int {
    var p = P { x: 1, y: 2 }
    p.x = 9
    p.y = 8
    return p.x + p.y
}


fn retag(s: string) -> int {
    var tk = Tok { kind: 0, text: "a" }
    tk.text = s
    tk.kind = 5
    return tk.kind
}


fn count(times: int) -> int {
    var c = P { x: 0, y: 0 }
    var i = 0
    loop {
        if i >= times {
            break
        }
        c.x = c.x + 1
        i = i + 1
    }
    return c.x
}
