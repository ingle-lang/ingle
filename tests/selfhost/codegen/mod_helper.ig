// imported by mod_main.ig. Constructs its OWN enum variants (valid in-module) behind constructor functions,
// so the importer can obtain Token values via a module-qualified call.
enum Token {
    TNum(v: int)
    TPlus
    TEnd
}


fn make_num(v: int) -> Token {
    return TNum(v)
}


fn plus() -> Token {
    return TPlus
}
