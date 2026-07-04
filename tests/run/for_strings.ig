// for_strings.ig — arrays of any element type; iterate and concatenate.
fn main() -> string {
    let words = ["Hello", ", ", "Ingle"]
    var out = ""
    for w in words {
        out = out + w
    }
    return out
}
