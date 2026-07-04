// editor.ig — Inglenook's two stacked code windows ("Editor 1" over "Editor 2"): per-pane file
// tabs (click / close / drag-reorder — the Flare tabs primitive) over a scrollable, selectable,
// syntax-highlighted viewer (f.code — the std/highlight machinery markdown's fenced blocks use).
// Phase 1 is a VIEWER: contents load on open and re-load when the agent writes a file that's
// open (reload_if_open), so what you see always matches the disk the agent is acting on.
// Markdown files render as rich markdown — the viewer doubles as a docs preview.
import "std/flare" as flare
import "std/json" as json
import "std/string" as sstr


// Panes is both editors' state: parallel arrays per pane (open paths + their cached contents +
// the active tab). Pane 0 is the top window, pane 1 the bottom. MAX_TABS caps a strip the way
// flare_chat caps its conversation tabs.
struct Panes {
    a_paths: [string]
    a_text: [string]
    a_active: int
    b_paths: [string]
    b_text: [string]
    b_active: int


    // open loads `path` into `pane` (0 = top, 1 = bottom): an already-open file just refocuses
    // its tab (contents re-read, so re-opening is also a refresh); a new one appends a tab and
    // drops the least-recent beyond the cap.
    fn open(mut self, pane: int, path: string) {
        let text = read_file(path)
        if pane == 0 {
            var i = 0
            loop {
                if i == self.a_paths.len() {
                    break
                }
                if self.a_paths[i] == path {
                    self.a_text[i] = text
                    self.a_active = i
                    return
                }
                i = i + 1
            }
            self.a_paths.append(path)
            self.a_text.append(text)
            if self.a_paths.len() > 8 {
                self.a_paths.remove_at(0)
                let _ = self.a_text.remove_at(0)
            }
            self.a_active = self.a_paths.len() - 1
        } else {
            var i = 0
            loop {
                if i == self.b_paths.len() {
                    break
                }
                if self.b_paths[i] == path {
                    self.b_text[i] = text
                    self.b_active = i
                    return
                }
                i = i + 1
            }
            self.b_paths.append(path)
            self.b_text.append(text)
            if self.b_paths.len() > 8 {
                self.b_paths.remove_at(0)
                let _ = self.b_text.remove_at(0)
            }
            self.b_active = self.b_paths.len() - 1
        }
    }


    // reload_if_open re-reads `path` in any pane showing it — called when the agent's write_file
    // lands so an open file never shows stale bytes.
    fn reload_if_open(mut self, path: string) {
        var i = 0
        loop {
            if i == self.a_paths.len() {
                break
            }
            if self.a_paths[i] == path {
                self.a_text[i] = read_file(path)
            }
            i = i + 1
        }
        i = 0
        loop {
            if i == self.b_paths.len() {
                break
            }
            if self.b_paths[i] == path {
                self.b_text[i] = read_file(path)
            }
            i = i + 1
        }
    }


    // build renders one pane's content: the tab strip (labels are disambiguated basenames),
    // then the active file in a scrollable viewer — f.markdown for .md, f.code for everything
    // else. An empty pane shows the how-to hint instead.
    fn build(mut self, mut f: flare.Flare, pane: int, cw: int) {
        var paths: [string] = self.a_paths.clone()
        var active = self.a_active
        if pane == 1 {
            paths = self.b_paths.clone()
            active = self.b_active
        }
        if paths.len() == 0 {
            f.text_muted("No file open.")
            f.text_muted("Open one from the Files tab (right-click picks the pane).")
            return
        }
        if active >= paths.len() {
            active = paths.len() - 1
        }
        if active < 0 {
            active = 0
        }
        let tr = f.tabs("edtabs{pane}", tab_labels(paths), active)
        if tr.active >= 0 && tr.active < paths.len() && tr.active != active {
            active = tr.active
        }
        if tr.closed >= 0 && tr.closed < paths.len() {
            self.close(pane, tr.closed)
            if pane == 0 {
                active = self.a_active
                paths = self.a_paths.clone()
            } else {
                active = self.b_active
                paths = self.b_paths.clone()
            }
        }
        if tr.moved_from >= 0 && tr.moved_to >= 0 && tr.moved_from < paths.len() {
            self.reorder(pane, tr.moved_from, tr.moved_to)
            if pane == 0 {
                active = self.a_active
                paths = self.a_paths.clone()
            } else {
                active = self.b_active
                paths = self.b_paths.clone()
            }
        }
        if pane == 0 {
            self.a_active = active
        } else {
            self.b_active = active
        }
        if paths.len() == 0 {
            return
        }
        let path = paths[active]
        var text = ""
        if pane == 0 {
            text = self.a_text[active]
        } else {
            text = self.b_text[active]
        }
        f.scroll_begin("edscroll{pane}")
        if lang_for(path) == "markdown" {
            f.markdown(text, cw)
        } else {
            f.code("edcode{pane}", lang_for(path), text, cw)
        }
        f.scroll_end("edscroll{pane}")
    }


