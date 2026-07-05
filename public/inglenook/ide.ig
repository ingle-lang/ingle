// ide.ig — Inglenook: an IDE for coding with LLMs, written in Ingle on std/flare. The dockable
// workspace is Conversations | Chat | (Editor 1 over Editor 2) | Inspector: chat with the agent
// on the left of centre, watch it act on the project in the editors, keep the receipts on the
// right. Phase 1 is the shell — the full flare_chat agent (streaming, tools, both providers)
// plus a live project tree (the list_dir builtin) and syntax-highlighted viewer panes; the
// verify loop (compile/contract verdicts in the chat) arrives with std/proc in Phase 3.
//
// Build + run from the repo root:
//
//   ANTHROPIC_API_KEY=sk-ant-... ./public/inglenook/run.sh
//   # or: make net-graphics && ANTHROPIC_API_KEY=… build/inglec-net-gfx --emit=run public/inglenook/ide.ig
//
// It needs inglec-net-gfx (libcurl transport + the parallel runtime), like flare_chat. Without
// ANTHROPIC_API_KEY it still runs; sending just prints a reminder (or pick Ollama in Settings).
import "std/draw" as draw
import "std/flare" as flare
import "std/json" as json
import "../claude-desktop/anthropic" as api
import "../claude-desktop/ollama" as oll
import "chat" as chat
import "editor" as editor
import "files" as files
import "verify" as verify
import "run" as run
import "lint" as lint
import "tools" as tools

// Keyboard shortcuts (raylib keycodes): ⌘/Ctrl with +/- to zoom, N new chat, K palette,
// comma settings, Q quit; Esc stops a streaming reply.
let KEY_SUPER_L = 343
let KEY_SUPER_R = 347
let KEY_CTRL_L  = 341
let KEY_EQUAL   = 61
let KEY_MINUS   = 45
let KEY_N       = 78
let KEY_K       = 75
let KEY_COMMA   = 44
let KEY_Q       = 81
let KEY_S       = 83
let KEY_ESCAPE  = 256


// build_workspace lays out the default dock: Conversations | Chat | (Editor 1 / [Editor 2 · Run]) |
// Inspector. Chat is the pinned anchor; the bottom-centre leaf tabs Editor 2 with the Run panel (the
// tape scrubber — the "time window"). Every ratio is child A's fraction of its split.
fn build_workspace() -> flare.DockTree {
    var d = flare.dock_new()
    let chat_leaf = d.add_root("Chat")
    let _c = d.split_before(chat_leaf, "Conversations", true, 0.16)
    let e1 = d.split(chat_leaf, "Editor 1", true, 0.44)
    let _i = d.split(e1, "Inspector", true, 0.76)
    let e2 = d.split(e1, "Editor 2", false, 0.55)
    d.add_tab(e2, "Run")
    return d
}


// redock_* re-open a closed panel beside its usual neighbour (menu / palette / toolbar actions).
fn redock_conv(mut d: flare.DockTree) {
    if d.leaf_of("Conversations") < 0 {
        let _ = d.split_before(d.leaf_of("Chat"), "Conversations", true, 0.16)
    }
}


fn redock_insp(mut d: flare.DockTree) {
    if d.leaf_of("Inspector") < 0 {
        var beside = d.leaf_of("Editor 1")
        if beside < 0 {
            beside = d.leaf_of("Editor 2")
        }
        if beside < 0 {
            beside = d.leaf_of("Chat")
        }
        let _ = d.split(beside, "Inspector", true, 0.76)
    }
}


fn redock_editor(mut d: flare.DockTree, which: int) {
    var id = "Editor 1"
    var other = "Editor 2"
    if which == 1 {
        id = "Editor 2"
        other = "Editor 1"
    }
    if d.leaf_of(id) >= 0 {
        return
    }
    let ol = d.leaf_of(other)
    if ol >= 0 {
        if which == 0 {
            let _ = d.split_before(ol, id, false, 0.55)
        } else {
            let _ = d.split(ol, id, false, 0.55)
        }
    } else {
        let _ = d.split(d.leaf_of("Chat"), id, true, 0.44)
    }
}


