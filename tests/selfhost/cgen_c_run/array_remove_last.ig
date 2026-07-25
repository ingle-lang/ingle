// tests/selfhost/cgen_c_run/array_remove_last.ig — `arr.remove_last()` in the self-hosted C-emit (OFI-173,
// un-dodged). remove_last removes + RETURNS the last element (em_array_pop, length--), mutating the array IN
// PLACE. A field receiver `self.items.remove_last()` reads the field as a BORROW (em_enum_field returns the
// boxed array as-is, aliasing the heap array), so the shrink sticks with no read-modify-write-back — matching
// stage-0's `em_array_pop(&g_em, em_enum_field(...))`. The popped scalar crosses an erased Value slot (the
// self-hosted emit does not scalar-unbox the return the way the checker-typed stage-0 does — same as the
// existing remove_at), so this is a RUNTIME-diff fixture (native == VM), not byte-identical to stage-0.


struct Stack {
    items: [int]
}


fn drain(mut s: Stack) -> int {
    var total = 0
    loop {
        if s.items.len() == 0 {
            break
        }
        total = total + s.items.remove_last()      // field receiver: em_array_pop on the aliased heap array
    }
    return total
}


fn main() {
    var xs = [10, 20, 30]
    let a = xs.remove_last()                        // 30 — binding receiver, mutate in place
    let b = xs.remove_last()                        // 20
    println("a={a} b={b} left={xs.len()}")          // a=30 b=20 left=1

    var s = Stack { items: [1, 2, 3, 4] }
    println("drain={drain(s)}")                     // 10  (4 + 3 + 2 + 1)
}
