// M5o fixture for the self-hosted C-emit backend: ARRAY enum-payloads + refcounted array-element ownership
// (parser tail — the AST has `[Expr]` / `[Stmt]` / `[Field]` payloads). A `case V(xs)` binding of an ARRAY
// payload field is tracked as an array (is_arr + element scalar kind via EnumTab.pf_array / pf_elem), so
// `xs.len()` → em_array_len and `xs[i]` types correctly; a REFCOUNTED (non-scalar: string / enum / struct)
// array-ELEMENT read `arr[i]` passed to a call is MOVED in (own_into_slot the em_index clone), while a
// scalar element is passed as-is. Byte-identical to stage-0 `emberc --emit=c` (gated, Stage 6 of make
// selfhost).
struct Tok {
    kind: int
    text: string
}


enum Node {
    Leaf(n: int)
    List(items: [int])
    Toks(ts: [Tok])
}


fn describe(nd: Node) -> int {
    match nd {
        case Leaf(n) {
            return n
        }
        case List(items) {
            var t = 0
            var i = 0
            loop {
                if i >= items.len() {
                    break
                }
                t = t + items[i]
                i = i + 1
            }
            return t
        }
        case Toks(ts) {
            return ts.len()
        }
    }
    return 0
}


fn kind_at(ts: [Tok], i: int) -> int {
    let e = ts[i]
    return e.kind
}


fn main() -> int {
    var ts: [Tok] = []
    ts.append(Tok{kind: 2, text: "a"})
    let k = kind_at(ts, 0)
    return describe(List([3, 4, 5])) + describe(Leaf(9)) + describe(Toks(ts)) + k
}
