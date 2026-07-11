// std/html — render Markdown (and inline spans) to HTML, plus HTML escaping and a page wrapper.
// This is the server-side-rendering leaf of Ingle's web story: it reuses std/markdown's PURE
// parser (parse/inline) and swaps the emitter. Flare renders that same AST to a native window;
// here the same AST becomes HTML text the browser lays out — one content model, two hosts. Quog's
// read-only web view (history, diffs, files, commit messages) is mostly Markdown, so this covers
// most of it. Strings are concatenated directly; pages are small, so O(n) parts-joining can wait.
import "std/string" as str
import "std/markdown" as md


// _css is a small, dependency-free stylesheet: system fonts, a readable measure, and light/dark
// support so a served page looks like a real document, not raw markup. Inlined into every `page`
// so there is nothing external to fetch. (A function, not a top-level `let`, because a constant
// must be a single literal — and CSS is brace-heavy, so every literal brace is written `\{`/`\}`.)
fn _css() -> string {
    return "*\{box-sizing:border-box\}" +
    "body\{margin:0;font:16px/1.6 -apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;color:#1a1a1a;background:#fff\}" +
    "main\{max-width:46rem;margin:0 auto;padding:2.5rem 1.25rem\}" +
    "h1,h2,h3\{line-height:1.25;margin:1.6em 0 .5em\}h1\{font-size:2rem\}h2\{font-size:1.5rem\}h3\{font-size:1.2rem\}" +
    "p\{margin:0 0 1em\}a\{color:#0b66c3;text-decoration:none\}a:hover\{text-decoration:underline\}" +
    "code\{font:.9em ui-monospace,SFMono-Regular,Menlo,monospace;background:#f0f0f3;padding:.15em .35em;border-radius:4px\}" +
    "pre\{background:#f6f6f8;padding:1rem;border-radius:8px;overflow-x:auto\}pre code\{background:none;padding:0\}" +
    "blockquote\{margin:0 0 1em;padding:.2em 1em;border-left:3px solid #d0d0d6;color:#555\}" +
    "ul\{margin:0 0 1em;padding-left:1.4em\}li\{margin:.2em 0\}" +
    "table\{border-collapse:collapse;width:100%;margin:0 0 1em\}th,td\{border:1px solid #ddd;padding:.5em .7em;text-align:left\}th\{background:#f6f6f8\}" +
    "pre.diff\{line-height:1.45\}pre.diff span\{display:block;white-space:pre\}.diff .add\{background:#e6ffed;color:#22863a\}.diff .rem\{background:#ffeef0;color:#b31d28\}" +
    "@media(prefers-color-scheme:dark)\{body\{color:#e6e6e6;background:#151517\}code,pre,th\{background:#26262b\}" +
    ".diff .add\{background:#0f2f1a;color:#56d364\}.diff .rem\{background:#3a1418;color:#f26d78\}" +
    "a\{color:#5ab0ff\}blockquote\{border-left-color:#3a3a42;color:#aaa\}th,td\{border-color:#33333a\}\}"
}


// escape replaces the characters that are unsafe in HTML text/attribute context with their entities,
// so untrusted content (a commit message, a file path, a diff line) can never inject markup.
fn escape(text: string) -> string {
    var out = ""
    let cs = text.chars()
    var i = 0
    loop {
        if i == cs.len() {
            break
        }
        let c = cs[i]
        if c == "&" {
            out = out + "&amp;"
        } else if c == "<" {
            out = out + "&lt;"
        } else if c == ">" {
            out = out + "&gt;"
        } else if c == "\"" {
            out = out + "&quot;"
        } else if c == "'" {
            out = out + "&#39;"
        } else {
            out = out + c
        }
        i = i + 1
    }
    return out
}


// render_spans turns inline spans (from md.inline) into HTML — emphasis, code, and links, with all
// text escaped. A link's URL is escaped into the href so it cannot break out of the attribute.
fn render_spans(spans: [md.Span]) -> string {
    var out = ""
    var i = 0
    loop {
        if i == spans.len() {
            break
        }
        match spans[i] {
            case Text(s) {
                out = out + escape(s)
            }
            case Strong(s) {
                out = out + "<strong>" + escape(s) + "</strong>"
            }
            case Em(s) {
                out = out + "<em>" + escape(s) + "</em>"
            }
            case Mono(s) {
                out = out + "<code>" + escape(s) + "</code>"
            }
            case Link(t, u) {
                out = out + "<a href=\"" + escape(u) + "\">" + escape(t) + "</a>"
            }
        }
        i = i + 1
    }
    return out
}


