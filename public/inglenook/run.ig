// run.ig — the tape scrubber: the bottom pane as a TIME window. Run the file in the editor, capture
// the execution TAPE (`inglec --emit=trace` — one JSON event per bytecode step, each carrying its
// source line), and scrub it like video: drag the slider or step ◂ ▸, and the editor spotlights the
// exact line that was executing at that moment. Cursor debugs with console.log; this debugs with time
// travel, because Ingle's tape is deterministic and total. The run happens on a worker fiber (std/proc)
// so a long program never freezes the 60fps UI.
import "std/proc" as proc
import "std/json" as json
import "std/string" as sstr
import "std/flare" as flare
import "verify" as verify


let TAPE_CAP = 6000     // max events kept (a huge trace is capped so the channel + scrubber stay snappy)
let TIMELINE_CAP = 500  // max timeline ROWS rendered per frame (the slider still covers the whole tape)


// TapeEvent is one executed step: the function, the opcode, and the SOURCE LINE it ran (1-based) —
// the line is what the scrubber spotlights in the editor.
struct TapeEvent {
    fn_name: string
    op: string
    line: int
}


// TapeRow is one collapsed timeline row: a run of consecutive steps on the SAME source line + function,
// starting at step `step` and `count` steps long. Clicking it scrubs the tape to `step`.
struct TapeRow {
    step: int
    fn_name: string
    line: int
    op: string
    count: int
}


// Runner owns the tape scrubber's state: the captured events, the scrub position, the program's
// output + exit code, and which file was run (so the editor showing THAT file gets the spotlight).
struct Runner {
    ran: bool
    running: bool
    ran_path: string
    exit_code: int
    output: string
    truncated: bool
    events: [TapeEvent]
    scrub: int              // current event index (the slider position)
    run_code: string        // per-frame action: a path to dispatch to the worker ("" = none)
    save_tape: bool         // when set, persist the execution tape to a file after each run
    tape_path: string       // where to save it ("" = <source>.tape, next to the file that ran)


    fn begin_frame(mut self) {
        self.run_code = ""
    }


    // hot_line returns the 1-based source line the scrubber is currently parked on for `path` — or -1
    // if nothing is loaded, the run is stale, or `path` isn't the file that was run. The editor showing
    // `path` passes this to code_editor_marked to spotlight the executing line.
    fn hot_line(self, path: string) -> int {
        if !self.ran || self.events.len() == 0 || path != self.ran_path {
            return 0 - 1
        }
        var i = self.scrub
        if i < 0 {
            i = 0
        }
        if i >= self.events.len() {
            i = self.events.len() - 1
        }
        return self.events[i].line
    }


    // apply_tape lands a finished run (the tape JSON from the tooling worker): decode the events +
    // output + exit, and park the scrubber at the start (or, for a fault, at the LAST event — where it
    // stopped).
    fn apply_tape(mut self, js: string) {
        self.decode(js)
        self.running = false
        self.ran = true
        self.scrub = 0
        if self.exit_code != 0 && self.events.len() > 0 {
            self.scrub = self.events.len() - 1   // a fault → jump to where it stopped
        }
        if self.save_tape {
            self.write_tape_file()               // persist the captured tape to disk (opt-in)
        }
    }


