// Non-decimal integer literals + digit separators (OFI-185): 0x/0b/0o prefixes and `_`
// separators in both integer and float literals, including width-suffixed hex. Both
// backends must agree (differential-tested by the codegen/native stages).

fn main() {
    println(0xFF)           // 255
    println(0xff)           // 255  (case-insensitive)
    println(0b1010)         // 10
    println(0o755)          // 493
    println(0xDEAD_BEEF)    // 3735928559  (separators between hex digits)
    println(1_000_000)      // 1000000
    println(0b1111_0000)    // 240

    // A width-suffixed hex literal keeps its type.
    let mask: u8 = 0xFFu8
    println(mask)           // 255

    // Full-range u64 via hex + separators.
    let big: u64 = 0xFFFF_FFFF_FFFF_FFFF
    println(big)            // 18446744073709551615

    // Float with digit separators.
    println(1_234.567_5)    // 1234.5675 (printed rounded)

    // A long (>64-byte lexeme) underscored float must strip fully, not truncate at the first '_'
    // (guards the arena-buffer strip path; stage-0 and the self-hosted parser must agree).
    println(1_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000_000.0)  // 1e+48

    // A leading zero is NOT octal — plain decimal (avoids the C footgun).
    println(0755)           // 755

    // Hex/binary compose with compound assignment.
    var flags = 0
    flags |= 0x04
    flags |= 0b0001
    println(flags)          // 5
}
