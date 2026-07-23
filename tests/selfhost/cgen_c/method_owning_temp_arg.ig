// C-emit OFI-165 un-dodged (OFI-218 Phase 4): a fresh OWNING-TEMP array (an inline `dup(src)` call result)
// passed to a struct METHOD's borrow parameter must be staged — hoist the arg, call with `self` inline, drop
// the temp after — exactly as a free call does. The self-hosted C-emit previously emitted the method call
// inline with no drop (leaking the temp / diverging from stage-0), forcing a named-snapshot dodge in
// selfhost/checker.ig. Byte-identical both backends.
fn dup(xs: [bool]) -> [bool] {
    var out: [bool] = []
    var i = 0
    loop {
        if i >= xs.len() {
            break
        }
        out.append(xs[i])
        i = i + 1
    }
    return out
}
struct Merger {
    acc: [bool]

    fn take(mut self, snap: [bool]) {
        self.acc = snap
    }
}
fn main() -> int {
    var m = Merger { acc: [] }
    let src = [true, false, true]
    m.take(dup(src))                 // inline owning-temp array -> method borrow param (staged + dropped)
    return m.acc.len() + src.len()   // 3 + 3 = 6
}
