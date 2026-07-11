// quog.ig — Quog: a small, safe version control system, built in Ingle (dogfood). This is the
// Phase-1 core store: `init` / `save` / `log` over ONE SQLite file (.quog/quog.db), every object
// content-addressed by SHA-256, the object table append-only (INSERT OR IGNORE — content is never
// overwritten), and every mutation recorded in an operation log (the spine `undo` will unwind).
//
// Run it with the db build (std/sqlite is VM-only, OFI-143):
//     build/inglec-db --emit=run public/quog/quog.ig <verb> [args]
// Verbs:
//     init            create a repo in the current directory (.quog/quog.db)
//     save <message>  snapshot the working tree as a commit
//     log             show the history of the current branch
//
// Representation note: a snapshot tree is carried as text ("path\tid\n" per file) and a commit as
// text, rather than as arrays of a value-struct. Building the store originally surfaced a compiler
// memory bug in value-struct-in-array copies (OFI-215, since FIXED); the string-serialised tree is
// kept anyway because it IS the object's on-disk bytes — hashing and storage want the text directly.
import "std/sqlite" as sql
import "std/sha256" as sha
import "std/encoding" as enc
import "std/string" as str
import "std/time" as time
import "std/fs" as fs
import "std/html" as html
import "std/http_server" as hs


let DB_PATH = ".quog/quog.db"
let TIP_REF = "branch:main"


// object_id is the content address of `data`: its SHA-256 as lowercase hex. A SHA-256 hex id is
// always exactly 64 characters — a cheap, real postcondition that catches any hashing/encoding slip.
fn object_id(data: [u8]) -> string
    ensures result.len() == 64
{
    return enc.to_hex(sha.digest(data))
}


// put_object stores `data` under its content id and returns that id. Append-only by construction:
// INSERT OR IGNORE never overwrites an existing object, so identical content stored twice is one row
// and no past object can ever change. Storing is therefore idempotent and safe to repeat.
fn put_object(db: sql.Db, kind: string, data: [u8]) -> Result<string, string> {
    let id = object_id(data)
    let st = sql.prepare(db, "INSERT OR IGNORE INTO object(id, kind, data) VALUES(?, ?, ?)")?
    let _ = sql.bind_text(st, 1, id)
    let _ = sql.bind_text(st, 2, kind)
    let _ = sql.bind_blob(st, 3, data)
    let _ = sql.step(st)?
    return Ok(id)
}


// get_object reads an object's raw bytes back by id, or errs if it is absent.
fn get_object(db: sql.Db, id: string) -> Result<[u8], string> {
    let st = sql.prepare(db, "SELECT data FROM object WHERE id = ?")?
    let _ = sql.bind_text(st, 1, id)
    let found = sql.step(st)?
    if !found {
        return Err("object not found: " + id)
    }
    return Ok(sql.column_blob(st, 0))
}


// get_ref returns a ref's target, or "" if the ref does not exist (an absent branch tip = no commits).
fn get_ref(db: sql.Db, name: string) -> Result<string, string> {
    let st = sql.prepare(db, "SELECT target FROM ref WHERE name = ?")?
    let _ = sql.bind_text(st, 1, name)
    let found = sql.step(st)?
    if !found {
        return Ok("")
    }
    return Ok(sql.column_text(st, 0))
}


// set_ref points a ref at `target` (a branch tip is a mutable pointer; the objects it names are not).
fn set_ref(db: sql.Db, name: string, target: string) -> Result<int, string> {
    let st = sql.prepare(db, "INSERT OR REPLACE INTO ref(name, target) VALUES(?, ?)")?
    let _ = sql.bind_text(st, 1, name)
    let _ = sql.bind_text(st, 2, target)
    let _ = sql.step(st)?
    return Ok(0)
}


// log_op appends to the operation log — the append-only spine that makes every mutation undoable.
// `before`/`after` capture the ref move so a future `undo` can restore the prior tip exactly.
fn log_op(db: sql.Db, op: string, before: string, after: string) -> Result<int, string> {
    let st = sql.prepare(db, "INSERT INTO oplog(op, before, after, ts) VALUES(?, ?, ?, ?)")?
    let _ = sql.bind_text(st, 1, op)
    let _ = sql.bind_text(st, 2, before)
    let _ = sql.bind_text(st, 3, after)
    let _ = sql.bind_int(st, 4, time.now())
    let _ = sql.step(st)?
    return Ok(0)
}


