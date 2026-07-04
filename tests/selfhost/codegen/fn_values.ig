// M4 codegen fixture: first-class FUNCTION VALUES (zero-capture closures). A named function used as a VALUE
// (passed as an arg, stored in a `let`, returned) lowers to MAKE_CLOSURE <fn index> 0 — a closure with no
// captures. A call whose callee is a fn-typed LOCAL/param (or a call-expression that yields a fn value)
// lowers to CALL_CLOSURE <argc>, NOT a direct CALL. A fn-value binding is a refcounted closure -> a droppable
// slot. (Lambdas with capture build on this.)
fn double(x: int) -> int {
    return x * 2
}


fn inc(x: int) -> int {
    return x + 1
}


fn apply(f: fn(int) -> int, x: int) -> int {
    return f(x)                        // f is a fn-typed param -> CALL_CLOSURE
}


fn pick(up: bool) -> fn(int) -> int {
    if up {
        return inc                     // a named fn as a returned value -> MAKE_CLOSURE inc 0
    }
    return double
}


fn main() -> int {
    let g = double                     // a fn value in a local -> droppable closure
    let a = apply(double, 5)           // 10  (double passed as a value)
    let b = apply(inc, 5)              // 6
    let c = g(7)                       // 14  (call a fn-value local)
    let d = pick(true)(9)              // 10  (call the returned fn value)
    println("{a + b + c + d}")         // 10 + 6 + 14 + 10 = 40
    return 0
}
