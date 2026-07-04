// multi-module fixture (top): a DIAMOND (top->mid->base and top->base, base deduped). Exercises a
// cross-module struct-returning call (typed as multi-slot), imported struct field access, an enum-returning
// cross-module call (a droppable enum), and cross-module function calls.
import "mm_mid" as mid
import "mm_base" as base


fn main() -> int {
    let n = mid.mk(7)                          // cross-module struct return -> multi-slot Node
    return mid.mid_name(n.kind) + base.name(base.ka()) + n.id   // imported field + enum-call + cross-call
}
