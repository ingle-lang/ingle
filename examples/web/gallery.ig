// examples/web/gallery.ig — every interactive Flare widget, running live in the browser (W4).
// Tabs switch sections; buttons, a text field, a slider, and a checkbox all work as WebAssembly from
// one Flare component. Build + run:  make wasm APP=examples/web/gallery.ig   then serve build/wasm.
import "std/flare" as flare
import "std/web" as web


fn main() -> int {
    var f = flare.new()
    var tab = 0
    var name = ""
    var vol = 50
    var size = 1
    var notify = false
    var show_modal = false
    loop {
        f.begin()
        web.pump(f)

        f.heading("Ingle · Flare widget gallery (WASM)")
        f.markdown("Every interactive Flare widget, running **live in the browser** — the same builder API that draws the desktop window.", 620)
        f.divider()

        let tr = f.tabs("sections", ["Buttons", "Inputs", "Toggles"], tab)
        tab = tr.active
        f.divider()

        f.panel_begin(0, 3)
        if tab == 0 {
            f.label("Four button styles — click any of them.")
            f.row(0, 1)
            let _p = f.primary("Primary")
            let _s = f.button("Secondary")
            let _d = f.danger("Danger")
            let _g = f.ghost_button("Ghost")
            f.end()
        } else if tab == 1 {
            f.label("A text field and a slider:")
            name = f.text_field("name", name)
            f.label("Hello, {name}")
            f.divider()
            f.label("Volume: {vol}")
            vol = f.slider("vol", vol, 0, 100)
            f.divider()
            f.label("Size:")
            size = f.dropdown("size", ["Small", "Medium", "Large"], size)
            f.label("Chosen size index: {size}")
        } else {
            f.label("A toggle and a modal dialog:")
            notify = f.checkbox("notify", "Enable notifications", notify)
            if notify {
                f.label("Notifications are ON.")
            } else {
                f.label("Notifications are off.")
            }
            f.divider()
            if f.primary("Open dialog") {
                show_modal = true
            }
        }
        f.end()

        if show_modal {
            let stay = f.modal_begin("dlg", 380, 0)
            f.heading("A modal dialog")
            f.markdown("This floats above a **scrim**, centred on the page. Click *Close*, or click the dimmed background, to dismiss it.", 340)
            f.row(0, 2)                          // END-justified: push the button right
            if f.primary("Close") {
                show_modal = false
            }
            f.end()
            f.modal_end()
            if !stay {                           // clicked the scrim
                show_modal = false
            }
        }

        web.set_html(f.html())
        web.yield_ms(30)
    }
}
