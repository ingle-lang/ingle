// M5e.1b fixture for the self-hosted C-emit backend: VALUE-struct PARAMS, RETURNS, and METHODS. A value-
// struct parameter is `em_s<sid> a<i>` (passed by value); a value-struct return is a `em_s<sid>` C return
// type; the em_invoke dispatcher unboxes each struct param slot (em_unbox_struct) and boxes a struct result
// (em_box_struct). A method call `recv.m(args)` lowers to `em_fn_<K>(recv, args…)` with self as arg 0
// (resolved via the `Struct.method` name); a method's `self` is the borrowed receiver, so a `self.field`
// read in a CONSUMING op (`+`, `==`, `!=`) is retained (a by-value param / let field is an owned copy and
// is NOT retained); a scalar-returning method bound to a `let` types as a scalar. Byte-identical to stage-0
// `inglec --emit=c` (gated, Stage 6 of make selfhost). Chained / call-result method receivers (a struct
// TEMP receiver, needing materialisation), field WRITE, and mut/move self are later increments.
struct Vec {
    x: int
    y: int

    fn norm1(self) -> int {
        return self.x + self.y
    }

    fn dot(self, o: Vec) -> int {
        return self.x * o.x + self.y * o.y
    }

    fn scaled(self, k: int) -> Vec {
        return Vec{x: self.x * k, y: self.y * k}
    }

    fn shifted(self, dx: int, dy: int) -> Vec {
        return Vec{x: self.x + dx, y: self.y + dy}
    }
}


fn make(a: int, b: int) -> Vec {
    return Vec{x: a, y: b}
}


fn sum_of(v: Vec) -> int {
    return v.x + v.y
}


fn main() -> int {
    let u = make(2, 3)
    let w = Vec{x: 4, y: 5}
    let s = u.scaled(3)
    let t = u.shifted(1, 1)
    let n = u.norm1()
    let d = u.dot(w)
    return n + d + s.norm1() + t.norm1() + sum_of(u) + sum_of(w)
}
