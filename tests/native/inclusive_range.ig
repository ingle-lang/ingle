// inclusive_range.ig — the `..=` INCLUSIVE range: `lo..=hi` includes `hi`, where the exclusive `lo..hi`
// stops before it. It needs no new lexer token (`..=` lexes as `..` then `=`) and desugars in the parser
// to `lo..(hi + 1)`, so for-range loops and slices need no other change. A P5-era feature added by editing
// the Ingle-written compiler (selfhost/lexer.ig + parser.ig) and rebuilt through `make bootstrap`.
fn main() -> int {
    var incl = 0
    for i in 0..=3 {          // 4 iterations: 0, 1, 2, 3
        incl += 1
    }
    var excl = 0
    for i in 0..3 {           // 3 iterations: 0, 1, 2
        excl += 1
    }
    var sum = 0
    for i in 1..=5 {          // 1 + 2 + 3 + 4 + 5
        sum += i
    }
    return incl * 1000 + excl * 100 + sum   // 4000 + 300 + 15 = 4315
}
