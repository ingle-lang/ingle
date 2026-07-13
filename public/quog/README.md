# Quog

**Breadcrumb-based repository storage — a version control system that is not half as
dangerous as git.**

Quog gives you git's good idea — a content-addressed, tamper-evident history of your
project — without git's foot-guns. There is no staging area to forget, no detached HEAD
to strand you, no `--force` to rewrite shared history, and no command that silently throws
away uncommitted work. Every destructive-looking action is *recoverable*, and the whole
store is *verifiable* down to the last byte.

It ships as one small binary with three faces:

- a **command line** (`quog save`, `quog log`, `quog switch`, …),
- a **web UI** you can drive from a browser (`quog serve`), and
- **distributed sync** over plain HTTP (`quog pull` / `quog push`), authenticated with a
  shared token.

Quog is written entirely in [**Ingle**](../../README.md) — it is a working, end-to-end
application built to dogfood the language, its standard library, and its web story.

---

## Why Quog is safer than git

Six invariants hold *by construction* — they are not conventions you have to remember, they
are the way the store works.

| # | Invariant | What it means for you |
|---|-----------|-----------------------|
| 1 | **Append-only store** | Objects are content-addressed and written `INSERT OR IGNORE`. History is added to, never edited in place. Re-writing a commit's bytes changes its id — so `verify` catches it. |
| 2 | **Universal undo** | Every state-changing command journals a before/after pair. `quog undo` walks it back — saves, switches, merges alike. |
| 3 | **No staging area** | `quog save` snapshots your whole working tree. There is no index to add to, forget, or get out of sync with reality. |
| 4 | **Switching never loses work** | `quog switch` snapshots the branch you leave before moving. Uncommitted changes are parked in the attic, not discarded. |
| 5 | **No `--force`, ever** | Sync is *additive*: a push that would overwrite someone else's branch is filed under `pushed/<branch>` instead of clobbering it. There is no command that rewrites shared history. |
| 6 | **Discard is recoverable** | Even `quog discard` — the "throw away my changes" command — copies the tree into the attic first, so `quog restore` can bring it back. |

The design bet: for people who avoid git *because* it is dangerous, safety **is** the
feature. Everything reversible; everything checkable.

---

## Install

Quog builds to **one standalone native binary** — drop it on your `PATH` and you are done.
There is no runtime, no interpreter, and no toolchain to install alongside it; the only thing
it links against at run time is your system C library (the SQLite engine is compiled *into*
the binary).

```sh
make quog            # emits Quog to C, links it -> build/quog (a ~1.5 MB executable)
make install-quog    # copies build/quog to ~/.ingle/bin/quog
```

Put `~/.ingle/bin` on your `PATH` (or copy `build/quog` anywhere you like — `/usr/local/bin`,
`~/bin`, …) and every example below just works:

```sh
quog init
```

Under the hood `make quog` compiles [`quog.ig`](quog.ig) through Ingle's native backend
(`inglec --emit=c`) and links the emitted C against the runtime + the vendored SQLite — the
same path that produces the Ingle compiler itself. The binary is self-contained and
relocatable.

### Running from source (no binary)

If you would rather run Quog straight through the Ingle VM without producing a binary — handy
while hacking on it — build the SQLite-enabled compiler and interpret the source:

```sh
make db
build/inglec-db --emit=run public/quog/quog.ig <verb> [args]
```

All state lives in **`.quog/quog.db`** at the root of your repo — one file, easy to back up,
easy to inspect, easy to delete.

---

## Quick start

```console
$ quog init
initialised empty Quog repo in .quog/

$ quog save "initial import"
saved 1b403862b3 (2 files) — initial import

$ echo "delta" >> README.md && quog status
  modified  README.md

$ quog diff
=== README.md  (+1 -0) ===
 gamma
+delta

$ quog save "add delta"
saved bc003bd838 (2 files) — add delta

$ quog log
bc003bd838  t=1751000000  add delta
1b403862b3  t=1751000000  initial import
```

That is the whole daily loop: **edit → `status` → `diff` → `save`**. No `add`, no staging,
no ceremony.

---

## Command reference

Every command operates on the repo in the current directory. IDs are SHA-256 content
hashes; they are shown abbreviated to 10 characters but any command that takes an id
accepts the full 64-character form too.

### Recording work

**`quog init`** — create a fresh, empty repository in `.quog/`.

