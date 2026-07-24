// tests/selfhost/cgen_c/string_const.ig — module-level STRING constants through the self-hosted C-emit.
//
// A `let NAME = "literal"` at module scope is a folded compile-time constant, like the int TAG_* tags but
// carrying a string value. build_const_tab records it (kinds[i] == 1, svals[i] = the text); every reference —
// bare (`MODEL_OPUS`), module-qualified after merge (`api.MODEL_OPUS`), in a comparison, a `+` concat, or an
// interpolation hole — emits the interned cached-str literal. The hole case treats it as a fresh owning-temp
// (concatenated directly), matching stage-0. Inglenook's anthropic.ig model ids are the real-world driver.
// The self-hosted C output must be byte-identical to stage-0 `--emit=c`.


let MODEL_OPUS = "claude-opus-4-8"
let MODEL_SONNET = "claude-sonnet-5"
let GREETING = "hello"


fn model_for(tier: int) -> string {
    if tier == 0 {
        return MODEL_OPUS
    }
    return MODEL_SONNET
}


fn is_opus(name: string) -> bool {
    return name == MODEL_OPUS
}


fn banner() -> string {
    return GREETING + ", " + MODEL_OPUS
}


fn main() {
    println(model_for(0))
    println(model_for(1))
    println(banner())
    println("{GREETING} from {MODEL_SONNET}")
    if is_opus(MODEL_OPUS) {
        println("matched opus")
    }
    if is_opus(MODEL_SONNET) == false {
        println("sonnet is not opus")
    }
}
