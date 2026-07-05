// error_interp_brace.ig — a literal '{' in a string opens an interpolation hole; when the hole's
// contents don't lex as an expression (here, escaped quotes meant as JSON — a classic LLM mistake),
// the compiler points ONE clean error at the '{' with the '\{' hint, at its true location — not a
// phantom "line 1 near '\'" cascade (OFI-181). The hole `\"k\": 1` fails to lex, triggering the guard.
fn main() -> int {
    let s = "json: {\"k\": 1}"
    return s.len()
}
