// std/diff — a line-oriented diff via the longest common subsequence. Given the old and new lines it
// produces an edit script (each line KEPT, ADDED, or REMOVED) — the basis of a `status`/`diff`/review
// view. O(n·m) time and space (a full LCS table); fine for source files. A Myers O(n·d) refinement
// can follow if large-file diffs ever bite.


// One step of an edit script: a line unchanged (Keep), only in the new version (Add), or only in the
// old version (Remove). Render with `match`.
enum Edit {
    Keep(text: string)
    Add(text: string)
    Remove(text: string)
}


// diff_lines computes the edit script that turns `a` into `b`, following their longest common
// subsequence so unchanged runs stay put and only real insertions/deletions are flagged.
fn diff_lines(a: [string], b: [string]) -> [Edit] {
    let n = a.len()
    let m = b.len()
    let w = m + 1
    // dp[i*w + j] = LCS length of a[i..] and b[j..]; row n and column m are the zero base cases.
    var dp: [int] = []
    var t = 0
    loop {
        if t == (n + 1) * w {
            break
        }
        dp.append(0)
        t = t + 1
    }
    var i = n - 1
    loop {
        if i < 0 {
            break
        }
        var j = m - 1
        loop {
            if j < 0 {
                break
            }
            if a[i] == b[j] {
                dp[i * w + j] = dp[(i + 1) * w + (j + 1)] + 1
            } else {
                let down = dp[(i + 1) * w + j]
                let right = dp[i * w + (j + 1)]
                if down >= right {
                    dp[i * w + j] = down
                } else {
                    dp[i * w + j] = right
                }
            }
            j = j - 1
        }
        i = i - 1
    }
    // Backtrack from (0,0), emitting the script in order.
    var out: [Edit] = []
    var x = 0
    var y = 0
    loop {
        if x >= n || y >= m {
            break
        }
        if a[x] == b[y] {
            out.append(Keep(a[x]))
            x = x + 1
            y = y + 1
        } else if dp[(x + 1) * w + y] >= dp[x * w + (y + 1)] {
            out.append(Remove(a[x]))
            x = x + 1
        } else {
            out.append(Add(b[y]))
            y = y + 1
        }
    }
    loop {
        if x >= n {
            break
        }
        out.append(Remove(a[x]))
        x = x + 1
    }
    loop {
        if y >= m {
            break
        }
        out.append(Add(b[y]))
        y = y + 1
    }
    return out
}


// unified renders an edit script with git-style prefixes: "+" added, "-" removed, " " context.
fn unified(edits: [Edit]) -> string {
    var out = ""
    for e in edits {
        match e {
            case Keep(t) {
                out = out + " " + t + "\n"
            }
            case Add(t) {
                out = out + "+" + t + "\n"
            }
            case Remove(t) {
                out = out + "-" + t + "\n"
            }
        }
    }
    return out
}


// added_count / removed_count give the "+a -r" summary line counts.
fn added_count(edits: [Edit]) -> int {
    var n = 0
    for e in edits {
        match e {
            case Add(t) {
                n = n + 1
            }
            case Keep(t) {}
            case Remove(t) {}
        }
    }
    return n
}


fn removed_count(edits: [Edit]) -> int {
    var n = 0
    for e in edits {
        match e {
            case Remove(t) {
                n = n + 1
            }
            case Keep(t) {}
            case Add(t) {}
        }
    }
    return n
}