    // build renders the Run panel: a Run/Stop control + exit status, the program output, and — once a
    // tape is captured — the scrubber (◂ step ▸, a slider, and the current event read-out).
    fn build(mut self, mut f: flare.Flare, active_path: string, tick: int, cw: int) {
        f.row(flare.START, flare.CENTER)
        f.heading("Run")
        f.spacer()
        if self.running {
            f.badge("running " + flare.spinner(tick), 3)
        } else if self.ran {
            if self.exit_code == 0 {
                f.badge("exit 0", 1)
            } else {
                f.badge("exit {self.exit_code}", 2)
            }
        }
        f.end()

        if active_path.len() == 0 {
            f.text_muted("Open a file in Editor 1 to run it.")
            return
        }
        f.row(flare.START, flare.CENTER)
        if !self.running {
            if f.primary("▶  Run " + basename(active_path)) {
                self.run_code = active_path       // dispatched to the worker after the frame
            }
        } else {
            f.text_muted("Running " + basename(active_path) + " " + flare.spinner(tick))
        }
        f.end()

        // Save-tape option: persist the captured execution tape to a portable, replayable file after
        // each run. The path defaults to <source>.tape next to the file — edit it to send it elsewhere.
        self.save_tape = f.checkbox("savetape", "Save tape to file", self.save_tape)
        if self.save_tape {
            let np = f.text_field("tapepath", self.tape_path)
            if np != self.tape_path {
                self.tape_path = np
            }
            f.text_muted("→ {self.effective_tape_path(active_path)}")
        }

        if !self.ran {
            f.text_muted("Run the file to capture its execution tape, then scrub the line that ran.")
            return
        }

        // The scrubber: step buttons, a slider over the event index, and the current event read-out.
        if self.events.len() > 0 {
            f.divider()
            f.text_muted("Tape — {self.events.len()} step(s){tape_more(self.truncated)}")
            f.row(flare.START, flare.CENTER)
            if f.ghost_button("◂ step") {
                self.scrub = self.scrub - 1
            }
            if f.ghost_button("step ▸") {
                self.scrub = self.scrub + 1
            }
            f.spacer()
            let ev = self.events[self.clamp_scrub()]
            f.label("{ev.fn_name}  line {ev.line}  ·  {ev.op}")
            f.end()
            let ns = f.slider("tapescrub", self.clamp_scrub(), 0, self.events.len() - 1)
            if ns != self.clamp_scrub() {
                self.scrub = ns
            }
            self.scrub = self.clamp_scrub()
        }

        // Timeline: every executed step as a clickable row, with consecutive steps on the same source
        // line collapsed to one row (× count). Click a row to jump the scrubber there — which also
        // spotlights that line in the editor. The slider above still covers the whole tape if capped.
        if self.events.len() > 0 {
            f.divider()
            f.text_muted("Timeline — click a step to jump")
            let rows = self.timeline_rows()
            f.scroll_begin("timeline")
            var r = 0
            loop {
                if r == rows.len() || r == TIMELINE_CAP {
                    break
                }
                let row = rows[r]
                var upper = self.events.len()
                if r + 1 < rows.len() {
                    upper = rows[r + 1].step
                }
                let active = self.scrub >= row.step && self.scrub < upper
                if f.nav_item(row_label(row), active) {
                    self.scrub = row.step
                }
                r = r + 1
            }
            f.scroll_end("timeline")
            if rows.len() > TIMELINE_CAP {
                f.text_muted("… {rows.len() - TIMELINE_CAP} more step-groups (use the slider for the rest)")
            }
        }

        // Program output (stdout, minus the tape lines).
        if self.output.len() > 0 {
            f.divider()
            f.text_muted("Output")
            f.code("runout", "", self.output, cw)
        }
    }


    // clamp_scrub keeps the scrub index within the event range.
    fn clamp_scrub(self) -> int {
        var i = self.scrub
        if i < 0 {
            i = 0
        }
        if i >= self.events.len() {
            i = self.events.len() - 1
        }
        if i < 0 {
            i = 0
        }
        return i
    }


    // decode parses the worker's JSON envelope into the runner: exit, output, truncated, and the events
    // as three parallel arrays (lines/ops/fns — compact over the channel).
    fn decode(mut self, js: string) {
        self.events = []
        self.output = ""
        self.exit_code = 0
        self.truncated = false
        match json.parse(js) {
            case Ok(root) {
                self.exit_code = json.as_int(json.get(root, "exit"))
                self.output = json.as_str(json.get(root, "output"))
                self.truncated = json.as_bool(json.get(root, "truncated"))
                let ln = json.get(root, "lines")
                let op = json.get(root, "ops")
                let fnn = json.get(root, "fns")
                var i = 0
                loop {
                    if i == json.length(ln) {
                        break
                    }
                    self.events.append(TapeEvent {
                        fn_name: json.as_str(json.at(fnn, i)),
                        op: json.as_str(json.at(op, i)),
                        line: json.as_int(json.at(ln, i))
                    })
                    i = i + 1
                }
            }
            case Err(e) {}
        }
    }


