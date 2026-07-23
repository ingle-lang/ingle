// panic_diverges.ig — P5 (the first Ingle-first feature): a `panic(...)` call DIVERGES, so a function
// whose only non-returning path panics still type-checks against its `-> T` return — no `return` is
// needed after the panic. Here the panics are never reached, so it runs clean.
fn require_positive(n: int) -> int {
    if n > 0 {
        return n
    }
    panic("expected a positive number")
}


fn main() -> int {
    println("{require_positive(7)}")
    println("{require_positive(3)}")
    return 0
}