    // close removes tab `idx` from `pane` and keeps the active index sane.
    fn close(mut self, pane: int, idx: int) {
        if pane == 0 {
            if idx >= self.a_paths.len() {
                return
            }
            let _ = self.a_paths.remove_at(idx)
            let _ = self.a_text.remove_at(idx)
            if self.a_active >= self.a_paths.len() {
                self.a_active = self.a_paths.len() - 1
            }
            if self.a_active < 0 {
                self.a_active = 0
            }
        } else {
            if idx >= self.b_paths.len() {
                return
            }
            let _ = self.b_paths.remove_at(idx)
            let _ = self.b_text.remove_at(idx)
            if self.b_active >= self.b_paths.len() {
                self.b_active = self.b_paths.len() - 1
            }
            if self.b_active < 0 {
                self.b_active = 0
            }
        }
    }


    // reorder applies a tab drag: move index `from` before `to`, following the active file.
    fn reorder(mut self, pane: int, from: int, to: int) {
        if pane == 0 {
            let cur = self.a_paths[self.a_active]
            let p = self.a_paths.remove_at(from)
            let t = self.a_text.remove_at(from)
            self.a_paths = insert_str(self.a_paths, to, p)
            self.a_text = insert_str(self.a_text, to, t)
            self.a_active = pos_of(self.a_paths, cur)
        } else {
            let cur = self.b_paths[self.b_active]
            let p = self.b_paths.remove_at(from)
            let t = self.b_text.remove_at(from)
            self.b_paths = insert_str(self.b_paths, to, p)
            self.b_text = insert_str(self.b_text, to, t)
            self.b_active = pos_of(self.b_paths, cur)
        }
    }


    // active_path names the file focused in `pane` ("" when the pane is empty) — the Inspector
    // shows it, and later phases hang verdicts/tape context off it.
    fn active_path(self, pane: int) -> string {
        if pane == 0 {
            if self.a_active >= 0 && self.a_active < self.a_paths.len() {
                return self.a_paths[self.a_active]
            }
        } else {
            if self.b_active >= 0 && self.b_active < self.b_paths.len() {
                return self.b_paths[self.b_active]
            }
        }
        return ""
    }


    // to_json persists the open tabs (paths + active index per pane) — contents re-read on load,
    // the disk is the truth.
    fn to_json(self) -> json.Json {
        var aj: [json.Json] = []
        var i = 0
        loop {
            if i == self.a_paths.len() {
                break
            }
            aj.append(json.str(self.a_paths[i]))
            i = i + 1
        }
        var bj: [json.Json] = []
        i = 0
        loop {
            if i == self.b_paths.len() {
                break
            }
            bj.append(json.str(self.b_paths[i]))
            i = i + 1
        }
        return json.obj([
            json.member("a", json.arr(aj)),
            json.member("a_active", json.num(self.a_active)),
            json.member("b", json.arr(bj)),
            json.member("b_active", json.num(self.b_active))
        ])
    }
}


