// examples/web/repo.ig — a live, data-driven Flare app in the browser (W4 + network).
// Click Load: the component fetches the Ingle repo from the GitHub API over web.fetch (a real HTTP GET,
// awaited via emscripten ASYNCIFY), parses the JSON with std/json, and renders it — all in WebAssembly.
// Build + run:  make wasm APP=examples/web/repo.ig   then serve build/wasm and open repo.html
import "std/flare" as flare
import "std/web" as web
import "std/json" as json


fn main() -> int {
    var f = flare.new()
    var loaded = false
    var status = "Click Load to fetch ingle-lang/ingle live from the GitHub API."
    var name = ""
    var desc = ""
    var stars = 0
    var lang = ""
    loop {
        f.begin()
        web.pump(f)

        f.heading("Ingle · a live data-driven web app (WASM)")
        f.markdown("This Flare component fetches **live data** from the GitHub API over `web.fetch`, parses it with `std/json`, and renders it — all running in WebAssembly.", 620)
        f.divider()

        if f.primary("Load ingle-lang/ingle") {
            let body = web.fetch("https://api.github.com/repos/ingle-lang/ingle")
            match json.parse(body) {
                case Ok(j) {
                    let full = json.as_str(json.get(j, "full_name"))
                    if full != "" {
                        name = full
                        desc = json.as_str(json.get(j, "description"))
                        stars = json.as_int(json.get(j, "stargazers_count"))
                        lang = json.as_str(json.get(j, "language"))
                        loaded = true
                        status = "Loaded live from api.github.com"
                    } else {
                        loaded = false
                        let msg = json.as_str(json.get(j, "message"))
                        let ferr = json.as_str(json.get(j, "_fetch_error"))
                        status = "Could not load: " + msg + ferr
                    }
                }
                case Err(e) {
                    loaded = false
                    status = "Bad response: {e}"
                }
            }
        }

        if loaded {
            f.panel_begin(0, 3)
            f.heading(name)
            f.label(desc)
            f.divider()
            f.row(0, 1)
            f.label("★ {stars} stars")
            f.label("·")
            f.label(lang)
            f.end()
            f.end()
        } else {
            f.label(status)
        }

        web.set_html(f.html())
        web.yield_ms(30)
    }
}