// walk recurses the working tree rooted at `fsdir` (a filesystem path), storing each file's bytes as
// a blob and returning the snapshot's tree text: one "logicalpath\tblobid" line per file, carrying
// `prefix`. The `.quog` repo directory is skipped so the store never versions itself. list_dir is
// sorted, so the traversal — and therefore the tree id — is deterministic for a given working tree.
fn walk(db: sql.Db, fsdir: string, prefix: string) -> Result<string, string> {
    var out = ""
    for name in list_dir(fsdir).split("\n") {
        if name != "" {
            if str.ends_with(name, "/") {
                let base = str.cp_slice(name, 0, str.cp_count(name) - 1)   // drop the trailing '/'
                if base != ".quog" {
                    out = out + walk(db, fsdir + "/" + base, prefix + base + "/")?
                }
            } else {
                let bytes = read_file(fsdir + "/" + name).bytes()
                let id = put_object(db, "blob", bytes)?
                out = out + prefix + name + "\t" + id + "\n"
            }
        }
    }
    return Ok(out)
}


// _count_lines counts the newline-terminated entries in a tree text (the number of files snapshotted).
fn _count_lines(text: string) -> int {
    var n = 0
    for c in text.bytes() {
        if c == 10u8 {
            n = n + 1
        }
    }
    return n
}


// commit_serialize renders a commit object: three header lines, a blank line, then the message body
// (which may contain anything — it is the rest of the object).
fn commit_serialize(tree: string, parent: string, ts: int, message: string) -> string {
    return "tree {tree}\nparent {parent}\ntime {ts}\n\n{message}"
}


// _after returns `line` with `prefix` removed from its front (assumes it is present).
fn _after(line: string, prefix: string) -> string {
    return str.cp_slice(line, str.cp_count(prefix), str.cp_count(line))
}


// _atoi parses the leading decimal digits of `s` into an int (non-digits stop it).
fn _atoi(s: string) -> int {
    var n = 0
    for c in s.bytes() {
        if c >= 48u8 && c <= 57u8 {
            n = n * 10 + (i64(c) - 48)
        }
    }
    return n
}


// commit_header returns the value of the header line beginning with `prefix` (e.g. "parent "), or "".
fn commit_header(text: string, prefix: string) -> string {
    for line in text.split("\n") {
        if str.starts_with(line, prefix) {
            return _after(line, prefix)
        }
    }
    return ""
}


// commit_message returns a commit's message body — everything after the blank line at index 3.
fn commit_message(text: string) -> string {
    let lines = text.split("\n")
    var msg = ""
    var i = 4
    loop {
        if i == lines.len() {
            break
        }
        if i > 4 {
            msg = msg + "\n"
        }
        msg = msg + lines[i]
        i = i + 1
    }
    return msg
}


// _short is the abbreviated content id shown in the log (the first 10 hex characters).
fn _short(id: string) -> string {
    return str.cp_slice(id, 0, 10)
}


// cmd_init creates a fresh repo in the current directory: the .quog directory, the schema, and the
// branch/HEAD refs pointing at an empty history.
fn cmd_init() -> Result<int, string> {
    let _ = fs.mkdir(".quog")                        // -1 if it already exists — harmless
    let db = sql.open(DB_PATH)?
    let _ = sql.exec(db, "CREATE TABLE IF NOT EXISTS object(id TEXT PRIMARY KEY, kind TEXT, data BLOB); CREATE TABLE IF NOT EXISTS ref(name TEXT PRIMARY KEY, target TEXT); CREATE TABLE IF NOT EXISTS oplog(seq INTEGER PRIMARY KEY AUTOINCREMENT, op TEXT, before TEXT, after TEXT, ts INTEGER)")?
    let _ = set_ref(db, "HEAD", "main")?
    let _ = set_ref(db, TIP_REF, "")?
    println("initialised empty Quog repo in .quog/")
    return Ok(0)
}


