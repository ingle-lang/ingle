// tests/graphics/flare_badge.ig — regression for f.badge, the compact rounded status pill (the
// Verified Loop's pass/fail chips). Renders one of each kind — 0 neutral, 1 ok (green), 2 bad (red),
// 3 pending (accent) — in a row and locks the tinted fills + centred labels via the tape. Two frames
// for a stable layout; no input injected.

import "std/draw" as draw
import "std/flare" as flare


fn main() -> int {
    draw.window(420, 140, "flarebadgetest")
    var f = flare.new()
    draw.tape_on("/tmp/ember_flare_badge_test.tape")
    var frame = 0
    loop {
        if frame == 2 {
            break
        }
        draw.begin(f.bg())
        f.begin()
        f.heading("Badges")
        f.row(flare.START, flare.CENTER)
        f.badge("neutral", 0)
        f.strut(6, 0)
        f.badge("compiles", 1)
        f.strut(6, 0)
        f.badge("won't compile", 2)
        f.strut(6, 0)
        f.badge("checking", 3)
        f.end()
        f.finish()
        draw.finish()
        frame = frame + 1
    }
    draw.tape_off()
    draw.close()
    print(read_file("/tmp/ember_flare_badge_test.tape"))
    return 0
}
