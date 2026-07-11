# Quog

*A small, safe version control system — built in Ingle.*

**Status:** building. The readiness audit below was independently verified against the tree (a
5-agent read-only pass plus hand-checks) and holds up; the corrections it surfaced are folded in.
The web architecture that makes Quog also a *dogfood of Ingle as a web language* has its own design
of record — [docs/design/ingle-web.md](../../docs/design/ingle-web.md). **First bricks are laid:**
`std/sha256`, `std/encoding` (hex+base64), and `std/html` (Markdown → HTML) all ship, tested.

## Why

Git's *storage* model is fine — content-addressed blobs, trees, and commits in a DAG is the right
core, and we keep it. The danger lives in the *command surface* bolted on top: `reset --hard`,
`push --force`, `rebase`, `clean -fd`, a `checkout` that silently discards uncommitted work, plus a
staging area and detached-HEAD state that are easy to hurt yourself with. Quog keeps the good core
and drops the hazardous porcelain.

Three systems we borrow from, openly:

- **Jujutsu (jj)** — an operation log so `undo` always works; no staging area; the working copy is
  itself a commit.
- **Fossil** — the whole repo is a single SQLite file; syncs by default, so you don't lose work by
  forgetting to push.
- **Pijul / Darcs** — patches that commute, so merges hurt less.

## Safe-by-design (the invariants)

These must hold no matter what command runs:

1. **Append-only.** Objects are content-addressed and never overwritten or deleted. Every past state
   stays reachable.
2. **Everything is undoable.** Each mutating command appends to an operation log; `quog undo` reverts
   the last op. No command can lose committed work.
3. **No staging area.** The working tree is the truth — no `add` step, no index to fall out of sync.
4. **Switching never loses work.** `quog switch` snapshots the current tree first, so uncommitted
   changes are always recoverable.
5. **No `--force`.** Sync is additive; a conflicting push creates a new head rather than clobbering
   existing history.
6. **"Discard" is recoverable.** Throwing away changes moves them to an attic, not to `/dev/null`.

**Prove them, don't just assert them.** These six are exactly the kind of property Ingle's flagship
verification tools exist for. Each mutating command carries executable `requires`/`ensures`
contracts (append-only: the object table only grows; undo: the pre-state is reachable after
`undo`), and the tape + `inglec --check` turn the invariants into machine-checked guarantees. A VCS
whose safety is proven by the language's own contract machinery is the strongest possible dogfood of
Ingle's north star — so it is a first-class goal here, not an afterthought.

## Command surface (~a dozen verbs)

| verb | does |
|---|---|
| `init` | create a repo (one SQLite file) |
| `save` | snapshot the working tree as a commit (no staging) |
| `status` | what changed since the last save |
| `log` | history of the current branch |
| `show` | a commit's metadata and changes |
| `diff` | changes between working tree / commits |
| `switch` | move to a branch or commit (auto-snapshots first) |
| `branch` | make / list branches |
| `merge` | join two histories (additive; conflict → new head) |
| `undo` | revert the last operation (from the op-log) |
| `restore` | bring something back from the attic |
| `sync` | exchange objects with a remote (additive) |
| `serve` | run the web view + sync endpoint |

## Storage model

One SQLite file per repo (`.quog/quog.db`), Fossil-style — copy the file to back it up, hard to
corrupt, easy to reason about. Content IDs are SHA-256 hashes rendered as hex (both shipped:
`std/sha256.digest` + `std/encoding.to_hex`). Rough shape:

- `object(id TEXT PRIMARY KEY, kind TEXT, data BLOB)` — blobs, trees, commits; `id` = SHA-256 of `data`.
- `ref(name TEXT PRIMARY KEY, target TEXT)` — branch / head names → commit id.
- `oplog(seq INTEGER PRIMARY KEY, op TEXT, before TEXT, after TEXT, ts INTEGER)` — the undo spine.
- `attic(id TEXT, reason TEXT, ts INTEGER)` — recoverable discards.

