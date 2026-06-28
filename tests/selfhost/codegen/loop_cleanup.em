// M4 codegen fixture: `break`/`continue` must release the loop-body locals declared before them (DROP owned
// + POP the slot) before jumping — otherwise a per-iteration local leaks/desyncs the stack. Also an
// enum-returning method call binds a droppable enum, and a refcounted (enum) field/local read consumed into
// a new owner INCREFs — the same discipline as a string.

enum Tk {
    TA
    TB(n: int)
    TEnd
}


struct Box {
    tag: Tk
    count: int


    fn next(self) -> Tk {
        return TB(self.count)
    }
}


fn use_tk(t: Tk) -> int {
    match t {
        case TA { return 1 }
        case TB(n) { return n }
        case TEnd { return 0 }
    }
}


fn run(b: Box) -> int {
    var total = 0
    var i = 0
    loop {
        if i >= 5 {
            break                       // releases nothing here, but exits the loop
        }
        let k = b.next()                // enum-returning method -> a droppable enum local
        let label = "tick"              // a droppable string body local
        if label.len() == 0 {
            i = i + 1
            continue                    // must release k + label before the back-edge
        }
        total = total + use_tk(k) + use_tk(b.tag)   // b.tag is an enum field -> INCREF on consume
        i = i + 1
    }
    return total
}


fn main() -> int {
    let b = Box { tag: TA, count: 7 }
    return run(b)
}
