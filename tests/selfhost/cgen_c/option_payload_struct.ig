// tests/selfhost/cgen_c/option_payload_struct.ig — return-typing of an Option/Result CONCRETE-struct payload in
// the self-hosted C-emit (OFI-173, un-dodged). A plain `match o { case Some(v) }` where the scrutinee `o` is a
// LOCAL or PARAM typed Option<Struct>/Result<Struct,_> now tracks v's struct: the payload's concrete base sid is
// recorded on the binding (sc_opt_payload, via option_payload_concrete_sid at the let/param push), and
// match_payload_sid's new EIdent arm reads it — so `v.field` resolves. Previously both tripped the "unsupported
// field access" hole (match_payload_sid had only ECall(EGet) / EIndex arms). A GENERIC-INSTANCE payload
// (Option<Box<int>>) is deliberately NOT tracked (its type-param field needs category-C substitution, deferred).
// Byte-identical to stage-0. Returns 7 + 5 = 12.
struct Item {
    name: string
    n: int
}


fn item_n(o: Option<Item>) -> int {          // PARAM scrutinee
    match o {
        case Some(it) {
            return it.n
        }
        case None {
            return 0 - 1
        }
    }
}


fn main() -> int {
    let o: Option<Item> = Some(Item { name: "a", n: 7 })    // LOCAL scrutinee
    var total = 0
    match o {
        case Some(it) {
            total = it.n
        }
        case None {
        }
    }
    return total + item_n(Some(Item { name: "b", n: 5 }))
}
