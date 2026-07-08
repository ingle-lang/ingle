// Compound assignment operators (OFI-184): `+= -= *= /= %= &= |= ^=` desugar to
// `place = place <op> rhs`. Exercised on locals, struct fields, array elements, and
// floats — both backends must agree (differential-tested by the codegen/native stages).

struct Counter {
    n: int
}

fn main() {
    // Arithmetic compound assignment on a local.
    var x = 10
    x += 5
    x -= 3
    x *= 2
    x /= 4
    x %= 5
    println(x)          // ((((10+5-3)*2)/4)%5) = 1

    // Bitwise compound assignment.
    var flags = 0
    flags |= 5
    flags &= 6
    flags ^= 1
    println(flags)      // ((0|5)&6)^1 = 5

    // Through a struct field.
    var c = Counter { n: 100 }
    c.n += 23
    c.n *= 2
    println(c.n)        // 246

    // Through an array element (indexed by a variable and a literal).
    var arr = [1, 2, 3]
    var i = 1
    arr[i] += 40
    arr[0] *= 7
    println(arr[0])     // 7
    println(arr[1])     // 42

    // Floats.
    var f = 2.5
    f += 0.5
    f *= 3.0
    println(f)          // 9
}
