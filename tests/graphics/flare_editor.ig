// tests/graphics/flare_editor.ig — regression for f.code_editor, the editable monospace code editor
// (Inglenook's Phase-2 widget). Renders a small multi-line Ingle snippet and locks, via the tape: the
// line-number gutter (draws "1".."5"), the per-line syntax-highlighted spans (keyword/type/number/
// comment colours), and the recessed surface — the READ path. Editing (caret/selection/scroll) reuses
// the std/ui field machinery covered elsewhere; this test pins layout + highlighted render. Two frames
// for a stable layout; no input injected. Braces in the sample are escaped (\{ \}) so the string does
// not interpolate.

import "std/draw" as draw
import "std/flare" as flare


fn main() -> int {
    draw.window(520, 260, "flareeditortest")
    var f = flare.new()
    draw.tape_on("/tmp/ember_flare_editor_test.tape")
    var code = "// count lines\nfn main() -> int \{\n    let n = 42\n    return n\n\}"
    var frame = 0
    loop {
        if frame == 2 {
            break
        }
        draw.begin(f.bg())
        f.begin()
        f.heading("Editor")
        code = f.code_editor("ed", "ember", code)
        f.finish()
        draw.finish()
        frame = frame + 1
    }
    draw.tape_off()
    draw.close()
    print(read_file("/tmp/ember_flare_editor_test.tape"))
    return 0
}
