// M5 fixture for the self-hosted C-emit backend: LITERAL patterns (Phase 2a). A `match` on an
// int / string / bool subject lowers each `case <literal>` to `em_truthy(em_eq_op(&g_em, <subject
// retained>, <literal>))` (em_eq_op drops both operands, so the borrowed subject is retained;
// IS_OBJ no-ops it for int/bool), with the `em_tag` header omitted (no variant arm). The self-hosted
// cgen_c must emit this byte-identically to stage-0 `inglec --emit=c`.

fn classify(n: int) -> int {
    match n {
        case 0 { return 100 }
        case 1 { return 101 }
        case -1 { return 99 }
        case _ { return 0 }
    }
}


fn light(cmd: string) -> int {
    match cmd {
        case "go" { return 1 }
        case "stop" { return 2 }
        case _ { return 0 }
    }
}


fn flag(b: bool) -> int {
    match b {
        case true { return 1 }
        case false { return 0 }
    }
}


fn main() -> int {
    return classify(0) + classify(1) + classify(-1) + classify(7) +
        light("go") + light("stop") + light("x") +
        flag(true) + flag(false)
}
