// tests/graphics/flare_code.ig — regression for f.code, the standalone monospace syntax-
// highlighted code panel (Inglenook's file-viewer primitive). Renders one small Ingle snippet
// that exercises every span kind the highlighter emits (keyword, type, string, number, comment,
// plain) and locks the solved layout + the highlighted span draws via the tape. Two frames so
// the layout is stable; no input injected (selection reuses std/ui's machinery, covered there).

import "std/draw" as draw
import "std/flare" as flare


fn main() -> int {
    draw.window(420, 220, "flarecodetest")
    var f = flare.new()
    draw.tape_on("/tmp/ember_flare_code_test.tape")
    let src = "// greet builds a Greeting\nfn greet(name: string) -> Greeting \{\n    let n = 42\n    return Greeting \{ text: \"hi\", n: n \}\n\}"
    var frame = 0
    loop {
        if frame == 2 {
            break
        }
        draw.begin(f.bg())
        f.begin()
        f.heading("Viewer")
        f.code("snippet", "ember", src, 380)
        f.finish()
        draw.finish()
        frame = frame + 1
    }
    draw.tape_off()
    draw.close()
    print(read_file("/tmp/ember_flare_code_test.tape"))
    return 0
}
