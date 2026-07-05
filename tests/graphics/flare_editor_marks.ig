// tests/graphics/flare_editor_marks.ig — regression for code_editor_marked: the diagnostic SQUIGGLE
// (a red underline + gutter dot on an error line) and the execution-tape SPOTLIGHT (a full-width band
// on the line being scrubbed). Renders a small snippet with line 3 marked as an error and line 2 as the
// hot line, and locks the markers via the tape. Two frames for a stable layout; no input injected.

import "std/draw" as draw
import "std/flare" as flare


fn main() -> int {
    draw.window(460, 220, "flareeditmarks")
    var f = flare.new()
    draw.tape_on("/tmp/ember_flare_editmarks.tape")
    let src = "fn main() -> int \{\n    let ok = 1\n    let bad = nope\n    return ok\n\}"
    let marks = [3]        // line 3 has a diagnostic → red squiggle + gutter dot
    let hot = 2            // line 2 is the tape's current line → spotlight band
    var frame = 0
    loop {
        if frame == 2 {
            break
        }
        draw.begin(f.bg())
        f.begin()
        f.heading("Marks")
        let _ = f.code_editor_marked("em", "ember", src, marks, hot)
        f.finish()
        draw.finish()
        frame = frame + 1
    }
    draw.tape_off()
    draw.close()
    print(read_file("/tmp/ember_flare_editmarks.tape"))
    return 0
}