**Store caveat (found in audit):** the `data BLOB` column has no read/write path in `std/sqlite`
today — it exposes `bind_int/f64/text/null` and `column_int/f64/text` but **no `bind_blob`/
`column_blob`** (`std/sqlite.ig:45-56`). Storing raw bytes as TEXT is unsafe (`sqlite3_column_text`
truncates at NUL). So Phase 1 needs **OFI-209** (add the blob FFI — small, mirrors `bind_text`), or
stores objects base64-in-TEXT (`std/encoding.to_base64`, +33% size). Recommend adding blob support.

## Readiness audit — what Ingle already gives us

Verified against the current tree (independent 5-agent read-only pass + hand-checks). The audit was
accurate; two entries are refined below.

| need | status | in Ingle |
|---|---|---|
| single-file store | have* | `std/sqlite` — `open()->Result<Db,string>`, `exec`, `prepare`/`step`, `bind_*`, `column_*` (*no BLOB accessor — OFI-209) |
| content addressing | **have (new)** | `std/sha256` — `digest([u8])`/`digest_str(string)`; `std/encoding` — `to_hex`/`to_base64` |
| metadata / wire format | have | `std/json` — `parse`/`stringify`, builders, typed accessors |
| text handling | have | `std/string`, UTF-8; `s.bytes()->[u8]`, `from_bytes([u8])->string`, `s.len()` (bytes) |
| collections | have | `std/list`, `std/map`, `std/set`, `std/slotmap` |
| concurrency (for the server) | have | structured: `nursery`/`spawn`/`channel`, no function colouring (missing only `select`/timeout, OFI-197) |
| HTTP client + streaming | have | `std/http` (`get`/`post`/`open`/`next`), `std/sse` — **client only; no server yet (OFI-211)** |
| shell-out (editor, tools) | have | `std/proc` — `run`/`run_argv` |
| errors | have | `Result`/`Option` + `?`; contracts (`requires`/`ensures`); newtypes + refinements |
| CLI | have | `args()`, `env()` builtins |
| read / write / list files | have | `read_file`/`write_file`/`list_dir` builtins — **binary-safe already** (`rb`/`wb`, length-prefixed) |
| render web pages | **have (new)** | `std/html` — Markdown/AST → HTML; the SSR leaf (see design doc) |

**Refinement — binary I/O is narrower than first thought.** `read_file`/`write_file` open `"rb"`/
`"wb"` and move length-prefixed byte buffers (`src/runtime.c:2455-2491`), so arbitrary bytes already
round-trip losslessly today; `from_bytes`/`.bytes()`/`byte_slice` give the `[u8]`↔string bridge. The
only gap is an ergonomic *typed* `[u8]` file API (OFI-210) — not a blocker for Phase 1.

## Quog as the web dogfood

Quog is also how we prove Ingle serves web pages. The full architecture is in
[docs/design/ingle-web.md](../../docs/design/ingle-web.md); the short version: **one component model
(Flare), three render targets — native (shipped), server HTML (in progress), browser/WASM
(endgame).** `serve` renders history/diffs/files as HTML via `std/html` (Tier A, shipped) over a
pure-Ingle HTTP server (W2); later the whole Flare component library gains an HTML backend (Tier B),
so a Quog UI written once runs as both a desktop app and a website.

## Gaps — status

Shipped this campaign:

- **SHA-256** (`std/sha256`) — content addressing. Pure Ingle, FIPS-vector-tested. **OFI-207 CLOSED.**
- **hex + base64** (`std/encoding`) — render/parse content ids and byte payloads. **OFI-191 CLOSED.**
- **Markdown → HTML** (`std/html`) — the SSR content leaf. **OFI-208 CLOSED.**

Open, in dependency order:

- **`bind_blob`/`column_blob` in `std/sqlite`** — the store's `data BLOB` column. **OFI-209.**
- **Typed `[u8]` file I/O** (`read_bytes`/`write_bytes`) — ergonomic, not a blocker. **OFI-210.**
- **Socket primitive + HTTP/1.1 server** in `std` — the `serve`/`sync` engine. **OFI-211.**
- **Wall-clock time** — commit timestamps; joins the record/replay set. **OFI-188.**
- **Flare HTML render backend** (the `Backend` seam) — Tier B isomorphism. **OFI-212.**
- **Ingle → WASM client host** — live in-browser components. **OFI-213.**
- **(deferrable)** deflate/zlib for blob compression; a Myers diff in `std`.

