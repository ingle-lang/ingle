// Literal patterns (Phase 2a, OFI-186): `match` on an int / string / bool subject with `case 0`,
// `case "x"`, `case true`, `case -1`, and `_`. Both backends must agree (differential-tested by the
// codegen/native stages), and the self-hosted compiler mirrors the same lexer/parser/checker.

fn classify(n: int) -> string {
    match n {
        case 0 { return "zero" }
        case 1 { return "one" }
        case -1 { return "neg-one" }
        case _ { return "many" }
    }
}


fn light(cmd: string) -> string {
    match cmd {
        case "go" { return "green" }
        case "stop" { return "red" }
        case _ { return "unknown" }
    }
}


fn main() {
    println(classify(0))       // zero
    println(classify(1))       // one
    println(classify(-1))      // neg-one
    println(classify(42))      // many

    println(light("go"))       // green
    println(light("stop"))     // red
    println(light("wait"))     // unknown

    // A bool match is exhaustive via true + false (no wildcard needed).
    let ready = true
    match ready {
        case true { println("ready") }
        case false { println("waiting") }
    }
}
