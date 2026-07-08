// Match guards + scalar value binding (Phase 2b, OFI-186): `case pat if <bool>` fires only when the
// pattern matches AND the guard is true (else control falls through to later arms), and `case n` on a
// scalar subject binds the value. A guarded arm never counts toward exhaustiveness. Both backends must
// agree (differential-tested), and the self-hosted compiler mirrors the same parser + checker.

enum Box { Val(v: int) Empty }


fn grade(s: int) -> string {
    match s {
        case k if k >= 90 { return "A" }      // value binding + guard; fall through on false
        case k if k >= 80 { return "B" }
        case k if k >= 70 { return "C" }
        case _            { return "F" }       // required: guarded arms don't cover
    }
}


fn describe(b: Box) -> string {
    match b {
        case Val(x) if x > 0 { return "positive" }   // variant binding + guard
        case Val(x)          { return "non-positive" }
        case Empty           { return "empty" }
    }
}


fn kind(s: string) -> string {
    match s {
        case "" { return "empty" }
        case t if t == "hi" { return "greeting" }    // string value binding + guard
        case _  { return "other" }
    }
}


fn main() {
    println(grade(95))            // A
    println(grade(85))            // B
    println(grade(72))            // C
    println(grade(40))            // F
    println(describe(Val(5)))     // positive
    println(describe(Val(-2)))    // non-positive
    println(describe(Empty))      // empty
    println(kind(""))             // empty
    println(kind("hi"))           // greeting
    println(kind("yo"))           // other
}