// _inline is the shorthand for "parse this prose into spans and render them" — the inline emphasis
// layer every block-level element (paragraph, heading, quote, list item, table cell) runs its text through.
fn _inline(text: string) -> string {
    return render_spans(md.inline(text))
}


// _table renders a Markdown pipe table (header row + data rows, '\n'-joined; the '|---|' separator
// already dropped by the parser) into a real <table>, the first row as <th> and the rest as <td>.
fn _table(raw: string) -> string {
    let rows = raw.split("\n")
    var out = "<table>"
    var r = 0
    loop {
        if r == rows.len() {
            break
        }
        let cells = rows[r].split("|")
        var tag = "td"
        if r == 0 {
            tag = "th"
        }
        var last = cells.len()                       // cells[0] is "" (leading '|'); a trailing '|' adds a "" too
        if last > 0 && str.trim(cells[last - 1]) == "" {
            last = last - 1
        }
        out = out + "<tr>"
        var ci = 1
        loop {
            if ci >= last {
                break
            }
            out = out + "<" + tag + ">" + _inline(str.trim(cells[ci])) + "</" + tag + ">"
            ci = ci + 1
        }
        out = out + "</tr>"
        r = r + 1
    }
    return out + "</table>"
}


// render_block renders one Markdown block to its HTML element. Code is escaped verbatim (no inline
// parsing) inside <pre><code>, tagged with a language class for downstream syntax highlighting.
fn render_block(b: md.Block) -> string {
    match b {
        case Para(t) {
            return "<p>" + _inline(t) + "</p>"
        }
        case Heading(n, t) {
            return "<h{n}>" + _inline(t) + "</h{n}>"
        }
        case Quote(t) {
            return "<blockquote>" + _inline(t) + "</blockquote>"
        }
        case Code(lang, src) {
            if lang.len() > 0 {
                return "<pre><code class=\"language-" + escape(lang) + "\">" + escape(src) + "</code></pre>"
            }
            return "<pre><code>" + escape(src) + "</code></pre>"
        }
        case Bullet(t) {
            return "<li>" + _inline(t) + "</li>"
        }
        case Table(raw) {
            return _table(raw)
        }
    }
}


// _is_bullet reports whether a block is a list item — used to wrap runs of consecutive bullets in a
// single <ul> (the parser emits one Bullet block per item, not a grouped list).
fn _is_bullet(b: md.Block) -> bool {
    match b {
        case Bullet(t) {
            return true
        }
        case Para(t) {
            return false
        }
        case Heading(n, t) {
            return false
        }
        case Quote(t) {
            return false
        }
        case Code(lang, src) {
            return false
        }
        case Table(raw) {
            return false
        }
    }
}


// render_markdown parses Markdown text and renders it to an HTML fragment, grouping adjacent list
// items into <ul> blocks. The result is body content — wrap it with `page` for a full document.
fn render_markdown(text: string) -> string {
    let blocks = md.parse(text)
    var out = ""
    var in_list = false
    var i = 0
    loop {
        if i == blocks.len() {
            break
        }
        let bullet = _is_bullet(blocks[i])
        if bullet && !in_list {
            out = out + "<ul>"
            in_list = true
        }
        if !bullet && in_list {
            out = out + "</ul>"
            in_list = false
        }
        out = out + render_block(blocks[i])
        i = i + 1
    }
    if in_list {
        out = out + "</ul>"
    }
    return out
}


// page wraps a body HTML fragment in a complete, self-contained HTML5 document with the inlined
// stylesheet — the unit a web server hands back for a request. The title is escaped.
fn page(title: string, body: string) -> string {
    return "<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n" +
        "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n" +
        "<title>" + escape(title) + "</title>\n<style>" + _css() + "</style>\n</head>\n" +
        "<body>\n<main>\n" + body + "\n</main>\n</body>\n</html>\n"
}
