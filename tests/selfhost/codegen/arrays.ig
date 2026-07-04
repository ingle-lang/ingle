// M4d array fixture: literal `[..]` is NEW_ARRAY <count> <ArrayElemKind>; `a[i]` is INDEX; `a[i]=v` is
// SET_INDEX; `a.len()` is ARRAY_LEN; `a.append(x)` is ARRAY_APPEND; an owned array `let`/`var` is DROP'd at
// exit (an array param is a borrow — not dropped). (Returning an owned array LOCAL — a move — is deferred.)
fn first(xs: [int]) -> int {
    return xs[0]
}


fn size(xs: [int]) -> int {
    return xs.len()
}


fn at(xs: [int], i: int) -> int {
    return xs[i]
}


fn make() -> [int] {
    return [1, 2, 3]
}


fn sum(xs: [int]) -> int {
    var total = 0
    var i = 0
    loop {
        if i >= xs.len() {
            break
        }
        total = total + xs[i]
        i = i + 1
    }
    return total
}


fn build(n: int) -> int {
    var xs = [0, 0]
    xs[0] = n
    xs.append(n + 1)
    return xs[0] + xs.len()
}
