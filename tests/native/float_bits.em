// Native backend differential test for float_bits(f: float) -> int — the raw IEEE-754 bits of an f64
// reinterpreted bit-for-bit as an i64 (no numeric conversion). Added for the self-hosted bytecode
// serializer, which writes a float constant's 8 bytes to the .emb container. The harness runs this on the
// VM and as a compiled binary and requires identical stdout, so the bit pattern must match on both.

fn main() -> int {
    println("half={float_bits(0.5)}")        // 0.5  = 0x3FE0000000000000
    println("one={float_bits(1.0)}")         // 1.0  = 0x3FF0000000000000
    println("onehalf={float_bits(1.5)}")     // 1.5  = 0x3FF8000000000000
    println("two={float_bits(2.0)}")         // 2.0  = 0x4000000000000000
    println("zero={float_bits(0.0)}")        // 0.0  = 0
    println("neg={float_bits(0.0 - 1.0)}")   // -1.0 = 0xBFF0000000000000 (a negative i64)
    // Round-trip is monotonic for positive values: bits(1.0) < bits(1.5) < bits(2.0).
    println("ordered={float_bits(1.0) < float_bits(1.5) && float_bits(1.5) < float_bits(2.0)}")
    return 0
}
