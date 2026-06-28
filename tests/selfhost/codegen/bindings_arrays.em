// M4 codegen fixture: match-binding payload classification + array element-kind discipline. Exercises the
// refcount/layout rules a `case V(x)` binding and an array element must follow, all of which the self-hosted
// backend re-derives without a checker:
//   - a STRING payload binding INCREFs when returned (it borrows the scrutinee's field);
//   - a STRUCT payload binding resolves `.field`;
//   - an ARRAY payload binding resolves `[i]`, and an enum element read INCREFs (-4 element code);
//   - `obj.arr[i].field` — indexing a struct FIELD array, then a field read off the (boxed) element;
//   - an array field value takes the FIELD's element kind: an empty `[]` and a single `[x]` of a boxed
//     (enum/struct) element are AEK_BOXED (0), not the context-free int default.

struct Node {
    name: string
    kids: [Tok]
}


struct Tok {
    text: string
    kind: int
}


enum Item {
    IStr(s: string)
    INode(n: Node)
    IList(xs: [Tok])
    IEnum(inner: Color)
}


enum Color {
    Red
    Green
}


fn item_str(it: Item) -> string {
    match it {
        case IStr(s) {
            return s                              // string binding: INCREF before the scrutinee drops
        }
        case INode(n) {
            return n.name                         // struct binding: resolve `.name`
        }
        case IList(xs) {
            if xs.len() > 0 {
                return xs[0].text                 // array binding: `xs[0]` then `.text`
            }
            return "empty"
        }
        case IEnum(inner) {
            return color_str(inner)               // enum binding: passed by value (refcounted)
        }
    }
}


fn color_str(c: Color) -> string {
    match c {
        case Red {
            return "red"
        }
        case Green {
            return "green"
        }
    }
}


fn first_kid_kind(n: Node) -> int {
    if n.kids.len() > 0 {
        return n.kids[0].kind                     // obj.arr[i].field — index a struct FIELD array, then read
    }
    return 0 - 1
}


fn main() -> int {
    let empty = Node { name: "root", kids: [] }   // empty array field value -> AEK_BOXED (0), not int
    var one = Node { name: "leaf", kids: [] }
    one.kids.append(Tok { text: "x", kind: 7 })   // build a struct-element array by append (parser.em's idiom)
    let a = item_str(IStr("hi")).len()
    let b = item_str(INode(empty)).len()
    let c = first_kid_kind(one)
    return a + b + c
}
