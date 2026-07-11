// diff.ig — locks std/diff: the LCS line diff (edit script + unified render + counts), over a
// modify/insert case, an identical case, and an all-new case.
import "std/diff" as diff

fn lines(s: string) -> [string] {
    return s.split("\n")
}

fn main() -> int {
    let ed = diff.diff_lines(lines("alpha\nbeta\ngamma\ndelta"),
                             lines("alpha\nBETA\ngamma\nepsilon\ndelta"))
    print(diff.unified(ed))
    println("summary +{diff.added_count(ed)} -{diff.removed_count(ed)}")

    let same = diff.diff_lines(lines("x\ny"), lines("x\ny"))
    println("identical +{diff.added_count(same)} -{diff.removed_count(same)}")

    var none: [string] = []
    let allnew = diff.diff_lines(none, lines("p\nq"))
    println("allnew +{diff.added_count(allnew)} -{diff.removed_count(allnew)}")
    return 0
}
