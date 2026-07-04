// M5c fixture for the self-hosted C-emit backend: control flow. Exercises if / else / else-if chains
// (`em_truthy` conditions), a `loop {}` with `break`, a `for i in lo..hi` range loop, a `for x in xs`
// array loop, an indexed `for (i, x)` loop, `continue`, nested loops, scalar `var` reassignment, and the
// per-block scope discipline. Byte-identical to stage-0 `inglec --emit=c` (gated, Stage 6 of make selfhost).
fn grade(n: int) -> int {
    if n >= 90 {
        return 1
    } else if n >= 50 {
        return 2
    } else {
        return 3
    }
}


fn count_evens(n: int) -> int {
    var c = 0
    var i = 0
    loop {
        if i >= n {
            break
        }
        if i % 2 == 1 {
            i = i + 1
            continue
        }
        c = c + 1
        i = i + 1
    }
    return c
}


fn triangle(n: int) -> int {
    var t = 0
    for i in 0..n {
        for j in 0..i {
            t = t + 1
        }
    }
    return t
}


fn weighted(xs: [int]) -> int {
    var t = 0
    for (i, x) in xs {
        t = t + i * x
    }
    return t
}


fn main() -> int {
    return grade(75) + count_evens(10) + triangle(5)
}
