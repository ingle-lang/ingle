// verify.ig — the Verified Loop: the moat, made visible. When the agent produces Ingle code, a
// worker fiber runs the real compiler over it — does it compile? do its contracts hold? does it run
// clean? — and the chat renders the verdict as a strip of green/red pills. A red verdict routes the
// exact fault (a type error, a runtime trap, or a prover COUNTEREXAMPLE like `abs_val(-1)`) back to
// the model, which fixes it and tries again, capped so a genuinely hard bug can't spiral. Cursor
// shows you what the AI said; this shows you what the code did — checked by the compiler, not vibes.
//
// It shells out to `inglec` via std/proc on a worker fiber (so the compiler's few-hundred-ms never
// stalls the 60fps UI), reading the machine-readable verdict surface: --diagnostics=json (compile
// errors, on stderr), --faults=agent (runtime faults, on stderr), and --emit=check (the prover's
// counterexample, on stdout). See docs/proc.md + docs/faults.md.
import "std/proc" as proc
import "std/json" as json
import "std/string" as sstr
import "std/flare" as flare


let VERIFY_CAP = 3      // max auto-fix rounds before the loop stops and hands back to the human


// Verdict is the outcome of verifying one snippet. `ran` is false until the first result lands; the
// three booleans are the pill states; `detail` is the fault/counterexample fed back to the model on a
// red verdict; `counterexample` is the prover's falsifying input (e.g. "abs_val(-1)") when it has one.
struct Verdict {
    ran: bool
    compiles: bool
    contracts_ok: bool
    contracts_checked: int
    runs_clean: bool
    detail: string
    counterexample: string
}


fn empty_verdict() -> Verdict {
    return Verdict {
        ran: false,
        compiles: false,
        contracts_ok: false,
        contracts_checked: 0,
        runs_clean: false,
        detail: "",
        counterexample: ""
    }
}


// all_green is the pass condition: it compiles, its contracts hold, and it runs clean.
fn all_green(v: Verdict) -> bool {
    return v.compiles && v.contracts_ok && v.runs_clean
}


// agent_feedback renders a red verdict as the message routed back to the model — precise about WHAT
// failed and, for a falsified contract, the exact counterexample, so the model fixes the real bug.
fn agent_feedback(v: Verdict) -> string {
    if !v.compiles {
        return "The code you provided does not compile:\n\n" + v.detail + "\n\nPlease fix it and show the corrected code."
    }
    if !v.contracts_ok {
        var msg = "The code compiles, but a contract does NOT hold — the checker found a counterexample"
        if v.counterexample.len() > 0 {
            msg = msg + ": `" + v.counterexample + "`"
        }
        msg = msg + ".\n\n" + v.detail + "\n\nEither the implementation is wrong or the contract is; fix whichever is at fault and show the corrected code."
        return msg
    }
    if !v.runs_clean {
        return "The code compiles, but it FAILS at runtime:\n\n" + v.detail + "\n\nPlease fix it and show the corrected code."
    }
    return ""
}


// inglec_path resolves the compiler to shell out to: $INGLENOOK_INGLEC if set (dev: build/inglec),
// else `inglec` on PATH (the installed binary). Kept in one place so every invocation agrees.
fn inglec_path() -> string {
    let e = env("INGLENOOK_INGLEC")
    if e.len() > 0 {
        return e
    }
    return "inglec"
}


// tmp_path is where a snippet is written for the compiler to read. $INGLENOOK_VERIFY_TMP overrides;
// else a dotfile under $HOME (user-scoped, always writable, no mkdir).
fn tmp_path() -> string {
    let e = env("INGLENOOK_VERIFY_TMP")
    if e.len() > 0 {
        return e
    }
    return env("HOME") + "/.inglenook-verify.ig"
}


// run_verify does the actual verification: write the snippet to a temp file, run the compiler THREE
// ways (compile+run, then the prover), and return the packed verdict JSON. Called on the shared tooling
// worker fiber (tools.ig) — blocking work off the render thread. Kept a plain function (not its own
// fiber) so Inglenook runs ONE tooling worker, not three (less worker-thread contention on the UI).
fn run_verify(code: string) -> string {
    let path = tmp_path()
    write_file(path, code)
    let cc = inglec_path()
    let q = proc.shell_quote(path)
    // 1. compile + run: exit 0 = compiles AND runs clean; on failure the stderr carries a
    //    --diagnostics=json compile error OR a --faults=agent runtime fault.
    let r_run = proc.run(cc + " --emit=run --diagnostics=json --faults=agent " + q)
    // 2. the prover: --emit=check searches each contract for a counterexample (stdout).
    let r_chk = proc.run(cc + " --emit=check " + q)
    return encode(r_run.ok(), r_run.err(), r_chk.out())
}