// load rebuilds the panes from their store fragment: every saved path re-opens (fresh read;
// files that vanished since last run come back empty and harmless), then the active tabs settle.
fn load(j: json.Json) -> Panes {
    var p = new_panes()
    if json.is_null(j) {
        return p
    }
    let aj = json.get(j, "a")
    var i = 0
    loop {
        if i == json.length(aj) {
            break
        }
        p.open(0, json.as_str(json.at(aj, i)))
        i = i + 1
    }
    let bj = json.get(j, "b")
    i = 0
    loop {
        if i == json.length(bj) {
            break
        }
        p.open(1, json.as_str(json.at(bj, i)))
        i = i + 1
    }
    if !json.is_null(json.get(j, "a_active")) {
        let a = json.as_int(json.get(j, "a_active"))
        if a >= 0 && a < p.a_paths.len() {
            p.a_active = a
        }
    }
    if !json.is_null(json.get(j, "b_active")) {
        let b = json.as_int(json.get(j, "b_active"))
        if b >= 0 && b < p.b_paths.len() {
            p.b_active = b
        }
    }
    return p
}


fn new_panes() -> Panes {
    return Panes {
        a_paths: [],
        a_text: [],
        a_active: 0,
        b_paths: [],
        b_text: [],
        b_active: 0
    }
}


// lang_for maps a filename to the highlighter's language id by extension. Unknown extensions
// fall back to "" — std/highlight reads unknowns with its broad C-family default.
fn lang_for(path: string) -> string {
    let parts = path.split(".")
    if parts.len() < 2 {
        return ""
    }
    let ext = parts[parts.len() - 1]
    if ext == "ig" || ext == "em" {
        return "ember"
    }
    if ext == "c" || ext == "h" {
        return "c"
    }
    if ext == "py" {
        return "python"
    }
    if ext == "sh" {
        return "sh"
    }
    if ext == "md" {
        return "markdown"
    }
    if ext == "json" {
        return "json"
    }
    if ext == "yml" || ext == "yaml" {
        return "yaml"
    }
    if ext == "toml" {
        return "toml"
    }
    return ""
}


// basename returns the final path component — the tab label.
fn basename(path: string) -> string {
    let parts = path.split("/")
    if parts.len() > 0 {
        return parts[parts.len() - 1]
    }
    return path
}


// pos_of returns the index of `v` in `arr`, or 0 if absent (a safe active index).
fn pos_of(arr: [string], v: string) -> int {
    var i = 0
    loop {
        if i == arr.len() {
            break
        }
        if arr[i] == v {
            return i
        }
        i = i + 1
    }
    return 0
}


// insert_str returns `arr` with `v` inserted before `idx` (>= len appends) — the [string] twin
// of flare_chat's insert_int; Ingle arrays have append/remove_at but no insert.
fn insert_str(arr: [string], idx: int, v: string) -> [string] {
    var out: [string] = []
    var k = 0
    loop {
        if k == arr.len() {
            break
        }
        if k == idx {
            out.append(v)
        }
        out.append(arr[k])
        k = k + 1
    }
    if idx >= arr.len() {
        out.append(v)
    }
    return out
}


// tab_labels turns the open paths into UNIQUE tab labels: the basename, then — because the tabs
// primitive keys chips by label — any duplicate gets its parent directory prefixed, and a still-
// colliding label a " (n)" suffix. Two open README.md files read "docs/README.md" style.
fn tab_labels(paths: [string]) -> [string] {
    var out: [string] = []
    var i = 0
    loop {
        if i == paths.len() {
            break
        }
        var lbl = basename(paths[i])
        var dup = false
        var j = 0
        loop {
            if j == paths.len() {
                break
            }
            if j != i && basename(paths[j]) == lbl {
                dup = true
            }
            j = j + 1
        }
        if dup {
            let parts = paths[i].split("/")
            if parts.len() >= 2 {
                lbl = parts[parts.len() - 2] + "/" + lbl
            }
        }
        var n = 2
        loop {
            var seen = false
            var k = 0
            loop {
                if k == out.len() {
                    break
                }
                if out[k] == lbl {
                    seen = true
                }
                k = k + 1
            }
            if !seen {
                break
            }
            lbl = lbl + " ({n})"
            n = n + 1
        }
        out.append(lbl)
        i = i + 1
    }
    return out
}
