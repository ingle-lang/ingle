// generic_nested.ig — nested instantiation Box<Box<int>>; chained field access.
struct Box<T> { value: T }
fn main() -> int {
    let b = Box<Box<int>> { value: Box<int> { value: 7 } }
    return b.value.value
}
