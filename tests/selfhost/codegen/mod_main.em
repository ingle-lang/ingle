// imports mod_helper.em: matches its enum cross-module (variant tags resolve against the imported Token's
// declaration order) and calls an imported function (a module-qualified CALL).
import "mod_helper" as h


fn eval(t: h.Token) -> int {
    match t {
        case TNum(v) { return v }
        case TPlus { return 0 - 1 }
        case TEnd { return 0 }
    }
}


fn main() -> int {
    return eval(h.make_num(7)) + eval(h.plus())
}
