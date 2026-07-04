// stdlib_string.ig — the string standard library, now a real file under std/ and
// pulled in with `import` (trim/to_upper/to_lower/contains/index_of/starts_with/repeat).
import "std/string" as str
fn main() -> int {
    let t = str.trim("  Ingle Lang  ")
    println("[{t}]")
    println(str.to_upper(t))
    println(str.to_lower(t))
    println(str.repeat("ab", 3))
    var n = 0
    if str.contains(t, "Lang")     { n = n + 1 }
    if str.starts_with(t, "Ingle") { n = n + 1 }
    if str.index_of(t, "Lang") == 6 { n = n + 1 }
    println("checks={n}")                       // 3
    return t.len() + n                          // "Ingle Lang"=10, +3 = 13
}
