// examples/web/counter.ig — a live Flare component running in the browser via WebAssembly (W4, OFI-213).
// The SAME builder API that draws the desktop window; each DOM click re-runs the frame and repaints the
// page. Build + run:  make wasm APP=examples/web/counter.ig  then serve build/wasm and open counter.html.
import "std/flare" as flare
import "std/web" as web


fn main() -> int {
    var f = flare.new()
    var count = 0
    loop {
        f.set_click(web.next_click())          // "" when nothing was clicked this tick
        f.begin()
        f.heading("Ingle · Flare in the browser (WASM)")
        f.markdown("This counter is a **live Flare component** compiled to WebAssembly. Each click re-runs the frame and repaints the page — the same builder API as the desktop window.", 560)
        f.divider()
        f.heading("count = {count}")
        f.row(0, 1)                            // START, CENTER: a button row
        let inc = f.primary("Increment")
        let dec = f.button("Decrement")
        let rst = f.danger("Reset")
        f.end()
        if inc {
            count = count + 1
        }
        if dec {
            count = count - 1
        }
        if rst {
            count = 0
        }
        web.set_html(f.html())
        web.yield_ms(30)
    }
}
