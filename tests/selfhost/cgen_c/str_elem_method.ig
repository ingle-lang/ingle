// C-emit: a string method on an indexed array element (xs[i].len()) — the element AEK is inferred (OFI-206 follow-on).
fn main() -> int {
    let xs = ["ab", "cde", "f"]
    return xs[0].len() + xs[1].len() + xs[2].len()   // 2 + 3 + 1 = 6
}
