// M4b codegen fixture: sized-int / float SCALAR KINDS must reach the WRAP_*/binary num_kind operand AND the
// TO_STRING render kind. A sized LITERAL carries its iN/uN width on the EInt node (int_suffix_kind); a CALL
// carries its declared return width (fn_ret_kind) — a wrapping intrinsic preserves its first operand's width.
// Without these the operand defaults to int=0, diverging from stage-0. Because --emit=bytecode does NOT print
// the string pool AND the TO_STRING/WRAP operands ARE in the disassembly, cgdiff catches the operand kinds;
// but this fixture also rides the Stage 8 .igb byte-identity (same guard class as contracts.ig).

fn fnv1a(s: string) -> u32 {
    var h: u32 = 2166136261u32
    let bytes = s.chars()
    var i = 0
    loop {
        if i == bytes.len() {
            break
        }
        let b = u32(char_code(bytes[i]))
        h = wrapping_mul(h ^ b, 16777619u32)
        i = i + 1
    }
    return h
}


fn half_u16(n: u16) -> u16 {
    return n / 2u16
}


fn main() -> int {
    // sized wrapping LITERALS -> WRAP_* <width>, and in a hole -> TO_STRING <width>
    println("add_u8={wrapping_add(200u8, 100u8)}")
    println("mul_u16={wrapping_mul(1000u16, 1000u16)}")
    println("add_i8={wrapping_add(100i8, 100i8)}")
    // a user fn returning a sized type in a hole -> TO_STRING <fn_ret_kind>
    println("hash={fnv1a("hello")}")
    println("half={half_u16(9u16)}")
    // a regular sized binary carries its operand width too
    let q: u16 = 40000u16
    println("sub={q - 30000u16}")
    // a float hole renders f64=9
    let pi = 3.5
    println("pi={pi}")
    return 0
}
