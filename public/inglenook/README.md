# Inglenook

*The seat built into the hearth: an IDE for coding with LLMs, written in Ingle on
[Flare](../../docs/flare.md).*

Inglenook is the flagship Ingle application — a real, dockable IDE whose UI kit, HTTP stack,
JSON, syntax highlighter, and (soon) compiler front end are all written in the language it
edits. The workspace is five dockable panels:

```
Conversations | Chat | Editor 1  | Inspector
 (Chats/Files)|      | ─────────
              |      | Editor 2  |
```

- **Conversations** — your chats, plus a **Files** tab: a live project tree over the new
  `list_dir` builtin (sorted, replay-recorded — a directory listing is an input).
- **Chat** — the full agent from the claude-desktop example: streaming replies, the
  tool_use → tool_result loop, and both providers (Anthropic API / local Ollama). The agent's
  tools are `list_dir`, `read_file`, and `write_file` over the project the IDE was launched in —
  it browses before it guesses.
- **Editor 1 / Editor 2** — stacked code windows: per-pane file tabs, and a real editable,
  syntax-highlighted code editor (`f.code_editor`) — line-number gutter, caret, selection,
  clipboard, Tab-indents, Enter that keeps the block's indentation, and its own caret-following
  scroll. Edit a file, hit **Save** (or ⌘S) to write it; a `•` marks unsaved changes. Each open
  file keeps its own scroll position, and when the agent writes a file that's open the pane
  reloads — what you see is the disk it acted on. The editor **virtualizes**, so a thousand-line
  file costs the same as a screenful.
- **Inspector** — the workspace's context at a glance; verdicts and the tape scrubber land here
  in later phases.

Everything docks: drag dividers, close panels, re-dock from the View menu / toolbar / ⌘K
palette; the layout (and your chats, open tabs, and tree expansions) persists across restarts.

## Run

```sh
ANTHROPIC_API_KEY=sk-ant-... ./public/inglenook/run.sh
# or, by hand:
make net-graphics
ANTHROPIC_API_KEY=… build/inglec-net-gfx --emit=run public/inglenook/ide.ig
```

No key? It still runs — choose **Ollama (local)** in Settings (⌘,) to chat with a local model.

- `INGLENOOK_STORE=/path` overrides where the workspace persists (default
  `~/.inglenook-workspace.json`).
- `EMBER_TAPE=/path` records the UI tape (one JSON line per frame) for diagnosis.

## Where it's going

Phase 2 grows a real editable `f.code_editor` widget in Flare. Phase 3 adds `std/proc` and the
**Verified Loop** — agent-proposed code is compiled, contract-checked (`--check`), and run
before you see it, with the verdict strip rendered in the chat and red verdicts routed back to
the model until green. Phase 4 makes the bottom pane a *time window*: the execution tape,
scrubbable, with deterministic replay. Cursor shows you what the AI said; Inglenook shows you
what the code did.
