// tests/graphics/flare_presence.em — regression for presence animations (f.enter / f.presence): the immediate-
// mode <AnimatePresence>, built on keyed-state alone. enter() springs a first-seen key 0 → 1 (animate in).
// presence(key, present) springs to 1 while present, then back to 0 once present goes false (animate out) — here
// the key is present for the first 6 frames, then leaves. Progress is printed ×1000 (the fixed-timestep spring is
// deterministic, so the curve is exact). Proves: enter rises to ~1, presence rises then falls back toward 0.
import "std/draw" as draw
import "std/flare" as flare

fn main() -> int {
    draw.window(200, 100, "flarepresencetest")
    var f = flare.new()
    var frame = 0
    loop {
        if frame == 12 {
            break
        }
        draw.begin(f.bg())
        f.begin()
        let e = f.enter("e")
        let here = frame < 6                 // present for 6 frames, then leaving
        let p = f.presence("p", here)
        f.label("x")
        f.finish()
        draw.finish()
        print("frame {frame}: enter {to_int(e * 1000.0)}  presence {to_int(p * 1000.0)}\n")
        frame = frame + 1
    }
    draw.close()
    return 0
}