    // timeline_rows collapses the events into clickable rows: a run of consecutive steps on the SAME
    // source line + function becomes ONE row (with a count), so the timeline stays scannable even when a
    // line runs many times back-to-back. Order is preserved; `step` is the row's FIRST event index.
    fn timeline_rows(self) -> [TapeRow] {
        var rows: [TapeRow] = []
        var i = 0
        loop {
            if i == self.events.len() {
                break
            }
            let e = self.events[i]
            var j = i + 1
            loop {
                if j == self.events.len() {
                    break
                }
                if self.events[j].line != e.line || self.events[j].fn_name != e.fn_name {
                    break
                }
                j = j + 1
            }
            rows.append(TapeRow {
                step: i,
                fn_name: e.fn_name,
                line: e.line,
                op: e.op,
                count: j - i
            })
            i = j
        }
        return rows
    }


    // effective_tape_path is where a saved tape actually lands: the user's `tape_path` if set, else
    // <src>.tape derived from the file being run/edited.
    fn effective_tape_path(self, src: string) -> string {
        if self.tape_path.len() > 0 {
            return self.tape_path
        }
        return default_tape_path(src)
    }


    // write_tape_file reconstructs the execution tape as JSON Lines — one {"fn","op","line"} object per
    // step, the same shape `inglec --emit=trace` emits — and writes it to effective_tape_path. A no-op
    // with no events or no destination. The result is a portable, replayable record of the run.
    fn write_tape_file(self) {
        let path = self.effective_tape_path(self.ran_path)
        if path.len() == 0 || self.events.len() == 0 {
            return
        }
        var lines: [string] = []
        var i = 0
        loop {
            if i == self.events.len() {
                break
            }
            let ev = self.events[i]
            let obj = json.obj([
                json.member("fn", json.str(ev.fn_name)),
                json.member("op", json.str(ev.op)),
                json.member("line", json.num(ev.line))
            ])
            lines.append(json.stringify(obj))
            i = i + 1
        }
        write_file(path, sstr.join(lines, "\n") + "\n")
    }


    // tape_settings_json / load_tape_settings persist the two save-tape controls across sessions,
    // threaded into the workspace store alongside the chat / dock / editor state.
    fn tape_settings_json(self) -> json.Json {
        return json.obj([
            json.member("save_tape", json.boolean(self.save_tape)),
            json.member("tape_path", json.str(self.tape_path))
        ])
    }


    fn load_tape_settings(mut self, j: json.Json) {
        if !json.is_null(json.get(j, "save_tape")) {
            self.save_tape = json.as_bool(json.get(j, "save_tape"))
        }
        if !json.is_null(json.get(j, "tape_path")) {
            self.tape_path = json.as_str(json.get(j, "tape_path"))
        }
    }
}


fn new_runner() -> Runner {
    return Runner {
        ran: false,
        running: false,
        ran_path: "",
        exit_code: 0,
        output: "",
        truncated: false,
        events: [],
        scrub: 0,
        run_code: "",
        save_tape: false,
        tape_path: ""
    }
}


// row_label formats one timeline row for its clickable list entry: source line, function, op, and a
// ×count when consecutive same-line steps were collapsed into it.
fn row_label(r: TapeRow) -> string {
    var s = "line {r.line}  ·  {r.fn_name}  ·  {r.op}"
    if r.count > 1 {
        s = s + "  ×{r.count}"
    }
    return s
}


