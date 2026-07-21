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


// Attic is one recoverable discarded snapshot (invariant #6): its seq (restore key) and why it was
// stashed. Showing these makes "discard is recoverable" concrete — the safety net, visible.
struct Attic {
    seq: int
    reason: string
}


// DiffLine is one line of a file's diff for the Diff panel: op is "keep" (context) / "add" / "remove".
struct DiffLine {
    op: string
    text: string
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
    attic: [Attic]           // recoverable discarded snapshots (invariant #6)
    diff_path: string        // the file whose diff is shown in the Diff panel ("" = none selected)
    diff_lines: [DiffLine]   // that file's diff, line by line
    diff_added: int          // added-line count for the shown diff
    diff_removed: int        // removed-line count for the shown diff
    err: string              // a diagnostic to surface when there's no repo
    msg_draft: string        // the commit-message input buffer (persists across frames)
    branch_draft: string     // the new-branch-name input buffer (persists across frames)
    action_msg: string       // the last mutation's result line, surfaced under the header
    action_ok: bool          // whether that last mutation succeeded
    fs_changed: bool         // the last reply was a mutation that may have rewritten the working tree
    verify_ran: bool         // `quog verify` has run at least once
    verify_ok: bool          // the store verified intact (content-addressed integrity + link checks)
    verify_msg: string       // verify's summary line ("verified N … intact" / "N integrity problem(s)")
    verify_problems: [string]// the specific problems when verify failed (tamper / broken link)
    refreshing: bool         // a quog query is in flight
    want_refresh: bool       // action: re-query quog
    want_init: bool          // action: initialise a repo here, then query
    want_save: bool          // action: save the working tree (message = msg_draft)
    want_discard: bool       // action: discard working changes (to the recoverable attic)
    want_restore_seq: int    // action: restore this attic entry (-1 = none this frame)
    want_undo: bool          // action: undo the last operation (the op-log spine)
    want_branch: bool        // action: create a branch (name = branch_draft)
    want_switch_name: string // action: switch to this branch ("" = none this frame)
    want_merge_name: string  // action: merge this branch into the current one ("" = none this frame)
    want_diff_path: string   // action: load this file's diff into the Diff panel ("" = none this frame)
    want_verify: bool        // action: re-run `quog verify` (tamper-evidence)


    // begin_frame clears the per-frame action flags before the panel builds (msg_draft / branch_draft /
    // action_msg / diff / verify state persist — they are editing/result state, not one-shot intents).
    fn begin_frame(mut self) {
        self.want_refresh = false
        self.want_init = false
        self.want_save = false
        self.want_discard = false
        self.want_restore_seq = 0 - 1
        self.want_undo = false
        self.want_branch = false
        self.want_switch_name = ""
        self.want_merge_name = ""
        self.want_diff_path = ""
        self.want_verify = false
    }


    // build renders the Source tab: a header (branch + Refresh), the Save box (when there are changes),
    // the working-tree status, the branch history, and the branch list — plus Undo/Restore, the safety
    // net. `cw` is the panel's content width for wrapping. On first view it requests a refresh so the
    // panel self-loads. Mutating controls set want_* action flags, applied by ide.ig after layout.
    fn build(mut self, mut f: flare.Flare, cw: int) {
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
            f.paragraph("Couldn't run quog. Install it (make install-quog) or set INGLENOOK_QUOG.", cw)
            return
        }

