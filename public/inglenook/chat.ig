// chat.ig — Inglenook's conversation engine: flare_chat's chat panel, carried over whole and
// restructured as a module. All chat state lives in the Chat struct (the main-loop locals of
// flare_chat, promoted to fields); panel builders write per-frame ACTION fields (want_send,
// switch_to, …) that ide.ig applies AFTER layout — the checkout pattern (OFI-072) across a
// module boundary. The agent loop (tool_use → run tool → tool_result → re-send until the reply
// carries no call) is unchanged, with one addition: a list_dir tool, so the model can browse
// the project it's sitting in instead of guessing paths. Both providers ride along: the
// Anthropic Messages API (streaming, tools) and a local model under Ollama.
import "std/flare" as flare
import "std/json" as json
import "std/string" as sstr
import "../claude-desktop/anthropic" as api
import "../claude-desktop/ollama" as oll
import "verify" as verify


// Conv is one in-memory conversation: a title (derived from the first user turn) plus its own
// transcript. The ACTIVE conversation's turns live in the flat working Chat.turns array and are
// written back whole on a switch — never mutated through an index (OFI-072).
struct Conv {
    title: string
    turns: [api.Turn]
}


// Chat is the whole conversation subsystem: the store (convos + active + working turns), the
// composer, the in-flight request state, the agentic tool loop's pending call, the provider
// settings, and the per-frame action flags ide.ig reads after layout.
struct Chat {
    convos: [Conv]
    active: int
    turns: [api.Turn]
    input: string
    ta_dismiss: string
    open_tabs: [int]
    attachments: [string]
    pending: bool
    streaming: bool
    cur_reply: string
    tool_pending: bool
    tp_id: string
    tp_name: string
    tp_input: string
    menu_for: int
    menu_x: int
    menu_y: int
    has_undo: bool
    undo_title: string
    undo_turns: [api.Turn]
    model_idx: int
    tok_idx: int
    sys_prompt: string
    provider: int
    ollama_model: string
    ollama_models: [string]
    ollama_tool_models: [string]
    discovering: bool
    use_env: bool
    env_model: string
    ready: bool
    want_send: bool
    want_stop: bool
    new_chat: bool
    switch_to: int
    retry_idx: int
    delete_conv: int
    dirty: bool
    wrote_path: string
    want_settings: bool
    want_theme: bool
    want_quit: bool
    want_redock_conv: bool
    want_redock_insp: bool
    // --- the Verified Loop ---
    verifying: bool          // a verify run is in flight for the latest reply
    verdict: verify.Verdict  // the latest verdict (ran=false until the first result)
    verify_turn: int         // the assistant turn index the verdict is for (-1 = none)
    verify_rounds: int       // auto-fix rounds spent on the current failing snippet (capped)
    auto_verify: bool        // verify every reply automatically (the flagship default)
    verify_code: string      // per-frame: source to dispatch to the verify worker ("" = none)


    // begin_frame clears the per-frame action flags before the panels build.
    fn begin_frame(mut self) {
        self.verify_code = ""
        self.want_send = false
        self.want_stop = false
        self.new_chat = false
        self.switch_to = 0 - 1
        self.retry_idx = 0 - 1
        self.delete_conv = 0 - 1
        self.dirty = false
        self.wrote_path = ""
        self.want_settings = false
        self.want_theme = false
        self.want_quit = false
        self.want_redock_conv = false
        self.want_redock_insp = false
    }


    // drain pumps every response delta that arrived since last frame: token deltas grow the live
    // reply; a tool_use unpacks into tp_*; the done_mark either commits the reply or — when a
    // tool call is pending — runs the tool locally, appends its result, and RE-SENDS (the agent
    // loop; `pending` stays true throughout). A write_file that lands also records wrote_path so
    // ide.ig can refresh any editor pane showing that file.
    fn drain(mut self, resp_ch: Channel<string>, req_ch: Channel<string>, oll_req_ch: Channel<string>) {
        if !self.pending {
            return
        }
        loop {
            match try_recv(resp_ch) {
                case Some(d) {
                    if d == api.done_mark() {
                        if self.tool_pending {
                            self.turns.append(api.mk_tool_use(self.cur_reply, self.tp_id, self.tp_name, self.tp_input))
                            let result = run_tool(self.tp_name, self.tp_input)
                            if self.tp_name == "write_file" && sstr.starts_with(result, "Wrote") {
                                self.wrote_path = api.arg_str(self.tp_input, "path")
                            }
                            self.turns.append(api.mk_tool_result(self.tp_id, result))
                            self.send_now(req_ch, oll_req_ch)
                            self.cur_reply = ""
                            self.tool_pending = false
                            self.tp_id = ""
                            self.tp_name = ""
                            self.tp_input = ""
                            self.streaming = false
                            self.dirty = true
                        } else {
                            let reply = self.cur_reply
                            self.turns.append(api.mk_turn(1, reply))
                            self.cur_reply = ""
                            self.streaming = false
                            self.pending = false
                            self.dirty = true
                            // The Verified Loop: if the committed reply carries Ingle code and
                            // auto-verify is on, queue it for the worker — its verdict lands async.
                            if self.auto_verify {
                                let code = verify.extract_code(reply)
                                if code.len() > 0 {
                                    self.verify_code = code
                                    self.verifying = true
                                    self.verify_turn = self.turns.len() - 1
                                    self.verdict = verify.empty_verdict()
                                }
                            }
                        }
                    } else if api.is_tool_msg(d) {
                        match json.parse(api.strip_tool_mark(d)) {
                            case Ok(v) {
                                self.tp_id = json.as_str(json.get(v, "id"))
                                self.tp_name = json.as_str(json.get(v, "name"))
                                self.tp_input = json.as_str(json.get(v, "input"))
                                self.tool_pending = true
                            }
                            case Err(e) {}
                        }
                    } else {
                        self.cur_reply = self.cur_reply + d
                        self.streaming = true
                    }
                }
                case None {
                    break
                }
            }
        }
    }


