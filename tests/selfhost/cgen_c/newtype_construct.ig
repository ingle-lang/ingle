// tests/selfhost/cgen_c/newtype_construct.ig — newtype CONSTRUCTION in the self-hosted C-emit (OFI-202,
// un-dodged). A `type Name = Base [where …]` value is constructed with `Name(x)` at ZERO runtime cost: it
// erases to its base value. Stage-0 `--emit=c` emits `UserId(7)` as the bare `INT_VAL(7)`, with NO predicate
// check even for a refined `where` type — so the self-hosted C-emit lowers `Name(arg)` to just the argument
// (emit_call recognises a DType name via build_newtypes). Byte-identical to stage-0 (both backends emit the
// base value). Returns 7 + 500 + 50 = 557.
type UserId = int
type Money = int


fn fee(m: Money) -> Money {
    return m
}


fn main() -> int {
    let u = UserId(7)
    let m = fee(Money(500))
    let p = Pct(50)                       // a refined newtype constructs the same — erased, no check
    return int(u) + int(m) + int(p)
}
type Pct = int where 0 <= self && self <= 100
