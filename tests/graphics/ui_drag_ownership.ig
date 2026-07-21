// tests/graphics/ui_drag_ownership.ig — regression for the drag-select OWNERSHIP fix (std/ui). A text
// or code widget must extend its selection on a mouse-drag ONLY if the drag STARTED on it
// (ui.active == id), not merely if it is focused (ui.focus == id). Before the fix, pressing ANOTHER
// widget (e.g. the chat's scroll-to-bottom fab) while the code editor was focused stray-selected a
// little text in the editor, because the drag branch fired on focus alone. Drives _code_edit directly
// with set input fields — deterministic, no real mouse, and independent of font metrics.
import "std/draw" as draw
import "std/flare" as flare


fn pf(ok: bool) -> string {
    if ok {
        return "PASS"
    }
    return "FAIL"
}


fn main() -> int {
    draw.window(600, 400, "uidragtest")
    var f = flare.new()
    let val = "hello world\nsecond line\nthird line"
    let eid = f.ui.wid("editor")
    let oid = f.ui.wid("other")

    // (1) The bug: editor focused, but the drag is owned by ANOTHER widget, mouse far from the editor.
    //     The editor must NOT extend its selection — the caret stays put at the anchor.
    f.ui.buf = val
    f.ui.focus = eid
    f.ui.active = oid
    f.ui.sel_anchor = 3
    f.ui.caret = 3
    f.ui.down = true
    f.ui.was = true
    f.ui.mx = 550
    f.ui.my = 380
    let _ = f.ui._code_edit(eid, 100, 100, 300, 200, 140, 110, 16, 20, val)
    println("foreign_press_no_stray_select: {pf(f.ui.caret == 3)}")

    // (2) The normal case: the editor OWNS the drag (active == editor), mouse inside it — the selection
    //     extends, so the caret moves off the anchor (exact position depends on font metrics, so we only
    //     assert it moved).
    f.ui.buf = val
    f.ui.focus = eid
    f.ui.active = eid
    f.ui.sel_anchor = 0
    f.ui.caret = 0
    f.ui.down = true
    f.ui.was = true
    f.ui.mx = 220
    f.ui.my = 150
    let _ = f.ui._code_edit(eid, 100, 100, 300, 200, 140, 110, 16, 20, val)
    println("owned_drag_extends: {pf(f.ui.caret != 0)}")

    draw.close()
    return 0
}