// cmd_save snapshots the working tree as a commit: store every file's blob, build the tree object,
// build the commit object (parent = the old tip), advance the branch, and record the op. Append-only
// holds throughout — no object is overwritten, and the prior tip is preserved in the op-log.
fn cmd_save(message: string) -> Result<int, string> {
    let db = sql.open(DB_PATH)?
    let parent = get_ref(db, TIP_REF)?
    let tree_text = walk(db, ".", "")?
    let tree_id = put_object(db, "tree", tree_text.bytes())?
    let commit = commit_serialize(tree_id, parent, time.now(), message)
    let commit_id = put_object(db, "commit", commit.bytes())?
    let _ = set_ref(db, TIP_REF, commit_id)?
    let _ = log_op(db, "save", parent, commit_id)?
    println("saved {_short(commit_id)} ({_count_lines(tree_text)} files) — {message}")
    return Ok(0)
}


// cmd_log walks the current branch from its tip back through parent links, newest first.
fn cmd_log() -> Result<int, string> {
    let db = sql.open(DB_PATH)?
    var id = get_ref(db, TIP_REF)?
    if id == "" {
        println("no saves yet")
        return Ok(0)
    }
    loop {
        if id == "" {
            break
        }
        let text = from_bytes(get_object(db, id)?)
        let ts = _atoi(commit_header(text, "time "))
        println("{_short(id)}  t={ts}  {commit_message(text)}")
        id = commit_header(text, "parent ")
    }
    return Ok(0)
}


// cmd_show prints a commit's metadata and the files in its snapshot. With no id it shows the tip.
fn cmd_show(argv: [string]) -> Result<int, string> {
    let db = sql.open(DB_PATH)?
    var id = ""
    if argv.len() >= 2 {
        id = argv[1]
    } else {
        id = get_ref(db, TIP_REF)?
    }
    if id == "" {
        println("no saves yet")
        return Ok(0)
    }
    let text = from_bytes(get_object(db, id)?)
    let tree_id = commit_header(text, "tree ")
    let parent = commit_header(text, "parent ")
    println("commit   {id}")
    if parent != "" {
        println("parent   {parent}")
    }
    println("time     {_atoi(commit_header(text, "time "))}")
    println("message  {commit_message(text)}")
    println("files:")
    for line in from_bytes(get_object(db, tree_id)?).split("\n") {
        if line != "" {
            let parts = line.split("\t")
            if parts.len() == 2 {
                println("  {_short(parts[1])}  {parts[0]}")
            }
        }
    }
    return Ok(0)
}


// cmd_undo reverts the last operation from the op-log (invariant #2: everything is undoable). It moves
// the branch tip back to the op's `before` state and records the undo itself — so nothing is lost (the
// undone commit is still stored, append-only) and the undo is itself in the log.
fn cmd_undo() -> Result<int, string> {
    let db = sql.open(DB_PATH)?
    let st = sql.prepare(db, "SELECT op, before, after FROM oplog ORDER BY seq DESC LIMIT 1")?
    let found = sql.step(st)?
    if !found {
        println("nothing to undo")
        return Ok(0)
    }
    let op = sql.column_text(st, 0)
    let before = sql.column_text(st, 1)
    let after = sql.column_text(st, 2)
    let _ = set_ref(db, TIP_REF, before)?
    let _ = log_op(db, "undo", after, before)?
    if before == "" {
        println("undid {op} — back to empty history ({_short(after)} still stored, nothing lost)")
    } else {
        println("undid {op} — tip {_short(after)} → {_short(before)} (nothing lost)")
    }
    return Ok(0)
}


// serve_log renders the branch history as an HTML page — each commit a link to its detail page.
fn serve_log(db: sql.Db, conn: hs.Conn) -> Result<int, string> {
    var md = "# Quog — history\n\n"
    var id = get_ref(db, TIP_REF)?
    if id == "" {
        md = md + "_No saves yet._\n"
    } else {
        loop {
            if id == "" {
                break
            }
            let text = from_bytes(get_object(db, id)?)
            md = md + "- [`" + _short(id) + "`](/commit/" + id + ") — " + commit_message(text) + "\n"
            id = commit_header(text, "parent ")
        }
    }
    let _ = hs.ok_html(conn, html.page("Quog — history", html.render_markdown(md)))
    return Ok(0)
}


