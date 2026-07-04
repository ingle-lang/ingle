// M4 codegen fixture: both fused `for` forms — a range (`FOR_RANGE`, index = loop var, pre-incremented from
// lo-1) and an array (`FOR_ARRAY`, hidden array/index/len slots + a borrowed element), the indexed
// `for (i, x)` array form, break/continue (a continue is a back-edge to the fused op), nesting, and a
// droppable body local (released + popped each iteration before the back-edge).

fn sum_range(n: int) -> int {
    var s = 0
    for i in 0..n {
        if i == 2 {
            continue
        }
        s = s + i
    }
    return s
}


fn sum_array(xs: [int]) -> int {
    var s = 0
    for (i, x) in xs {
        s = s + i + x
    }
    return s
}


fn grid(n: int) -> int {
    var s = 0
    for a in 0..n {
        for b in 0..n {
            if a * b > 4 {
                break
            }
            s = s + a * b
        }
    }
    return s
}


fn label_lengths(n: int) -> int {
    var total = 0
    for i in 0..n {
        let tag = "item"
        total = total + tag.len()
    }
    return total
}


fn main() -> int {
    let xs = [10, 20, 30]
    return sum_range(5) + sum_array(xs) + grid(3) + label_lengths(2)
}
