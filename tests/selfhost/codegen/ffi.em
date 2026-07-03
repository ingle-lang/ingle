// M4 codegen fixture: `extern "c"` FFI dispatch. A call to a declared extern lowers to CALL_C <registry
// index> <op> (op = 65535 for a non-struct return), NOT a normal CALL — the registry index comes from
// cextern_index (locked to src/cextern.c g_sigs' default-build order). Extern args are BORROWED (no INCREF,
// no adopt); a fresh owning-temp object arg (a string literal) is kept + PICK'd + DROP_UNDER'd. An extern's
// DECLARED return type drives a `let r = strncmp(...)` binding's render/num width (i32 vs i64 are both 'i' in
// the ABI, only the declaration distinguishes). to_int/to_float are the int<->float reinterpret ops
// (FLOAT_TO_INT / INT_TO_FLOAT), distinct from a width CONV. Covers the scalar (libm) and string externs;
// Ptr/buffer/move externs (fopen/fwrite/fclose) are a separate ownership sub-feature.
extern "c" {
    fn sin(x: f64) -> f64
    fn cos(x: f64) -> f64
    fn hypot(a: f64, b: f64) -> f64
    fn strlen(s: string) -> i64
    fn strncmp(a: string, b: string, n: i64) -> i32
}


fn main() -> int {
    let s = sin(0.0)                              // 0.0
    let c = cos(0.0)                              // 1.0
    let h = hypot(3.0, 4.0)                       // 5.0
    println("trig = {s + c + h}")                 // f64 render (9): 6
    let a = "hello, ember"
    let n = strlen(a)                             // 12 (i64 -> render 0)
    println("len = {n}")
    let eq = strncmp("ember", "embers", i64(5))   // 0 (i32 -> render 3)
    println("eq = {eq}")
    if eq < 0 {
        println("neg")
    }
    // int<->float reinterpret ops
    let scaled = to_int(h * 2.0)                  // 10
    println("scaled = {scaled}")
    return int(n) + int(eq) + scaled              // 12 + 0 + 10 = 22
}
