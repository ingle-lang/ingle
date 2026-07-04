// M5e.1a fixture for the self-hosted C-emit backend: VALUE-TYPE structs (recursively all-scalar → a real
// C `em_s<sid>` struct, value semantics, no drop). Exercises the struct table + typedef preamble + the
// runtime packed-layout metadata (`em_sN_off/knd/fst[]` + the `em_structs[]` StructType table), struct
// construction as a C compound literal `((em_s<sid>){ … })` in DECLARED field order, struct-typed `let`
// bindings (stored as the C em_s aggregate), scalar field reads `p.f` (a direct C member access) in
// arithmetic and in a bool condition, sized-int / bool fields (a PACKED metadata layout, no alignment
// padding), multiple structs, and NESTED value structs (a value-struct field is stored inline as `em_s<m>
// f<i>`, read via a C member chain `v.f0.f1`). Each struct is built and read WITHIN a function (value-
// struct params / returns / methods, field WRITE, and float fields are later increments). Byte-identical
// to stage-0 `inglec --emit=c` (gated, Stage 6 of make selfhost).
struct Point {
    x: int
    y: int
}


struct Line {
    a: Point
    b: Point
}


struct Header {
    tag: i8
    size: i32
    flag: bool
    len: int
}


fn point_sum(a: int, b: int) -> int {
    let p = Point{x: a, y: b}
    return p.x + p.y
}


fn manhattan(x1: int, y1: int, x2: int, y2: int) -> int {
    let ln = Line{a: Point{x: x1, y: y1}, b: Point{x: x2, y: y2}}
    var d = 0
    d = d + ln.a.x + ln.a.y
    d = d + ln.b.x + ln.b.y
    return d
}


fn payload(on: bool, n: int) -> int {
    let h = Header{tag: 1, size: 2, flag: on, len: n}
    if h.flag {
        return h.len
    }
    return 0
}


fn main() -> int {
    let p = Point{x: 3, y: 4}
    let ln = Line{a: Point{x: 1, y: 2}, b: p}
    let flat = p.x + p.y
    let nested = ln.a.x + ln.b.y
    return flat + nested + point_sum(5, 6) + manhattan(1, 2, 3, 4) + payload(true, 40)
}