// default_tape_path derives <src>.tape from the source path (dropping a trailing .ig/.em) — the default
// destination when the user hasn't typed an explicit tape path. Falls back to $HOME for a path-less src.
fn default_tape_path(src: string) -> string {
    if src.len() == 0 {
        return env("HOME") + "/inglenook.tape"
    }
    if sstr.ends_with(src, ".ig") || sstr.ends_with(src, ".em") {
        return sstr.cp_slice(src, 0, src.char_count() - 3) + ".tape"
    }
    return src + ".tape"
}


// run_trace runs `path` under `--emit=trace`, splits the tape events (lines starting `{"fn":`) from the
// program's own stdout, and returns the compact JSON envelope. Called on the shared tooling worker
// fiber (tools.ig) — one tooling fiber instead of three, to ease worker-thread contention on the UI.
fn run_trace(path: string) -> string {
    let cc = verify.inglec_path()
    let q = proc.shell_quote(path)
    let r = proc.run(cc + " --emit=trace " + q)
    return encode_trace(path, r.code(), r.out(), r.err())
}


// encode_trace parses the raw --emit=trace stdout (tape JSON lines interleaved with the program's own
// output) into the compact envelope the Runner decodes: exit, the non-tape lines as `output`, and the
// events as parallel lines/ops/fns arrays (capped at TAPE_CAP). Compile errors (on stderr) become output.
fn encode_trace(path: string, exit: int, out: string, err: string) -> string {
    var lines: [json.Json] = []
    var ops: [json.Json] = []
    var fns: [json.Json] = []
    var output = ""
    var truncated = false
    var last_line = 0                          // the OVERFLOW's most recent event, kept so a fault past
    var last_op = ""                           // the cap is still the scrubber's final (parked) step
    var last_fn = ""
    let raw = out.split("\n")
    var i = 0
    loop {
        if i == raw.len() {
            break
        }
        let ln = raw[i]
        if sstr.starts_with(ln, "\{\"fn\":") {
            match json.parse(ln) {
                case Ok(ev) {
                    if lines.len() >= TAPE_CAP {
                        truncated = true       // past the cap: don't grow the arrays, but remember this event
                        last_line = json.as_int(json.get(ev, "line"))
                        last_op = json.as_str(json.get(ev, "op"))
                        last_fn = json.as_str(json.get(ev, "fn"))
                    } else {
                        lines.append(json.num(json.as_int(json.get(ev, "line"))))
                        ops.append(json.str(json.as_str(json.get(ev, "op"))))
                        fns.append(json.str(json.as_str(json.get(ev, "fn"))))
                    }
                }
                case Err(e) {}
            }
        } else if ln.len() > 0 {
            if output.len() > 0 {
                output = output + "\n"
            }
            output = output + ln
        }
        i = i + 1
    }
    if truncated {                             // append the overflow's LAST event so a fault line is scrubable
        lines.append(json.num(last_line))
        ops.append(json.str(last_op))
        fns.append(json.str(last_fn))
    }
    if err.len() > 0 {                        // a compile error (or a fault message) → show it as output
        if output.len() > 0 {
            output = output + "\n"
        }
        output = output + sstr.trim(err)
    }
    return json.stringify(json.obj([
        json.member("exit", json.num(exit)),
        json.member("output", json.str(output)),
        json.member("truncated", json.boolean(truncated)),
        json.member("lines", json.arr(lines)),
        json.member("ops", json.arr(ops)),
        json.member("fns", json.arr(fns))
    ]))
}


// tape_more renders the "(capped)" note when a trace overran TAPE_CAP.
fn tape_more(truncated: bool) -> string {
    if truncated {
        return " (capped)"
    }
    return ""
}


// basename returns the final path component (the filename) for a button/label.
fn basename(path: string) -> string {
    let parts = path.split("/")
    if parts.len() > 0 {
        return parts[parts.len() - 1]
    }
    return path
}
