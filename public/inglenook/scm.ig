// scm.ig — Inglenook's Source panel: version control driven graphically, backed by Quog (the safe
// VCS that is itself an Ingle app). Inglenook shells out to the shipped `quog` binary via std/proc —
// exactly as the Verified Loop shells out to `inglec` — reading its `--json` porcelain (status / log /
// branch). Two Ingle-built apps validating each other: an Inglenook user's default version control is
// the *safe* one, and every use of the panel exercises Quog end to end.
//
// The heavy work (three subprocess calls) runs off the render thread on the shared tooling worker
// (tools.ig, kind "Q"), so the 60fps UI never stalls. The parsed state below is refreshed from that
// worker's reply; the want_* fields are per-frame ACTION flags — set during build, applied by ide.ig
// after layout (the OFI-072 checkout pattern, like files.ig's Tree and chat.ig's Chat).
import "std/proc" as proc
import "std/json" as json
import "std/string" as sstr
import "std/flare" as flare


// Change is one working-tree change since the last save (status is "added" / "modified" / "deleted").
struct Change {
    status: string
    path: string
}


// Commit is one entry in the current branch's history (short id for display, full id kept for later
// drill-down in Phase 3's diff view; time is the commit timestamp).
struct Commit {
    id: string
    short: string
    time: int
    message: string
}


// Scm is the Source tab's whole state. The state fields are refreshed from `quog --json` off-thread;
// want_refresh / want_init are per-frame action flags cleared by begin_frame, set during build, and
// read + acted on by ide.ig post-frame.
struct Scm {
    loaded: bool             // has a worker reply landed at least once
    repo: bool               // is there a Quog repo in the working directory
    missing: bool            // the `quog` binary itself could not be run (not on PATH)
    branch: string           // the current branch (from status)
    clean: bool              // nothing changed since the last save
    changes: [Change]        // the working-tree status
    commits: [Commit]        // the branch history
    branches: [string]       // every branch name
    current: string          // the current branch (from branch list)
    err: string              // a diagnostic to surface when there's no repo
    refreshing: bool         // a quog query is in flight
    want_refresh: bool       // action: re-query quog
    want_init: bool          // action: initialise a repo here, then query


    // begin_frame clears the per-frame action flags before the panel builds.
    fn begin_frame(mut self) {
        self.want_refresh = false
        self.want_init = false
    }


    // build renders the Source tab: a header (branch + Refresh), the working-tree status, the branch
    // history, and the branch list. On first view it requests a refresh so the panel self-loads.
    fn build(mut self, mut f: flare.Flare) {
        f.row(flare.START, flare.CENTER)
        f.text_muted("Source")
        f.spacer()
        if self.refreshing {
            f.text_muted("working…")
        } else if f.ghost_button("Refresh") {
            self.want_refresh = true
        }
        f.end()

        if !self.loaded {
            if !self.refreshing {
                self.want_refresh = true             // lazy self-load the first time the tab is shown
            }
            f.label("Loading…")
            return
        }

        if self.missing {
            f.paragraph("Couldn't run quog. Install it (make install-quog) or set INGLENOOK_QUOG.", 240)
            return
        }

        if !self.repo {
            f.paragraph("No Quog repo in this folder yet.", 240)
            f.spacer()
            if f.primary("Initialize Quog repo") {
                self.want_init = true
            }
            if self.err.len() > 0 {
                f.text_muted(self.err)
            }
            return
        }

        // --- branch + working-tree integrity ---
        f.row(flare.START, flare.CENTER)
        f.badge(self.branch, 3)
        f.spacer()
        if self.clean {
            f.badge("clean", 1)
        } else {
            f.badge("{self.changes.len()} change(s)", 0)
        }
        f.end()
        f.divider()

        // --- working-tree status ---
        f.text_muted("Changes")
        if self.changes.len() == 0 {
            f.label("nothing changed since the last save")
        } else {
            var i = 0
            loop {
                if i == self.changes.len() {
                    break
                }
                let c = self.changes[i]
                f.row(flare.START, flare.CENTER)
                f.badge(c.status, status_tone(c.status))
                f.strut(6, 0)
                f.label(c.path)
                f.end()
                i = i + 1
            }
        }
        f.divider()

        // --- branch history ---
        f.text_muted("History — {self.branch}")
        if self.commits.len() == 0 {
            f.label("no saves yet")
        } else {
            var j = 0
            loop {
                if j == self.commits.len() {
                    break
                }
                let cm = self.commits[j]
                f.row(flare.START, flare.CENTER)
                f.text_muted(cm.short)
                f.strut(8, 0)
                f.label(cm.message)
                f.end()
                j = j + 1
            }
        }

        // --- branch list (display only in Phase 1; switching arrives in Phase 3) ---
        if self.branches.len() > 1 {
            f.divider()
            f.text_muted("Branches")
            var b = 0
            loop {
                if b == self.branches.len() {
                    break
                }
                let name = self.branches[b]
                f.row(flare.START, flare.CENTER)
                if name == self.current {
                    f.label("* {name}")
                } else {
                    f.label("  {name}")
                }
                f.end()
                b = b + 1
            }
        }
    }


