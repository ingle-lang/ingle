// M5a fixture for the self-hosted C-emit backend (selfhost/cgen_c.em): the int-scalar subset — params,
// scalar `let` bindings (unboxed C int64_t), arithmetic binops (the em_add retain dance + em_mul/em_sub
// direct operands), user-function calls, and re-boxed local reads. The self-hosted C output must be
// byte-identical to stage-0 `emberc --emit=c` (gated, Stage 6 of `make selfhost`).
fn calc(n: int) -> int {
    let a = n * 2 + 1
    let b = a - n
    return a * b - 3
}


fn pick(x: int, y: int) -> int {
    let chosen = x
    return chosen + y
}


fn main() -> int {
    let r = calc(5)
    let m = pick(r, 10)
    return m + r * 2
}
