// M4c string differential fixture: literals, concatenation, interpolation, string locals + params, and the
// refcount discipline (INCREF on a consumed borrowed-string-local, DROP every string local at each exit).
fn passthru(p: string) -> string {
    return p
}


fn shout(p: string) -> string {
    return p + "!"
}


fn greet(name: string) -> string {
    let msg = "Hello, " + name + "!"
    return msg
}


fn label(n: int) -> string {
    return "n={n}"
}


fn pair(a: int, b: int) -> string {
    return "({a}, {b})"
}


fn build(s: string) -> string {
    let a = s + "1"
    let b = a + "2"
    let c = b + s
    return c
}


fn discards(p: string) -> int {
    let tag = p + "."
    return 5
}