// encode turns the two compiler runs into a verdict JSON string (channels carry strings). run_ok is
// the compile+run exit==0; run_err is its stderr (diagnostics or fault); chk_out is the prover stdout.
fn encode(run_ok: bool, run_err: string, chk_out: string) -> string {
    var compiles = true
    var runs_clean = true
    var detail = ""
    if !run_ok {
        // A compile/type error is a --diagnostics=json line with "severity" and NO "category"; a
        // runtime fault is a --faults=agent line WITH "category". Tell them apart to set `compiles`.
        if sstr.contains(run_err, "\"category\"") {
            compiles = true
            runs_clean = false
            detail = first_message(run_err)
        } else if sstr.contains(run_err, "\"severity\"") {
            compiles = false
            runs_clean = false
            detail = first_message(run_err)
        } else {
            compiles = false
            runs_clean = false
            detail = sstr.trim(run_err)
        }
    }
    var contracts_ok = true
    var counterexample = ""
    if sstr.contains(chk_out, "check_failed") {
        contracts_ok = false
        counterexample = field_of(chk_out, "check_failed", "input")
        if detail.len() == 0 {
            detail = field_of(chk_out, "check_failed", "detail")
        }
    }
    let checked = checked_count(chk_out)
    return json.stringify(json.obj([
        json.member("compiles", json.boolean(compiles)),
        json.member("contracts_ok", json.boolean(contracts_ok)),
        json.member("checked", json.num(checked)),
        json.member("runs_clean", json.boolean(runs_clean)),
        json.member("detail", json.str(detail)),
        json.member("counterexample", json.str(counterexample))
    ]))
}


// decode parses a verdict JSON (from the worker) back into a Verdict, with ran = true.
fn decode(s: string) -> Verdict {
    var v = empty_verdict()
    v.ran = true
    match json.parse(s) {
        case Ok(root) {
            v.compiles = json.as_bool(json.get(root, "compiles"))
            v.contracts_ok = json.as_bool(json.get(root, "contracts_ok"))
            v.contracts_checked = json.as_int(json.get(root, "checked"))
            v.runs_clean = json.as_bool(json.get(root, "runs_clean"))
            v.detail = json.as_str(json.get(root, "detail"))
            v.counterexample = json.as_str(json.get(root, "counterexample"))
        }
        case Err(e) {}
    }
    return v
}


// first_message parses the FIRST JSON-Lines object out of `s` (a diagnostics or faults stream) and
// renders its "message" with the "line" appended — the one-line human detail for the strip + feedback.
fn first_message(s: string) -> string {
    let lines = s.split("\n")
    var i = 0
    loop {
        if i == lines.len() {
            break
        }
        let ln = sstr.trim(lines[i])
        if sstr.starts_with(ln, "\{") {
            match json.parse(ln) {
                case Ok(o) {
                    var msg = json.as_str(json.get(o, "message"))
                    if !json.is_null(json.get(o, "line")) {
                        let lineno = json.as_int(json.get(o, "line"))
                        msg = msg + " (line {lineno})"
                    }
                    return msg
                }
                case Err(e) {}
            }
        }
        i = i + 1
    }
    return sstr.trim(s)
}


// field_of finds the first JSON-Lines object in `s` that contains `marker`, parses it, and returns
// its string field `key` — used to pull "input" (the counterexample) / "detail" from a check_failed.
fn field_of(s: string, marker: string, key: string) -> string {
    let lines = s.split("\n")
    var i = 0
    loop {
        if i == lines.len() {
            break
        }
        let ln = sstr.trim(lines[i])
        if sstr.starts_with(ln, "\{") && sstr.contains(ln, marker) {
            match json.parse(ln) {
                case Ok(o) {
                    if !json.is_null(json.get(o, key)) {
                        return json.as_str(json.get(o, key))
                    }
                }
                case Err(e) {}
            }
        }
        i = i + 1
    }
    return ""
}


