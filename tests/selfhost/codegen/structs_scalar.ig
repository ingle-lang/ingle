// M4d all-scalar (multi-slot) struct fixture: an immutable `let` or plain-param struct whose fields are
// all scalars is exploded onto consecutive stack slots (no boxing, no drops) — construction pushes the
// fields in declaration order, `p.field` is GET_LOCAL(base+index), a struct return is RETURN_STRUCT N.
struct P {
    x: int
    y: int
}


struct V3 {
    a: int
    b: int
    c: int
}


fn make(a: int, b: int) -> P {
    return P { y: b, x: a }
}


fn getx(p: P) -> int {
    return p.x
}


fn dot(u: V3, v: V3) -> int {
    return u.a * v.a + u.b * v.b + u.c * v.c
}


fn midpoint(p: P) -> int {
    let d = p.x + p.y
    return d
}


fn pick(c: bool) -> P {
    if c {
        return P { x: 1, y: 2 }
    }
    return P { x: 3, y: 4 }
}


fn two() -> int {
    let p = P { x: 5, y: 6 }
    let q = P { x: 7, y: 8 }
    return p.x + q.y
}
