// tests/selfhost/file_io.ig — Stage A self-hosting spike (docs/design/self-hosting.md §2 capability row
// "Read a file in, write a file out"; §4 Stage 1, whose lexer driver `read_file`s its input).
//
// The other Stage A spikes are pure computation; none touches the filesystem. But the self-hosted lexer's
// literal entry point is `read_file(path) -> source`, so the read-a-file-in / write-a-file-out
// prerequisite needs its own both-backends proof. This spike writes a source-like blob, reads it back,
// and confirms the round-trip is byte-exact and that the UTF-8 byte/char-length ops a lexer relies on
// behave identically on the VM and the native binary — then scans the bytes the way a lexer would.
//
// Determinism: the content written is fixed, so any two runs (VM then native) write identical bytes to
// the same path — a collision is harmless. read_file returns "" on error; we write first, so it exists.

// _count_digits scans a string's code points and counts ASCII digits — the innermost loop of a lexer's
// number rule, run here over file content that came back off disk. char_code returns the first byte of a
// code point, so a multi-byte char (é) is never miscounted as a digit.
fn _count_digits(s: string) -> int {
    let cs = s.chars()
    var n = 0
    var i = 0
    loop {
        if i >= cs.len() {
            break
        }
        let k = char_code(cs[i])
        if k >= 48 && k <= 57 {
            n = n + 1
        }
        i = i + 1
    }
    return n
}


// check_i / check_b assert against expected values; a mismatch returns Err and exits non-zero (a Fault on
// the VM) so the harness scores it FAIL — the oracle the VM==native differential lacks on its own.
fn check_i(label: string, got: int, want: int) -> Result<int, string> {
    if got != want {
        return Err("CHECK FAILED [{label}]: expected {want} got {got}")
    }
    return Ok(0)
}


fn check_b(label: string, got: bool) -> Result<int, string> {
    if got == false {
        return Err("CHECK FAILED [{label}]: expected true")
    }
    return Ok(0)
}


fn main() -> Result<int, string> {
    let path = "/tmp/ember_selfhost_fileio.txt"
    // A source-like blob: ASCII tokens plus a multi-byte UTF-8 line so byte length and char count differ.
    let content = "let x = 42\nlet y = 7\n// note: café\n"

    write_file(path, content)
    let back = read_file(path)

    let matched = back == content
    println("round-trip = {matched}")
    let _ = check_b("round-trip", matched)?

    // "café" makes byte length exceed code-point count by exactly the one 2-byte é.
    let bytes = back.len()
    let chars = back.char_count()
    println("bytes = {bytes}, chars = {chars}")
    let _ = check_i("byte length", bytes, 36)?
    let _ = check_i("char count", chars, 35)?

    // Lexer-shaped scan over the round-tripped content: the digits of 42 and 7.
    let digits = _count_digits(back)
    println("digit code points = {digits}")
    let _ = check_i("digit scan", digits, 3)?

    println("selfhost file_io: OK")
    return Ok(0)
}
