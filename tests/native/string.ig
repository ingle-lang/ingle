// Native backend (M2) differential test: strings (boxed, refcounted, immutable).
// Literals, concatenation (+), interpolation, println output, == comparison, and .len(),
// plus a string param and return.

fn greet(name: string) -> string {
    return "Hello, " + name + "!"
}

fn main() -> int {
    let who = "Ingle"
    let msg = greet(who)
    println(msg)
    println("len = {msg.len()}")
    let n = 42
    println("the answer is {n}")
    if msg == "Hello, Ingle!" {
        println("match ok")
    }
    return msg.len()
}
