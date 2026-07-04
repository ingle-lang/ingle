// error_print_as_value.ig — a print has no value; binding it is an error.
fn main() -> int {
    let x = println("hi")
    return x
}