    // drain_disco lands an async Ollama model-discovery result (OFI-136): refresh the picker and
    // the tool-capable subset; polled every frame so a slow daemon never stalls a frame.
    fn drain_disco(mut self, disco_resp_ch: Channel<string>) {
        match try_recv(disco_resp_ch) {
            case Some(env) {
                self.ollama_models = oll.models_of(env)
                self.ollama_tool_models = oll.tool_models_of(env)
                if self.ollama_model.len() == 0 && self.ollama_models.len() > 0 {
                    self.ollama_model = self.ollama_models[0]
                }
                self.discovering = false
            }
            case None {}
        }
    }


    // ask injects a user message and queues a send — the programmatic way another panel starts a turn
    // (contract-first Implement sends the editor's contract here, then the Verified Loop drives the
    // reply to green). want_send is consumed by apply() in the same post-frame pass ide.ig calls this in.
    fn ask(mut self, prompt: string) {
        self.turns.append(api.mk_turn(0, prompt))
        self.want_send = true
        self.dirty = true
    }


    // reset_verify clears the Verified Loop state — called when the active conversation changes so a
    // verdict never bleeds from one chat onto another.
    fn reset_verify(mut self) {
        self.verifying = false
        self.verdict = verify.empty_verdict()
        self.verify_turn = 0 - 1
        self.verify_rounds = 0
    }


    // apply_verdict lands the Verified Loop's result (the verdict JSON from the tooling worker): decode
    // it, then AUTO-ROUTE a red one back to the model — append the precise fault (or the prover's
    // counterexample) as a new user turn and re-send, so the model fixes it and tries again, capped at
    // verify.VERIFY_CAP rounds so a genuinely hard bug can't spiral. A green verdict resets the counter.
    fn apply_verdict(mut self, vj: string) {
        self.verdict = verify.decode(vj)
        self.verifying = false
        if verify.all_green(self.verdict) {
            self.verify_rounds = 0
        } else if self.auto_verify && self.verify_rounds < verify.VERIFY_CAP && !self.pending {
            self.verify_rounds = self.verify_rounds + 1
            self.turns.append(api.mk_turn(0, verify.agent_feedback(self.verdict)))
            self.want_send = true
            self.dirty = true
        }
    }


    // send_now dispatches the CURRENT transcript to the active provider's worker. Central so the
    // first send, the agentic re-send, and Retry can never drift in how they build a request.
    fn send_now(mut self, req_ch: Channel<string>, oll_req_ch: Channel<string>) {
        let esys = effective_system(self.sys_prompt, self.provider)
        var model = api.MODEL_OPUS
        if self.use_env {
            model = self.env_model
        } else if self.model_idx == 1 {
            model = api.MODEL_SONNET
        } else if self.model_idx == 2 {
            model = api.MODEL_HAIKU
        }
        if self.provider == 1 {
            var tools = json.arr([])
            if list_has(self.ollama_tool_models, self.ollama_model) {
                tools = oll.openai_tools(tool_defs())
            }
            send(oll_req_ch, oll.build_request(self.ollama_model, tokens_for(self.tok_idx), esys, self.turns, true, tools))
        } else {
            send(req_ch, api.build_request(model, tokens_for(self.tok_idx), esys, tool_defs(), self.turns))
        }
    }


    // can_send gates dispatch on the active provider's readiness: an exported API key for
    // Claude, a selected local model for Ollama.
    fn can_send(self) -> bool {
        if self.provider == 1 {
            return self.ollama_model.len() > 0
        }
        return self.ready
    }


    // model_label names the active model for the toolbar and Inspector.
    fn model_label(self) -> string {
        if self.provider == 1 {
            if self.ollama_model.len() > 0 {
                return self.ollama_model
            }
            return "(no model)"
        }
        if self.use_env {
            return "(env)"
        }
        if self.model_idx == 1 {
            return "Sonnet 5"
        }
        if self.model_idx == 2 {
            return "Haiku 4.5"
        }
        return "Opus 4.8"
    }


    // provider_label names the active backend: the hosted Anthropic API, or a local Ollama model.
    fn provider_label(self) -> string {
        if self.provider == 1 {
            return "Ollama (local)"
        }
        return "Claude (API)"
    }


    // title returns the active conversation's display title.
    fn title(self) -> string {
        if self.turns.len() == 0 {
            return "New conversation"
        }
        return title_for(self.turns)
    }


    // build_chats renders the Chats tab of the sidebar: the "+ New chat" CTA and the Recents
    // list (click switches, "..." or right-click opens the per-conversation menu).
    fn build_chats(mut self, mut f: flare.Flare) {
        if f.primary_fill("+ New chat") && !self.pending {
            self.new_chat = true
        }
        f.text_muted("Recents")
        var ci = 0
        loop {
            if ci == self.convos.len() {
                break
            }
            var ce = false                                   // skip empty conversations
            if ci == self.active {
                if self.turns.len() == 0 {
                    ce = true
                }
            } else {
                if self.convos[ci].turns.len() == 0 {
                    ce = true
                }
            }
            if ce {
                ci = ci + 1
                continue
            }
            f.key("_cv{ci}")
            f.row(flare.START, flare.CENTER)
            let clicked = f.nav_item(self.convos[ci].title, ci == self.active)
            if f.right_clicked() {
                self.menu_for = ci
                self.menu_x = mouse_x()
                self.menu_y = mouse_y()
            }
            if f.ghost_button("...") {
                self.menu_for = ci
                self.menu_x = mouse_x()
                self.menu_y = mouse_y()
            }
            f.end()
            f.key_clear()
            if clicked && !self.pending && ci != self.active {
                self.switch_to = ci
            }
            ci = ci + 1
        }
    }


