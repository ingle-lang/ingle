// M5b fixture for the self-hosted C-emit backend: strings + the ownership/drop discipline. Exercises an
// interned string literal (the cached static + retain), a string concatenation `+` (em_add — the owned
// operand MOVES via own_into_slot, a borrowed one retains), an owned string param (dropped at every exit),
// a string-returning call bound to an owned `let`, a `println` builtin call statement, and the
// return-scope wrapping (own the value, drop the owned locals, return). Byte-identical to stage-0
// `inglec --emit=c` (gated, Stage 6 of `make selfhost`).
fn greet(name: string) -> string {
    return "hi " + name
}


fn shout(msg: string) -> string {
    let loud = msg + "!"
    return loud
}


fn main() -> int {
    let g = greet("bob")
    println(g)
    let s = shout(g)
    println(s)
    return 0
}
