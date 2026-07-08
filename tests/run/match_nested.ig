// One-level nested destructuring (`case Some(Point(x, y))`) — Phase 2d. A variant's payload
// field that is an all-scalar VALUE STRUCT can be destructured inline into its fields (an
// irrefutable inner pattern: a struct always matches). Composes with guards, generic Option
// payloads, mixed nested+plain slots, and ignored `_` inner bindings. Refutable enum-inner,
// literal-in-variant, and depth>1 are rejected (see the error_match_* fixtures).
struct Point { x: int  y: int }
struct Rgb { r: int  g: int  b: int }
enum Shape { Cell(p: Point)  Rect(p: Point, area: int)  Empty }
enum Paint { Fill(c: Rgb)  Blank }


fn cell_sum(s: Shape) -> int {
    match s {
        case Cell(Point(x, y)) {
            return x + y
        }
        case Rect(Point(x, y), area) {
            return x + y + area
        }
        case Empty {
            return 0
        }
    }
}


fn bright(p: Paint) -> int {
    match p {
        case Fill(Rgb(r, g, b)) if r + g + b > 300 {
            return 1
        }
        case Fill(Rgb(r, g, b)) {
            return r + g + b
        }
        case Blank {
            return 0 - 1
        }
    }
}


fn opt_x(o: Option<Point>) -> int {
    match o {
        case Some(Point(x, y)) {
            return x * 100 + y
        }
        case None {
            return 0 - 1
        }
    }
}


fn only_y(s: Shape) -> int {
    match s {
        case Cell(Point(_, y)) {
            return y
        }
        case Rect(Point(_, y), _) {
            return y
        }
        case Empty {
            return 0
        }
    }
}


fn main() {
    println("{cell_sum(Cell(Point { x: 3, y: 4 }))}")
    println("{cell_sum(Rect(Point { x: 1, y: 2 }, 10))}")
    println("{cell_sum(Empty)}")
    println("{bright(Fill(Rgb { r: 10, g: 20, b: 30 }))}")
    println("{bright(Fill(Rgb { r: 200, g: 200, b: 200 }))}")
    println("{bright(Blank)}")
    println("{opt_x(Some(Point { x: 5, y: 7 }))}")
    println("{opt_x(None)}")
    println("{only_y(Cell(Point { x: 9, y: 4 }))}")
    println("{only_y(Rect(Point { x: 8, y: 6 }, 99))}")
}
