// M4 codegen fixture: enum construction (NEW_ENUM, bare + payload) and `match` dispatch (GET_TAG tag-test
// chain, positional payload binding, wildcard catch-all, and the owned-enum drop discipline — an enum is a
// heap/move value, so enum lets and params are dropped at every exit).

enum Dir {
    North
    South
    East
    West
}


enum Shape {
    Circle(r: int)
    Rect(w: int, h: int)
}


fn dir_code(d: Dir) -> int {
    match d {
        case North { return 1 }
        case South { return 2 }
        case _ { return 0 }
    }
}


fn area(s: Shape) -> int {
    match s {
        case Circle(r) { return r * r * 3 }
        case Rect(w, h) { return w * h }
    }
}


fn unwrap_or(o: Option<int>, fallback: int) -> int {
    match o {
        case Some(v) { return v }
        case None { return fallback }
    }
}


fn main() -> int {
    let d = East
    let c = Circle(4)
    let total = dir_code(d) + area(c) + unwrap_or(Some(7), 0) + unwrap_or(None, 9)
    return total
}
