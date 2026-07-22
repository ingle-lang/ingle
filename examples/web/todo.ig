// examples/web/todo.ig — a live todo app in the browser via WebAssembly (W4, full interactivity).
// Text input, a button, and a checkbox + delete per item — all from ONE Flare component, the same
// builder API that draws the desktop window. Build + run:
//   make wasm APP=examples/web/todo.ig   then serve build/wasm and open todo.html
import "std/flare" as flare
import "std/web" as web


fn main() -> int {
    var f = flare.new()
    var items: [string] = []
    var done: [bool] = []
    var ids: [int] = []                        // a stable id per item, so a row's widget ids survive deletes
    var next_id = 0
    var draft = ""
    loop {
        f.begin()
        web.pump(f)                            // drain this frame's DOM click + text-input events into f

        f.heading("Ingle · Flare todo (WASM)")
        f.markdown("A **live todo app** — text input, a button, and a checkbox per item — all running as WebAssembly from one Flare component.", 560)
        f.divider()

        f.row(0, 1)                            // the composer: field + Add
        draft = f.text_field("draft", draft)
        let add = f.primary("Add")
        f.end()
        if add && draft != "" {
            items.append(draft)
            done.append(false)
            ids.append(next_id)
            next_id = next_id + 1
            draft = ""
        }

        var i = 0
        loop {
            if i == items.len() {
                break
            }
            f.key("item/{ids[i]}")             // a stable per-item scope → unique ids for this row's widgets
            f.row(0, 1)
            done[i] = f.checkbox("done", items[i], done[i])
            let del = f.danger("✕")
            f.end()
            f.key_clear()
            if del {
                let _a = items.remove_at(i)
                let _b = done.remove_at(i)
                let _c = ids.remove_at(i)
            } else {
                i = i + 1
            }
        }

        web.set_html(f.html())
        web.yield_ms(30)
    }
}