        if !self.repo {
            f.paragraph("No Quog repo in this folder yet.", cw)
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

        // --- provably safe: quog verify's content-addressed tamper-evidence, made visible (the moat) ---
        if !self.verify_ran && !self.refreshing {
            self.want_verify = true              // lazily verify once when the repo is first shown
        }
        f.row(flare.START, flare.CENTER)
        if !self.verify_ran {
            f.badge("not verified", 0)
        } else if self.verify_ok {
            f.badge("provably safe", 1)
        } else {
            f.badge("integrity problem", 2)
        }
        f.spacer()
        if f.ghost_button("Verify") {
            self.want_verify = true
        }
        f.end()
        if self.verify_ran && self.verify_msg.len() > 0 {
            f.paragraph(self.verify_msg, cw)     // wrap the full "receipt" — the narrow panel truncates a label
        }
        if self.verify_ran && !self.verify_ok {
            var vi = 0
            loop {
                if vi == self.verify_problems.len() {
                    break
                }
                f.paragraph(self.verify_problems[vi], cw - 8)
                vi = vi + 1
            }
        }

        // --- last action's result (saved / discarded — recoverable / undone) ---
        if self.action_msg.len() > 0 {
            if self.action_ok {
                f.paragraph(self.action_msg, cw)
            } else {
                f.row(flare.START, flare.CENTER)
                f.badge("error", 2)
                f.strut(6, 0)
                f.paragraph(self.action_msg, cw - 48)
                f.end()
            }
        }
        f.divider()

        // --- save the working tree (only meaningful when something changed) ---
        if !self.clean {
            f.text_muted("Message")
            self.msg_draft = f.text_field("scm_msg", self.msg_draft)
            let submitted = f.submit()
            f.row(flare.START, flare.CENTER)
            if sstr.trim(self.msg_draft).len() > 0 {
                if f.primary("Save") || submitted {
                    self.want_save = true
                }
            } else {
                f.text_muted("enter a message to save")
            }
            f.spacer()
            if f.danger("Discard") {                 // safe: discard goes to a recoverable attic
                self.want_discard = true
            }
            f.end()
            f.divider()
        }

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
                f.key("chg:{c.path}")
                f.row(flare.START, flare.CENTER)
                f.badge(c.status, status_tone(c.status))
                f.strut(6, 0)
                if f.nav_item(c.path, self.diff_path == c.path) {   // click → show this file's diff
                    self.want_diff_path = c.path
                }
                f.end()
                f.key_clear()
                i = i + 1
            }
        }
        f.divider()

        // --- branch history + undo (the op-log spine: any operation is reversible) ---
        f.row(flare.START, flare.CENTER)
        f.text_muted("History — {self.branch}")
        f.spacer()
        if f.ghost_button("Undo") {
            self.want_undo = true
        }
        f.end()
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

        // --- branches: switch (auto-snapshots first, invariant #4) and merge (additive: a real
        //     conflict is declined, not clobbered, invariant #5) ---
        f.divider()
        f.text_muted("Branches")
        var b = 0
        loop {
            if b == self.branches.len() {
                break
            }
            let name = self.branches[b]
            f.key("br:{name}")
            f.row(flare.START, flare.CENTER)
            if name == self.current {
                f.label("* {name}")
            } else {
                f.label("  {name}")
                f.spacer()
                if f.ghost_button("Switch") {
                    self.want_switch_name = name
                }
                if f.ghost_button("Merge") {
                    self.want_merge_name = name
                }
            }
            f.end()
            f.key_clear()
            b = b + 1
        }
        f.row(flare.START, flare.CENTER)
        self.branch_draft = f.text_field("scm_branch", self.branch_draft)
        if sstr.trim(self.branch_draft).len() > 0 {
            if f.ghost_button("Create") {
                self.want_branch = true
            }
        }
        f.end()

        // --- the attic: discarded work is recoverable, not gone (invariant #6, made visible) ---
        if self.attic.len() > 0 {
            f.divider()
            f.text_muted("Attic — recoverable")
            var k = 0
            loop {
                if k == self.attic.len() {
                    break
                }
                let a = self.attic[k]
                f.row(flare.START, flare.CENTER)
                f.paragraph(a.reason, cw - 80)
                f.spacer()
                f.key("atrestore:{a.seq}")
                if f.ghost_button("Restore") {
                    self.want_restore_seq = a.seq
                }
                f.key_clear()
                f.end()
                k = k + 1
            }
        }
    }


    // apply_result folds a worker reply back into the panel state. A reply is either a DIFF reply (a
    // "diff" member — a file's diff to show in the Diff panel, leaving the rest of the state untouched)
    // or a full STATE reply (repo status/log/branch/attic, with an optional mutation result line).
    fn apply_result(mut self, s: string) {
        self.refreshing = false
        self.fs_changed = false
        match json.parse(s) {
            case Ok(root) {
                let dj = json.get(root, "diff")
                if !json.is_null(dj) {
                    self.apply_diff(json.as_str(dj))
                    return
                }
                let vj = json.get(root, "verify")
                if !json.is_null(vj) {
                    self.apply_verify(json.as_str(vj))
                    return
                }
                self.loaded = true
                self.changes = []
                self.commits = []
                self.branches = []
                self.attic = []
                self.repo = json.as_bool(json.get(root, "repo"))
                self.missing = json.as_bool(json.get(root, "missing"))
                self.err = json.as_str(json.get(root, "err"))
                self.action_ok = json.as_bool(json.get(root, "action_ok"))
                self.action_msg = json.as_str(json.get(root, "action_msg"))
                self.fs_changed = self.action_msg.len() > 0    // a mutation ran → the tree may have changed
                if self.repo {
                    self.parse_status(json.as_str(json.get(root, "status")))
                    self.parse_log(json.as_str(json.get(root, "log")))
                    self.parse_branch(json.as_str(json.get(root, "branch")))
                    self.parse_attic(json.as_str(json.get(root, "attic")))
                }
            }
            case Err(e) {
                self.repo = false
                self.err = "could not parse quog output"
            }
        }
    }


    // apply_diff parses a `quog diff <path> --json` reply (the {"files":[…]} shape) — its single file's
    // entry — into the Diff-panel state.
    fn apply_diff(mut self, s: string) {
        self.diff_lines = []
        self.diff_added = 0
        self.diff_removed = 0
        match json.parse(s) {
            case Ok(root) {
                let files = json.get(root, "files")
                if json.length(files) > 0 {
                    let f0 = json.at(files, 0)
                    self.diff_path = json.as_str(json.get(f0, "path"))
                    self.diff_added = json.as_int(json.get(f0, "added"))
                    self.diff_removed = json.as_int(json.get(f0, "removed"))
                    let lines = json.get(f0, "lines")
                    var i = 0
                    loop {
                        if i == json.length(lines) {
                            break
                        }
                        let ln = json.at(lines, i)
                        self.diff_lines.append(DiffLine {
                            op: json.as_str(json.get(ln, "op")),
                            text: json.as_str(json.get(ln, "text"))
                        })
                        i = i + 1
                    }
                }
            }
            case Err(e) {}
        }
    }


    // apply_verify folds a `quog verify --json` reply ({ok, message, problems}) into the panel state.
    fn apply_verify(mut self, s: string) {
        self.verify_ran = true
        self.verify_problems = []
        match json.parse(s) {
            case Ok(root) {
                self.verify_ok = json.as_bool(json.get(root, "ok"))
                self.verify_msg = json.as_str(json.get(root, "message"))
                let arr = json.get(root, "problems")
                var i = 0
                loop {
                    if i == json.length(arr) {
                        break
                    }
                    self.verify_problems.append(json.as_str(json.at(arr, i)))
                    i = i + 1
                }
            }
            case Err(e) {
                self.verify_ok = false
                self.verify_msg = "could not run verify"
            }
        }
    }


    // build_diff renders the Diff dock panel: the selected file's coloured diff (or a hint when none is
    // selected). Each line uses the f.diff_line primitive (green add / red remove / muted context).
    fn build_diff(mut self, mut f: flare.Flare, cw: int) {
        if self.diff_path.len() == 0 {
            f.text_muted("Select a changed file in the Source panel to see its diff.")
            return
        }
        f.row(flare.START, flare.CENTER)
        f.text_muted(self.diff_path)
        f.spacer()
        f.badge("+{self.diff_added}", 1)
        f.strut(4, 0)
        f.badge("-{self.diff_removed}", 2)
        f.end()
        f.divider()
        if self.diff_lines.len() == 0 {
            f.text_muted("no changes (saved since selected — Refresh the Source panel)")
            return
        }
        var i = 0
        loop {
            if i == self.diff_lines.len() {
                break
            }
            f.diff_line(self.diff_lines[i].op, self.diff_lines[i].text)
            i = i + 1
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


    // parse_attic reads `quog restore --json` into the recoverable-snapshot list (newest first).
    fn parse_attic(mut self, s: string) {
        match json.parse(s) {
            case Ok(at) {
                let arr = json.get(at, "entries")
                var i = 0
                loop {
                    if i == json.length(arr) {
                        break
                    }
                    let it = json.at(arr, i)
                    self.attic.append(Attic {
                        seq: json.as_int(json.get(it, "seq")),
                        reason: json.as_str(json.get(it, "reason"))
                    })
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


// _first_line returns the first line of `s` (its most useful summary — quog's action messages are
// one line), trimmed. Keeps a multi-line stderr from bloating the panel's status line.
fn _first_line(s: string) -> string {
    let t = sstr.trim(s)
    let nl = sstr.index_of(t, "\n")
    if nl < 0 {
        return t
    }
    return sstr.trim(sstr.cp_slice(t, 0, nl))
}


// run_scm is the tooling-worker task (tools.ig kind "Q"): optionally apply ONE mutation, then shell
// out to the three read commands and pack their JSON into a single reply. The payload names the intent:
// "" refreshes; "init" creates a repo; "discard"/"restore"/"undo" run that verb; "save\t<message>"
// commits. A mutation's result line (and whether it succeeded) rides back so the panel can surface it —
// this is where Quog's safety shows: a discard reports it is recoverable, an undo confirms the revert.
// Repo detection keys off `status`: exit 0 with a JSON object means a repo is present; a shell
// "command not found" (exit 127) means quog itself is missing, told apart from a plain "no repo" error.
fn run_scm(payload: string) -> string {
    let q = proc.shell_quote(quog_path())
    // A diff request only fetches one file's diff (no state re-query) — a lighter, separate reply.
    if sstr.starts_with(payload, "diff\t") {
        let path = sstr.cp_slice(payload, 5, payload.char_count())
        let d = proc.run(q + " diff " + proc.shell_quote(path) + " --json")
        return json.stringify(json.obj([json.member("diff", json.str(d.out()))]))
    }
    // A verify request re-hashes the store (tamper-evidence) — also a separate, read-only reply.
    if payload == "verify" {
        let v = proc.run(q + " verify --json")
        return json.stringify(json.obj([json.member("verify", json.str(v.out()))]))
    }
    var action_ok = true
    var action_msg = ""
    if payload == "init" {
        let r = proc.run(q + " init")
        action_ok = r.ok()
        action_msg = _first_line(r.combined())
    } else if payload == "discard" {
        let r = proc.run(q + " discard")
        action_ok = r.ok()
        action_msg = _first_line(r.combined())
    } else if sstr.starts_with(payload, "restore\t") {
        let seq = sstr.cp_slice(payload, 8, payload.char_count())
        let r = proc.run(q + " restore " + proc.shell_quote(seq))
        action_ok = r.ok()
        action_msg = _first_line(r.combined())
    } else if payload == "undo" {
        let r = proc.run(q + " undo")
        action_ok = r.ok()
        action_msg = _first_line(r.combined())
    } else if sstr.starts_with(payload, "save\t") {
        let msg = sstr.cp_slice(payload, 5, payload.char_count())
        let r = proc.run(q + " save " + proc.shell_quote(msg))
        action_ok = r.ok()
        action_msg = _first_line(r.combined())
    } else if sstr.starts_with(payload, "branch\t") {
        let name = sstr.cp_slice(payload, 7, payload.char_count())
        let r = proc.run(q + " branch " + proc.shell_quote(name))
        action_ok = r.ok()
        action_msg = _first_line(r.combined())
    } else if sstr.starts_with(payload, "switch\t") {
        let name = sstr.cp_slice(payload, 7, payload.char_count())
        let r = proc.run(q + " switch " + proc.shell_quote(name))
        action_ok = r.ok()
        action_msg = _first_line(r.combined())
    } else if sstr.starts_with(payload, "merge\t") {
        let name = sstr.cp_slice(payload, 6, payload.char_count())
        let r = proc.run(q + " merge " + proc.shell_quote(name))
        action_ok = r.ok()
        action_msg = _first_line(r.combined())
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
    var attic_out = ""
    if repo {
        log_out = proc.run(q + " log --json").out()
        branch_out = proc.run(q + " branch --json").out()
        attic_out = proc.run(q + " restore --json").out()
    }
    return json.stringify(json.obj([
        json.member("repo", json.boolean(repo)),
        json.member("missing", json.boolean(missing)),
        json.member("err", json.str(err)),
        json.member("action_ok", json.boolean(action_ok)),
        json.member("action_msg", json.str(action_msg)),
        json.member("status", json.str(r_status.out())),
        json.member("log", json.str(log_out)),
        json.member("branch", json.str(branch_out)),
        json.member("attic", json.str(attic_out))
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
        attic: [],
        diff_path: "",
        diff_lines: [],
        diff_added: 0,
        diff_removed: 0,
        err: "",
        msg_draft: "",
        branch_draft: "",
        action_msg: "",
        action_ok: true,
        fs_changed: false,
        verify_ran: false,
        verify_ok: false,
        verify_msg: "",
        verify_problems: [],
        refreshing: false,
        want_refresh: false,
        want_init: false,
        want_save: false,
        want_discard: false,
        want_restore_seq: 0 - 1,
        want_undo: false,
        want_branch: false,
        want_switch_name: "",
        want_merge_name: "",
        want_diff_path: "",
        want_verify: false
    }
}
