// tests/graphics/flare_dock_ui.ig — regression for the INTERACTIVE dock (std/flare dock_begin / dock_panel /
// _dock_divider / the close ✕). Where flare_dock.ig covers the pure DockTree data model and flare_dock_solve.ig
// its geometry, this drives the RENDERER + interaction: it injects mouse state (like flare_splitter.ig) and
// asserts the deterministic, font-independent outcomes — so it can't drift off the docking UX:
//   • dock_panel records each panel's content BODY rect (below the title bar) — locks the float anchoring
//   • dragging a divider re-proportions the split LIVE (ratio tracks the cursor, clamped)
//   • clicking a panel's close ✕ returns its leaf index; close() then collapses the parent split
// All assertions are integers / ids / ratios (no measure_text), so the golden is immune to font-metric drift.
import "std/draw" as draw
import "std/flare" as flare


// build lays out Explorer | (Editor / Output): split indices 0=Explorer 1=root-split 2=Editor 3=split 4=Output.
fn build() -> flare.DockTree {
    var t = flare.dock_new()
    let explorer = t.add_root("Explorer")
    let editor = t.split(explorer, "Editor", true, 0.20)    // Explorer 20% | Editor 80%  (root split = node 1)
    let _ = t.split(editor, "Output", false, 0.66)          // Editor 66% / Output 34%     (split = node 3)
    return t
}


// content builds a trivial body for every live panel (so dock_panel is exercised and the body rects are recorded).
fn content(mut f: flare.Flare, t: flare.DockTree) {
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
}


fn show_bodies(mut f: flare.Flare, t: flare.DockTree) {
    let ids = t.leaves()
    var i = 0
    loop {
        if i == ids.len() { break }
        match f.ds.get(ids[i]) {
            case Some(r) { print("  body {ids[i]}: x={r.x} y={r.y} w={r.w} h={r.h}\n") }
            case None { print("  body {ids[i]}: MISSING\n") }
        }
        i = i + 1
    }
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


fn main() -> int {
    draw.window(1000, 600, "flaredockuitest")
    var f = flare.new()
    var t = build()

    // ---- Phase A: geometry + dock_panel body rects (frame 1, no input) ----
    draw.begin(f.bg())
    f.begin()
    f.ui.mx = -1  f.ui.my = -1  f.ui.down = false  f.ui.was = false
    let hA = f.dock_begin(t, 0, 0, 1000, 600)
    content(f, t)
    f.finish()
    draw.finish()
    print("A hit={hA} ratio={to_int(t.dk_ratio[1] * 1000.0)}\n")
    show_bodies(f, t)

    // ---- Phase B: drag the vertical divider (node 1) from x≈202 to x=420 ----
    // press (down-edge over the band latches), drag (ratio tracks the cursor), release (ratio holds).
    draw.begin(f.bg())  f.begin()
    f.ui.mx = 202  f.ui.my = 300  f.ui.down = true  f.ui.was = false
    let _ = f.dock_begin(t, 0, 0, 1000, 600)  content(f, t)  f.finish()  draw.finish()
    print("B press  ratio={to_int(t.dk_ratio[1] * 1000.0)}\n")

    draw.begin(f.bg())  f.begin()
    f.ui.mx = 420  f.ui.my = 300  f.ui.down = true  f.ui.was = true
    let _ = f.dock_begin(t, 0, 0, 1000, 600)  content(f, t)  f.finish()  draw.finish()
    print("B drag   ratio={to_int(t.dk_ratio[1] * 1000.0)}\n")

    // clamp: still held, drag far past the right edge — ratio pins at 0.92, never past.
    draw.begin(f.bg())  f.begin()
    f.ui.mx = 5000  f.ui.my = 300  f.ui.down = true  f.ui.was = true
    let _ = f.dock_begin(t, 0, 0, 1000, 600)  content(f, t)  f.finish()  draw.finish()
    print("B clamp  ratio={to_int(t.dk_ratio[1] * 1000.0)}\n")

    draw.begin(f.bg())  f.begin()
    f.ui.mx = 420  f.ui.my = 300  f.ui.down = false  f.ui.was = true
    let _ = f.dock_begin(t, 0, 0, 1000, 600)  content(f, t)  f.finish()  draw.finish()
    print("B release ratio={to_int(t.dk_ratio[1] * 1000.0)}\n")

    // ---- Phase C: close the Output panel via its ✕ (fresh tree + state so geometry is predictable) ----
    forget_all(f, t)
    t = build()
    // Output (node 4) solves to x=206 w=794 → close button square at the bar's right edge: cx=1000-bar.
    // With bar=36 the ✕ centre is ≈ (982, 18) of the panel at y=398 → (982, 416). Press then release on it.
    draw.begin(f.bg())  f.begin()
    f.ui.mx = 982  f.ui.my = 416  f.ui.down = true  f.ui.was = false
    let cPress = f.dock_begin(t, 0, 0, 1000, 600)  content(f, t)  f.finish()  draw.finish()
    print("C press  hit={cPress}\n")

    draw.begin(f.bg())  f.begin()
    f.ui.mx = 982  f.ui.my = 416  f.ui.down = false  f.ui.was = true
    let cHit = f.dock_begin(t, 0, 0, 1000, 600)
    var closedId = "none"
    if cHit >= 0 {
        closedId = t.close(cHit)
        f.forget(closedId)
    }
    content(f, t)  f.finish()  draw.finish()
    print("C release hit={cHit} closed={closedId} leaves={t.leaves().len()} nodes={t.node_count()}\n")

    // ---- Phase D: a PINNED panel draws no ✕ and can't be closed (press+release where its ✕ would be) ----
    forget_all(f, t)
    t = build()
    draw.begin(f.bg())  f.begin()
    f.ui.mx = 982  f.ui.my = 416  f.ui.down = true  f.ui.was = false
    f.dock_pin("Output")
    let dPress = f.dock_begin(t, 0, 0, 1000, 600)  content(f, t)  f.finish()  draw.finish()

    draw.begin(f.bg())  f.begin()
    f.ui.mx = 982  f.ui.my = 416  f.ui.down = false  f.ui.was = true
    f.dock_pin("Output")
    let dHit = f.dock_begin(t, 0, 0, 1000, 600)  content(f, t)  f.finish()  draw.finish()
    print("D pinned press={dPress} release={dHit} leaves={t.leaves().len()}\n")

    draw.close()
    return 0
}
