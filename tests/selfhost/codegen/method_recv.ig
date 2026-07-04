// M4 codegen fixture: a built-in or user method whose RECEIVER is not a bare identifier — a struct field
// (`a.vals.len()`, `t.text.len()`), or a method on a struct-field receiver (`o.inner.mag()`). The receiver
// expression is evaluated, then dispatched by its static type (array/string opcode, or a boxed-struct CALL
// with PICK/DROP_UNDER for the owning temp), exactly as the checker's op flags would direct.

struct Vec {
    x: int
    y: int


    fn mag(self) -> int {
        return self.x + self.y
    }
}


struct Acc {
    vals: [int]
    label: string
    here: Vec
}


fn run(mut a: Acc) -> int {
    a.vals.append(7)
    return a.vals.len() + a.label.len() + a.here.mag()
}


fn main() -> int {
    var a = Acc { vals: [1, 2], label: "hi", here: Vec { x: 3, y: 4 } }
    return run(a)
}
