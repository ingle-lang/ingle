// examples/web/counter_ssr.ig — the SERVER-SIDE render of examples/web/counter.ig's initial frame.
// Run with the web compiler (build/inglec-web --emit=run) to print the counter's HTML at count=0 — the
// same output the WASM client produces on its first frame, so the client hydrates onto it as a no-op
// (see tools/wasm-shell.html's ingleMorph). This is the SSR half of the "IngleScript" loop: a browser
// shows this instantly (no JS needed), then the wasm client takes over live. Keep the body in sync with
// counter.ig's loop body — if they drift, hydration visibly flashes (a built-in self-check).
import "std/flare" as flare


fn main() -> int {
    var f = flare.new()
    let count = 0
    f.begin()
    f.heading("Ingle · Flare in the browser (WASM)")
    f.markdown("This counter is a **live Flare component** compiled to WebAssembly. Each click re-runs the frame and repaints the page — the same builder API as the desktop window.", 560)
    f.divider()
    f.heading("count = {count}")
    f.row(0, 1)
    let _i = f.primary("Increment")
    let _d = f.button("Decrement")
    let _r = f.danger("Reset")
    f.end()
    print(f.html())
    return 0
}
