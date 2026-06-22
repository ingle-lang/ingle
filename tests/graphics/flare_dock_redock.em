// tests/graphics/flare_dock_redock.em — regression for DRAG-A-TITLE-BAR-TO-REDOCK (std/flare _dock_drag /
// _dock_drop / redock / dock_root_edge). Where flare_dock_ui.em drives divider-drag + close, this drives the
// panel-drag interaction: it injects mouse state (press on a bar → move past the threshold → release) and
// asserts the deterministic, font-independent outcome — the leaf ORDER after the tree re-docks, the latch
// (f.pdrag), and that a sub-threshold click never mutates. All assertions are ids / orders / counts (no
// measure_text), so the golden is immune to font-metric drift.
import "std/draw" as draw
import "std/flare" as flare


// build lays out Explorer | (Editor / Output): a 20% vertical sidebar, the rest split 66/34 horizontally.
fn build() -> flare.DockTree {
    var t = flare.dock_new()
    let explorer = t.add_root("Explorer")
    let editor = t.split(explorer, "Editor", true, 0.20)
    let _ = t.split(editor, "Output", false, 0.66)
    return t
}


// order joins the panel ids left-to-right so a re-dock shows as a single comparable string.
fn order(t: flare.DockTree) -> string {
    let ls = t.leaves()
    var s = ""
    var i = 0
    loop {
        if i == ls.len() { break }
        if i > 0 { s = s + "|" }
        s = s + ls[i]
        i = i + 1
    }
    return s
}


fn forget_all(mut f: flare.Flare, t: flare.DockTree) {
    let ids = t.leaves()
    var i = 0
    loop {
        if i == ids.len() { break }
        f.forget(ids[i])
        i = i + 1
    }
}


// frame runs one injected-input dock frame at (mx,my,down,was) over a 1000x600 workspace.
fn frame(mut f: flare.Flare, mut t: flare.DockTree, mx: int, my: int, down: bool, was: bool) {
    draw.begin(f.bg())
    f.begin()
    f.ui.mx = mx  f.ui.my = my  f.ui.down = down  f.ui.was = was
    let _ = f.dock_begin(t, 0, 0, 1000, 600)
    let ids = t.leaves()
    var i = 0
    loop {
        if i == ids.len() { break }
        f.key(ids[i])
        if f.dock_panel(ids[i]) {
            f.label("body")
            f.dock_panel_end()
        }
        i = i + 1
    }
    f.finish()
    draw.finish()
}


fn main() -> int {
    draw.window(1000, 600, "flaredockredock")
    var f = flare.new()
    var t = build()

    // ---- Phase A: baseline order, no input ----
    frame(f, t, -1, -1, false, false)
    print("A order={order(t)} nodes={t.node_count()}\n")

    // ---- Phase B: drag Output's title bar onto Explorer's RIGHT edge → Explorer | Output | Editor ----
    // Output bar is at (206,398,..); Explorer is the (0,0,198,600) sidebar, its right third the drop zone.
    frame(f, t, 400, 416, true, false)              // press on Output's bar → latch
    print("B press   pdrag={f.pdrag} order={order(t)}\n")
    frame(f, t, 160, 300, true, true)               // drag over Explorer's right edge → preview, no mutation yet
    print("B drag    pdrag={f.pdrag} order={order(t)}\n")
    frame(f, t, 160, 300, false, true)              // release → redock applies
    print("B release pdrag={f.pdrag} order={order(t)} nodes={t.node_count()}\n")

    // ---- Phase C: a sub-threshold click on a bar (press + release, no move) never re-docks ----
    forget_all(f, t)
    t = build()
    frame(f, t, 400, 416, true, false)              // press on Output's bar
    frame(f, t, 402, 417, false, true)              // release ~1px away (under the 6px threshold)
    print("C order={order(t)} pdrag={f.pdrag}\n")

    // ---- Phase D: drag Editor to the LEFT outer band (mx<28) → docks against the whole workspace edge ----
    forget_all(f, t)
    t = build()
    frame(f, t, 400, 18, true, false)               // press on Editor's bar (206,0,..)
    frame(f, t, 10, 300, true, true)                // drag into the left outer band → root-edge preview
    frame(f, t, 10, 300, false, true)               // release → dock_root_edge(Editor, left)
    print("D order={order(t)} nodes={t.node_count()}\n")

    forget_all(f, t)
    draw.close()
    return 0
}
