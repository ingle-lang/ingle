// tests/graphics/flare_fade.ig — regression for the fade primitive (f.fade_begin/fade_end + the set_alpha
// runtime path). A subtree wrapped in fade_begin(0.5) draws at HALF opacity — text, fills and shadows alike —
// while everything outside stays fully opaque. The tape carries the folded alpha on the faded ops (text/rect
// gain an "alpha" field only when < 255, so un-faded goldens are unaffected). Proves fade composes through a
// real widget (button = a rounded fill + centred text).
import "std/draw" as draw
import "std/flare" as flare

fn main() -> int {
    draw.window(220, 140, "flarefadetest")
    var f = flare.new()
    draw.tape_on("/tmp/ember_flare_fade.tape")
    draw.begin(f.bg())
    f.begin()
    f.fade_begin(0.5)            // half opacity for the enclosed subtree
    if f.button("Faded") {
    }
    f.fade_end()
    if f.button("Solid") {       // outside the bracket → fully opaque
    }
    f.finish()
    draw.finish()
    draw.tape_off()
    draw.close()
    print(read_file("/tmp/ember_flare_fade.tape"))
    return 0
}
