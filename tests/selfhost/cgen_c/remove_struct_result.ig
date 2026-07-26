// tests/selfhost/cgen_c/remove_struct_result.ig — return-typing of an array-element-returning builtin in
// the self-hosted C-emit (OFI-173, un-dodged). `let c = cv.remove_at(i)` / `cv.remove_last()` binds a VALUE
// struct ELEMENT out of the array; the C-emit now resolves the result's struct sid from the array's element
// struct (struct_sid_any's remove_at/remove_last/pop case → array_elem_struct_of), so `c.title` / `c.n`
// resolve exactly as `let c = cv[i]` does — previously both tripped the "unsupported field access" hole
// because a builtin return carried no type. Byte-identical to stage-0 (the checker-typed backend gets the
// same element type). Prints popped=z/3 mid=x/1 left=1.
struct Conv {
    title: string
    n: int
}


fn main() -> int {
    var cv: [Conv] = []
    cv.append(Conv { title: "x", n: 1 })
    cv.append(Conv { title: "y", n: 2 })
    cv.append(Conv { title: "z", n: 3 })
    let popped = cv.remove_last()              // a value-struct element out of remove_last
    let mid = cv.remove_at(0)                  // ...and out of remove_at
    println("popped={popped.title}/{popped.n} mid={mid.title}/{mid.n} left={cv.len()}")
    return 0
}
