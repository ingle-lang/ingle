// C-emit OFI-220 un-dodged (OFI-218 Phase 4): storing an enum-payload ARRAY into a var (`ks = kids` from a
// `case Branch(kids, ..)`) must own_into_slot it — a borrowed array read into a new owner is CLONED (arrays
// are unique-owner), the enum keeps its own reference (stage-0's moves_local==2). The self-hosted C-emit
// previously stored it as-is (a shared array with one refcount → a double-free on drop), which broke the
// reproduction fixed point and forced a helper-based dodge in hof_srcs_of. Byte-identical both backends.
enum Node {
    Branch(kids: [int], tag: int)
    Leaf
}
fn sum_kids(n: Node) -> int {
    var ks: [int] = []
    match n {
        case Branch(kids, tag) {
            ks = kids                 // enum-payload array -> var (own_into_slot / clone)
        }
        case Leaf {
        }
    }
    var s = 0
    var i = 0
    loop {
        if i >= ks.len() {
            break
        }
        s = s + ks[i]
        i = i + 1
    }
    return s
}
fn main() -> int {
    return sum_kids(Branch([3, 4, 5], 1))   // 12
}
