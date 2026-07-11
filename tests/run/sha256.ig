// sha256.ig — locks std/sha256 against the canonical FIPS 180-4 vectors, including a 56-byte
// message whose padding spills into a second 64-byte block.
import "std/sha256" as sha
import "std/encoding" as enc

fn dig(s: string) -> string {
    return enc.to_hex(sha.digest_str(s))
}

fn main() -> int {
    println("empty={dig("")}")
    println("abc={dig("abc")}")
    println("fox={dig("The quick brown fox jumps over the lazy dog")}")
    println("two={dig("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")}")
    return 0
}
