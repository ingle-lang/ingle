// tests/graphics/flare_virtual.ig — regression for immediate-mode list virtualization (virtual_begin/
// virtual_item/virtual_end): only the rows whose extent falls in the scroll viewport (plus an overscan) are
// BUILT each frame; the rest become spacer struts of their summed height, so scroll height + sticky-follow
// are unchanged. 30 fixed-height (40px) rows in a small STICKY viewport (follows the bottom): the window must
// settle on a handful of rows at the END, NOT all 30 — that is the O(total) → O(visible) win. Rows are a
// fixed-size strut (not text) so the window math is FONT-INDEPENDENT and the golden is stable across builds.
// Heights are learned from last frame's solved rows, so the window settles after a frame or two (run six).
import "std/draw" as draw
import "std/flare" as flare

fn main() -> int {
    draw.window(220, 170, "flarevirtualtest")
    var f = flare.new()
    var frame = 0
    loop {
        if frame == 6 {
            break
        }
        draw.begin(f.bg())
        f.begin()
        f.scroll_begin_sticky("sc")
        let vc = f.virtual_begin("sc", 30)
        var i = vc.start
        loop {
            if i >= vc.end {
                break
            }
            f.virtual_item(i)
            f.strut(160, 40)          // a fixed 40px row → window math independent of font metrics
            f.virtual_item_end()
            i = i + 1
        }
        f.virtual_end()
        f.scroll_end("sc")
        f.finish()
        draw.finish()
        // The window actually built this frame: a small slice near the end, never the whole 30.
        print("frame {frame}: built rows {f.vstart}..{f.vend} of 30\n")
        frame = frame + 1
    }
    draw.close()
    return 0
}
