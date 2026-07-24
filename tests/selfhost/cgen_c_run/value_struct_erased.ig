// tests/selfhost/cgen_c_run/value_struct_erased.ig — value structs crossing ERASED Value slots.
//
// The self-hosted C-emit ERASES where stage-0 monomorphises, so a VALUE struct (a real C `em_s`) that crosses
// an erased boundary — an enum payload, a boxed-struct field, an array element — is BOXED into a heap Value on
// the way in (em_box_struct) and UNBOXED back to an em_s on the way out (em_unbox_struct). Its emitted C is
// therefore NOT byte-identical to stage-0's monomorphised form, so this lives in cgen_c_run (a runtime diff:
// the self-hosted native binary must print the SAME as the bytecode VM), not the byte-identity fixture set.
// Every construct here compiled to `<Value>.fN` (a member access on a Value — a C error) or silently mis-read
// before OFI-218's box/unbox fixes. Point is a value struct (all-scalar); Container is boxed (a string field).


struct Point {
    x: int
    y: int
}


struct Container {
    inner: Point
    tag: int
}


struct Poly {
    pts: [Point]
    name: string
}


enum Shape {
    Dot(p: Point)
    Seg(a: Point, b: Point)
}


// enum payload READ: `case Dot(p) { p.x }` — the boxed payload is unboxed into an em_s.
fn shape_sum(s: Shape) -> int {
    match s {
        case Dot(p) {
            return p.x + p.y
        }
        case Seg(a, b) {
            return a.x + b.y
        }
    }
}


fn main() {
    // enum payload construction (box) + read (unbox)
    println("{shape_sum(Dot(Point { x: 5, y: 9 }))}")           // 14
    println("{shape_sum(Seg(Point { x: 1, y: 2 }, Point { x: 3, y: 4 }))}")   // 1 + 4 = 5

    // boxed-struct INLINE value-struct field: build-then-place construction + em_enum_field/unbox read
    let c = Container { inner: Point { x: 7, y: 8 }, tag: 100 }
    println("{c.inner.x}")                                      // 7
    println("{c.inner.y}")                                      // 8
    println("{c.tag}")                                          // 100

    // value-struct ARRAY element read through a tracked `[Point]` struct field: em_index materialise + unbox
    let poly = Poly { pts: [Point { x: 10, y: 20 }, Point { x: 30, y: 40 }], name: "tri" }
    println("{poly.pts[0].x}")                                  // 10
    println("{poly.pts[1].y}")                                  // 40

    // plain value-struct local (regression — a direct em_s, no unbox)
    let p = Point { x: 42, y: 43 }
    println("{p.x}")                                            // 42
}
