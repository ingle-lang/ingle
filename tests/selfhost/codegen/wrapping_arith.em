// M4 codegen fixture: built-in wrapping arithmetic (OFI-041). `wrapping_add/sub/mul(a, b)` are NOT user
// calls — they lower inline to the dedicated WRAP_ADD/WRAP_SUB/WRAP_MUL opcodes, each carrying the operand
// width kind (int=0). This is exactly how parser.em's parse_int_lit folds digits (u64-wrap like stage-0).

fn fold(text: string) -> int {
    var v = 0
    var i = 0
    loop {
        if i >= 10 {
            break
        }
        v = wrapping_add(wrapping_mul(v, 10), i)
        i = i + 1
    }
    return wrapping_sub(v, 1)
}


fn main() -> int {
    return fold("x")
}
