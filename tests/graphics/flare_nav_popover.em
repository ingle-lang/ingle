// tests/graphics/flare_nav_popover.em — regression for OFI-116: a nav_item kept ellipsizing its title
// while a POPOVER/modal is open. The background goes inert when a popover opens, but the inert gate must
// only suppress the CLICK — not the last-frame WIDTH read that drives ellipsis. Before the fix, an open
// popover made every background nav_item render its FULL title, overflowing the pill (Karl's screenshot).
// We warm up 3 frames (so the popover's inert state propagates and the nav's last-frame rect exists), then
// tape the settled frame: the long title MUST still carry a trailing "…".
import "std/draw" as draw
import "std/flare" as flare

fn main() -> int {
    draw.window(300, 200, "navpopover")
    var f = flare.new()
    f.use_dark()
    var frame = 0
    loop {
        if frame == 3 { let _ = draw.tape_on("/tmp/ember_nav_popover.tape") }
        draw.begin(f.bg())
        f.begin()
        f.row(flare.START, flare.CENTER)
        if f.nav_item("A very long conversation title that must ellipsize", true) { }
        f.end()
        if f.popover_begin("p", 120, 60) {          // an open popover → the nav row behind it is inert
            if f.menu_item("Delete chat") { }
            f.popover_end()
        }
        f.finish()
        draw.finish()
        if frame == 3 {
            draw.tape_off()
            break
        }
        frame = frame + 1
    }
    draw.close()
    print(read_file("/tmp/ember_nav_popover.tape"))
    return 0
}
