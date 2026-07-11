// std/encoding — hex and base64 text codecs for binary data (OFI-191). Pure Ingle, no runtime
// change: raw bytes in, ASCII text out (and back). A content-addressed store renders a digest as
// text with `to_hex`; a wire/JSON payload that must carry arbitrary bytes uses `to_base64`. Both
// round-trip losslessly — `from_hex(to_hex(b))` and `from_base64(to_base64(b))` return `Ok(b)`.


// _hex_digit maps a nibble (0–15) to its lowercase ASCII hex byte ('0'–'9', 'a'–'f').
fn _hex_digit(v: u8) -> u8 {
    if v < 10u8 {
        return 48u8 + v          // '0'..'9'
    }
    return 87u8 + v              // 'a'..'f'  (97 - 10 = 87)
}


// to_hex renders bytes as a lowercase hex string, two characters per byte (the canonical form for
// a SHA-256 content id). Building a byte array and converting once avoids O(n²) string concatenation.
fn to_hex(bytes: [u8]) -> string {
    var out: [u8] = []
    var i = 0
    loop {
        if i == bytes.len() {
            break
        }
        let b = bytes[i]
        out.append(_hex_digit(b >> 4))
        out.append(_hex_digit(b & 15u8))
        i = i + 1
    }
    return from_bytes(out)
}


// _hex_val returns the 0–15 value of a hex digit byte, or -1 if it is not one (upper or lower case).
fn _hex_val(c: u8) -> int {
    if c >= 48u8 && c <= 57u8 {
        return i64(c) - 48       // '0'..'9'
    }
    if c >= 97u8 && c <= 102u8 {
        return i64(c) - 87       // 'a'..'f'
    }
    if c >= 65u8 && c <= 70u8 {
        return i64(c) - 55       // 'A'..'F'
    }
    return -1
}


// from_hex parses a hex string back to bytes. Errs on an odd length or any non-hex character, so a
// malformed content id fails loudly rather than decoding to silent garbage.
fn from_hex(s: string) -> Result<[u8], string> {
    let src = s.bytes()
    if src.len() % 2 != 0 {
        return Err("hex: odd number of digits")
    }
    var out: [u8] = []
    var i = 0
    loop {
        if i == src.len() {
            break
        }
        let hi = _hex_val(src[i])
        let lo = _hex_val(src[i + 1])
        if hi < 0 || lo < 0 {
            return Err("hex: invalid digit")
        }
        out.append(u8(hi * 16 + lo))
        i = i + 2
    }
    return Ok(out)
}


// _b64_char maps a 6-bit value (0–63) to its standard-alphabet base64 byte (A–Z a–z 0–9 + /).
fn _b64_char(v: int) -> u8 {
    if v < 26 {
        return u8(65 + v)        // 'A'..'Z'
    }
    if v < 52 {
        return u8(97 + v - 26)   // 'a'..'z'
    }
    if v < 62 {
        return u8(48 + v - 52)   // '0'..'9'
    }
    if v == 62 {
        return 43u8              // '+'
    }
    return 47u8                  // '/'
}


// to_base64 encodes bytes as standard base64 with '=' padding — three input bytes become four output
// characters, the final group padded so the length is always a multiple of four.
fn to_base64(bytes: [u8]) -> string {
    var out: [u8] = []
    let n = bytes.len()
    var i = 0
    loop {
        if i >= n {
            break
        }
        let rem = n - i                          // input bytes left in this group (1, 2, or 3+)
        var b1 = 0
        var b2 = 0
        if rem > 1 {
            b1 = i64(bytes[i + 1])
        }
        if rem > 2 {
            b2 = i64(bytes[i + 2])
        }
        let triple = (i64(bytes[i]) << 16) | (b1 << 8) | b2
        out.append(_b64_char((triple >> 18) & 63))
        out.append(_b64_char((triple >> 12) & 63))
        if rem > 1 {
            out.append(_b64_char((triple >> 6) & 63))
        } else {
            out.append(61u8)                     // '='
        }
        if rem > 2 {
            out.append(_b64_char(triple & 63))
        } else {
            out.append(61u8)                     // '='
        }
        i = i + 3
    }
    return from_bytes(out)
}


// _b64_val returns the 0–63 value of a base64 character byte, or -1 if it is not in the alphabet.
fn _b64_val(c: u8) -> int {
    if c >= 65u8 && c <= 90u8 {
        return i64(c) - 65       // 'A'..'Z'
    }
    if c >= 97u8 && c <= 122u8 {
        return i64(c) - 71       // 'a'..'z'  (97 - 26 = 71)
    }
    if c >= 48u8 && c <= 57u8 {
        return i64(c) + 4        // '0'..'9'  (52 - 48 = 4)
    }
    if c == 43u8 {
        return 62                // '+'
    }
    if c == 47u8 {
        return 63                // '/'
    }
    return -1
}


// from_base64 decodes standard base64 back to bytes. ASCII whitespace (space, tab, CR, LF) is
// ignored so wrapped payloads decode; '=' ends the data; any other stray character errs.
fn from_base64(s: string) -> Result<[u8], string> {
    let src = s.bytes()
    var out: [u8] = []
    var acc = 0                  // bit accumulator
    var bits = 0                 // valid bits currently in `acc`
    var i = 0
    loop {
        if i == src.len() {
            break
        }
        let c = src[i]
        i = i + 1
        if c == 61u8 {
            break                // '=' padding — the data is complete
        }
        let v = _b64_val(c)
        if v < 0 {
            if c != 10u8 && c != 13u8 && c != 32u8 && c != 9u8 {
                return Err("base64: invalid character")
            }
        } else {
            acc = (acc << 6) | v
            bits = bits + 6
            if bits >= 8 {
                bits = bits - 8
                out.append(u8((acc >> bits) & 255))
            }
        }
    }
    return Ok(out)
}
