// C-emit nested arrays (OFI-219, OFI-218 Phase 4): a `[[T]]` element is itself an ARRAY, not a string — so
// `grid[i].len()` is em_array_len (the self-hosted C-emit previously mistyped the boxed AEK-0 element as a
// string → em_str_len), and `grid[i][j]` reads plain as a scalar (not spuriously own_into_slot'd). Tracked via
// two scope facets: element-is-array and the inner element's scalar kind. Byte-identical both backends.
fn row_max(row: [int]) -> int {
    var m = 0
    var j = 0
    loop {
        if j >= row.len() {
            break
        }
        if row[j] > m {
            m = row[j]
        }
        j = j + 1
    }
    return m
}
fn main() -> int {
    let grid: [[int]] = [[1, 2, 3], [4, 5], [9]]
    var total = 0
    var i = 0
    loop {
        if i >= grid.len() {
            break
        }
        total = total + grid[i].len()      // .len() on a [[int]] element -> em_array_len
        var j = 0
        loop {
            if j >= grid[i].len() {
                break
            }
            total = total + grid[i][j]     // double-index scalar read (plain, no own_into_slot)
            j = j + 1
        }
        total = total + row_max(grid[i])   // pass a [[int]] element to a [int] param
        i = i + 1
    }
    return total                            // lens 3+2+1=6, elems 1+2+3+4+5+9=24, maxes 3+5+9=17 -> 47
}
