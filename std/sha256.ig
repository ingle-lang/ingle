// std/sha256 — SHA-256 in pure Ingle (FIPS 180-4). Content addressing for Quog and anything else
// that needs a stable, collision-resistant id for a byte sequence. No runtime change: the whole
// algorithm is 32-bit modular arithmetic (`wrapping_add`) over the width-aware bitwise operators —
// exactly the shape the manifesto notes a hash takes. `hash` returns the 32 raw digest bytes;
// render them as a text id with `std/encoding.to_hex`.


// _rotr rotates a 32-bit word right by n bits. Every SHA-256 use has 1 <= n <= 31, so neither
// shift is by 0 or 32 (both would be out of the [0, width) range the shift operators require).
fn _rotr(x: u32, n: int) -> u32 {
    return (x >> n) | (x << (32 - n))
}


// digest computes the SHA-256 of `data`, returning the 32 result bytes (H0..H7, big-endian).
// (Named `digest`, not `hash`, because `hash` is the built-in FNV-1a `hash(string) -> int`.)
fn digest(data: [u8]) -> [u8] {
    // Round constants K: first 32 bits of the fractional parts of the cube roots of the first 64 primes.
    let k: [u32] = [
        0x428a2f98u32, 0x71374491u32, 0xb5c0fbcfu32, 0xe9b5dba5u32, 0x3956c25bu32, 0x59f111f1u32, 0x923f82a4u32, 0xab1c5ed5u32,
        0xd807aa98u32, 0x12835b01u32, 0x243185beu32, 0x550c7dc3u32, 0x72be5d74u32, 0x80deb1feu32, 0x9bdc06a7u32, 0xc19bf174u32,
        0xe49b69c1u32, 0xefbe4786u32, 0x0fc19dc6u32, 0x240ca1ccu32, 0x2de92c6fu32, 0x4a7484aau32, 0x5cb0a9dcu32, 0x76f988dau32,
        0x983e5152u32, 0xa831c66du32, 0xb00327c8u32, 0xbf597fc7u32, 0xc6e00bf3u32, 0xd5a79147u32, 0x06ca6351u32, 0x14292967u32,
        0x27b70a85u32, 0x2e1b2138u32, 0x4d2c6dfcu32, 0x53380d13u32, 0x650a7354u32, 0x766a0abbu32, 0x81c2c92eu32, 0x92722c85u32,
        0xa2bfe8a1u32, 0xa81a664bu32, 0xc24b8b70u32, 0xc76c51a3u32, 0xd192e819u32, 0xd6990624u32, 0xf40e3585u32, 0x106aa070u32,
        0x19a4c116u32, 0x1e376c08u32, 0x2748774cu32, 0x34b0bcb5u32, 0x391c0cb3u32, 0x4ed8aa4au32, 0x5b9cca4fu32, 0x682e6ff3u32,
        0x748f82eeu32, 0x78a5636fu32, 0x84c87814u32, 0x8cc70208u32, 0x90befffau32, 0xa4506cebu32, 0xbef9a3f7u32, 0xc67178f2u32,
    ]

    // Pad: append 0x80, then zero bytes until the length is 56 (mod 64), then the 64-bit big-endian
    // bit length. Copy into a fresh array so the caller's `data` is never mutated.
    var msg: [u8] = []
    var p = 0
    loop {
        if p == data.len() {
            break
        }
        msg.append(data[p])
        p = p + 1
    }
    let bitlen = data.len() * 8
    msg.append(128u8)                                    // 0x80
    loop {
        if msg.len() % 64 == 56 {
            break
        }
        msg.append(0u8)
    }
    var lj = 7
    loop {
        if lj < 0 {
            break
        }
        msg.append(u8((bitlen >> (8 * lj)) & 255))
        lj = lj - 1
    }

    // Initial hash values H: first 32 bits of the fractional parts of the square roots of the first 8 primes.
    var h0: u32 = 0x6a09e667u32
    var h1: u32 = 0xbb67ae85u32
    var h2: u32 = 0x3c6ef372u32
    var h3: u32 = 0xa54ff53au32
    var h4: u32 = 0x510e527fu32
    var h5: u32 = 0x9b05688cu32
    var h6: u32 = 0x1f83d9abu32
    var h7: u32 = 0x5be0cd19u32

    // Process each 64-byte chunk.
    var base = 0
    loop {
        if base == msg.len() {
            break
        }
        // Message schedule w[0..63]: the first 16 words are the chunk's big-endian u32s.
        var w: [u32] = []
        var t = 0
        loop {
            if t == 16 {
                break
            }
            let o = base + t * 4
            w.append((u32(msg[o]) << 24) | (u32(msg[o + 1]) << 16) | (u32(msg[o + 2]) << 8) | u32(msg[o + 3]))
            t = t + 1
        }
        loop {
            if t == 64 {
                break
            }
            let s0 = _rotr(w[t - 15], 7) ^ _rotr(w[t - 15], 18) ^ (w[t - 15] >> 3)
            let s1 = _rotr(w[t - 2], 17) ^ _rotr(w[t - 2], 19) ^ (w[t - 2] >> 10)
            w.append(wrapping_add(wrapping_add(w[t - 16], s0), wrapping_add(w[t - 7], s1)))
            t = t + 1
        }

        // Compression.
        var a = h0
        var b = h1
        var c = h2
        var d = h3
        var e = h4
        var f = h5
        var g = h6
        var hh = h7
        var i = 0
        loop {
            if i == 64 {
                break
            }
            let big1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25)
            let ch = (e & f) ^ ((~e) & g)
            let temp1 = wrapping_add(wrapping_add(hh, big1), wrapping_add(ch, wrapping_add(k[i], w[i])))
            let big0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22)
            let maj = (a & b) ^ (a & c) ^ (b & c)
            let temp2 = wrapping_add(big0, maj)
            hh = g
            g = f
            f = e
            e = wrapping_add(d, temp1)
            d = c
            c = b
            b = a
            a = wrapping_add(temp1, temp2)
            i = i + 1
        }
        h0 = wrapping_add(h0, a)
        h1 = wrapping_add(h1, b)
        h2 = wrapping_add(h2, c)
        h3 = wrapping_add(h3, d)
        h4 = wrapping_add(h4, e)
        h5 = wrapping_add(h5, f)
        h6 = wrapping_add(h6, g)
        h7 = wrapping_add(h7, hh)
        base = base + 64
    }

    // Serialize H0..H7 big-endian into the 32-byte digest.
    let hs: [u32] = [h0, h1, h2, h3, h4, h5, h6, h7]
    var out: [u8] = []
    var wi = 0
    loop {
        if wi == 8 {
            break
        }
        let word = hs[wi]
        out.append(u8((word >> 24) & 255u32))
        out.append(u8((word >> 16) & 255u32))
        out.append(u8((word >> 8) & 255u32))
        out.append(u8(word & 255u32))
        wi = wi + 1
    }
    return out
}


// digest_str is the convenience for hashing a string's UTF-8 bytes — the common case for text content.
fn digest_str(s: string) -> [u8] {
    return digest(s.bytes())
}