**`quog save "<message>"`** — snapshot the entire working tree as a new commit on the
current branch.
```console
$ quog save "edit readme, add todo"
saved bc003bd838 (3 files) — edit readme, add todo
```

**`quog status`** — show what changed since the last save.
```console
$ quog status
  modified  README.md
  added     TODO.md
  deleted   OLD.md
```
When nothing has changed it prints `clean — nothing changed since the last save`.

**`quog diff`** — the line-level unified diff of every changed file, computed with an LCS
diff.
```console
$ quog diff
=== README.md  (+2 -1) ===
 alpha
-beta
+BETA
 gamma
+delta
=== TODO.md  (+1 -0) ===
+notes
```

### Inspecting history

**`quog log`** — the current branch's history, newest first.
```console
$ quog log
d706d5131a  t=1751000000  experiment work
d90b9dae79  t=1751000000  resync
1b403862b3  t=1751000000  initial import
```

**`quog show <id>`** — the details of one commit: its parent, time, message, and the files
in its tree.
```console
$ quog show bc003bd838
commit   bc003bd838f0c1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6
parent   1b403862b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0
time     1751000000
message  edit readme, add todo
files:
  9f2b1c8a0d  README.md
  a17e04c3f1  TODO.md
```
IDs on the `commit`/`parent` lines are shown in full; file ids are the 10-character
short form.

### Undoing and recovering — the safety net

**`quog undo`** — walk back the most recent state change. It knows what it is undoing and
tells you, and it never loses anything:
```console
$ quog undo
undid save — tip bc003bd838 → 1b403862b3 (nothing lost)

$ quog undo
undid switch — back on main
```

**`quog discard`** — throw away *uncommitted* working changes. Even this is reversible: the
tree is copied to the attic first.
```console
$ quog discard
discarded working changes — recoverable with: quog restore 1
```

**`quog restore`** — list what is in the attic (discarded trees, work parked by a switch),
and bring an entry back.
```console
$ quog restore
  1  t=1751000000  discarded working changes
restore one with: quog restore <n>

$ quog restore 1
```

### Branching

**`quog branch`** — list branches (the current one marked `*`).
```console
$ quog branch
  experiment
* main
```

**`quog branch <name>`** — create a branch at the current tip.
```console
$ quog branch experiment
created branch experiment at d90b9dae79
```

**`quog switch <name>`** — move to another branch. Your current work is snapshotted before
the move, so switching can never lose uncommitted changes.
```console
$ quog switch experiment
switched to experiment
```

**`quog merge <name>`** — merge another branch into the current one. A fast-forward when the
current branch is an ancestor; otherwise a three-way merge against the merge base. Text
conflicts are surfaced, never silently resolved.
```console
$ quog merge experiment
fast-forwarded main to d706d5131a
```

### Integrity

**`quog verify`** — re-hash every object and re-resolve every link. This is the
tamper-evidence guarantee: because objects are content-addressed, any in-place edit to
history — corruption or a deliberate rewrite — makes an object stop hashing to its own id,
and `verify` finds it.
```console
$ quog verify
verified 4 commits, 4 trees, 6 blobs — every object intact, every link resolves
```
If something is wrong it exits non-zero and lists the problems:
```console
$ quog verify
  TAMPERED bc003bd838 — its content no longer hashes to its id
FAILED — 1 integrity problem(s) found
```

---

## The web UI

`quog serve` starts a small web server — written in pure Ingle over a raw socket — that both
*shows* the repo and lets you *drive* it from a browser.

```console
$ quog serve
quog serving on http://localhost:8017 (loopback only) — Ctrl-C to stop
```

By default it binds **loopback only** (`127.0.0.1`) — reachable from your machine, not the
network. It listens on port **8017**; pass a number to change it, and `--public` to bind all
interfaces (see the warning below).

```console
$ quog serve 9000                # different port, still loopback
$ quog serve --public            # bind 0.0.0.0 — network-reachable
quog serving PUBLICLY on http://0.0.0.0:8017 — reachable from your network, NO auth. Ctrl-C to stop
```

### What the dashboard gives you

The home page is a live control panel, server-rendered in Ingle:

- **Uncommitted changes** with a **Save** form (type a message, click Save) and a **Discard**
  button.
- The **branch list**, each with a **Switch** button, plus a **Create branch** form.
- An **Undo** button.
- The browsable **history** — every commit links to its detail page and colored diff.
- A link to the **verify** integrity view.

