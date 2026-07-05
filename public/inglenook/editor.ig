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
    a_dirty: [bool]
    a_active: int
    b_paths: [string]
    b_text: [string]
    b_dirty: [bool]
    b_active: int
    saved_path: string       // per-frame action: a file was just saved to disk → ide.ig refreshes the tree
    implement_code: string   // per-frame action: contract-first Implement was clicked → ide.ig sends it to the agent


    // open loads `path` into `pane` (0 = top, 1 = bottom): an already-open file just refocuses its
    // tab WITHOUT re-reading (so unsaved edits survive re-opening); a new one is read from disk,
    // appended as a clean (not-dirty) tab, and the least-recent dropped beyond the cap.
    fn open(mut self, pane: int, path: string) {
        if pane == 0 {
            var i = 0
            loop {
                if i == self.a_paths.len() {
                    break
                }
                if self.a_paths[i] == path {
                    self.a_active = i
                    return
                }
                i = i + 1
            }
            self.a_paths.append(path)
            self.a_text.append(read_file(path))
            self.a_dirty.append(false)
            if self.a_paths.len() > 8 {
                self.a_paths.remove_at(0)
                let _ = self.a_text.remove_at(0)
                let _ = self.a_dirty.remove_at(0)
            }
            self.a_active = self.a_paths.len() - 1
        } else {
            var i = 0
            loop {
                if i == self.b_paths.len() {
                    break
                }
                if self.b_paths[i] == path {
                    self.b_active = i
                    return
                }
                i = i + 1
            }
            self.b_paths.append(path)
            self.b_text.append(read_file(path))
            self.b_dirty.append(false)
            if self.b_paths.len() > 8 {
                self.b_paths.remove_at(0)
                let _ = self.b_text.remove_at(0)
                let _ = self.b_dirty.remove_at(0)
            }
            self.b_active = self.b_paths.len() - 1
        }
    }


    // reload_if_open re-reads `path` in any pane showing it — called when the agent's write_file
    // lands so an open file matches the bytes the agent wrote (its write is authoritative, so this
    // also clears the pane's dirty flag; a rare user-vs-agent edit conflict resolves to the agent).
    fn reload_if_open(mut self, path: string) {
        var i = 0
        loop {
            if i == self.a_paths.len() {
                break
            }
            if self.a_paths[i] == path {
                self.a_text[i] = read_file(path)
                self.a_dirty[i] = false
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
                self.b_dirty[i] = false
            }
            i = i + 1
        }
    }


    // build renders one pane's content: the tab strip (labels are disambiguated basenames),
    // then the active file in a scrollable viewer — f.markdown for .md, f.code for everything
    // else. An empty pane shows the how-to hint instead. `hot_line` spotlights the execution-tape line
    // as you scrub (the Run panel); `err_lines` flags compiler-diagnostic lines with a red squiggle.
    fn build(mut self, mut f: flare.Flare, pane: int, cw: int, hot_line: int, err_lines: [int]) {
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
        var dirty = false
        if pane == 0 {
            text = self.a_text[active]
            dirty = self.a_dirty[active]
        } else {
            text = self.b_text[active]
            dirty = self.b_dirty[active]
        }

        // Toolbar: the path (with a • when modified) on the left, a Save button on the right.
        f.row(flare.START, flare.CENTER)
        var label = basename(path)
        if dirty {
            label = "• " + label
        }
        f.text_muted(label)
        f.spacer()
        if lang_for(path) == "ember" {              // contract-first: hand the code to the agent to implement
            if f.ghost_button("Implement") {
                self.implement_code = text
                f.toast("Sent to the agent — the Verified Loop will drive it to green")
            }
            f.tooltip("Send this code to the agent and let the Verified Loop implement it until its contracts hold")
        }
        if dirty {
            if f.ghost_button("Save") {
                write_file(path, text)
                if pane == 0 {
                    self.a_dirty[active] = false
                } else {
                    self.b_dirty[active] = false
                }
                self.saved_path = path
                f.toast("Saved " + basename(path))
            }
            f.tooltip("Write this file to disk (⌘S)")
        }
        f.end()

        // The editable, syntax-highlighted editor — keyed by pane AND path so each open file keeps
        // its own scroll/caret and switching tabs never carries one file's position onto another.
        // Diagnostic squiggles (err_lines) and the tape spotlight (hot_line) ride along.
        let ekey = "edcode{pane}:{path}"
        let edited = f.code_editor_marked(ekey, lang_for(path), text, err_lines, hot_line)
        if edited != text {
            if pane == 0 {
                self.a_text[active] = edited
                self.a_dirty[active] = true
            } else {
                self.b_text[active] = edited
                self.b_dirty[active] = true
            }
        }
    }


    // save_active writes the active file of `pane` to disk and clears its dirty flag, returning the
    // path saved — or "" if the pane is empty or the active file has no unsaved edits (so ⌘S over a
    // clean file is a no-op, never touching the mtime). Drives the ⌘S shortcut from ide.ig.
    fn save_active(mut self, pane: int) -> string {
        if pane == 0 {
            if self.a_active < 0 || self.a_active >= self.a_paths.len() || !self.a_dirty[self.a_active] {
                return ""
            }
            write_file(self.a_paths[self.a_active], self.a_text[self.a_active])
            self.a_dirty[self.a_active] = false
            return self.a_paths[self.a_active]
        }
        if self.b_active < 0 || self.b_active >= self.b_paths.len() || !self.b_dirty[self.b_active] {
            return ""
        }
        write_file(self.b_paths[self.b_active], self.b_text[self.b_active])
        self.b_dirty[self.b_active] = false
        return self.b_paths[self.b_active]
    }


    // any_dirty reports whether any open file in either pane has unsaved edits (the window-title •).
    fn any_dirty(self) -> bool {
        var i = 0
        loop {
            if i == self.a_dirty.len() {
                break
            }
            if self.a_dirty[i] {
                return true
            }
            i = i + 1
        }
        i = 0
        loop {
            if i == self.b_dirty.len() {
                break
            }
            if self.b_dirty[i] {
                return true
            }
            i = i + 1
        }
        return false
    }


    // close removes tab `idx` from `pane` and keeps the active index sane.
    fn close(mut self, pane: int, idx: int) {
        if pane == 0 {
            if idx >= self.a_paths.len() {
                return
            }
            let _ = self.a_paths.remove_at(idx)
            let _ = self.a_text.remove_at(idx)
            let _ = self.a_dirty.remove_at(idx)
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
            let _ = self.b_dirty.remove_at(idx)
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
            let d = self.a_dirty.remove_at(from)
            self.a_paths = insert_str(self.a_paths, to, p)
            self.a_text = insert_str(self.a_text, to, t)
            self.a_dirty = insert_bool(self.a_dirty, to, d)
            self.a_active = pos_of(self.a_paths, cur)
        } else {
            let cur = self.b_paths[self.b_active]
            let p = self.b_paths.remove_at(from)
            let t = self.b_text.remove_at(from)
            let d = self.b_dirty.remove_at(from)
            self.b_paths = insert_str(self.b_paths, to, p)
            self.b_text = insert_str(self.b_text, to, t)
            self.b_dirty = insert_bool(self.b_dirty, to, d)
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


    // active_text returns the LIVE buffer of `pane`'s active file (unsaved edits included, "" if empty)
    // — the linter checks this so squiggles reflect what you're typing, not the last saved bytes.
    fn active_text(self, pane: int) -> string {
        if pane == 0 {
            if self.a_active >= 0 && self.a_active < self.a_text.len() {
                return self.a_text[self.a_active]
            }
        } else {
            if self.b_active >= 0 && self.b_active < self.b_text.len() {
                return self.b_text[self.b_active]
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
        a_dirty: [],
        a_active: 0,
        b_paths: [],
        b_text: [],
        b_dirty: [],
        b_active: 0,
        saved_path: "",
        implement_code: ""
    }
}


// insert_bool returns `arr` with `v` inserted before `idx` (>= len appends) — the [bool] twin of
// insert_str, for keeping the dirty flags aligned with the paths through a tab reorder.
fn insert_bool(arr: [bool], idx: int, v: bool) -> [bool] {
    var out: [bool] = []
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
