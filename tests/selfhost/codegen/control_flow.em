// M4 control-flow differential fixture: if/else/else-if, loop, break, continue, nested loops, assignment.
fn sum_to(n: int) -> int {
    var total = 0
    var i = 0
    loop {
        if i >= n {
            break
        }
        total = total + i
        i = i + 1
    }
    return total
}


fn skip_threes(n: int) -> int {
    var total = 0
    var i = 0
    loop {
        if i >= n {
            break
        }
        if i == 3 {
            i = i + 1
            continue
        }
        total = total + i
        i = i + 1
    }
    return total
}


fn triangle(n: int) -> int {
    var count = 0
    var i = 0
    loop {
        if i >= n {
            break
        }
        var j = 0
        loop {
            if j >= i {
                break
            }
            count = count + 1
            j = j + 1
        }
        i = i + 1
    }
    return count
}


fn sign(x: int) -> int {
    if x < 0 {
        return 0 - 1
    } else if x == 0 {
        return 0
    } else {
        return 1
    }
}
