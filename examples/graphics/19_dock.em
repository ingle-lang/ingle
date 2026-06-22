// examples/graphics/19_dock.em — an INTERACTIVE docked workspace on Flare's DockTree. Three panels are
// tiled by a split tree — an Explorer alongside an Editor stacked over an Output pane — and each is a LIVE
// Flare surface: the Explorer's file list drives what the Editor shows; every boundary is a draggable
// splitter (grab it, the panes re-proportion live); every panel has a close ✕ (click it and the survivors
// spring to fill the freed space — FLIP, deterministic over a fixed timestep). Reset (R, or the button)
// rebuilds the default layout. This is the dogfood that drove dock_begin / dock_panel into std/flare.
//
//   make graphics && build/emberc-gfx --emit=run examples/graphics/19_dock.em
//   keys:  R = reset layout   T = toggle theme   (drag a title bar to re-dock / onto a centre to tab · click ✕)
import "std/draw" as draw
import "std/flare" as flare


// build_default lays out the starting workspace: Explorer | (Editor / Output).
fn build_default() -> flare.DockTree {
    var t = flare.dock_new()
    let explorer = t.add_root("Explorer")
    let editor = t.split(explorer, "Editor", true, 0.20)    // Explorer 20% | Editor 80%
    let _ = t.split(editor, "Output", false, 0.66)          // Editor 66% / Output 34%
    return t
}


// content_w returns panel `id`'s inner content width (its body minus the float's two-sided padding), so
// paragraphs wrap to the panel as the user resizes it. Read from the body rect dock_begin recorded.
fn content_w(mut f: flare.Flare, id: string) -> int {
    var w = 240
    match f.ds.get(id) {
        case Some(r) { w = r.w - f.ui.style.pad * 2 }
        case None {}
    }
    return w
}


fn explorer_panel(mut f: flare.Flare, sel: int) -> int {
    var pick = sel
    let files = ["main.em", "flare.em", "ui.em", "layout.em", "README.md"]
    var i = 0
    loop {
        if i == files.len() { break }
        f.row(flare.START, flare.CENTER)
        if f.nav_item(files[i], i == sel) {
            pick = i
        }
        f.end()
        i = i + 1
    }
    f.spacer()
    f.divider()
    f.text_muted("drag a title bar to re-dock · onto a centre to tab · drag a divider · click ✕ · R resets")
    return pick
}


fn editor_panel(mut f: flare.Flare, name: string, cw: int) {
    f.heading(name)
    f.paragraph("A docked editor surface. The panel is a full Flare subtree, so headings, wrapped prose, "
        + "buttons and scroll regions all compose inside it exactly as they do at the top level.", cw)
    f.paragraph("Grab the boundary on the left to resize the Explorer, or the one below to trade height "
        + "with the Output pane — the text re-wraps to the width as you drag.", cw)
}


fn output_panel(mut f: flare.Flare) {
    f.scroll_begin("out")
    f.text_muted("$ emberc --emit=run workspace.em")
    f.label("solved 3 panels in 0.1ms")
    f.label("explorer | editor / output")
    f.text_muted("springs settled · 0 leaked nodes")
    f.label("ready.")
    f.scroll_end("out")
}


fn render_panel(mut f: flare.Flare, id: string, sel: int) -> int {
    var pick = sel
    if id == "Explorer" {
        pick = explorer_panel(f, sel)
    } else if id == "Editor" {
        let files = ["main.em", "flare.em", "ui.em", "layout.em", "README.md"]
        var name = "Editor"
        if sel >= 0 && sel < files.len() {
            name = files[sel]
        }
        editor_panel(f, name, content_w(f, id))
    } else if id == "Output" {
        output_panel(f)
    }
    return pick
}


fn main() -> int {
    draw.window(1180, 760, "Ember — Flare Dock")
    var f = flare.new()
    f.use_dark()
    f.set_zoom(85)

    var t = build_default()
    var sel = 1                      // selected file index (drives the Editor)
    var reset = false

    loop {
        if draw.closing() {
            break
        }
        if draw.key(82) {            // R — rebuild the default layout next frame
            reset = true
        }
        if draw.key(84) {            // T — toggle theme
            if f.ui.style.bg == flare.theme_dark().bg {
                f.use_light()
            } else {
                f.use_dark()
            }
        }
        if reset {
            var old = t.leaves()
            var k = 0
            loop {
                if k == old.len() { break }
                f.forget(old[k])
                k = k + 1
            }
            t = build_default()
            sel = 1
            reset = false
        }

        draw.begin(f.bg())
        f.begin()

        let m = 16
        let hit = f.dock_begin(t, m, m, screen_width() - 2 * m, screen_height() - 2 * m)
        if hit >= 0 {
            let id = t.close_tab(hit)            // ✕ closes the active tab (the leaf survives if it has more)
            f.forget(id)
        }

        let ids = t.leaves()
        var i = 0
        loop {
            if i == ids.len() { break }
            let id = ids[i]
            f.key(id)
            if f.dock_panel(id) {
                sel = render_panel(f, id, sel)
                f.dock_panel_end()
            }
            i = i + 1
        }

        f.finish()
        draw.finish()
    }

    draw.close()
    return 0
}
