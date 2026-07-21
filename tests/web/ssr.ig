// tests/web/ssr.ig — regression for the Flare -> HTML terminal walk (flare.html(), OFI-212 / W3)
// under the raylib-free web runtime (build/inglec-web). It exercises a spread of widget kinds and
// nested flex containers, then prints the rendered page. Output is fully deterministic: no window, no
// mouse, and measure_text is the headless codepoint estimate — so this is an exact-match golden.
import "std/flare" as flare


fn main() -> int {
    var f = flare.new()
    f.begin()

    f.heading("SSR regression")
    f.label("A plain label.")
    f.divider()

    f.row(0, 3)                              // sidebar + content (row of two stretch columns)

    f.panel_begin(0, 3)
    let _a = f.nav_item("Active", true)
    let _b = f.nav_item("Inactive", false)
    f.end()

    f.panel_begin(0, 3)
    f.heading("Content")
    f.markdown("Text with **bold**, *em*, `code`, and a [link](#).", 420)
    f.row(0, 1)
    let _p = f.primary("Primary")
    let _s = f.button("Secondary")
    let _d = f.danger("Danger")
    f.end()
    f.end()

    f.end()                                  // close the row
    print(f.html())
    return 0
}