    // apply_result folds a worker reply (the packed JSON from run_scm) back into the panel state.
    fn apply_result(mut self, s: string) {
        self.refreshing = false
        self.loaded = true
        self.changes = []
        self.commits = []
        self.branches = []
        match json.parse(s) {
            case Ok(root) {
                self.repo = json.as_bool(json.get(root, "repo"))
                self.missing = json.as_bool(json.get(root, "missing"))
                self.err = json.as_str(json.get(root, "err"))
                if self.repo {
                    self.parse_status(json.as_str(json.get(root, "status")))
                    self.parse_log(json.as_str(json.get(root, "log")))
                    self.parse_branch(json.as_str(json.get(root, "branch")))
                }
            }
            case Err(e) {
                self.repo = false
                self.err = "could not parse quog output"
            }
        }
    }


    // parse_status reads `quog status --json` into branch / clean / changes.
    fn parse_status(mut self, s: string) {
        match json.parse(s) {
            case Ok(st) {
                self.branch = json.as_str(json.get(st, "branch"))
                self.clean = json.as_bool(json.get(st, "clean"))
                let arr = json.get(st, "changes")
                var i = 0
                loop {
                    if i == json.length(arr) {
                        break
                    }
                    let it = json.at(arr, i)
                    self.changes.append(Change {
                        status: json.as_str(json.get(it, "status")),
                        path: json.as_str(json.get(it, "path"))
                    })
                    i = i + 1
                }
            }
            case Err(e) {}
        }
    }


    // parse_log reads `quog log --json` into the commit list (tip first).
    fn parse_log(mut self, s: string) {
        match json.parse(s) {
            case Ok(lg) {
                let arr = json.get(lg, "commits")
                var i = 0
                loop {
                    if i == json.length(arr) {
                        break
                    }
                    let it = json.at(arr, i)
                    self.commits.append(Commit {
                        id: json.as_str(json.get(it, "id")),
                        short: json.as_str(json.get(it, "short")),
                        time: json.as_int(json.get(it, "time")),
                        message: json.as_str(json.get(it, "message"))
                    })
                    i = i + 1
                }
            }
            case Err(e) {}
        }
    }


    // parse_branch reads `quog branch --json` into current + the branch names.
    fn parse_branch(mut self, s: string) {
        match json.parse(s) {
            case Ok(br) {
                self.current = json.as_str(json.get(br, "current"))
                let arr = json.get(br, "branches")
                var i = 0
                loop {
                    if i == json.length(arr) {
                        break
                    }
                    self.branches.append(json.as_str(json.at(arr, i)))
                    i = i + 1
                }
            }
            case Err(e) {}
        }
    }
}


// status_tone maps a change status to a Flare badge tone: added = green, deleted = red, modified = info.
fn status_tone(s: string) -> int {
    if s == "added" {
        return 1
    }
    if s == "deleted" {
        return 2
    }
    return 3
}


// quog_path resolves the VCS binary to shell out to: $INGLENOOK_QUOG if set (dev: build/quog), else
// `quog` on PATH (what `make install-quog` installs). One place so every invocation agrees — the
// inglec_path() pattern from verify.ig.
fn quog_path() -> string {
    let e = env("INGLENOOK_QUOG")
    if e.len() > 0 {
        return e
    }
    return "quog"
}


// run_scm is the tooling-worker task (tools.ig kind "Q"): shell out to quog and pack the three read
// commands' JSON into one reply. payload "init" runs `quog init` first, then queries. Repo detection
// keys off `status`: exit 0 with a JSON object means a repo is present; a shell "command not found"
// (exit 127) means quog itself is missing, told apart from an ordinary "no repo here" error.
fn run_scm(payload: string) -> string {
    let q = proc.shell_quote(quog_path())
    if payload == "init" {
        let _ = proc.run(q + " init")
    }
    let r_status = proc.run(q + " status --json")
    var missing = false
    var repo = false
    var err = ""
    if r_status.ok() && sstr.contains(r_status.out(), "\{") {
        repo = true
    } else if r_status.code() == 127 {
        missing = true
    } else {
        err = sstr.trim(r_status.err())
    }
    var log_out = ""
    var branch_out = ""
    if repo {
        log_out = proc.run(q + " log --json").out()
        branch_out = proc.run(q + " branch --json").out()
    }
    return json.stringify(json.obj([
        json.member("repo", json.boolean(repo)),
        json.member("missing", json.boolean(missing)),
        json.member("err", json.str(err)),
        json.member("status", json.str(r_status.out())),
        json.member("log", json.str(log_out)),
        json.member("branch", json.str(branch_out))
    ]))
}


// new_scm is the panel's initial state: unloaded, so its first frame requests a refresh.
fn new_scm() -> Scm {
    return Scm {
        loaded: false,
        repo: false,
        missing: false,
        branch: "",
        clean: false,
        changes: [],
        commits: [],
        branches: [],
        current: "",
        err: "",
        refreshing: false,
        want_refresh: false,
        want_init: false
    }
}
