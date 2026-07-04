// string_param.ig — strings as parameters and return values.
fn greet(name: string) -> string {
    return "Hi " + name
}
fn main() -> string {
    return greet("Karl")
}
