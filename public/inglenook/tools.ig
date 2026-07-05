// tools.ig — ONE worker fiber for all three compiler-shelling tasks (verify, run/tape, lint). Inglenook
// was spawning three separate tooling fibers on top of the api/ollama/discovery workers — six worker
// threads sharing the render loop. Under that contention the API worker intermittently stalled and the
// render thread could deadlock in the macOS WindowServer present. Folding verify/run/lint into a single
// serialised worker drops it to FOUR fibers and one response channel to drain per frame. The three
// tasks rarely overlap, so serialising them costs nothing and buys stability.
//
// Each request is tagged with a one-character kind ("V" verify · "R" run · "L" lint) then the payload;
// the response echoes the kind so the render loop can route it back to chat / runner / linter.
import "verify" as verify
import "run" as run
import "lint" as lint
import "std/string" as sstr


let KIND_VERIFY = "V"
let KIND_RUN    = "R"
let KIND_LINT   = "L"


// tool_worker is the single tooling fiber: receive a tagged request, dispatch to the right task, send a
// tagged result. Closing req_ch (recv → None) ends it, so the nursery join never deadlocks.
fn tool_worker(req_ch: Channel<string>, resp_ch: Channel<string>) {
    loop {
        match recv(req_ch) {
            case Some(msg) {
                let kind = kind_of(msg)
                let payload = payload_of(msg)
                if kind == KIND_VERIFY {
                    send(resp_ch, KIND_VERIFY + verify.run_verify(payload))
                } else if kind == KIND_RUN {
                    send(resp_ch, KIND_RUN + run.run_trace(payload))
                } else if kind == KIND_LINT {
                    send(resp_ch, KIND_LINT + lint.run_lint(payload))
                }
            }
            case None {
                break
            }
        }
    }
}


// verify_req / run_req / lint_req tag a payload for tool_worker.
fn verify_req(code: string) -> string {
    return KIND_VERIFY + code
}


fn run_req(path: string) -> string {
    return KIND_RUN + path
}


fn lint_req(code: string) -> string {
    return KIND_LINT + code
}


// kind_of / payload_of split a tagged message (the leading kind char, then the rest).
fn kind_of(msg: string) -> string {
    if msg.char_count() == 0 {
        return ""
    }
    return sstr.cp_slice(msg, 0, 1)
}


fn payload_of(msg: string) -> string {
    return sstr.cp_slice(msg, 1, msg.char_count())
}
