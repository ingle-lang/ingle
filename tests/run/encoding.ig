// encoding.ig — locks std/encoding: hex + base64 encode/decode over known vectors and round-trips.
import "std/encoding" as enc

fn bytes_of(vals: [int]) -> [u8] {
    var out: [u8] = []
    var i = 0
    loop {
        if i == vals.len() {
            break
        }
        out.append(u8(vals[i]))
        i = i + 1
    }
    return out
}

fn main() -> int {
    // hex encode: 0x00 0x0f 0x10 0xff 0xab
    let b = bytes_of([0, 15, 16, 255, 171])
    println("hex={enc.to_hex(b)}")                              // 000f10ffab
    match enc.from_hex("000f10ffab") {
        case Ok(r) { println("hex_rt={r.len()}:{r[0]}:{r[4]}") } // 5:0:171
        case Err(e) { println("hex_err={e}") }
    }
    match enc.from_hex("0f0") {
        case Ok(r) { println("odd_ok={r.len()}") }
        case Err(e) { println("odd={e}") }                      // odd number of digits
    }

    // base64 encode (RFC 4648 vectors)
    println("b64_M={enc.to_base64("M".bytes())}")               // TQ==
    println("b64_Ma={enc.to_base64("Ma".bytes())}")             // TWE=
    println("b64_Man={enc.to_base64("Man".bytes())}")           // TWFu
    println("b64_hello={enc.to_base64("hello".bytes())}")       // aGVsbG8=

    // base64 decode round-trip
    match enc.from_base64("aGVsbG8gd29ybGQ=") {
        case Ok(r) { println("b64_rt={from_bytes(r)}") }        // hello world
        case Err(e) { println("b64_err={e}") }
    }
    return 0
}
