// files.ig — Inglenook's project tree: the launch directory browsed live via the list_dir
// builtin. State is a Tree struct (expanded dirs + a per-dir listing cache, refreshed on demand
// so an immediate-mode frame never re-scans the disk); the walk renders dirs-first per level,
// hides dot-entries (.git and friends), and reports clicks back through per-frame action fields
// (open_path/open_pane) the way flare_chat's panels report theirs — set during build, applied by
// ide.ig after layout. A right-click (or the "..." affordance) targets the OTHER editor pane.
import "std/flare" as flare
import "std/string" as sstr


// Tree is the Files tab's whole state. cache_dirs/cache_lists are parallel arrays (dir path →
// its raw list_dir string); expanded holds the open directory paths, relative to the launch dir.
// open_path/open_pane/menu_* are per-frame ACTION fields: written during build, read + cleared
// by ide.ig after the frame (the checkout pattern, OFI-072 — never act mid-layout).
struct Tree {
    expanded: [string]
    cache_dirs: [string]
    cache_lists: [string]
    open_path: string
    open_pane: int
    menu_path: string
    menu_x: int
    menu_y: int


    // listing returns dir's entries (the raw newline-joined list_dir string), cached until the
    // next refresh() so the tree costs zero syscalls on an idle frame.
    fn listing(mut self, dir: string) -> string {
        var i = 0
        loop {
            if i == self.cache_dirs.len() {
                break
            }
            if self.cache_dirs[i] == dir {
                return self.cache_lists[i]
            }
            i = i + 1
        }
        let fresh = list_dir(dir)
        self.cache_dirs.append(dir)
        self.cache_lists.append(fresh)
        return fresh
    }


    // refresh drops the whole listing cache — every expanded dir re-reads lazily on its next
    // frame. Wired to the header button and the ⌘K palette.
    fn refresh(mut self) {
        self.cache_dirs = []
        self.cache_lists = []
    }


    fn is_expanded(self, dir: string) -> bool {
        var i = 0
        loop {
            if i == self.expanded.len() {
                return false
            }
            if self.expanded[i] == dir {
                return true
            }
            i = i + 1
        }
        return false
    }


    fn toggle(mut self, dir: string) {
        var i = 0
        loop {
            if i == self.expanded.len() {
                break
            }
            if self.expanded[i] == dir {
                self.expanded.remove_at(i)
                return
            }
            i = i + 1
        }
        self.expanded.append(dir)
    }


    // build renders the Files tab's content: a header row (project label + Refresh), then the
    // recursive walk from the launch directory. Click a file → open_path/open_pane records it.
    fn build(mut self, mut f: flare.Flare, project: string) {
        f.row(flare.START, flare.CENTER)
        f.text_muted(project)
        f.spacer()
        if f.ghost_button("Refresh") {
            self.refresh()
        }
        f.end()
        self.walk(f, ".", 0)
    }


    // walk renders one directory level: subdirectories first (expand/collapse rows, recursing
    // into expanded ones), then files. Dot-entries are hidden — the tree is for the project's
    // sources, not its plumbing. Indentation is a strut per depth level.
    fn walk(mut self, mut f: flare.Flare, dir: string, depth: int) {
        let raw = self.listing(dir)
        if raw.len() == 0 {
            return
        }
        let entries = raw.split("\n")
        var pass = 0                                       // 0 = directories, 1 = files
        loop {
            if pass == 2 {
                break
            }
            var i = 0
            loop {
                if i == entries.len() {
                    break
                }
                let e = entries[i]
                let is_dir = sstr.ends_with(e, "/")
                if e.len() == 0 || sstr.starts_with(e, ".") || (is_dir && pass == 1) || (!is_dir && pass == 0) {
                    i = i + 1
                    continue
                }
                var name = e
                var path = e
                if is_dir {
                    name = sstr.cp_slice(e, 0, e.char_count() - 1)   // drop the trailing '/'
                    path = name
                }
                if dir != "." {
                    path = dir + "/" + name
                }
                f.key("ft:{path}")
                f.row(flare.START, flare.CENTER)
                f.strut(12 * depth, 0)
                if is_dir {
                    var arrow = ">"                        // ASCII arrows — the embedded font tofus U+25B8
                    if self.is_expanded(path) {
                        arrow = "v"
                    }
                    if f.nav_item("{arrow} {name}", false) {
                        self.toggle(path)
                    }
                } else {
                    if f.nav_item(name, false) {
                        self.open_path = path              // click → open in Editor 1 (applied post-frame)
                        self.open_pane = 0
                    }
                    if f.right_clicked() {                 // right-click → "which pane?" popover
                        self.menu_path = path
                        self.menu_x = mouse_x()
                        self.menu_y = mouse_y()
                    }
                }
                f.end()
                f.key_clear()
                if is_dir && self.is_expanded(path) {
                    self.walk(f, path, depth + 1)
                }
                i = i + 1
            }
            pass = pass + 1
        }
    }


    // build_menu draws the right-click popover for menu_path: open the file in either editor
    // pane. Layered last by ide.ig so it floats above the dock, like the conversation menu.
    fn build_menu(mut self, mut f: flare.Flare) {
        if self.menu_path.len() == 0 {
            return
        }
        if !f.popover_begin("filemenu", self.menu_x, self.menu_y) {
            self.menu_path = ""
        }
        if f.menu_item("Open in Editor 1") {
            self.open_path = self.menu_path
            self.open_pane = 0
            self.menu_path = ""
        }
        if f.menu_item("Open in Editor 2") {
            self.open_path = self.menu_path
            self.open_pane = 1
            self.menu_path = ""
        }
        f.popover_end()
    }
}


// new_tree starts with the top level expanded implicitly (the walk always lists ".") and
// nothing else open — the saved workspace restores the user's expansions on load.
fn new_tree() -> Tree {
    return Tree {
        expanded: [],
        cache_dirs: [],
        cache_lists: [],
        open_path: "",
        open_pane: 0,
        menu_path: "",
        menu_x: 0,
        menu_y: 0
    }
}