    // build_panel renders the Chat panel: the open-conversation tab strip, the toolbar (title,
    // model, re-dock affordances for closed side panels), the virtualized transcript, and the
    // composer with its slash typeahead. `tick` drives the spinner + caret.
    fn build_panel(mut self, mut f: flare.Flare, cw: int, tick: int, conv_closed: bool, insp_closed: bool) {
        self.convos[self.active].title = title_for(self.turns)   // keep the active chat titled live

        // Open-conversation tabs (the VS Code editor-tabs model; the sidebar stays the full list).
        if int_pos(self.open_tabs, self.active) < 0 {
            self.open_tabs = insert_int(self.open_tabs, 0, self.active)
            loop {
                if self.open_tabs.len() <= 6 {
                    break
                }
                self.open_tabs.remove_at(self.open_tabs.len() - 1)
            }
        }
        if self.open_tabs.len() > 1 {
            var apos = int_pos(self.open_tabs, self.active)
            if apos < 0 {
                apos = 0
            }
            f.row(flare.START, flare.CENTER)
            let tr = f.tabs("convtabs", tab_labels(self.convos, self.open_tabs), apos)
            f.end()
            if tr.active != apos && tr.active >= 0 && tr.active < self.open_tabs.len() {
                self.switch_to = self.open_tabs[tr.active]
            }
            if tr.closed >= 0 && tr.closed < self.open_tabs.len() {
                let was_active = self.open_tabs[tr.closed] == self.active
                self.open_tabs.remove_at(tr.closed)
                if was_active && self.open_tabs.len() > 0 {
                    var ni = tr.closed
                    if ni >= self.open_tabs.len() {
                        ni = self.open_tabs.len() - 1
                    }
                    self.switch_to = self.open_tabs[ni]
                }
            }
            if tr.moved_from >= 0 && tr.moved_to >= 0 && tr.moved_from < self.open_tabs.len() {
                let m = self.open_tabs[tr.moved_from]
                self.open_tabs.remove_at(tr.moved_from)
                self.open_tabs = insert_int(self.open_tabs, tr.moved_to, m)
            }
        }

        // Toolbar: title left; model + re-dock affordances for closed panels right.
        f.row(flare.START, flare.CENTER)
        f.text_muted(ellipsize(self.title(), 40))
        f.spacer()
        f.text_muted("· {self.model_label()}")
        if conv_closed {
            if f.ghost_button("Sidebar") {
                self.want_redock_conv = true
            }
            f.tooltip("Re-open the Conversations panel")
        }
        if insp_closed {
            if f.ghost_button("Inspector") {
                self.want_redock_insp = true
            }
            f.tooltip("Re-open the Inspector panel")
        }
        f.end()

        // Transcript: a sticky scrollable viewport, virtualized over visual blocks (a tool_use
        // folds its following tool_result into one card).
        f.scroll_begin_sticky("transcript")
        f.page_begin(cw)
        if self.turns.len() == 0 {
            f.heading("Welcome to the nook.")
            f.text_muted("Ask about this project, or pick a starting point below.")
            let suggestions = [
                "What is this project? Look around and tell me.",
                "Read a source file and explain it",
                "Write and explain some code",
                "Draft a design note with me"
            ]
            var i = 0
            loop {
                if i == suggestions.len() {
                    break
                }
                if f.button_fill(suggestions[i]) && !self.pending {
                    self.turns.append(api.mk_turn(0, suggestions[i]))
                    self.want_send = true
                    f.scroll_to_bottom("transcript")
                }
                i = i + 1
            }
        } else {
            var block_start: [int] = []
            var bj = 0
            loop {
                if bj >= self.turns.len() {
                    break
                }
                block_start.append(bj)
                if self.turns[bj].kind == 1 && bj + 1 < self.turns.len() && self.turns[bj + 1].kind == 2 {
                    bj = bj + 2
                } else {
                    bj = bj + 1
                }
            }
            let vc = f.virtual_begin("transcript", block_start.len())
            var bk = vc.start
            loop {
                if bk >= vc.end {
                    break
                }
                let i = block_start[bk]
                f.virtual_item(bk)
                if self.turns[i].kind == 1 {
                    if self.turns[i].text.len() > 0 {
                        let _ = claude_turn(f, self.turns[i].text, cw, "pre{i}", false)
                    }
                    var have_result = false
                    if i + 1 < self.turns.len() {
                        if self.turns[i + 1].kind == 2 {
                            have_result = true
                        }
                    }
                    if have_result {
                        tool_card(f, "tc{i}", self.turns[i].tool_name, self.turns[i].tool_input, self.turns[i + 1].text, true, cw)
                    } else {
                        tool_card(f, "tc{i}", self.turns[i].tool_name, self.turns[i].tool_input, "", false, cw)
                    }
                } else if self.turns[i].kind == 2 {
                    tool_card(f, "tc{i}", "result", "", self.turns[i].text, true, cw)
                } else if self.turns[i].role == 0 {
                    let ue = f.enter("uent{i}")
                    f.fade_begin(ue)
                    f.at(0.0, (1.0 - ue) * 18.0)
                    user_turn(f, self.turns[i].text, cw)
                    f.end_at()
                    f.fade_end()
                } else {
                    if claude_turn(f, self.turns[i].text, cw, "msg{i}", true) {
                        self.retry_idx = i
                    }
                }
                f.virtual_item_end()
                bk = bk + 1
            }
            f.virtual_end()
            if self.streaming {
                var caret = ""
                if (tick / 20) % 2 == 0 {
                    caret = " |"
                }
                let _ = claude_turn(f, self.cur_reply + caret, cw, "stream", false)
            } else if self.pending {
                thinking_turn(f, tick, self.provider, self.ollama_model)
            }
            // The Verified Loop's verdict strip — the compiler's receipt for the latest reply,
            // rendered at the foot of the transcript (a checking pill while it runs, then the pills).
            if self.verifying || (self.verdict.ran && self.verify_turn >= 0) {
                verify.render(f, self.verdict, self.verifying, tick, cw)
            }
        }
        f.page_end()
        f.scroll_end("transcript")
        if f.scroll_fab("transcript") {
            f.scroll_to_bottom("transcript")
        }

        // Composer: Enter sends; while a reply streams a Stop button (or Esc) cancels.
        f.page_begin(cw)
        if self.pending {
            f.row(flare.START, flare.CENTER)
            if f.primary("Stop") {
                self.want_stop = true       // ide.ig turns this into a stop_ch send after layout
            }
            f.end()
        } else {
            if self.attachments.len() > 0 {
                f.row(flare.START, flare.CENTER)
                f.text_muted("Attached:")
                var remove_att = 0 - 1
                var ai = 0
                loop {
                    if ai == self.attachments.len() {
                        break
                    }
                    f.key("att{ai}")
                    if f.ghost_button("x " + basename_of(self.attachments[ai])) {
                        remove_att = ai
                    }
                    f.key_clear()
                    ai = ai + 1
                }
                f.end()
                if remove_att >= 0 {
                    self.attachments.remove_at(remove_att)
                }
            }
            self.input = f.text_area("composer", self.input)
            var slash_handled = false
            if sstr.starts_with(self.input, "/") && !sstr.contains(self.input, " ") && self.input != self.ta_dismiss {
                let pick = f.typeahead("comp_slash", "composer", sstr.cp_slice(self.input, 1, self.input.char_count()),
                                       ["new", "settings", "theme", "copy", "quit"])
                if pick == 0 - 2 {
                    self.ta_dismiss = self.input
                } else if pick >= 0 {
                    slash_handled = true
                    self.input = ""
                    f.clear_field()
                    if pick == 0 {
                        if !self.pending {
                            self.new_chat = true
                        }
                    } else if pick == 1 {
                        self.want_settings = true
                    } else if pick == 2 {
                        self.want_theme = true
                    } else if pick == 3 {
                        clipboard_set(transcript_export(self.turns, true))
                        f.toast("Conversation copied as Markdown")
                    } else if pick == 4 {
                        self.want_quit = true
                    }
                }
            } else {
                self.ta_dismiss = ""
            }
            if f.submit() && !slash_handled {
                var msg = self.input
                if self.attachments.len() > 0 {
                    var att = "\n\n[Attached files:"
                    var qi = 0
                    loop {
                        if qi == self.attachments.len() {
                            break
                        }
                        att = att + "\n  " + self.attachments[qi]
                        qi = qi + 1
                    }
                    msg = msg + att + "\n]"
                    self.attachments = []
                }
                if msg.len() > 0 {
                    self.turns.append(api.mk_turn(0, msg))
                    self.want_send = true
                    f.scroll_to_bottom("transcript")
                }
                self.input = ""
            }
        }
        f.page_end()
    }


