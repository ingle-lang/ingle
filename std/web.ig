// std/web — the browser (WASM) bridge for running Flare components client-side (W4, OFI-213).
//
// A Flare web app is an ordinary Ingle loop: pull the next DOM click, feed it to the frame with
// f.set_click(), build the component, render it with f.html(), push that into the page, and yield.
// Under emscripten these three primitives call into the page; on any other target they are inert stubs
// (the one web-flavored build — see `make web` / `make wasm` — runs everywhere, only DOES something in a
// browser). Compile a component to a browser app with `make wasm APP=<file.ig>`. See flare.set_click().
//
// The event loop shape (see examples/web/todo.ig):
//     loop {
//         f.begin()
//         web.pump(f)                  // drain this frame's DOM click + text-input events into f
//         ...build the component...
//         web.set_html(f.html())
//         web.yield_ms(30)
//     }
import "std/flare" as flare
import "std/string" as str


extern "c" {
    fn web_set_html(html: string) -> i64
    fn web_next_click() -> string
    fn web_next_input() -> string
    fn web_fetch(url: string) -> string
    fn web_sleep(ms: i64) -> i64
}


// fetch does a blocking HTTP GET in the browser and returns the response body, or a small
// {"_fetch_error":"…"} JSON on failure. It blocks the loop for the round-trip (emscripten ASYNCIFY), so
// call it ON DEMAND — a button click — not every frame. Parse the result with std/json.
fn fetch(url: string) -> string {
    return web_fetch(url)
}


// pump drains this frame's DOM events into `f`, right after begin(): the pending click (→ set_click) and
// every text-input change (→ set_input, one per "id\tvalue" event). After this, build the component and
// the clicked button / edited field register normally. The one call a Flare web app's loop needs.
fn pump(mut f: flare.Flare) {
    f.set_click(web_next_click())
    loop {
        let ev = web_next_input()
        if ev == "" {
            break
        }
        let tab = str.index_of(ev, "\t")
        if tab >= 0 {
            f.set_input(str.substring(ev, 0, tab), str.substring(ev, tab + 1, str.cp_count(ev)))
        }
    }
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
