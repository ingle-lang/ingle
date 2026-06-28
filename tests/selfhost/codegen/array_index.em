// M4 codegen fixture: reading an array ELEMENT via OP_INDEX, typed by the array's element kind (per-slot
// element tracking). A string-bearing struct element materialises a fresh BOXED struct (dropped at exit);
// an all-scalar struct element INDEX+UNBOX_STRUCTs into multi-slot (no drop); a string element INDEX+INCREFs
// into an owned binding; a scalar element is plain. A direct `arr[i].field` reads via GET_FIELD_OWNED.

struct Tok {
    kind: int
    text: string
}


struct Pt {
    x: int
    y: int
}


fn first_kind(ts: [Tok]) -> int {
    let t = ts[0]               // INDEX -> boxed Tok (string-bearing) ; DROP at exit
    return t.kind + t.text.len()
}


fn direct_text_len(ts: [Tok]) -> int {
    return ts[0].text.len()     // INDEX ; GET_FIELD_OWNED (owning temp)
}


fn pt_sum(ps: [Pt]) -> int {
    let p = ps[0]               // INDEX ; UNBOX_STRUCT (all-scalar) -> multi-slot, no drop
    return p.x + p.y
}


fn pick(names: [string], i: int) -> int {
    let s = names[i]            // INDEX ; INCREF -> owned string, DROP at exit
    return s.len()
}


fn nth(xs: [int], i: int) -> int {
    let n = xs[i]               // INDEX -> plain scalar
    return n
}


fn main() -> int {
    var ts: [Tok] = []
    ts.append(Tok { kind: 3, text: "ab" })
    var ps: [Pt] = []
    ps.append(Pt { x: 4, y: 5 })
    let names = ["x", "yy"]
    let xs = [10, 20]
    return first_kind(ts) + direct_text_len(ts) + pt_sum(ps) + pick(names, 1) + nth(xs, 0)
}
