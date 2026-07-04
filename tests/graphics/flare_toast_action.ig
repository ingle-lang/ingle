// tests/graphics/flare_toast_action.ig — regression for interactive toasts (f.toast_action + take_action). A
// toast with an action button ("Undo") fires its token on a RELEASE over the button and then dismisses; a
// press alone does not. take_action() returns the token for one frame. This is the reversible-action pattern
// (delete → "Deleted · Undo" → roll back). NOTE (OFI-068): the click position is the rendered button rect, so
// it depends on glyph widths — re-bless per machine if the font version shifts it past the button.
import "std/draw" as draw
import "std/flare" as flare

fn frame(mut f: flare.Flare, mx: int, my: int, down: bool, was: bool, raise: bool) -> string {
    draw.begin(f.bg())
    f.begin()
    if raise {
        f.toast_action("Conversation deleted", "Undo", "undo1")
    }
    f.label("body")
    f.finish()
    f.ui.mx = mx  f.ui.my = my  f.ui.down = down  f.ui.was = was
    f.toast_layer()
    let act = f.take_action()
    draw.finish()
    return act
}

fn main() -> int {
    draw.window(360, 200, "flaretoastactiontest")
    var f = flare.new()
    let a0 = frame(f, 0 - 1, 0 - 1, false, false, true)     // raise the toast (no click)
    print("raise   act='{a0}' toasts={f.toast_count()}\n")
    let a1 = frame(f, 291, 177, true, false, false)         // press on the Undo button — not yet a click
    print("press   act='{a1}' toasts={f.toast_count()}\n")
    let a2 = frame(f, 291, 177, false, true, false)         // release on Undo → token fires, toast closes
    print("release act='{a2}' toasts={f.toast_count()}\n")
    draw.close()
    return 0
}
