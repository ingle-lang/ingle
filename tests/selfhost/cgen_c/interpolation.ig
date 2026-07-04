// M5n fixture for the self-hosted C-emit backend: STRING INTERPOLATION — the single biggest remaining
// feature and what the parser/checker/codegen lean on hardest (their whole ast_print is `"…{expr}…"`, 206
// sites). An interpolated string LEFT-FOLDS em_add (string concat) over its parts: a literal run is an
// interned cached `em_str`, and a hole `{expr}` is `em_to_string(&g_em, <expr>, 0)` — a fresh owned string
// (the hole value is BORROWED); each part is an owned temp the em_add consumes. Holes may be an ident, a
// struct field, an array index, or an arithmetic expression, and holes may be adjacent (`{a}{b}`).
// Byte-identical to stage-0 `inglec --emit=c` (gated, Stage 6 of make selfhost).
struct Point {
    x: int
    label: string
}


fn describe(p: Point, xs: [int]) -> string {
    return "Point({p.x}, {p.label}) head={xs[0]} sum={p.x + xs[0]}"
}


fn pair(a: int, b: string) -> string {
    return "{a}{b}"
}


fn greet(name: string, n: int) -> string {
    return "hello {name}, you are #{n}!"
}


fn itoa(n: int) -> string {
    return "{n}"
}


fn bracket(n: int) -> string {
    // a hole that is a string-returning CALL (an owning temp) is concatenated DIRECTLY (no em_to_string);
    // a string BINDING hole goes through em_to_string.
    let inner = itoa(n)
    return "[{itoa(n)}] = [{inner}]"
}


fn main() -> int {
    let p = Point{x: 7, label: "origin"}
    let xs = [10, 20, 30]
    let d = describe(p, xs)
    let g = greet("ada", 1)
    let pr = pair(3, "!")
    let br = bracket(42)
    return d.len() + g.len() + pr.len() + br.len()
}
