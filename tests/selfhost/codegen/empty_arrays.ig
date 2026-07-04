// M4 codegen fixture: an empty array literal `[]` carries no element to infer its runtime ArrayElemKind
// from, so the kind must come from the declared `[T]` annotation — `[string]`/struct -> boxed (0),
// `[bool]` -> 11, `[f64]` -> 10, the sized ints -> their AEK, not the int default (4).

fn main() -> int {
    var ints: [int] = []
    var strs: [string] = []
    var flags: [bool] = []
    var reals: [f64] = []
    var bytes: [u8] = []
    ints.append(1)
    strs.append("x")
    flags.append(true)
    reals.append(1.5)
    bytes.append(7)
    return ints.len() + strs.len() + flags.len() + reals.len() + bytes.len()
}