Actions post to the server and redirect back (the POST-redirect-GET pattern), so a refresh
never re-submits. On a loopback server *you* are the owner and every action is allowed; on a
`--public` server the mutating actions are **token-gated** (see below), so a random visitor
can read but not change your repo.

> **`--public` has no transport security.** It serves plain HTTP with no TLS. Expose a repo
> to a network only behind a reverse proxy that terminates TLS, or over a trusted LAN/VPN.

---

## Distributed sync

Quog repos synchronize over plain HTTP, additively — in the spirit of Fossil, never git's
history-rewriting. One repo runs `quog serve`; another pulls from or pushes to it.

**`quog pull <host> <port>`** — fetch every object the remote has that you don't, and update
your branch pointers. A branch that has diverged is *kept* — the remote's tip is filed under
`remote/<branch>` rather than overwriting yours.
```console
$ quog pull localhost 8017
pulled 12 objects from localhost:8017 — 2 branch(es) updated
```

**`quog push <host> <port>`** — send every object the remote is missing, then offer your
branch tips. The remote fast-forwards where it can and files anything that would clobber
under `pushed/<branch>`. Nothing is ever force-updated.
```console
$ quog push localhost 8017
pushed 5 objects to localhost:8017
```

Every object a repo receives is **re-hashed on arrival** and stored under the id it actually
hashes to — so a peer cannot inject an object under a forged id. Combined with `verify`, the
store stays trustworthy across machines.

### Authenticating writes

Reads are open; **writes are gated by a shared token**.

**`quog auth <token>`** — set the token a server requires for any write (a push, or a
mutating web action).
```console
$ quog auth s3cr3t
sync token set — pushes now require it; share it, clients pass it via QUOG_TOKEN
```

Clients supply it via the **`QUOG_TOKEN`** environment variable:
```console
$ QUOG_TOKEN=s3cr3t quog push example.com 8017
pushed 5 objects to example.com:8017
```

The server rejects any write whose `X-Quog-Token` header doesn't match, and — the secure
default — **a server with no token set refuses every push**:
```console
$ quog push example.com 8017
push refused: the remote requires a token — set QUOG_TOKEN (server: quog auth <token>)
```

---

## How Quog stores things

Everything is in one SQLite file, `.quog/quog.db`, with four tables:

| Table | Shape | Role |
|-------|-------|------|
| `object` | `(id TEXT PK, kind TEXT, data BLOB)` | The content-addressed store. `kind` is `blob`, `tree`, or `commit`; `id` is the SHA-256 of `data`. Written `INSERT OR IGNORE`, so identical content is stored once and never overwritten. |
| `ref` | `(name TEXT PK, target TEXT)` | Named pointers: `HEAD`, `branch:<name>`, `config:token`, and the sync-received `remote/<branch>` / `pushed/<branch>`. |
| `oplog` | `(seq, op, before, after, ts)` | The undo journal — one row per state change, powering `quog undo`. |
| `attic` | `(seq, tree, reason, ts)` | Recovery bin — trees parked by `discard` and `switch`, powering `quog restore`. |

The object graph mirrors git's: a **commit** references its tree and parent(s); a **tree**
maps each path to a **blob** id; a **blob** is a file's bytes. Because an id *is* the hash of
its content, the graph is self-verifying — which is exactly what `verify` leans on.

---

## Environment variables

| Variable | Effect |
|----------|--------|
| `QUOG_TOKEN` | The token a client presents when pushing to an authenticated server. |
| `QUOG_NOW` | Overrides the wall clock used for commit and op-log timestamps. Set it to a fixed value for reproducible commits (this is how the integration test pins its transcript). |

---

## Built in Ingle

Quog is a dogfood application: a real tool that exercises the language end to end. Along the
way it stands on standard-library leaves written for it — `std/sha256` (content addressing),
`std/encoding` (hex/base64), `std/diff` (the LCS line diff), `std/markdown` + `std/html`
(server-side rendering that shares Flare's content model), and `std/http_server` (a pure-Ingle
HTTP/1.1 server *and* client over a small socket FFI). The store is `std/sqlite`; RAII
`resource struct`s guarantee sockets and database handles close on every path, including an
early `?`.

The full integration test lives in [`tests/run-quog.sh`](../../tests/run-quog.sh) and its
golden transcript in [`tests/quog/session.out`](../../tests/quog/session.out); run it with
`make test-quog`.
