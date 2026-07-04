// OFI-165 regression (self-hosted codegen): assigning an empty array literal DIRECTLY to a struct
// field (`self.flags = []`) must take the element render-kind from the field's declared `[T]`, not the
// context-free int default — otherwise a `[bool]` field is rebuilt as a boxed-int array and appended
// bools land in the wrong representation. The struct-literal form (`S{ flags: [] }`) always inferred
// the kind correctly; this exercises the field-ASSIGNMENT path that the self-hosted backend missed.
// Deterministic output; VM == native and self-hosted-codegen byte-identical to stage-0.
struct Bag {
    flags: [bool]


    fn reset(mut self) {
        self.flags = []
    }


    fn count_true(self) -> int {
        var n = 0
        var i = 0
        loop {
            if i >= self.flags.len() {
                break
            }
            if self.flags[i] {
                n = n + 1
            }
            i = i + 1
        }
        return n
    }
}


fn main() -> int {
    var b = Bag{ flags: [] }
    b.flags.append(true)
    b.flags.append(false)
    b.flags.append(true)
    println("before {b.flags.len()} {b.count_true()}")
    b.reset()                       // field-assign of an empty [] — the OFI-165 path
    println("after  {b.flags.len()} {b.count_true()}")
    b.flags.append(false)
    b.flags.append(true)
    println("rebuilt {b.flags.len()} {b.count_true()}")
    return 0
}
