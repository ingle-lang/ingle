// Native backend differential test (OFI-155): in-place mutation of a value-struct FIELD of a non-flat
// (heap-bearing) struct. The harness runs this on the VM and as a compiled binary and requires identical
// stdout. Before the fix the native backend either failed to compile (`n.span.col = …` emitted a
// statement-expression rvalue as an lvalue) or silently wrote garbage (`n.span = Span{…}` stored a boxed
// pointer into an inline slot). Both are fixed: the runtime's em_set_field now overwrites an inline
// struct field like the VM's OP_SET_FIELD, and cgen lowers a leaf assign through a boxed parent to a
// read-modify-writeback (unbox the inline field, set the leaf, re-box, store back).

struct Span {
    line: int
    col: int
}


struct Node {
    name: string          // makes Node non-flat -> boxed, so `span` is stored as an inline field
    span: Span
}


struct Inner {
    x: int
    y: int
}


struct FlatOuter {
    a: Inner              // all-scalar -> FlatOuter is itself a value struct (addressable C lvalue path)
    b: Inner
}


// bump mutates an inline field through `self` (a boxed receiver) — the checker-shaped case.
struct Counter {
    label: string
    span: Span

    fn bump(mut self) {
        self.span.col = self.span.col + 10
        self.span.line = self.span.line + 1
    }
}


fn main() -> int {
    // 1. Leaf assign through a boxed local parent (the original repro).
    var n = Node{ name: "x", span: Span{ line: 1, col: 5 } }
    n.span.col = n.span.col + 1
    println("leaf: line={n.span.line} col={n.span.col}")          // line=1 col=6

    // 2. Whole value-struct field assign (was silent garbage on native).
    n.span = Span{ line: 99, col: 8 }
    println("whole: line={n.span.line} col={n.span.col}")         // line=99 col=8

    // 3. Several sequential mutations interleaved with reads of the same field.
    var m = Node{ name: "y", span: Span{ line: 1, col: 1 } }
    m.span.col = 5
    m.span.line = 7
    m.span.col = m.span.col + m.span.line
    println("seq: line={m.span.line} col={m.span.col}")           // line=7 col=12

    // 4. Mutation through `self` inside a mut-self method.
    var c = Counter{ label: "c", span: Span{ line: 2, col: 3 } }
    c.bump()
    c.bump()
    println("self: line={c.span.line} col={c.span.col}")          // line=4 col=23

    // 5. The addressable path (a flat value-struct local) must still mutate in place directly.
    var f = FlatOuter{ a: Inner{ x: 1, y: 2 }, b: Inner{ x: 3, y: 4 } }
    f.a.x = 99
    f.b.y = f.a.x + f.b.x
    println("flat: a.x={f.a.x} a.y={f.a.y} b.x={f.b.x} b.y={f.b.y}")  // a.x=99 a.y=2 b.x=3 b.y=102

    // 6. WHOLE value-struct field assign on the addressable (flat) path — the field's C slot is an
    //    em_s, so the raw struct value is assigned (a literal, then a field-read source).
    var g = FlatOuter{ a: Inner{ x: 1, y: 1 }, b: Inner{ x: 2, y: 2 } }
    g.b = Inner{ x: 7, y: 8 }            // literal RHS
    g.a = g.b                            // field-read RHS (value copy)
    g.a.x = g.a.x + 100                  // mutate the copy; g.b must be unaffected
    println("flatw: a.x={g.a.x} a.y={g.a.y} b.x={g.b.x} b.y={g.b.y}")  // a.x=107 a.y=8 b.x=7 b.y=8
    return 0
}
