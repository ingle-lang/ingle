// lint.ig — live diagnostics: red squiggles as you type. On a debounced pause, the current editor
// buffer is handed to a worker fiber that runs the REAL compiler over it (`inglec --diagnostics=json`)
// and returns the lines that don't type-check. Inglenook doesn't ship a re-implemented language server
// — it runs the same compiler that builds it, on your buffer, off the render thread. (The self-hosted
// checker could run in-process, but it doesn't track source positions yet — a selfhost milestone — so
// it can't place a squiggle; the real compiler can, so we use it.)
import "std/proc" as proc
import "std/json" as json
import "std/string" as sstr
import "verify" as verify


let LINT_SETTLE = 7     // frames the buffer must sit unchanged before a check fires (debounce)


// Linter caches, per open file, the 1-based lines that failed to type-check, and debounces the buffer
// so the compiler runs on a pause, not every keystroke. Only ONE check is in flight at a time.
struct Linter {
    paths: [string]         // files we have a result for…
    lines: [string]         // …their comma-joined error lines (parallel to paths)
    checking: bool
    checking_path: string   // the file the in-flight check is for
    seen_code: string       // the buffer as of last frame (debounce: detect "stopped typing")
    seen_path: string
    stable: int             // frames the buffer has sat unchanged
    pend_code: string       // per-frame action: code to dispatch ("" = none)


    fn begin_frame(mut self) {
        self.pend_code = ""
    }


    // lines_for returns the cached error lines (1-based) for `path` — the squiggle set the editor draws.
    fn lines_for(self, path: string) -> [int] {
        var out: [int] = []
        var i = 0
        loop {
            if i == self.paths.len() {
                break
            }
            if self.paths[i] == path {
                let parts = self.lines[i].split(",")
                var k = 0
                loop {
                    if k == parts.len() {
                        break
                    }
                    if parts[k].len() > 0 {
                        match parts[k].parse_int() {
                            case Some(n) { out.append(n) }
                            case None {}
                        }
                    }
                    k = k + 1
                }
                return out
            }
            i = i + 1
        }
        return out
    }


    // note_buffer is called each frame with the active editor's path + live text. It debounces: once the
    // buffer has sat unchanged for LINT_SETTLE frames and differs from the last check, it queues a check.
    // Only .ig/.em files are linted (others aren't Ingle). Returns nothing; sets pend_code for ide.ig.
    fn note_buffer(mut self, path: string, code: string) {
        if !is_ingle(path) {
            return
        }
        if code != self.seen_code || path != self.seen_path {
            self.seen_code = code                 // buffer moved → restart the settle timer
            self.seen_path = path
            self.stable = 0
            return
        }
        self.stable = self.stable + 1
        // Fire ONCE per settle period: `stable == LINT_SETTLE` (not `>=`) is only true the single frame
        // it crosses the threshold, so a stable buffer isn't re-checked every frame. (An earlier
        // `code != last_code` guard here was redundant AND wrong — it permanently suppressed re-checking
        // if you edited then reverted to the exact prior text, leaving stale squiggles. Removed.)
        if self.stable == LINT_SETTLE && !self.checking {
            self.checking = true
            self.checking_path = path
            self.pend_code = code                 // dispatched to the worker after the frame
        }
    }


    // apply_result lands a finished check (the CSV of error lines from the tooling worker): store it
    // against the file that was checked, and clear the in-flight flag.
    fn apply_result(mut self, csv: string) {
        self.store(self.checking_path, csv)
        self.checking = false
    }


    // store caches `csv` (comma-joined error lines) for `path`, replacing any prior result.
    fn store(mut self, path: string, csv: string) {
        var i = 0
        loop {
            if i == self.paths.len() {
                break
            }
            if self.paths[i] == path {
                self.lines[i] = csv
                return
            }
            i = i + 1
        }
        self.paths.append(path)
        self.lines.append(csv)
    }
}


fn new_linter() -> Linter {
    return Linter {
        paths: [],
        lines: [],
        checking: false,
        checking_path: "",
        seen_code: "",
        seen_path: "",
        stable: 0,
        pend_code: ""
    }
}


// is_ingle reports whether `path` is an Ingle source file worth linting.
fn is_ingle(path: string) -> bool {
    return sstr.ends_with(path, ".ig") || sstr.ends_with(path, ".em")
}


// run_lint writes the buffer to a temp file, runs the compiler's machine-readable diagnostics over it,
// and returns the comma-joined error LINES (unique, in order). Called on the shared tooling worker
// fiber (tools.ig) — one tooling fiber instead of three, to ease worker-thread contention on the UI.
fn run_lint(code: string) -> string {
    let path = tmp_path()
    write_file(path, code)
    let cc = verify.inglec_path()
    let q = proc.shell_quote(path)
    let r = proc.run(cc + " --emit=bytecode --diagnostics=json " + q)
    return error_lines(r.err())
}


// tmp_path is where the buffer is written for the compiler to read (user-scoped, always writable).
fn tmp_path() -> string {
    let e = env("INGLENOOK_LINT_TMP")
    if e.len() > 0 {
        return e
    }
    return env("HOME") + "/.inglenook-lint.ig"
}


// error_lines parses the --diagnostics=json stream (one JSON object per error, on stderr) into a
// comma-joined list of the unique 1-based line numbers that carried an error.
fn error_lines(diag: string) -> string {
    var seen: [int] = []
    let rows = diag.split("\n")
    var i = 0
    loop {
        if i == rows.len() {
            break
        }
        let row = sstr.trim(rows[i])
        if sstr.starts_with(row, "\{") {
            match json.parse(row) {
                case Ok(o) {
                    if !json.is_null(json.get(o, "line")) {
                        let ln = json.as_int(json.get(o, "line"))
                        if !int_in(seen, ln) {
                            seen.append(ln)
                        }
                    }
                }
                case Err(e) {}
            }
        }
        i = i + 1
    }
    var out = ""
    var k = 0
    loop {
        if k == seen.len() {
            break
        }
        if k > 0 {
            out = out + ","
        }
        out = out + "{seen[k]}"
        k = k + 1
    }
    return out
}


// int_in reports whether `n` is already in `xs` (dedup of the error lines).
fn int_in(xs: [int], n: int) -> bool {
    var i = 0
    loop {
        if i == xs.len() {
            break
        }
        if xs[i] == n {
            return true
        }
        i = i + 1
    }
    return false
}
