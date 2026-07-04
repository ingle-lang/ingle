// M4d move-discipline fixture: consuming an OWNED move-type local (an array or boxed struct `let`/`var`) —
// by returning it, or storing it into a struct field / array element — MOVES it: the value goes to the
// consumer and the slot is zeroed (CONST 0; SET_LOCAL; POP), so the function-exit DROP of that slot is a
// harmless no-op. A local only READ (a field/index/len) is NOT moved and is still dropped normally.
struct Wrap {
    items: [int]
}


struct Node {
    name: string
    kids: [int]
}


fn ret_array(n: int) -> [int] {
    var xs = [n, n]
    return xs
}


fn into_field(n: int) -> Wrap {
    let xs = [n, n]
    return Wrap { items: xs }
}


fn into_struct(s: string, n: int) -> Node {
    let ks = [n]
    return Node { name: s, kids: ks }
}


fn conditional(c: bool, n: int) -> [int] {
    var a = [n]
    var b = [n, n]
    if c {
        return a
    }
    return b
}


fn read_not_moved(n: int) -> int {
    let xs = [n, n, n]
    return xs.len()
}
