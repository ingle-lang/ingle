// C-emit erased-generic OWNERSHIP precision (OFI-176 / OFI-218 Phase 4). Three checker-stamped decisions the
// self-hosted C-emit re-derives locally so it stays byte-identical to src/cgen_c.c on generic higher-order code:
//   F1  a fresh STRING temp passed to an erased generic-T BORROW param (x: T) is caller-dropped (drop_mask) —
//       the call is staged (hoist every arg, drop the string temp) — unlike a concrete `string` param (moved).
//   F2  an OWNED erased type-param LOCAL (`var acc = init`) MOVES on a whole-value consume (nil its slot),
//       not own_into_slot — stage-0's moves_local==1.
//   F3  a `[T]`-returning generic call's element resolves to the determining `[T]` arg's element scalar kind,
//       so indexing it in a consuming op is a plain borrow (no spurious own_into_slot).
fn twice_g<T>(f: fn(T) -> T, x: T) -> T { return f(f(x)) }
fn foldl<T, U>(xs: [T], init: U, g: fn(U, T) -> U) -> U {
    var acc = init
    var i = 0
    loop {
        if i == xs.len() { break }
        acc = g(acc, xs[i])
        i = i + 1
    }
    return acc
}
fn dup<T>(xs: [T]) -> [T] {
    var out: [T] = []
    var i = 0
    loop {
        if i == xs.len() { break }
        out.append(xs[i])
        i = i + 1
    }
    return out
}
fn main() -> int {
    let nums = [3, 4, 5]
    let shout = twice_g(|s| s + "!", "hi")       // F1: string temp "hi" -> T param -> "hi!!"
    let total = foldl(nums, 0, |a, x| a + x)      // F2: owned type-param accumulator -> 12
    let d = dup(nums)                             // F3: [T] return, element = int
    return total + d[0] + d[1] + shout.len()      // 12 + 3 + 4 + 4 = 23
}
