// M4 codegen fixture: numeric width conversions (int(x)/i32(x)/u8(x)) lower to CONV <target-kind>, NOT a
// user CALL. Crossing int<->float is to_int/to_float (not covered here — integer widths only).

fn widen(b: u8) -> int {
    return int(b)
}


fn narrow(n: int) -> int {
    let small = u8(n)
    let mid = i32(n)
    return int(small) + int(mid)
}


fn main() -> int {
    var total = 0
    for i in 0..5 {
        total = total + narrow(i) + widen(u8(i))
    }
    return total
}
