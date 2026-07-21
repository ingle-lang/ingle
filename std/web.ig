// std/web — the browser (WASM) bridge for running Flare components client-side (W4, OFI-213).
//
// A Flare web app is an ordinary Ingle loop: pull the next DOM click, feed it to the frame with
// f.set_click(), build the component, render it with f.html(), push that into the page, and yield.
// Under emscripten these three primitives call into the page; on any other target they are inert stubs
// (the one web-flavored build — see `make web` / `make wasm` — runs everywhere, only DOES something in a
// browser). Compile a component to a browser app with `make wasm APP=<file.ig>`. See flare.set_click().
//
// The event loop shape (see examples/web/counter.ig):
//     loop {
//         f.set_click(web.next_click())
//         f.begin()
//         ...build the component...
//         web.set_html(f.html())
//         web.yield_ms(30)
//     }

extern "c" {
    fn web_set_html(html: string) -> i64
    fn web_next_click() -> string
    fn web_sleep(ms: i64) -> i64
}


// set_html replaces the page's #app content with a freshly rendered frame (flare.html()'s output).
fn set_html(html: string) {
    let _ = web_set_html(html)
}


// next_click pops the id (the widget's data-fl-id) of the next queued DOM click, or "" if none this tick.
fn next_click() -> string {
    return web_next_click()
}


// yield_ms yields to the browser event loop for ~ms, so the page stays responsive between frames. Under
// emscripten this is emscripten_sleep (ASYNCIFY unwinds/rewinds the stack); a no-op off the browser.
fn yield_ms(ms: int) {
    let _ = web_sleep(ms)
}
