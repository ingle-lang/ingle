// M4 codegen fixture: a let/var whose initialiser is a same-file CALL returning an OWNED type. The binding
// must be tracked as owned-droppable (array/string/boxed struct) or multi-slot (all-scalar struct return),
// exactly as the checker would — so its `.len()`/field reads dispatch correctly and it is dropped at exit.

struct Pt {
    x: int
    y: int
}


fn make_list() -> [int] {
    var xs: [int] = []
    xs.append(1)
    xs.append(2)
    return xs
}


fn greet() -> string {
    return "hello"
}


fn origin() -> Pt {
    return Pt { x: 0, y: 0 }
}


fn main() -> int {
    var r = make_list()
    r.append(3)
    let s = greet()
    let p = origin()
    return r.len() + s.len() + p.x + p.y
}