    // build_conv_menu draws the per-conversation context menu (opened from "..." / right-click);
    // layered after the dock so it floats above every panel.
    fn build_conv_menu(mut self, mut f: flare.Flare) {
        if self.menu_for < 0 {
            return
        }
        if !f.popover_begin("convmenu", self.menu_x, self.menu_y) {
            self.menu_for = 0 - 1
        }
        if f.menu_item("Delete chat") {
            self.delete_conv = self.menu_for
            self.menu_for = 0 - 1
        }
        f.popover_end()
    }


    // build_settings renders the Settings modal's chat-side controls (provider, model,
    // max-tokens, system prompt). Returns true when the provider switched to Ollama and a model
    // discovery should be kicked off (ide owns the channel).
    fn build_settings(mut self, mut f: flare.Flare, tick: int) -> bool {
        var want_disco = false
        f.text_muted("Provider")
        let np = f.segmented("provider", ["Claude (API)", "Ollama (local)"], self.provider)
        if np != self.provider {
            self.provider = np
            self.dirty = true
            if self.provider == 1 {
                want_disco = true
            }
        }
        if self.provider == 1 {
            f.text_muted("Local model")
            if self.discovering {
                f.label("Discovering models " + flare.spinner(tick))
            } else if self.ollama_models.len() == 0 {
                f.label("No models found — run `ollama serve` and `ollama pull <model>`.")
            } else {
                var mi = 0
                loop {
                    if mi == self.ollama_models.len() {
                        break
                    }
                    f.key("om{mi}")
                    if f.nav_item(self.ollama_models[mi], self.ollama_models[mi] == self.ollama_model) {
                        self.ollama_model = self.ollama_models[mi]
                        self.dirty = true
                    }
                    f.key_clear()
                    mi = mi + 1
                }
            }
            if f.ghost_button("Refresh models") && !self.discovering {
                want_disco = true
            }
        } else {
            f.text_muted("Model")
            if self.use_env {
                f.text_muted("Pinned by ANTHROPIC_MODEL")
            } else {
                f.row(flare.START, flare.CENTER)
                let nm = f.dropdown("model", ["Opus 4.8", "Sonnet 5", "Haiku 4.5"], self.model_idx)
                f.end()
                if nm != self.model_idx {
                    self.model_idx = nm
                    self.dirty = true
                }
            }
        }
        f.text_muted("Max tokens")
        let nt = f.segmented("toks", ["1K", "2K", "4K", "8K"], self.tok_idx)
        if nt != self.tok_idx {
            self.tok_idx = nt
            self.dirty = true
        }
        f.text_muted("Verified Loop")
        let nav = f.checkbox("autoverify", "Auto-verify + fix the agent's code", self.auto_verify)
        if nav != self.auto_verify {
            self.auto_verify = nav
            self.dirty = true
        }

        f.text_muted("System prompt")
        let new_sys = f.text_area("sysprompt", self.sys_prompt)
        if new_sys != self.sys_prompt {
            self.sys_prompt = new_sys
            self.dirty = true
        }
        let _ = f.submit()                        // drain a stray Enter so it can't trip the composer
        return want_disco
    }