// panel_cw returns docked panel `id`'s inner content width, clamped to [floor, cap], so a
// panel's content wraps to its CURRENT width as the user resizes it.
fn panel_cw(mut f: flare.Flare, id: string, floor: int, cap: int) -> int {
    var w = floor
    match f.ds.get(id) {
        case Some(r) { w = r.w - f.ui.style.pad * 2 }
        case None {}
    }
    if w > cap { w = cap }
    if w < floor { w = floor }
    return w
}


// store_path is where the workspace persists: $INGLENOOK_STORE if set, else a dotfile in $HOME.
fn store_path() -> string {
    let custom = env("INGLENOOK_STORE")
    if custom.len() > 0 {
        return custom
    }
    return env("HOME") + "/.inglenook-workspace.json"
}


// save_store writes the whole workspace as versioned JSON: the chat fragment (conversations +
// chat settings), the dock layout, the editors' open tabs, the tree's expansions, and the
// app-level looks (theme / zoom / sidebar tab).
fn save_store(ch: chat.Chat, dock: flare.DockTree, panes: editor.Panes, expanded: [string], dark: bool, zoom: int, side: int) {
    var ej: [json.Json] = []
    var i = 0
    loop {
        if i == expanded.len() {
            break
        }
        ej.append(json.str(expanded[i]))
        i = i + 1
    }
    let root = json.obj([
        json.member("v", json.num(1)),
        json.member("dark", json.boolean(dark)),
        json.member("zoom", json.num(zoom)),
        json.member("side", json.num(side)),
        json.member("dock", dock.to_json()),
        json.member("chat", ch.to_json()),
        json.member("editors", panes.to_json()),
        json.member("tree", json.arr(ej))
    ])
    write_file(store_path(), json.stringify(root))
}


// project_label names the workspace in the Files header: the launch directory's basename.
fn project_label() -> string {
    let pwd = env("PWD")
    if pwd.len() == 0 {
        return "Project"
    }
    let parts = pwd.split("/")
    if parts.len() > 0 && parts[parts.len() - 1].len() > 0 {
        return parts[parts.len() - 1]
    }
    return "Project"
}


// implement_prompt frames the editor's code as a contract-first request: implement the body so the
// executable contracts hold. The reply flows through the Verified Loop, so a wrong implementation is
// caught (and auto-fixed) against those very contracts — spec-driven development where the spec can't
// drift, because it executes. The fenced ```ember block is what the loop extracts and checks.
fn implement_prompt(code: string) -> string {
    return "Here is Ingle code with a function signature and an executable contract (requires/ensures) that describes what it must do. Write the COMPLETE implementation so its contracts hold, keeping the signature and contract exactly as given. Return the full code as a single Ingle code block:\n\n```ember\n" + code + "\n```"
}