Constraints to plan around:

- **OFI-143** — `std/sqlite` runs on the bytecode VM only (`make db`), not the native backend. Quog
  runs on the VM path for now; **Quog is the concrete "native-db need" that forces OFI-143 closed**
  (its own OFI note defers it "until a native-db need"). Frame as the payoff, not just the constraint.
- **OFI-198** — `==` on a struct is a compile error today; a VCS comparing commit/blob/ref structs
  will hit it. Use explicit field compares until it lands.

## Open decisions — resolved

- **Hash: SHA-256** (not BLAKE3). Its add/rotate/xor core maps onto the shipped `wrapping_*`
  builtins (the machinery FNV-1a already uses in-tree), needs no runtime change, stays pure Ingle;
  BLAKE3's only edge is SIMD, which the VM can't exploit. *Shipped.*
- **Repo shape: one SQLite file** (not loose objects) — plays to Ingle's SQLite strength and the
  `resource struct` auto-close safety; sidesteps loose-object path helpers. Prerequisite: OFI-209.
- **Sync: Fossil-style additive** object/ref exchange (not git packfiles) — it *is* invariant #5
  ("no `--force`") expressed as the wire protocol; packfiles front-load the deferred deflate + Myers
  work for efficiency a dogfood VCS doesn't need yet.

## Phases

**Phase F — foundations.** `std/sha256` + `std/encoding` **(done)**; then `bind_blob`/`column_blob`
(OFI-209) and wall-clock time (OFI-188). Each is independently useful to the whole language.

**Phase 1 — core store + safe basics** *(the smallest honest slice)*. `init`, `save`, `log`, `show`,
`undo` over the SQLite store, with the safety invariants written as executable contracts. Goal:
prove append-only and universal undo actually hold, machine-checked, end to end.

**Phase 2 — working with change** *(status, diff, branch, switch done)*. `status`, `diff` (line-level,
via a new `std/diff` LCS engine — CLI **and** a GitHub-style colored web diff), plus `branch`
(create/list) and `switch` — which checks out the target snapshot (writing its files, pruning the
rest) and, per invariant #4, **auto-snapshots any uncommitted work first so nothing is lost**;
`undo` of a switch restores the prior branch. Still to come: `restore` from the attic, `merge`
(additive, new-head-on-conflict).

**Phase W1 — the web content leaf** *(done)*. `std/html` renders Markdown/AST to HTML; Quog's
history/diff/file views render as pages.

**Phase W2 — the server** *(server done)*. Socket FFI + HTTP/1.1 + router in pure Ingle (OFI-211);
`quog serve` renders the read-only web view (history + per-commit pages) via `std/html` — dogfooded
in a browser. Sequential for now (per-connection fibers = follow-on). Still to come: `sync` as
additive object/ref exchange over HTTP (Fossil-style). This is the phase that exercises Ingle as a
server-side web language — and it does.

**Phase W3 — full component isomorphism.** The Flare HTML backend (OFI-212): every Flare component
renders native *or* web from one source — a Quog UI written once, shipped as desktop and website.

**Phase W4 — the browser (endgame).** Ingle → WASM (OFI-213): the same components hydrate the SSR
page and run events client-side. Additive, not a rewrite.

**Phase 4 — polish.** Compression, safe GC/repack, sync auth, a TLS story.

## Testing & dogfood

Per CLAUDE.md: feature tests land in `tests/` (already: `tests/run/{sha256,encoding,html}.ig`); the
Quog app itself lives in `public/quog`. Reach for the tape tool and a dogfood repo to reproduce any
bug before fixing it. A milestone worth aiming at: version Quog's own source with Quog, and serve its
history as a Quog-rendered website.

---

*Working name: **Quog** (confirmed clear on GitHub / web search, July 2026). Trivial to rename if a
better one lands.*