    // apply runs the post-frame transitions in flare_chat's order: dispatch a queued send, then
    // New chat / switch / Retry / Delete — each a whole-array write-back through the index (the
    // checkout pattern), never a mutation through it.
    fn apply(mut self, mut f: flare.Flare, req_ch: Channel<string>, oll_req_ch: Channel<string>) {
        if self.want_send {
            self.dirty = true
            if self.can_send() {
                self.send_now(req_ch, oll_req_ch)
                self.pending = true
            } else if self.provider == 1 {
                self.turns.append(api.mk_turn(1, "No local model selected. Start `ollama serve`, pull a model (e.g. `ollama pull llama3.2`), then choose it in Settings → Provider → Ollama."))
                f.scroll_to_bottom("transcript")
            } else {
                self.turns.append(api.mk_turn(1, "No API key visible to the app. Make sure ANTHROPIC_API_KEY is EXPORTED in the shell you launch from, then relaunch."))
                f.scroll_to_bottom("transcript")
            }
        }
        if self.new_chat && !self.want_send && self.turns.len() > 0 {
            self.dirty = true
            self.convos[self.active].title = title_for(self.turns)
            self.convos[self.active].turns = self.turns.clone()
            self.convos.append(Conv { title: "New chat", turns: [] })
            self.active = self.convos.len() - 1
            self.turns = []
            self.input = ""
            self.cur_reply = ""
            self.streaming = false
            self.reset_verify()
        }
        if self.switch_to >= 0 && !self.want_send {
            self.dirty = true
            self.convos[self.active].title = title_for(self.turns)
            self.convos[self.active].turns = self.turns.clone()
            self.active = self.switch_to
            self.turns = self.convos[self.active].turns.clone()
            self.input = ""
            self.cur_reply = ""
            self.streaming = false
            self.reset_verify()
        }
        if self.retry_idx >= 1 && !self.want_send && !self.pending {
            self.dirty = true
            self.turns = self.turns.slice(0, self.retry_idx)
            if self.can_send() {
                self.send_now(req_ch, oll_req_ch)
                self.pending = true
            }
            f.scroll_to_bottom("transcript")
        }
        if self.delete_conv >= 0 && !self.want_send {
            self.dirty = true
            self.convos[self.active].title = title_for(self.turns)
            self.convos[self.active].turns = self.turns.clone()
            self.undo_title = self.convos[self.delete_conv].title
            self.undo_turns = self.convos[self.delete_conv].turns.clone()
            self.has_undo = true
            f.toast_action("Conversation deleted", "Undo", "undo_del")
            self.convos.remove_at(self.delete_conv)
            if self.delete_conv < self.active {
                self.active = self.active - 1
            }
            var remapped: [int] = []
            var rti = 0
            loop {
                if rti == self.open_tabs.len() {
                    break
                }
                var t = self.open_tabs[rti]
                if t != self.delete_conv {
                    if t > self.delete_conv {
                        t = t - 1
                    }
                    remapped.append(t)
                }
                rti = rti + 1
            }
            self.open_tabs = remapped
            if self.convos.len() == 0 {
                self.convos.append(Conv { title: "New chat", turns: [] })
                self.active = 0
            }
            if self.active >= self.convos.len() {
                self.active = self.convos.len() - 1
            }
            if self.active < 0 {
                self.active = 0
            }
            self.turns = self.convos[self.active].turns.clone()
            self.input = ""
            self.cur_reply = ""
            self.streaming = false
            self.reset_verify()
        }
    }


    // take_undo restores a just-deleted conversation when its toast's Undo fires ("undo_del").
    fn take_undo(mut self, mut f: flare.Flare) {
        if self.has_undo && f.take_action() == "undo_del" {
            self.convos.append(Conv { title: self.undo_title, turns: self.undo_turns.clone() })
            self.switch_to = self.convos.len() - 1
            self.has_undo = false
            self.dirty = true
            f.toast("Conversation restored")
        }
    }


    // to_json serialises the chat fragment of the store: every conversation's typed turns plus
    // the chat-side settings. The active conversation serialises from the LIVE working array.
    fn to_json(self) -> json.Json {
        var cjs: [json.Json] = []
        var i = 0
        loop {
            if i == self.convos.len() {
                break
            }
            var tjs: [json.Json] = []
            var ttl = ""
            if i == self.active {
                ttl = title_for(self.turns)
                var j = 0
                loop {
                    if j == self.turns.len() {
                        break
                    }
                    tjs.append(turn_json(self.turns[j].role, self.turns[j].text, self.turns[j].kind, self.turns[j].tool_id, self.turns[j].tool_name, self.turns[j].tool_input))
                    j = j + 1
                }
            } else {
                ttl = self.convos[i].title
                let ct = self.convos[i].turns.clone()
                var j = 0
                loop {
                    if j == ct.len() {
                        break
                    }
                    tjs.append(turn_json(ct[j].role, ct[j].text, ct[j].kind, ct[j].tool_id, ct[j].tool_name, ct[j].tool_input))
                    j = j + 1
                }
            }
            cjs.append(json.obj([
                json.member("title", json.str(ttl)),
                json.member("turns", json.arr(tjs))
            ]))
            i = i + 1
        }
        return json.obj([
            json.member("active", json.num(self.active)),
            json.member("model", json.num(self.model_idx)),
            json.member("toks", json.num(self.tok_idx)),
            json.member("system", json.str(self.sys_prompt)),
            json.member("provider", json.num(self.provider)),
            json.member("ollama_model", json.str(self.ollama_model)),
            json.member("auto_verify", json.boolean(self.auto_verify)),
            json.member("convos", json.arr(cjs))
        ])
    }
}


