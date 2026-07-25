// tests/selfhost/cgen_c_run/inferred_struct_array.ig — element-struct inference from an array LITERAL in the
// self-hosted C-emit (OFI-202/OFI-173, un-dodged). `var arr = [P{…}, …]` with NO `[Struct]` annotation: the
// element struct sid is now inferred from the first element (value_elem_struct's EArray case), so `arr[i].x`
// and `let e = arr[i]; e.x` resolve exactly as the annotated `var arr: [P]` path — previously both tripped the
// "unsupported field access `.x`" hole. Runtime-diff (native == VM), not byte-identical: a direct `arr[i].field`
// unbox names its struct temp `vN` where stage-0 uses `rN` — a pre-existing cosmetic naming convention only.


struct P {
    x: int
    y: int
}


fn main() {
    var arr = [P { x: 1, y: 2 }, P { x: 3, y: 4 }]     // inferred [P] — no annotation
    arr.append(P { x: 5, y: 6 })
    let first = arr[0]                                   // bind-then-read: an element copy
    let direct = arr[1].x + arr[2].y                     // direct arr[i].field
    println("first={first.x},{first.y} direct={direct} len={arr.len()}")   // first=1,2 direct=9 len=3
}
