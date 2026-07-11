# Ingle as a web language — design of record

*How Ingle serves web pages: one component model, three render targets. Started 2026-07-11,
driven by the Quog dogfood ([public/quog/PLAN.md](../../public/quog/PLAN.md)).*

## Thesis

There is no separate "IngleScript" dialect. **"IngleScript" is Ingle itself, plus Flare, rendered
to the web.** A component is an ordinary Ingle function that calls semantic methods on a builder
(`f.heading`, `f.button`, `f.markdown`); the same component renders to three *hosts*:

1. **Native** — raylib, the desktop window. *Shipped* (`std/flare.ig`).
2. **Server HTML (SSR)** — the component tree emitted as HTML+CSS a browser lays out. *In progress.*
3. **Browser (WASM)** — the same components compiled to WASM, hydrating the SSR page and running
   events client-side. *The endgame; additive, not a rewrite.*

One vocabulary an LLM learns once targets desktop, server, and browser. This is the LLM-first
coherence play and the moat — and it violates none of the manifesto's "one obvious way / minimize
surface" principles, which a bespoke web dialect would.

## Why this is mostly a *retarget*, not new machinery

Flare is immediate-mode in its API but **retained-per-frame in its guts** (`std/flare.ig:370`). A
component never touches a pixel — it appends to two per-frame, walkable, backend-neutral structures:

- a **layout-intent tree** (`lo: lay.Layout`, `std/flare.ig:378`) — pure flexbox (`COL`/`ROW`,
  `START`/`CENTER`/`STRETCH`, `gap`, `pad`, `grow`); `std/layout.ig` has *no imports*, runs headless,
  and maps 1:1 onto CSS flexbox;
- a **semantic paint queue** (`rnode/rkind/rtext/rid`, `std/flare.ig:379`) of ~55 kind codes
  (`_BUTTON`, `_PANEL`, `_H1`, `_LINK`, `_MENUITEM`, …).

Raylib is touched in exactly one place — `finish()`/`_paint()`. **A web backend is a second walk of
the same queue**, mapping `kind → tag/class` (`_BUTTON`→`<button>`, `_H1`→`<h1>`) and reading the
layout tree's flex intent as CSS. It is not a change to a single component.

### The one real coupling, and how we resolve it

Text measurement leaks into the *build* pass — buttons and word-wrap call raylib `measure_text`
before paint (`std/flare.ig:2799`, `wrap` at `:208`). A naive "swap the draw calls" backend would
miss it. **Resolution: the HTML backend never measures text — it defers to the browser.** In HTML
mode `measure_text` is a stub and text-bearing widgets emit intrinsic-sized elements the browser
wraps. This is exactly what you want for responsive, reflowing, accessible pages; the coupling only
bites if you chase pixel-identical-to-native, which documents do not need. The ~20% of the API that
leaks device pixels (the `*_width` text APIs; the absolute overlays `modal`/`popover`/`dock`) is
small and nameable — overlays become CSS positioning, `*_width` is ignored in HTML mode.

## The two granularities of "reuse Flare for the web"

**Tier A — content rendering (`std/html`, shipped 2026-07-11).** `std/markdown` is a *pure parser*
that emits an AST (`enum Block`/`enum Span`) with no renderer of its own — Flare's `f.markdown`
supplies one emitter, `std/html` supplies another. `std/html.render_markdown` walks the same AST to
HTML; `std/highlight`'s `Kind` spans map to CSS classes for code. Quog's read-only web view (history,
diffs, files, commit messages) is largely Markdown, so this covers most of it with almost no refactor.

**Tier B — full component retarget (OFI-212).** Introduce a `Backend`/`Surface` value on `struct
Flare`; route the ~17 gfx primitives + a `measure_text` oracle through it (also `ui.card`/`ui.shadow`
and `ui._tf_draw`/`_paint_code`); add an HTML `finish()` walking the display list. Then *every* Flare
component renders native or web from one source — write Quog's UI once, ship desktop and website.

## The server — built in, not imported (OFI-211)

No socket primitive exists today; `std/http` is a libcurl **client**. The path is:

- Add ~a dozen socket wrappers to the runtime (`socket`/`bind`/`listen`/`accept`/`recv`/`send`) — the
  `src/cextern.c` registry pattern (`g_sigs`/`g_fns` parallel arrays) already handles this; the
  fd-only calls can even use the **direct-extern FFI** (OFI-167) with zero registry edits, and
  `recv`/`send` use the existing `'b'` buffer marshalling. Behind an opt-in build flag; the default
  build stays dependency-free.
- Write HTTP/1.1 parsing + routing in **pure Ingle** (`std/http_server.ig`) over the existing
  `nursery`/`spawn` model — the accept loop `loop { let fd = accept(l); spawn handle(fd) }` is the
  spawn-at-spawn-time nursery pattern the runtime already ships. Closing **OFI-197** (`select`/timeout)
  adds graceful shutdown/idle-timeouts; it is a nice-to-have, not a blocker.

TLS is the one genuine import candidate, and it is deferred (Phase 4) — terminate at a reverse proxy
first, or link a TLS lib behind a flag later. Rolling our own crypto is the one place "build it in"
is wrong.

## The client — Ingle → WASM (OFI-213, endgame)

Two backends exist: the canonical AST→bytecode VM, and a mature, self-hosting **AST→C** backend
(`src/cgen_c.c`) whose runtime shim is already swappable per target — proven by the freestanding/
kernel work retargeting the *same* AST→C machinery to a no-OS/no-libc platform. WASM is the *same
shape of retarget*: emit C, add a WASI/JS platform shim for the runtime, compile with
emscripten/clang-wasm, glue exports to JS. It reuses the backend investment almost entirely; it is
"add a platform target", never a new compiler. This is where the same Flare components hydrate the
SSR page and run events in the browser — the full "IngleScript".

## What we build vs import

| piece | decision | why |
|---|---|---|
| SHA-256, hex, base64 | **build** (`std/sha256`, `std/encoding`, shipped) | ~small pure Ingle, reuses `wrapping_*`; zero-dep, on-brand |
| Markdown → HTML | **build** (`std/html`, shipped) | reuses the pure parser; the SSR leaf |
| sockets | **build** (thin FFI) | libc/POSIX syscalls, not a library — no dep |
| HTTP/1.1 + router | **build** (pure Ingle) | the dogfood; rides `nursery`/`spawn` |
| Flare → HTML backend | **build** (the `Backend` seam) | the isomorphism moat |
| TLS | **import**, deferred | never roll your own crypto |

## Sequencing

| step | lands | status |
|---|---|---|
| **F** | hex + SHA-256 (content ids); `bind_blob`/`column_blob`; wall-clock time | encoding+sha256 **done**; blob (OFI-209) + time (OFI-188) next |
| **W1** | `std/html` — Markdown/AST → HTML+CSS; Quog's read-only view renders | **done** |
| **W2** | socket FFI + HTTP/1.1 + router (OFI-211); Quog `serve` + additive `sync` | next |
| **W3** | full Flare→HTML backend (OFI-212) — every component renders native or web | after W2 |
| **W4** | Ingle→WASM client host (OFI-213) — live in-browser components | endgame, additive |

None of these is deferred *because of* anything — it is a true dependency order. W1+W2 gives a served
Quog website; W3 is the write-once-run-desktop-and-web moat; W4 is the browser runtime.
