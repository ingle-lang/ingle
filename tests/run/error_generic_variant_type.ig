// error_generic_variant_type.ig — Some("s") cannot satisfy Option<int>.
enum Option<T> { Some(value: T)  None }
fn main() -> int {
    let x: Option<int> = Some("s")
    return 0
}