// load rebuilds a Chat from its store fragment (or a fresh one from a null fragment). The
// environment is re-read on every launch: ANTHROPIC_API_KEY gates readiness, ANTHROPIC_MODEL
// pins the model.
fn load(j: json.Json) -> Chat {
    var c = new_chat()
    if json.is_null(j) {
        return c
    }
    let carr = json.get(j, "convos")
    var ci = 0
    loop {
        if ci == json.length(carr) {
            break
        }
        let cj = json.at(carr, ci)
        var lt: [api.Turn] = []
        let tj = json.get(cj, "turns")
        var k = 0
        loop {
            if k == json.length(tj) {
                break
            }
            let tk = json.at(tj, k)
            var t_kind = 0
            if !json.is_null(json.get(tk, "kind")) {
                t_kind = json.as_int(json.get(tk, "kind"))
            }
            var t_tid = ""
            if !json.is_null(json.get(tk, "tid")) {
                t_tid = json.as_str(json.get(tk, "tid"))
            }
            var t_tname = ""
            if !json.is_null(json.get(tk, "tname")) {
                t_tname = json.as_str(json.get(tk, "tname"))
            }
            var t_tinput = ""
            if !json.is_null(json.get(tk, "tinput")) {
                t_tinput = json.as_str(json.get(tk, "tinput"))
            }
            lt.append(api.mk_turn_full(json.as_int(json.get(tk, "role")), json.as_str(json.get(tk, "text")), t_kind, t_tid, t_tname, t_tinput))
            k = k + 1
        }
        let title = title_for(lt)
        c.convos.append(Conv { title: title, turns: lt })
        ci = ci + 1
    }
    if !json.is_null(json.get(j, "active")) {
        c.active = json.as_int(json.get(j, "active"))
    }
    if !json.is_null(json.get(j, "model")) {
        c.model_idx = json.as_int(json.get(j, "model"))
    }
    if !json.is_null(json.get(j, "toks")) {
        c.tok_idx = json.as_int(json.get(j, "toks"))
    }
    if !json.is_null(json.get(j, "system")) {
        c.sys_prompt = json.as_str(json.get(j, "system"))
    }
    if !json.is_null(json.get(j, "provider")) {
        c.provider = json.as_int(json.get(j, "provider"))
    }
    if !json.is_null(json.get(j, "ollama_model")) {
        c.ollama_model = json.as_str(json.get(j, "ollama_model"))
    }
    if !json.is_null(json.get(j, "auto_verify")) {
        c.auto_verify = json.as_bool(json.get(j, "auto_verify"))
    }
    if c.convos.len() == 0 {
        c.convos.append(Conv { title: "New chat", turns: [] })
        c.active = 0
    }
    if c.active >= c.convos.len() {
        c.active = c.convos.len() - 1
    }
    if c.active < 0 {
        c.active = 0
    }
    if c.model_idx < 0 || c.model_idx > 2 {
        c.model_idx = 0
    }
    if c.tok_idx < 0 || c.tok_idx > 3 {
        c.tok_idx = 1
    }
    if c.provider != 0 && c.provider != 1 {
        c.provider = 0
    }
    c.turns = c.convos[c.active].turns.clone()
    return c
}


fn new_chat() -> Chat {
    let env_model = env("ANTHROPIC_MODEL")
    let api_key = env("ANTHROPIC_API_KEY")
    return Chat {
        convos: [Conv { title: "New chat", turns: [] }],
        active: 0,
        turns: [],
        input: "",
        ta_dismiss: "",
        open_tabs: [],
        attachments: [],
        pending: false,
        streaming: false,
        cur_reply: "",
        tool_pending: false,
        tp_id: "",
        tp_name: "",
        tp_input: "",
        menu_for: 0 - 1,
        menu_x: 0,
        menu_y: 0,
        has_undo: false,
        undo_title: "",
        undo_turns: [],
        model_idx: 0,
        tok_idx: 1,
        sys_prompt: "",
        provider: 0,
        ollama_model: "",
        ollama_models: [],
        ollama_tool_models: [],
        discovering: false,
        use_env: env_model.len() > 0,
        env_model: env_model,
        ready: api_key.len() > 0,
        want_send: false,
        want_stop: false,
        new_chat: false,
        switch_to: 0 - 1,
        retry_idx: 0 - 1,
        delete_conv: 0 - 1,
        dirty: false,
        wrote_path: "",
        want_settings: false,
        want_theme: false,
        want_quit: false,
        want_redock_conv: false,
        want_redock_insp: false,
        verifying: false,
        verdict: verify.empty_verdict(),
        verify_turn: 0 - 1,
        verify_rounds: 0,
        auto_verify: true,
        verify_code: ""
    }
}


// ---- the agent's tools: the catalogue advertised to the model, and their local execution ----

// tool_defs is the tool catalogue: list_dir (browse the project — discover paths, don't guess),
// read_file (inspect a file), write_file (create/overwrite under the launch directory). Each
// description is the model's only cue for WHEN to reach for the tool.
fn tool_defs() -> json.Json {
    return json.arr([
        json.obj([
            json.member("name", json.str("list_dir")),
            json.member("description", json.str("List one directory of the project (the directory the IDE was launched from). Returns one entry per line; a trailing '/' marks a subdirectory. Use \".\" for the project root, and use this to DISCOVER paths before read_file — do not guess at file names.")),
            json.member("input_schema", json.obj([
                json.member("type", json.str("object")),
                json.member("properties", json.obj([
                    json.member("path", json.obj([
                        json.member("type", json.str("string")),
                        json.member("description", json.str("Directory path relative to the project root (\".\" for the root itself)."))
                    ]))
                ])),
                json.member("required", json.arr([json.str("path")]))
            ]))
        ]),
        json.obj([
            json.member("name", json.str("read_file")),
            json.member("description", json.str("Read a UTF-8 text file and return its full contents. Use this to inspect source code, configuration, or any file the user refers to BEFORE answering questions about it — do not guess at file contents.")),
            json.member("input_schema", json.obj([
                json.member("type", json.str("object")),
                json.member("properties", json.obj([
                    json.member("path", json.obj([
                        json.member("type", json.str("string")),
                        json.member("description", json.str("Path to the file to read — relative to the project root."))
                    ]))
                ])),
                json.member("required", json.arr([json.str("path")]))
            ]))
        ]),
        json.obj([
            json.member("name", json.str("write_file")),
            json.member("description", json.str("Create or overwrite a UTF-8 text file under the project root, then report the result. The path MUST be relative (no leading '/', no '..'). Use this ONLY when the user EXPLICITLY asks you to save, create, or change a file. Do NOT call it just to show code — put examples directly in your reply as Markdown fenced code blocks.")),
            json.member("input_schema", json.obj([
                json.member("type", json.str("object")),
                json.member("properties", json.obj([
                    json.member("path", json.obj([
                        json.member("type", json.str("string")),
                        json.member("description", json.str("Destination path, relative to the project root (e.g. \"notes/plan.md\")."))
                    ])),
                    json.member("content", json.obj([
                        json.member("type", json.str("string")),
                        json.member("description", json.str("The full text to write to the file."))
                    ]))
                ])),
                json.member("required", json.arr([json.str("path"), json.str("content")]))
            ]))
        ])
    ])
}


