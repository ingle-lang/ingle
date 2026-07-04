// M4 codegen fixture: an interpolation hole is re-lexed standalone, so its expression must be re-based onto
// the enclosing string's source line — otherwise the hole's operands land on line 1 and the bytecode line
// column diverges. The holes below sit on lines 7+ and contain binary expressions whose operand line must
// match the string, not 1.

fn render(a: int, b: int, name: string) -> string {
    let header = "name={name}"
    let sum = "sum={a + b}"
    let mixed = "both {a * b} and {a - b}"
    return header + sum + mixed
}


fn main() -> int {
    let s = render(3, 4, "ok")
    return s.len()
}
