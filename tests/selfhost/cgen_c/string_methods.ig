// M5h fixture for the self-hosted C-emit backend: built-in STRING methods (another lexer need surfaced by
// dogfooding). `s.len()` → em_str_len(recv) — note NO ctx arg, unlike the array/ctx helpers; `s.bytes()` →
// em_str_bytes(&g_em, recv), a fresh OWNED [u8] array (so `let bs = s.bytes()` is a dropped array local with
// element scalar kind u8, and `bs.len()` / `bs[i]` resolve); `s.chars()` → [string], `s.split(sep)` →
// [string]. The receiver is a BORROW (read as-is; a temp-receiver drop is a later increment). Byte-identical
// to stage-0 `inglec --emit=c` (gated, Stage 6 of make selfhost).
fn byte_sum(s: string) -> int {
    let bs = s.bytes()
    var t = 0
    var i = 0
    loop {
        if i >= bs.len() {
            break
        }
        t = t + int(bs[i])
        i = i + 1
    }
    return t
}


fn length(s: string) -> int {
    return s.len()
}


fn main() -> int {
    return byte_sum("Ingle") + length("hello world")
}
