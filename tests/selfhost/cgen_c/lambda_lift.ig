// C-emit lambda lifting (OFI-206): a lambda VALUE through a fn-typed param, with a capture.
fn apply(f: fn(int) -> int, x: int) -> int { return f(x) }
fn main() -> int {
    let n = 10
    let a = apply(|y| y + 1, 5)      // zero-capture lambda
    let b = apply(|z| z * n, 3)      // capturing lambda (n)
    return a + b                      // 6 + 30 = 36
}
