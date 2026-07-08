// M5 fixture for the self-hosted C-emit backend: match GUARDS + scalar VALUE BINDINGS (Phase 2b). A
// match with any guard lowers to a `matched`-flag + independent `if` blocks (guards break the
// if/else-if chain); a `case n` on a scalar binds the subject value (the self-hosted backend classifies
// it as a value binding by the same by-name resolution it uses for tags — a bare name the enum table
// does not resolve). The self-hosted cgen_c must emit this byte-identically to stage-0 `inglec --emit=c`.

enum Box { Val(v: int) Empty }


fn grade(s: int) -> int {
    match s {
        case k if k >= 90 { return 4 }      // value binding + guard; fall through on false
        case k if k >= 80 { return 3 }
        case _            { return 0 }
    }
}


fn describe(b: Box) -> int {
    match b {
        case Val(x) if x > 0 { return 1 }    // variant binding + guard
        case Val(x)          { return 0 }
        case Empty           { return 0 - 1 }
    }
}


fn main() -> int {
    return grade(95) + grade(85) + grade(10) +
        describe(Val(5)) + describe(Val(0 - 2)) + describe(Empty)
}
