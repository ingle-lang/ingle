// C-emit HOF lambda PARAM typing (OFI-206 follow-on): the self-hosted C-emit lifts lambdas globally with no
// checker to stamp their param types, so it recovers each lifted lambda's param typing from its HOF call
// context — the input array's element (map/filter) or an init value. A string param then dispatches `.len()`
// to em_str_len and its owned arg is dropped; a scalar param drives arithmetic; a map's element type is the
// lambda's return, so `lens[i]` reads plain (no own_into_slot). Byte-identical on both backends.
fn map_i(xs: [int], f: fn(int) -> int) -> [int] {
    var out: [int] = []
    var i = 0
    loop { if i == xs.len() { break } out.append(f(xs[i])) i = i + 1 }
    return out
}
fn map_len(xs: [string], f: fn(string) -> int) -> [int] {
    var out: [int] = []
    var i = 0
    loop { if i == xs.len() { break } out.append(f(xs[i])) i = i + 1 }
    return out
}
fn keep(xs: [int], p: fn(int) -> bool) -> [int] {
    var out: [int] = []
    var i = 0
    loop { if i == xs.len() { break } if p(xs[i]) { out.append(xs[i]) } i = i + 1 }
    return out
}
fn main() -> int {
    let nums = [1, 2, 3, 4]
    let words = ["ab", "cde", "f"]
    let base = 10
    let doubled = map_i(nums, |x| x * 2)          // scalar param → [2,4,6,8]
    let shifted = map_i(nums, |x| x + base)       // capturing scalar param → [11,12,13,14]
    let lens = map_len(words, |w| w.len())        // STRING param → .len(); element is int → plain reads
    let big = keep(nums, |x| x > 2)               // scalar param, bool body → [3,4]
    return doubled[3] + shifted[0] + lens[1] + big[0] + big[1]   // 8 + 11 + 3 + 3 + 4 = 29
}
