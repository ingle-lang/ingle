// M4a scalar-codegen differential fixture: pure-scalar Ingle (int/bool arithmetic, locals, user-fn calls,
// returns) whose self-hosted bytecode must be byte-identical to stage-0 `--emit=bytecode`. Grows as M4
// coverage grows. (Lives under a subdir so the Stage-A `tests/selfhost/*.ig` glob does not run it.)
fn inc(x: int) -> int {
    return x + 1
}


fn diff(a: int, b: int) -> int {
    return a - b
}


fn chain(n: int) -> int {
    let a = n * 2
    let b = a + n
    let c = b - 1
    return c * a
}


fn precedence() -> int {
    return 2 + 3 * 4 - (5 - 1)
}


fn nested() -> int {
    return inc(diff(10, 3)) + chain(4)
}


fn compare(x: int) -> bool {
    return x > 0
}
