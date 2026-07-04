// M4 codegen fixture: short-circuit logical operators (&& / || lower to jumps, NOT a binop opcode) and
// top-level `let` constants (inlined as their folded literal at each reference, exactly as stage-0 does).

let LIMIT: int = 10
let GREETING: string = "hi"
let ENABLED: bool = true


fn in_range(x: int) -> bool {
    return x >= 0 && x < LIMIT          // && short-circuit; LIMIT inlined as CONST 10
}


fn classify(x: int) -> int {
    if x < 0 || x >= LIMIT {            // || short-circuit
        return 0 - 1
    }
    if ENABLED && in_range(x) {         // a global bool + a call, short-circuited
        return x
    }
    return 0
}


fn main() -> int {
    var hits = 0
    for i in 0..15 {
        if in_range(i) && i % 2 == 0 {
            hits = hits + classify(i)
        }
    }
    let _ = GREETING                    // a string global inlined as STRING
    return hits
}
