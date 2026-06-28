// Native backend differential test for the byte_slice(s, start, end) builtin (added for the
// self-hosted lexer — exact, byte-indexed lexemes). The harness runs this on the VM and as a compiled
// binary and requires identical stdout. byte_slice returns the RAW bytes [start, end) of s, byte-indexed
// (not code-point), so multi-byte UTF-8 is preserved exactly and out-of-range bounds clamp.

fn main() -> int {
    let s = "ab café λ z"          // bytes: a b _ c a f é(2) _ λ(2) _ z  => 13 bytes, 11 code points
    let n = s.len()
    let empty = ""

    println("byte_len={n} char_count={s.char_count()}")     // byte_len=13 char_count=11
    println(byte_slice(s, 0, 2))                             // ab
    println(byte_slice(s, 3, 8))                             // café (é is 2 bytes: [3,8) = 5 bytes)
    println("roundtrip={byte_slice(s, 0, n) == s}")          // true
    println("empty={byte_slice(s, 5, 4) == empty}")          // start>end -> empty -> true
    println("clamp_hi={byte_slice(s, 0, 9999) == s}")        // end clamps to len -> true
    println("clamp_lo={byte_slice(s, 0 - 5, 2)}")            // start clamps to 0 -> ab

    // Reassemble the whole string one byte at a time — proves every single-byte slice is faithful and
    // concatenating them reproduces the original (including the multi-byte sequences split mid-character).
    var parts: [string] = []
    var i = 0
    loop {
        if i >= n {
            break
        }
        parts.append(byte_slice(s, i, i + 1))
        i = i + 1
    }
    println("byte_reassemble={concat(parts) == s}")          // true
    return 0
}
