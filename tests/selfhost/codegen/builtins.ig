// M4 codegen fixture: built-in free-function calls lower to CALL_NATIVE (by native id), not a user CALL.
// print/println/write_file drop their owning-temp object args (a fresh string literal/concat) via the
// keep+PICK+DROP_UNDER protocol; the "transform" natives (char_code, hash, …) release their args
// internally, so they pass plain. A native returning an owned object (read_file/args -> string/[string])
// makes its `let` binding droppable.

fn describe(label: string, n: int) -> string {
    return "{label}: {n}"
}


fn main() -> int {
    println("start")                 // owning-temp literal -> masked
    let tag = "tag"
    println(tag)                     // a borrowed local -> plain
    println("a" + tag)               // a fresh concat -> masked
    let code = char_code("Z")        // transform native -> plain; returns int
    let h = hash("Z")
    println(describe("code", code))  // a call result (owning-temp string) -> masked
    return code + h - h
}