// assistant_identity opens the steering prompt with a PROVIDER-ACCURATE identity: Claude on the
// hosted Anthropic API, a neutral local-assistant line on Ollama. Sending "You are Claude" to a
// local model (qwen etc.) makes it dutifully role-play as Claude — so only claim it when it's true.
fn assistant_identity(provider: int) -> string {
    if provider == 1 {
        return "You are a helpful coding assistant running locally via Ollama"
    }
    return "You are Claude"
}


// default_system is the steering prompt sent when the user hasn't set their own. It names the
// setting (an IDE written in Ingle), the tools, and the desktop-chat conventions that keep
// tool_choice=auto from writing files just to show an example. The identity is provider-accurate.
fn default_system(provider: int) -> string {
    return assistant_identity(provider) + " working inside Inglenook, an IDE written in the Ingle programming language — its UI, HTTP stack, and this chat are all Ingle code. You have tools over the project the IDE was launched in: list_dir to browse directories, read_file to inspect files, write_file to create or overwrite a file (relative paths only). Read the relevant files before answering questions about them. Show code, commands, and examples INLINE in your reply as Markdown fenced code blocks; use write_file ONLY when the user explicitly asks you to save, create, or change a file on disk."
}


// effective_system returns the user's system prompt if set, else the provider-accurate default.
fn effective_system(user: string, provider: int) -> string {
    if user.len() > 0 {
        return user
    }
    return default_system(provider)
}


// run_tool dispatches a tool_use by name and returns the result string that goes back to the
// model as the tool_result content. An unknown tool returns an error string it can recover from.
fn run_tool(name: string, input: string) -> string {
    if name == "list_dir" {
        return run_list_dir(input)
    }
    if name == "read_file" {
        return run_read_file(input)
    }
    if name == "write_file" {
        return run_write_file(input)
    }
    return "Error: unknown tool \"{name}\"."
}


// run_list_dir executes the list_dir tool: sorted entries one per line, '/' marking directories
// (the builtin's own contract). Empty means missing/unreadable/empty — say which way is likely.
fn run_list_dir(input: string) -> string {
    let path = api.arg_str(input, "path")
    if path.len() == 0 {
        return "Error: list_dir requires a \"path\" string argument (\".\" for the project root)."
    }
    let out = list_dir(path)
    if out.len() == 0 {
        return "Error: \"{path}\" is missing, unreadable, or an empty directory."
    }
    return api.cap_text(out, 20000)
}


// run_read_file executes the read_file tool; a missing/empty/unreadable file comes back as an
// error result so the model knows it failed.
fn run_read_file(input: string) -> string {
    let path = api.arg_str(input, "path")
    if path.len() == 0 {
        return "Error: read_file requires a \"path\" string argument."
    }
    let content = read_file(path)
    if content.len() == 0 {
        return "Error: could not read \"{path}\" — it is missing, empty, or not readable."
    }
    return api.cap_text(content, 60000)
}


// path_is_safe gates write_file: only a RELATIVE path under the launch directory — no absolute
// path and no '..' segment. Errs toward refusal, the safe bias.
fn path_is_safe(path: string) -> bool {
    let cs = path.chars()
    if cs.len() == 0 {
        return false
    }
    if cs[0] == "/" {
        return false
    }
    if path.split("..").len() > 1 {
        return false
    }
    return true
}


// run_write_file executes the write_file tool: validate, write, then read BACK to confirm the
// bytes landed — the model gets a truthful result, not an optimistic guess.
fn run_write_file(input: string) -> string {
    let path = api.arg_str(input, "path")
    if path.len() == 0 {
        return "Error: write_file requires a \"path\" string argument."
    }
    if !path_is_safe(path) {
        return "Error: refusing to write \"{path}\" — only a relative path under the project root is allowed (no leading '/', no '..')."
    }
    let content = api.arg_str(input, "content")
    write_file(path, content)
    let back = read_file(path)
    if back.len() == 0 && content.len() > 0 {
        return "Error: the write to \"{path}\" did not take — does the target directory exist and is it writable?"
    }
    return "Wrote \"{path}\" ({content.chars().len()} chars)."
}


// ---- transcript rendering (flare_chat's turn renderers, unchanged) ----

// claude_turn renders one assistant turn: the avatar beside the "Claude" label and the reply as
// rich Markdown, then (for committed turns) Copy/Retry ghost buttons. Returns true on Retry.
fn claude_turn(mut f: flare.Flare, body: string, cw: int, key: string, show_actions: bool) -> bool {
    var retry = false
    f.key(key)
    f.row(flare.START, flare.START)
    f.avatar("*")
    f.strut(8, 0)
    f.column(flare.START, flare.START)
    f.text_muted("Claude")
    f.markdown(body, cw - 56)
    if show_actions {
        f.row(flare.START, flare.CENTER)
        if f.ghost_button("Copy") {
            clipboard_set(body)
            f.toast("Copied to clipboard")
        }
        if f.ghost_button("Retry") {
            retry = true
        }
        f.end()
    }
    f.end()
    f.end()
    f.key_clear()
    return retry
}


// user_turn renders one user turn as a rounded chat bubble: a "You" label above the plain prose.
fn user_turn(mut f: flare.Flare, body: string, cw: int) {
    f.bubble_begin()
    f.text_muted("You")
    f.paragraph(body, cw - 24)
    f.bubble_end()
}


// thinking_turn is the pre-stream placeholder: a muted status line with a spinner; a cold local
// model names its GPU-warming wait ("Loading <model>…", OFI-137) instead of the generic thinking.
fn thinking_turn(mut f: flare.Flare, tick: int, provider: int, model: string) {
    f.row(flare.START, flare.CENTER)
    f.avatar("*")
    f.strut(8, 0)
    var label = "Claude is thinking "
    if provider == 1 {
        if model.len() > 0 {
            label = "Loading {model} "
        } else {
            label = "Loading model "
        }
    }
    f.text_muted(label + flare.spinner(tick))
    f.end()
}


