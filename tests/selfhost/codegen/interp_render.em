// M4 codegen fixture: string-interpolation lowering details the self-hosted backend must reproduce.
//   - the TO_STRING RENDER KIND follows the hole's scalar type — a float renders as f64 (kind 9), a bool as
//     kind 10, an int (and anything else) as 0 (mirrors the checker's render_kind);
//   - an OWNING-TEMP string hole (a call/concat result — `ind(d)`, `a + b`) SKIPS TO_STRING (it already
//     leaves an owned reference the fold's CONCAT consumes; emitting TO_STRING would leak it — stage-0
//     `string_temp`), while a BORROWED string hole (a local) still retains via TO_STRING;
//   - a bare `return` in a void function still pushes the unit value (CONST 0) before RETURN.

fn ind(d: int) -> string {
    var s = ""
    var i = 0
    loop {
        if i >= d {
            break
        }
        s = s + "  "
        i = i + 1
    }
    return s
}


fn show_float(v: float, d: int) {
    println("{ind(d)}Float {v}")          // {ind(d)} = owning-temp string hole (no TO_STRING); {v} = f64 (kind 9)
    if v > 0.0 {
        return                            // bare return in a void fn -> CONST 0; RETURN
    }
    println("done")
}


fn show_flags(name: string, on: bool, n: int) -> string {
    return "{name}={on} ({n})"            // {name} borrowed string (TO_STRING 0); {on} bool (10); {n} int (0)
}


fn main() -> int {
    show_float(3.5, 1)
    let s = show_flags("ready", true, 7)
    return s.len()
}
