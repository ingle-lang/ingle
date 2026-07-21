// tests/graphics/ui_code_scroll.ig — regression for the code-editor SCROLLBAR (OFI-217). A code_editor
// whose content overflows its viewport grows a draggable vertical scrollbar. This drives it
// deterministically: frame 1 lays out (voff starts at 0); frame 2 injects a press on the thumb; frame 3
// injects a drag downward — the editor's voff must scroll off zero. content_h = lines × lineheight is
// font-independent, so the assertions are stable. (Mouse-wheel scroll can't be injected headlessly —
// mouse_wheel() reads the real device — so it is covered by review, not here.)
import "std/draw" as draw
import "std/flare" as flare


fn pf(ok: bool) -> string {
    if ok {
        return "PASS"
    }
    return "FAIL"
}


fn main() -> int {
    draw.window(460, 220, "codescroll")
    var f = flare.new()
    var src = ""
    var i = 0
    loop {
        if i == 15 {                         // 15 lines overflows the ~110px editor viewport
            break
        }
        if i > 0 {
            src = src + "\n"
        }
        src = src + "line {i}"
        i = i + 1
    }
    var voff0 = 0
    var voffd = 0
    var frame = 0
    loop {
        if frame == 4 {
            break
        }
        draw.begin(f.bg())
        f.begin()
        // Inject a scrollbar-thumb press (frame 2) then a downward drag (frame 3) AFTER begin() syncs
        // the real mouse, so the injected state is what the widget sees. x=437 is on the right-edge bar.
        if frame == 2 {
            f.ui.mx = 437
            f.ui.my = 95
            f.ui.down = true
            f.ui.was = false
        }
        if frame == 3 {
            f.ui.mx = 437
            f.ui.my = 190
            f.ui.down = true
            f.ui.was = true
        }
        f.heading("Scroll")
        let _ = f.code_editor("ed", "ember", src)
        f.finish()
        draw.finish()
        if frame == 1 {
            voff0 = f.state_int("ed/voff", 0)   // laid out, before any input
        }
        if frame == 3 {
            voffd = f.state_int("ed/voff", 0)   // after dragging the thumb down
        }
        frame = frame + 1
    }
    draw.close()
    let edwid = f.ui.wid("ed")
    println("initial_voff_zero: {pf(voff0 == 0)}")
    // The scrollbar drag scrolls the viewport WITHOUT focusing the text (pressing the bar is not a
    // text press). This distinguishes it from the old behaviour, where dragging over the editor body
    // text-selected and caret-follow scrolled — that path would leave the editor focused.
    println("scrollbar_drag_scrolls: {pf(voffd > 0 && f.ui.focus != edwid)}")
    return 0
}