// serve_commit renders one commit: its metadata, a link to its parent, and the files in its snapshot.
fn serve_commit(db: sql.Db, conn: hs.Conn, id: string) -> Result<int, string> {
    match get_object(db, id) {
        case Ok(bytes) {
            let text = from_bytes(bytes)
            let ts = _atoi(commit_header(text, "time "))
            var md = "# Commit `" + _short(id) + "`\n\n"
            md = md + "**message:** " + commit_message(text) + "\n\n"
            md = md + "**time:** {ts}\n\n"
            let parent = commit_header(text, "parent ")
            if parent != "" {
                md = md + "**parent:** [`" + _short(parent) + "`](/commit/" + parent + ")\n\n"
            }
            md = md + "## Files\n\n"
            for line in from_bytes(get_object(db, commit_header(text, "tree "))?).split("\n") {
                if line != "" {
                    let parts = line.split("\t")
                    if parts.len() == 2 {
                        md = md + "- `" + parts[0] + "` — `" + _short(parts[1]) + "`\n"
                    }
                }
            }
            md = md + "\n[← back to history](/)\n"
            let _ = hs.ok_html(conn, html.page("Commit " + _short(id), html.render_markdown(md)))
            return Ok(0)
        }
        case Err(e) {
            let _ = hs.not_found(conn, html.page("Not found", html.render_markdown("# 404\n\nNo such commit.\n\n[← history](/)")))
            return Ok(0)
        }
    }
}


// route dispatches a request path to the page that serves it.
fn route(db: sql.Db, conn: hs.Conn, path: string) -> Result<int, string> {
    if path == "/" {
        return serve_log(db, conn)
    }
    if str.starts_with(path, "/commit/") {
        return serve_commit(db, conn, str.substring(path, 8, str.cp_count(path)))
    }
    let _ = hs.not_found(conn, html.page("Not found", html.render_markdown("# 404\n\nNo such path.\n\n[← history](/)")))
    return Ok(0)
}


// cmd_serve runs the read-only web view: a Fossil-style local server over the repo's history. It
// serves one connection at a time (per-connection fibers are a follow-on); a bad request or transient
// accept error is swallowed so the server stays up.
fn cmd_serve(argv: [string]) -> Result<int, string> {
    let db = sql.open(DB_PATH)?
    var port = 8017
    if argv.len() >= 2 {
        port = _atoi(argv[1])
    }
    let server = hs.listen(port)?
    println("quog serving on http://localhost:{port}  —  Ctrl-C to stop")
    loop {
        match hs.accept(server) {
            case Ok(conn) {
                match hs.read_request(conn) {
                    case Ok(req) {
                        let _ = route(db, conn, req.path)
                    }
                    case Err(e) {}
                }
            }
            case Err(e) {}
        }
    }
}


// dispatch runs the requested verb, returning a Result so any store error routes to one place.
fn dispatch(argv: [string]) -> Result<int, string> {
    if argv.len() == 0 {
        println("usage: quog <init|save|log|show|undo|serve> [args]")
        return Ok(0)
    }
    let verb = argv[0]
    if verb == "init" {
        return cmd_init()
    }
    if verb == "serve" {
        return cmd_serve(argv)
    }
    if verb == "save" {
        if argv.len() < 2 {
            return Err("save needs a message: quog save <message>")
        }
        return cmd_save(argv[1])
    }
    if verb == "log" {
        return cmd_log()
    }
    if verb == "show" {
        return cmd_show(argv)
    }
    if verb == "undo" {
        return cmd_undo()
    }
    return Err("unknown verb: " + verb)
}


fn main() -> int {
    match dispatch(args()) {
        case Ok(code) {
            return code
        }
        case Err(e) {
            println("quog: {e}")
            return 1
        }
    }
}