fn main() -> int {
    draw.window(1460, 880, "Inglenook")
    var f = flare.new()
    f.set_realtime(true)

    // Opt-in UI tape (trust the tape): EMBER_TAPE=/path records one JSON line per frame.
    let tape_path = env("EMBER_TAPE")
    if tape_path.len() > 0 {
        draw.tape_on(tape_path)
    }

    // Workspace state — defaults, then the saved store overrides.
    var ch = chat.new_chat()
    var panes = editor.new_panes()
    var tree = files.new_tree()
    var runner = run.new_runner()            // the tape scrubber (Run panel)
    var linter = lint.new_linter()           // live diagnostics (editor squiggles)
    var dock = build_workspace()
    var dark = true
    var zoom = 80
    var side = 0                              // sidebar tab: 0 = Chats, 1 = Files
    let saved = read_file(store_path())
    if saved.len() > 0 {
        match json.parse(saved) {
            case Ok(root) {
                ch = chat.load(json.get(root, "chat"))
                panes = editor.load(json.get(root, "editors"))
                let tj = json.get(root, "tree")
                if !json.is_null(tj) {
                    var ti = 0
                    loop {
                        if ti == json.length(tj) {
                            break
                        }
                        tree.expanded.append(json.as_str(json.at(tj, ti)))
                        ti = ti + 1
                    }
                }
                if !json.is_null(json.get(root, "dark")) {
                    dark = json.as_bool(json.get(root, "dark"))
                }
                if !json.is_null(json.get(root, "zoom")) {
                    zoom = json.as_int(json.get(root, "zoom"))
                }
                if !json.is_null(json.get(root, "side")) {
                    side = json.as_int(json.get(root, "side"))
                }
                let dockj = json.get(root, "dock")
                if !json.is_null(dockj) {
                    let saved_dock = flare.dock_from_json(dockj)
                    if saved_dock.leaf_of("Chat") >= 0 {   // only if the pinned anchor survived
                        dock = saved_dock
                    }
                }
            }
            case Err(e) {}
        }
    }
    if zoom < 60 || zoom > 220 {
        zoom = 80
    }
    if side != 0 && side != 1 {
        side = 0
    }
    if dark {
        f.use_dark()
    } else {
        f.use_light()
    }
    f.set_zoom(zoom)

    let project = project_label()
    var settings_open = false
    var palette_open = false
    var tick = 0

    // Async transport: worker fibers pump the HTTPS streams; the render loop drains resp_ch with
    // non-blocking try_recv so drawing never stalls — the flare_chat shape, verbatim.
    let req_ch: Channel<string> = channel(2)
    let oll_req_ch: Channel<string> = channel(2)
    let resp_ch: Channel<string> = channel(64)
    let stop_ch: Channel<bool> = channel(2)
    let disco_base_ch: Channel<string> = channel(2)
    let disco_resp_ch: Channel<string> = channel(2)
    // ONE tooling worker for verify + tape-run + lint (kind-tagged), so the app runs 4 worker fibers
    // (api, ollama, discovery, tools) instead of 6 — less worker-thread contention on the render loop.
    let tool_req_ch: Channel<string> = channel(4)      // tagged verify/run/lint requests → the tooling worker
    let tool_resp_ch: Channel<string> = channel(8)     // …tagged results (verdict / tape / CSV) come back here
    let api_key = env("ANTHROPIC_API_KEY")
    let ollama_base = oll.default_base()
    nursery {
    spawn api.stream_worker(api_key, req_ch, resp_ch, stop_ch)
    spawn oll.stream_worker(ollama_base, oll_req_ch, resp_ch, stop_ch)
    spawn oll.disco_worker(disco_base_ch, disco_resp_ch)
    spawn tools.tool_worker(tool_req_ch, tool_resp_ch)          // verify + tape-run + lint, serialised off-thread
    if ch.provider == 1 {
        send(disco_base_ch, ollama_base)
        ch.discovering = true
    }
    var prev_down = false
    var ws_snap = ""                          // last-persisted workspace snapshot (dock+tabs+tree)
    var coast = 12
    loop {
        if draw.closing() {
            break
        }
        tick = tick + 1
        ch.begin_frame()
        runner.begin_frame()
        linter.begin_frame()
        ch.drain(resp_ch, req_ch, oll_req_ch)
        ch.drain_disco(disco_resp_ch)
        // One tooling-response drain, routed by the kind tag back to chat / runner / linter.
        match try_recv(tool_resp_ch) {
            case Some(m) {
                let k = tools.kind_of(m)
                let p = tools.payload_of(m)
                if k == tools.KIND_VERIFY {
                    ch.apply_verdict(p)
                } else if k == tools.KIND_RUN {
                    runner.apply_tape(p)
                } else if k == tools.KIND_LINT {
                    linter.apply_result(p)
                }
            }
            case None {}
        }
        linter.note_buffer(panes.active_path(0), panes.active_text(0))   // debounced live-check of Editor 1
        var quit = false
        var want_disco = false

        // Keyboard shortcuts.
        let cmd = key_down(KEY_SUPER_L) || key_down(KEY_SUPER_R) || key_down(KEY_CTRL_L)
        if cmd && key_pressed(KEY_EQUAL) {
            f.zoom_by(10)
            ch.dirty = true
        }
        if cmd && key_pressed(KEY_MINUS) {
            f.zoom_by(0 - 10)
            ch.dirty = true
        }
        if cmd && key_pressed(KEY_N) && !ch.pending {
            ch.new_chat = true
        }
        if cmd && key_pressed(KEY_COMMA) {
            settings_open = true
        }
        if cmd && key_pressed(KEY_K) {
            palette_open = true
        }
        if cmd && key_pressed(KEY_Q) {
            quit = true
        }
        if cmd && key_pressed(KEY_S) {                 // ⌘S: save the active file of both editor panes
            let s0 = panes.save_active(0)
            let s1 = panes.save_active(1)
            if s0.len() > 0 || s1.len() > 0 {
                tree.refresh()
                ch.dirty = true
                var saved = s0
                if saved.len() == 0 {
                    saved = s1
                }
                f.toast("Saved " + editor.basename(saved))
            }
        }
        if key_pressed(KEY_ESCAPE) && ch.pending {
            send(stop_ch, true)
        }

        draw.begin(f.bg())
        f.begin()

        // File drag-drop → staged attachment chips (read every frame or raylib discards them).
        let dropped = dropped_files()
        if dropped.len() > 0 {
            let dpaths = dropped.split("\n")
            var dpi = 0
            loop {
                if dpi == dpaths.len() {
                    break
                }
                if dpaths[dpi].len() > 0 {
                    ch.attachments.append(dpaths[dpi])
                }
                dpi = dpi + 1
            }
        }

        // ---- menu bar — every item drives the SAME state as the shortcuts/palette. ----
        let bar_h = f.menubar_height()
        f.menubar_begin()
        if f.menu("File") {
            if f.menu_item_accel("New chat", "⌘N") && !ch.pending {
                ch.new_chat = true
            }
            f.menu_sep()
            if f.submenu("Export") {
                if f.menu_item("Copy as Markdown") {
                    clipboard_set(chat.transcript_export(ch.turns, true))
                    f.toast("Conversation copied as Markdown")
                }
                if f.menu_item("Copy as Plain text") {
                    clipboard_set(chat.transcript_export(ch.turns, false))
                    f.toast("Conversation copied as text")
                }
                f.submenu_end()
            }
            f.menu_sep()
            if f.menu_item_accel("Settings…", "⌘,") {
                settings_open = true
            }
            f.menu_sep()
            if f.menu_item_accel("Quit", "⌘Q") {
                quit = true
            }
            f.menu_end()
        }
        if f.menu("View") {
            if f.menu_item_accel("Zoom In", "⌘+") {
                f.zoom_by(10)
                ch.dirty = true
            }
            if f.menu_item_accel("Zoom Out", "⌘−") {
                f.zoom_by(0 - 10)
                ch.dirty = true
            }
            if f.menu_item("Toggle Theme") {
                dark = !dark
                if dark {
                    f.use_dark()
                } else {
                    f.use_light()
                }
                ch.dirty = true
            }
            f.menu_sep()
            if dock.leaf_of("Conversations") < 0 {
                if f.menu_item("Show Conversations") {
                    redock_conv(dock)
                }
            }
            if dock.leaf_of("Editor 1") < 0 {
                if f.menu_item("Show Editor 1") {
                    redock_editor(dock, 0)
                }
            }
            if dock.leaf_of("Editor 2") < 0 {
                if f.menu_item("Show Editor 2") {
                    redock_editor(dock, 1)
                }
            }
            if dock.leaf_of("Inspector") < 0 {
                if f.menu_item("Show Inspector") {
                    redock_insp(dock)
                }
            }
            if f.menu_item("Reset Layout") {
                dock = build_workspace()
            }
            f.menu_end()
        }
        if f.menu("Help") {
            if f.menu_item("About Inglenook") {
                f.toast("Inglenook — an IDE for coding with LLMs, written in Ingle + Flare")
            }
            f.menu_end()
        }
        f.menubar_end()

        // ---- the dockable workspace ----
        f.dock_pin("Chat")
        let dm = 12
        let dhit = f.dock_begin(dock, dm, dm + bar_h, screen_width() - 2 * dm, screen_height() - 2 * dm - bar_h)
        if dhit >= 0 {
            let pid = dock.close_tab(dhit)
            f.forget(pid)
        }
        let conv_closed = dock.leaf_of("Conversations") < 0
        let insp_closed = dock.leaf_of("Inspector") < 0

        // --- Conversations: the sidebar — Chats and Files as in-panel tabs ---
        if f.dock_panel("Conversations") {
            f.row(flare.START, flare.CENTER)
            f.heading("Inglenook")
            f.end()
            let nside = f.segmented("sidetabs", ["Chats", "Files"], side)
            if nside >= 0 && nside <= 1 {
                side = nside
            }
            if side == 0 {
                ch.build_chats(f)
            } else {
                f.scroll_begin("filetree")
                tree.build(f, project)
                f.scroll_end("filetree")
            }
            f.dock_panel_end()
        }

        // --- Chat: the conversation panel (tabs, toolbar, transcript, composer) ---
        if f.dock_panel("Chat") {
            let cw = panel_cw(f, "Chat", 280, 820)
            ch.build_panel(f, cw, tick, conv_closed, insp_closed)
            f.dock_panel_end()
        }

        // --- Editor 1 / Editor 2: the stacked code windows (with tape spotlight + diagnostic squiggles) ---
        if f.dock_panel("Editor 1") {
            let cw1 = panel_cw(f, "Editor 1", 240, 3000)
            panes.build(f, 0, cw1, runner.hot_line(panes.active_path(0)), linter.lines_for(panes.active_path(0)))
            f.dock_panel_end()
        }
        if f.dock_panel("Editor 2") {
            let cw2 = panel_cw(f, "Editor 2", 240, 3000)
            panes.build(f, 1, cw2, runner.hot_line(panes.active_path(1)), linter.lines_for(panes.active_path(1)))
            f.dock_panel_end()
        }
        // --- Run: the tape scrubber (the "time window") ---
        if f.dock_panel("Run") {
            let cwr = panel_cw(f, "Run", 200, 3000)
            runner.build(f, panes.active_path(0), tick, cwr)
            f.dock_panel_end()
        }

        // --- Inspector: the workspace's context at a glance ---
        if f.dock_panel("Inspector") {
            let iw = panel_cw(f, "Inspector", 120, 600)
            f.heading("Context")
            f.divider()
            f.text_muted("Provider")
            f.label(ch.provider_label())
            f.text_muted("Model")
            f.label(ch.model_label())
            f.text_muted("Max tokens")
            let mt = chat.tokens_for(ch.tok_idx)
            f.label("{mt}")
            f.text_muted("Messages")
            var nmsg = 0
            var ntool = 0
            var ii = 0
            loop {
                if ii == ch.turns.len() {
                    break
                }
                if ch.turns[ii].kind == 1 {
                    ntool = ntool + 1
                } else if ch.turns[ii].kind == 0 {
                    nmsg = nmsg + 1
                }
                ii = ii + 1
            }
            f.label("{nmsg} message(s) · {ntool} tool call(s)")
            f.text_muted("Tools")
            if ch.provider == 1 {
                if chat.list_has(ch.ollama_tool_models, ch.ollama_model) {
                    f.label("list_dir · read_file · write_file")
                } else {
                    f.label("(none — local model)")
                }
            } else {
                f.label("list_dir · read_file · write_file")
            }
            f.text_muted("Verified Loop")
            if !ch.auto_verify {
                f.label("off (Settings ⌘,)")
            } else if ch.verifying {
                f.badge("checking " + flare.spinner(tick), 3)
            } else if !ch.verdict.ran {
                f.label("waiting for code")
            } else if verify.all_green(ch.verdict) {
                f.badge("verified", 1)
            } else if !ch.verdict.compiles {
                f.badge("won't compile", 2)
            } else if !ch.verdict.contracts_ok {
                f.badge("contract falsifiable", 2)
            } else {
                f.badge("faults at runtime", 2)
            }
            f.text_muted("Editor 1")
            var ap = panes.active_path(0)
            if ap.len() == 0 {
                ap = "(empty)"
            }
            f.paragraph(ap, iw)
            f.text_muted("Editor 2")
            var bp = panes.active_path(1)
            if bp.len() == 0 {
                bp = "(empty)"
            }
            f.paragraph(bp, iw)
            f.text_muted("System prompt")
            if ch.sys_prompt.len() > 0 {
                f.paragraph(ch.sys_prompt, iw)
            } else {
                f.label("(default — override in Settings)")
            }
            f.spacer()
            f.divider()
            f.row(flare.START, flare.CENTER)
            if f.ghost_button("Settings") {
                settings_open = true
            }
            if f.ghost_button("Reset layout") {
                dock = build_workspace()
            }
            f.end()
            f.dock_panel_end()
        }

        // ---- floating layers: context menus, the settings modal, the ⌘K palette ----
        ch.build_conv_menu(f)
        tree.build_menu(f)

        if settings_open {
            if !f.modal_begin("settings", 460, 0) {
                settings_open = false
            }
            f.heading("Settings")
            f.divider()
            f.text_muted("Appearance")
            let new_dark = f.checkbox("dark", "Dark mode", dark)
            if new_dark != dark {
                dark = new_dark
                if dark {
                    f.use_dark()
                } else {
                    f.use_light()
                }
                ch.dirty = true
            }
            if ch.build_settings(f, tick) {
                want_disco = true
            }
            f.text_muted("Text size — {f.zoom}%")
            let nz = f.slider("zoom", f.zoom, 60, 220)
            if nz != f.zoom {
                f.set_zoom(nz)
                ch.dirty = true
            }
            f.divider()
            f.row(flare.END, flare.CENTER)
            if f.primary("Done") {
                settings_open = false
            }
            f.end()
            f.modal_end()
        }

        if palette_open {
            let pick = f.command_palette("cmdk", ["New chat", "Settings…", "Toggle theme", "Zoom in", "Zoom out", "Reset zoom", "Show Conversations", "Show Editor 1", "Show Editor 2", "Show Inspector", "Reset layout", "Refresh files", "Copy conversation as Markdown", "Copy conversation as plain text", "Quit"])
            if pick != 0 - 1 {
                palette_open = false
                if pick == 0 {
                    if !ch.pending {
                        ch.new_chat = true
                    }
                } else if pick == 1 {
                    settings_open = true
                } else if pick == 2 {
                    dark = !dark
                    if dark {
                        f.use_dark()
                    } else {
                        f.use_light()
                    }
                    ch.dirty = true
                } else if pick == 3 {
                    f.zoom_by(10)
                    ch.dirty = true
                } else if pick == 4 {
                    f.zoom_by(0 - 10)
                    ch.dirty = true
                } else if pick == 5 {
                    f.set_zoom(80)
                    ch.dirty = true
                } else if pick == 6 {
                    redock_conv(dock)
                } else if pick == 7 {
                    redock_editor(dock, 0)
                } else if pick == 8 {
                    redock_editor(dock, 1)
                } else if pick == 9 {
                    redock_insp(dock)
                } else if pick == 10 {
                    dock = build_workspace()
                } else if pick == 11 {
                    tree.refresh()
                    f.toast("File tree refreshed")
                } else if pick == 12 {
                    clipboard_set(chat.transcript_export(ch.turns, true))
                    f.toast("Conversation copied as Markdown")
                } else if pick == 13 {
                    clipboard_set(chat.transcript_export(ch.turns, false))
                    f.toast("Conversation copied as text")
                } else if pick == 14 {
                    quit = true
                }
            }
        }

        f.finish()
        f.toast_layer()
        ch.take_undo(f)

        // Idle frame-gating: nothing moving → block on OS events instead of re-rendering.
        // The linter's debounce fits inside the post-input coast (LINT_SETTLE 7 < coast 12), so typing's
        // own had_input keeps enough frames running for a check to fire — only an IN-FLIGHT check
        // (linter.checking) or a run needs to hold the loop awake beyond that.
        if had_input() || f.is_animating() || ch.pending || ch.discovering || ch.verifying || runner.running || linter.checking {
            coast = 12
        } else if coast > 0 {
            coast = coast - 1
        }
        set_event_waiting(coast == 0)
        draw.finish()

        // ---- post-frame application (the checkout pattern: act only after layout) ----
        if ch.want_stop {
            send(stop_ch, true)
        }
        if panes.implement_code.len() > 0 && !ch.pending {   // contract-first Implement → ask the agent (before apply, so it sends this frame)
            ch.ask(implement_prompt(panes.implement_code))
            panes.implement_code = ""
            side = 0                                          // surface the Chats tab so the reply is visible
            f.scroll_to_bottom("transcript")
        }
        ch.apply(f, req_ch, oll_req_ch)
        if ch.want_settings {
            settings_open = true
        }
        if ch.want_theme {
            dark = !dark
            if dark {
                f.use_dark()
            } else {
                f.use_light()
            }
            ch.dirty = true
        }
        if ch.want_quit {
            quit = true
        }
        if ch.want_redock_conv {
            redock_conv(dock)
        }
        if ch.want_redock_insp {
            redock_insp(dock)
        }
        if want_disco {
            send(disco_base_ch, ollama_base)
            ch.discovering = true
        }
        if ch.verify_code.len() > 0 {          // a reply carried Ingle code → verify it off-thread
            send(tool_req_ch, tools.verify_req(ch.verify_code))
        }
        if runner.run_code.len() > 0 {         // the Run button → run the file + capture its tape
            runner.running = true
            runner.ran_path = runner.run_code
            send(tool_req_ch, tools.run_req(runner.run_code))
        }
        if linter.pend_code.len() > 0 {        // the editor buffer settled → live-check it for squiggles
            send(tool_req_ch, tools.lint_req(linter.pend_code))
        }
        if tree.open_path.len() > 0 {          // a file-tree click → open in the chosen pane
            panes.open(tree.open_pane, tree.open_path)
            tree.open_path = ""
            ch.dirty = true
        }
        if ch.wrote_path.len() > 0 {           // the agent wrote a file → refresh what shows it
            panes.reload_if_open(ch.wrote_path)
            tree.refresh()
        }
        if panes.saved_path.len() > 0 {        // the editor's Save button wrote a file → refresh the tree
            tree.refresh()
            panes.saved_path = ""
            ch.dirty = true
        }

        // A workspace change (dock drag / tab open-close / tree expand) is detected on mouse
        // release by comparing a serialized snapshot — the rearranged workspace persists too.
        let now_down = f.ui.down
        if prev_down && !now_down {
            var exp = ""
            var xi = 0
            loop {
                if xi == tree.expanded.len() {
                    break
                }
                exp = exp + tree.expanded[xi] + "\n"
                xi = xi + 1
            }
            let cur_ws = json.stringify(dock.to_json()) + json.stringify(panes.to_json()) + exp + "{side}"
            if ws_snap.len() == 0 {
                ws_snap = cur_ws                       // first release: baseline, not a change
            } else if cur_ws != ws_snap {
                ch.dirty = true
                ws_snap = cur_ws
            }
        }
        prev_down = now_down

        if ch.dirty {
            save_store(ch, dock, panes, tree.expanded, dark, f.zoom, side)
        }
        if quit {
            break
        }
    }
    close(req_ch)
    close(oll_req_ch)
    close(disco_base_ch)
    close(tool_req_ch)     // wake the tooling worker out of recv → None → it exits (nursery join)
    // M:N safety: tear graphics down on THIS thread (it owns the GL context) BEFORE the nursery
    // join below — see flare_chat for the full story.
    if tape_path.len() > 0 {
        draw.tape_off()
    }
    draw.close()
    }
    return 0
}