// tool_card renders one tool call the way an agent UI does: a subtle panel headed with the tool
// and its argument, then — once the call returns — a capped preview of its output.
fn tool_card(mut f: flare.Flare, key: string, name: string, input: string, result: string, has_result: bool, cw: int) {
    f.key(key)
    f.panel_begin(flare.START, flare.START)
    f.row(flare.START, flare.CENTER)
    f.text_muted("used tool")
    f.strut(6, 0)
    f.label(name + "(" + tool_arg_summary(name, input) + ")")
    f.end()
    if name == "write_file" {
        let content = api.arg_str(input, "content")
        if content.len() > 0 {
            f.divider()
            f.markdown("```\n" + api.cap_text(content, 1500) + "\n```", cw - 48)
        }
    }
    if has_result {
        f.divider()
        f.paragraph(api.cap_text(result, 700), cw - 48)
    } else {
        f.text_muted("running…")
    }
    f.end()
    f.key_clear()
}


// tool_arg_summary renders a tool's args compactly for the card header: the path tools show
// their quoted path; anything else a bounded raw-args preview, never the full blob.
fn tool_arg_summary(name: string, input: string) -> string {
    if name == "read_file" || name == "write_file" || name == "list_dir" {
        let p = api.arg_str(input, "path")
        if p.len() > 0 {
            return "\"" + p + "\""
        }
    }
    return api.cap_text(input, 100)
}


// ---- small shared helpers (flare_chat's, unchanged) ----

// tokens_for maps the max-tokens picker index (0 1K · 1 2K · 2 4K · 3 8K) to the API value.
fn tokens_for(idx: int) -> int {
    if idx == 0 {
        return 1024
    }
    if idx == 2 {
        return 4096
    }
    if idx == 3 {
        return 8192
    }
    return 2048
}


// list_has reports whether a string list contains a value — gates Ollama tool-sending (OFI-135).
fn list_has(xs: [string], x: string) -> bool {
    var i = 0
    loop {
        if i == xs.len() {
            break
        }
        if xs[i] == x {
            return true
        }
        i = i + 1
    }
    return false
}


// ellipsize trims a label to at most n code points (newlines → spaces) with a trailing ellipsis.
fn ellipsize(s: string, n: int) -> string {
    let cs = s.chars()
    var out: [string] = []
    var i = 0
    loop {
        if i == cs.len() || i == n {
            break
        }
        if char_code(cs[i]) == 10 {
            out.append(" ")
        } else {
            out.append(cs[i])
        }
        i = i + 1
    }
    if cs.len() > n {
        out.append("…")
    }
    return concat(out)
}


// title_for names a conversation by its first user message; "New chat" until you speak.
fn title_for(turns: [api.Turn]) -> string {
    var i = 0
    loop {
        if i == turns.len() {
            break
        }
        if turns[i].role == 0 && turns[i].kind == 0 {
            return ellipsize(turns[i].text, 80)
        }
        i = i + 1
    }
    return "New chat"
}


// transcript_export serialises the plain-text turns for Export (Markdown or flat text);
// tool-call/result turns are skipped — this is the human-readable transcript.
fn transcript_export(turns: [api.Turn], md: bool) -> string {
    var out = ""
    var i = 0
    loop {
        if i == turns.len() {
            break
        }
        if turns[i].kind == 0 && turns[i].text.len() > 0 {
            var who = "Claude: "
            if md {
                who = "## Claude"
                if turns[i].role == 0 {
                    who = "## You"
                }
                out = out + who + "\n\n" + turns[i].text + "\n\n"
            } else {
                if turns[i].role == 0 {
                    who = "You: "
                }
                out = out + who + turns[i].text + "\n\n"
            }
        }
        i = i + 1
    }
    if out.len() == 0 {
        out = "(empty conversation)\n"
    }
    return out
}


// basename_of returns the final path component — an attachment chip's label.
fn basename_of(path: string) -> string {
    let parts = path.split("/")
    if parts.len() > 0 {
        return parts[parts.len() - 1]
    }
    return path
}


// int_pos returns the index of `v` in `arr`, or -1.
fn int_pos(arr: [int], v: int) -> int {
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
    return 0 - 1
}


// insert_int returns `arr` with `v` inserted before index `idx` (idx >= len → appended).
fn insert_int(arr: [int], idx: int, v: int) -> [int] {
    var out: [int] = []
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


// tab_labels turns the open conversation indices into unique chip labels (the tabs primitive
// keys a chip by its label; duplicates get a " (n)" suffix).
fn tab_labels(convos: [Conv], open_tabs: [int]) -> [string] {
    var out: [string] = []
    var i = 0
    loop {
        if i == open_tabs.len() {
            break
        }
        let base = ellipsize(convos[open_tabs[i]].title, 16)
        var lbl = base
        var n = 2
        loop {
            var dup = false
            var j = 0
            loop {
                if j == out.len() {
                    break
                }
                if out[j] == lbl {
                    dup = true
                }
                j = j + 1
            }
            if !dup {
                break
            }
            lbl = base + " ({n})"
            n = n + 1
        }
        out.append(lbl)
        i = i + 1
    }
    return out
}


// turn_json serialises one turn to its store JSON: always {role, text}; a tool turn adds
// {kind, tid} and a tool_use {tname, tinput}.
fn turn_json(role: int, text: string, kind: int, tid: string, tname: string, tinput: string) -> json.Json {
    var mem: [json.Member] = []
    mem.append(json.member("role", json.num(role)))
    mem.append(json.member("text", json.str(text)))
    if kind != 0 {
        mem.append(json.member("kind", json.num(kind)))
        mem.append(json.member("tid", json.str(tid)))
        if kind == 1 {
            mem.append(json.member("tname", json.str(tname)))
            mem.append(json.member("tinput", json.str(tinput)))
        }
    }
    return json.obj(mem)
}
