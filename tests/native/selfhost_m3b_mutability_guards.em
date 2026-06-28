// Regression for the self-hosted checker (selfhost/checker.em) M3b mutability + structural checks
// (2026-06-27). Every construct here is VALID Ember that stage-0 accepts, so the self-hosted checker
// MUST accept it too — these are the false-reject tripwires for the new checks. Lives under tests/ so the
// selfhost gate's corpus scan hard-fails (and VM==native is differentially gated) on any regression.
//
//   - `mut self` field/element mutation, and `var`/`mut`-param field/element/nested mutation (Checks 1-2)
//   - passing a `var` binding to a `mut` parameter (Check 3)
//   - break/continue inside loops (incl. nested in if/match) (Check 5)
//   - bool if/assert conditions + var reassignment with literal width adaptation (Checks 6-7)

struct Box {
    n: int
    items: [int]


    fn bump(mut self) {
        self.n = self.n + 1                 // mut-self field assign
        self.items[0] = self.n              // mut-self element assign
    }
}


struct Pair {
    a: int
    b: int
}


fn fill(mut xs: [int]) {
    xs[0] = 99                              // mut-param element assign
}


fn through_param(mut p: Pair) {
    p.a = 5                                 // mut-param field assign
}


fn nested_mut() -> int {
    var p = Pair { a: 1, b: 2 }
    p.a = 5                                 // var field assign
    var grid = [[1, 2], [3, 4]]
    grid[0][1] = 9                          // var nested element assign
    var arr = [Pair { a: 0, b: 0 }]
    arr[0].a = 7                            // var element-then-field assign
    return p.a
}


fn loops_and_conds(flag: bool) -> int {
    var total = 0
    for x in [1, 2, 3] {
        if x > 2 {
            break                           // break in if in for
        }
        total = total + x
    }
    loop {
        total = total + 1
        if total > 10 {
            break
        }
    }
    if flag {
        total = total + 1                   // bool condition (a bare bool param)
    }
    assert(total > 0)                       // assert bool
    var w: u8 = 0
    w = 5                                    // var reassign + int-literal width adaptation
    return total
}


fn main() -> int {
    var b = Box { n: 0, items: [0, 0] }
    b.bump()
    var xs = [1, 2, 3]
    fill(xs)
    var pr = Pair { a: 1, b: 2 }
    through_param(pr)
    let _ = nested_mut()
    let _ = loops_and_conds(true)
    return 0
}
