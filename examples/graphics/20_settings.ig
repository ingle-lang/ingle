// 20_settings.ig — a non-trivial Flare screen: a SETTINGS DIALOG (MANIFESTO §5g). It answers the
// question "how does an immediate-mode UI hold a tree of mutable state?" — and the answer is the quiet
// win: it doesn't need hooks or reducers. The "tree" is just plain `var`s the loop owns. You read them
// at the top of the frame and write them back as the user interacts; a `dirty` flag is your own
// "unsaved" signal. A `modal` (a centred panel over a dimmed scrim) of `segmented` single-choice
// controls drives `dark` / `model_idx` / `tok_idx` directly — no `useState`, no effect arrays.
//
//   make graphics && build/inglec-gfx --emit=run examples/graphics/20_settings.ig

import "std/draw" as draw
import "std/flare" as flare

fn main() -> int {
    draw.window(560, 460, "Settings")
    var f = flare.new()

    // The whole "tree of mutable state" — plain vars the loop owns.
    var dark = false
    var model_idx = 0
    var tok_idx = 2
    var open = true
    var dirty = false

    loop {
        if draw.closing() {
            break
        }
        draw.begin(f.bg())
        f.begin()

        f.heading("My app")
        if f.primary("Open settings") {
            open = true
        }
        if dirty {
            f.text_muted("Settings changed — would persist here.")
        }

        if open {
            if !f.modal_begin("settings", 460, 0) {   // a press on the dimmed scrim closes it
                open = false
            }
            f.heading("Settings")
            f.divider()

            f.text_muted("Appearance")
            var appear = 1
            if dark {
                appear = 0
            }
            let na = f.segmented("appearance", ["Dark", "Light"], appear)
            if na != appear {                          // a choice changed → mutate the var directly
                dark = (na == 0)
                if dark {
                    f.use_dark()
                } else {
                    f.use_light()
                }
                dirty = true
            }

            f.text_muted("Model")
            let nm = f.segmented("model", ["Opus", "Sonnet", "Haiku"], model_idx)
            if nm != model_idx {
                model_idx = nm
                dirty = true
            }

            f.text_muted("Max tokens")
            let nt = f.segmented("toks", ["1K", "2K", "4K", "8K"], tok_idx)
            if nt != tok_idx {
                tok_idx = nt
                dirty = true
            }

            f.divider()
            f.row(flare.END, flare.CENTER)
            if f.primary("Done") {
                open = false
            }
            f.end()
            f.modal_end()
        }

        f.finish()
        draw.finish()
    }
    draw.close()
    return 0
}
