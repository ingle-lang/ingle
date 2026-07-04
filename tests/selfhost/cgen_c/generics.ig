// M5l fixture for the self-hosted C-emit backend: GENERIC-STRUCT MONOMORPHIZATION (`Box<T>`) — the big
// feature the parser/checker/codegen need (the AST is built from `Box<Expr>` / `Box<Ty>` / `Box<Stmt>`). A
// generic struct gets ONE runtime struct id per distinct instantiation USED, numbered after the declared
// structs (id = declared_count + index) and collected in stage-0's order (a PRE-ORDER walk of every body,
// registering each `Box<X>{…}` construction the first time it is seen — InstColl). Each instance's C type
// ALIASES the generic base (`typedef em_s<base> em_s<inst>;`) and, for a BOXED type argument (an enum /
// struct — all the compiler uses), its metadata equals the base's (the wrapped value is a boxed Value); a
// `Box<X>{…}` construction is `em_struct(&g_em, <inst>, <fcount>, …)` with the instance id; `box.value` /
// `box.line` resolve through the base's field table (base_of), and a `Box<X>`-returning call / param is
// tracked (sid_of_ty). Byte-identical to stage-0 `inglec --emit=c` (gated, Stage 6 of make selfhost).
// (A SCALAR type argument like Box<int> — packed, not erased — is not used by the compiler and is deferred.)
struct Box<T> {
    value: T
    line: int
}


enum Node {
    Leaf(n: int)
    Branch(a: Box<Node>, b: Box<Node>)
}


fn wrap(nd: Node) -> Box<Node> {
    return Box<Node>{value: nd, line: 7}
}


fn node_tag(nd: Node) -> int {
    match nd {
        case Leaf(n) { return 1 }
        case Branch(a, b) { return 2 }
    }
    return 0
}


fn line_of(b: Box<Node>) -> int {
    return b.line
}


fn main() -> int {
    let bn = Box<Node>{value: Leaf(5), line: 3}
    let w = wrap(Leaf(9))
    return bn.line + w.line + line_of(bn) + node_tag(Leaf(1))
}