// checked_count reads how many functions the prover checked from its "checked N function(s): …" line,
// so the strip can say "3 contracts hold". 0 means the snippet had no checkable contracts.
fn checked_count(s: string) -> int {
    let marker = "checked "
    let at = sstr.index_of(s, marker)
    if at < 0 {
        return 0
    }
    let rest = sstr.cp_slice(s, at + marker.char_count(), s.char_count())
    let digits = sstr.cp_slice(rest, 0, num_prefix_len(rest))
    match digits.parse_int() {
        case Some(n) { return n }
        case None { return 0 }
    }
}


// num_prefix_len counts the leading ASCII-digit code points of `s` (the number at the start).
fn num_prefix_len(s: string) -> int {
    let cs = s.chars()
    var n = 0
    loop {
        if n == cs.len() {
            break
        }
        let c = char_code(cs[n])
        if c < 48 || c > 57 {
            break
        }
        n = n + 1
    }
    return n
}


// extract_code pulls the first Ingle code block out of an assistant reply: the contents of the first
// ``` fence whose language is ember/ingle/ig, or — if none is tagged — the first fenced block that
// looks like Ingle (has an `fn `). Returns "" when the reply carries no code to verify.
fn extract_code(reply: string) -> string {
    let lines = reply.split("\n")
    var i = 0
    var in_block = false
    var lang_ok = false
    var buf: [string] = []
    loop {
        if i == lines.len() {
            break
        }
        let ln = lines[i]
        if sstr.starts_with(sstr.trim(ln), "```") {
            if !in_block {
                in_block = true
                lang_ok = false
                buf = []
                let fence = sstr.trim(ln)
                let tag = sstr.cp_slice(fence, 3, fence.char_count())
                let tagl = sstr.to_lower(sstr.trim(tag))
                if tagl == "ember" || tagl == "ingle" || tagl == "ig" {
                    lang_ok = true
                } else if tagl == "" {
                    lang_ok = true                 // untagged: accept if the body looks like Ingle (checked below)
                }
            } else {
                // closing fence — decide whether to keep this block
                let body = join_lines(buf)
                if lang_ok && (looks_ingle(body)) {
                    return body
                }
                in_block = false
            }
        } else if in_block {
            buf.append(ln)
        }
        i = i + 1
    }
    return ""
}


// looks_ingle is a cheap heuristic that a code body is Ingle worth verifying: it declares a function.
fn looks_ingle(body: string) -> bool {
    return sstr.contains(body, "fn ")
}


// join_lines re-joins split lines with '\n' (the inverse of split, for reassembling a fenced block).
fn join_lines(lines: [string]) -> string {
    var out = ""
    var i = 0
    loop {
        if i == lines.len() {
            break
        }
        if i > 0 {
            out = out + "\n"
        }
        out = out + lines[i]
        i = i + 1
    }
    return out
}


// render draws the verdict strip: a row of green/red pills (compiles · contracts · runs), then the
// fault detail + counterexample on a red verdict. `verifying` shows a pending pill instead. Built as
// a subtle panel so it reads as "the compiler's receipt" attached under the reply it checked.
fn render(mut f: flare.Flare, v: Verdict, verifying: bool, tick: int, cw: int) {
    f.panel_begin(flare.START, flare.START)
    f.row(flare.START, flare.CENTER)
    f.text_muted("Verified Loop")
    f.strut(6, 0)
    if verifying {
        f.badge("checking " + flare.spinner(tick), 3)
        f.end()
        f.end()
        return
    }
    if !v.ran {
        f.badge("not checked", 0)
        f.end()
        f.end()
        return
    }
    // compiles
    if v.compiles {
        f.badge("compiles", 1)
    } else {
        f.badge("won't compile", 2)
    }
    f.strut(6, 0)
    // contracts (only a meaningful pill once it compiles)
    if v.compiles {
        if !v.contracts_ok {
            f.badge("contract falsifiable", 2)
        } else if v.contracts_checked > 0 {
            f.badge("{v.contracts_checked} contract(s) hold", 1)
        } else {
            f.badge("no contracts", 0)
        }
        f.strut(6, 0)
        // runs clean
        if v.runs_clean {
            f.badge("runs clean", 1)
        } else {
            f.badge("faults at runtime", 2)
        }
    }
    f.end()
    // detail line for a red verdict
    if !all_green(v) {
        if v.counterexample.len() > 0 {
            f.label("counterexample: " + v.counterexample)
        }
        if v.detail.len() > 0 {
            f.paragraph(v.detail, cw - 32)
        }
    }
    f.end()
}
