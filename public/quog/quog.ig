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
import "std/map" as map
import "std/diff" as diff


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


// now returns the timestamp for commits and op-log entries — the wall clock, unless QUOG_NOW is set
// (a fixed epoch value, like git's GIT_AUTHOR_DATE), in which case that is used so tests are reproducible.
fn now() -> int {
    let fixed = env("QUOG_NOW")
    if fixed != "" {
        return _atoi(fixed)
    }
    return time.now()
}


// head_branch returns the name of the branch HEAD points at (defaulting to "main" before the first ref).
fn head_branch(db: sql.Db) -> Result<string, string> {
    let b = get_ref(db, "HEAD")?
    if b == "" {
        return Ok("main")
    }
    return Ok(b)
}


// tip_ref returns the ref that holds the CURRENT branch's tip commit — "branch:<current>".
fn tip_ref(db: sql.Db) -> Result<string, string> {
    return Ok("branch:" + head_branch(db)?)
}


// log_op appends to the operation log — the append-only spine that makes every mutation undoable.
// `before`/`after` capture the ref move so a future `undo` can restore the prior tip exactly.
fn log_op(db: sql.Db, op: string, before: string, after: string) -> Result<int, string> {
    let st = sql.prepare(db, "INSERT INTO oplog(op, before, after, ts) VALUES(?, ?, ?, ?)")?
    let _ = sql.bind_text(st, 1, op)
    let _ = sql.bind_text(st, 2, before)
    let _ = sql.bind_text(st, 3, after)
    let _ = sql.bind_int(st, 4, now())
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
    let _ = sql.exec(db, "CREATE TABLE IF NOT EXISTS object(id TEXT PRIMARY KEY, kind TEXT, data BLOB); CREATE TABLE IF NOT EXISTS ref(name TEXT PRIMARY KEY, target TEXT); CREATE TABLE IF NOT EXISTS oplog(seq INTEGER PRIMARY KEY AUTOINCREMENT, op TEXT, before TEXT, after TEXT, ts INTEGER); CREATE TABLE IF NOT EXISTS attic(seq INTEGER PRIMARY KEY AUTOINCREMENT, tree TEXT, reason TEXT, ts INTEGER)")?
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
    let tr = tip_ref(db)?
    let parent = get_ref(db, tr)?
    let tree_text = walk(db, ".", "")?
    let tree_id = put_object(db, "tree", tree_text.bytes())?
    let commit = commit_serialize(tree_id, parent, now(), message)
    let commit_id = put_object(db, "commit", commit.bytes())?
    let _ = set_ref(db, tr, commit_id)?
    let _ = log_op(db, "save", parent, commit_id)?
    println("saved {_short(commit_id)} ({_count_lines(tree_text)} files) — {message}")
    return Ok(0)
}


// cmd_log walks the current branch from its tip back through parent links, newest first.
fn cmd_log() -> Result<int, string> {
    let db = sql.open(DB_PATH)?
    var id = get_ref(db, tip_ref(db)?)?
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
        id = get_ref(db, tip_ref(db)?)?
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
    if op == "switch" {
        // before/after are branch names: return to `before` and lay down its snapshot.
        let _ = checkout_branch(db, before)?
        let _ = set_ref(db, "HEAD", before)?
        let _ = log_op(db, "undo", after, before)?
        println("undid switch — back on {before}")
    } else {
        // save/undo: before/after are commit ids on the current branch; restore the tip.
        let _ = set_ref(db, tip_ref(db)?, before)?
        let _ = log_op(db, "undo", after, before)?
        if before == "" {
            println("undid {op} — back to empty history ({_short(after)} still stored, nothing lost)")
        } else {
            println("undid {op} — tip {_short(after)} → {_short(before)} (nothing lost)")
        }
    }
    return Ok(0)
}


// scan walks the working tree like `walk` but WITHOUT storing anything — it only hashes each file to
// its content id, for a read-only comparison against a saved snapshot (status / diff).
fn scan(fsdir: string, prefix: string) -> string {
    var out = ""
    for name in list_dir(fsdir).split("\n") {
        if name != "" {
            if str.ends_with(name, "/") {
                let base = str.cp_slice(name, 0, str.cp_count(name) - 1)
                if base != ".quog" {
                    out = out + scan(fsdir + "/" + base, prefix + base + "/")
                }
            } else {
                out = out + prefix + name + "\t" + object_id(read_file(fsdir + "/" + name).bytes()) + "\n"
            }
        }
    }
    return out
}


// tree_map parses a tree text ("path\tid" per line) into a path -> content-id lookup.
fn tree_map(text: string) -> map.Map<string, string> {
    var m = map.Map<string, string>{ buckets: [], count: 0 }
    for line in text.split("\n") {
        if line != "" {
            let parts = line.split("\t")
            if parts.len() == 2 {
                m.set(parts[0], parts[1])
            }
        }
    }
    return m
}


// map_get reads a key or returns "" when absent — the common "id, or nothing" shape here.
fn map_get(m: map.Map<string, string>, k: string) -> string {
    match m.get(k) {
        case Some(v) {
            return v
        }
        case None {
            return ""
        }
    }
}


// tip_tree_text returns the last saved snapshot's tree text, or "" if there are no commits yet.
fn tip_tree_text(db: sql.Db) -> Result<string, string> {
    let tip = get_ref(db, tip_ref(db)?)?
    if tip == "" {
        return Ok("")
    }
    let commit = from_bytes(get_object(db, tip)?)
    return Ok(from_bytes(get_object(db, commit_header(commit, "tree "))?))
}


// cmd_status reports what changed in the working tree since the last save: added / modified / deleted.
fn cmd_status() -> Result<int, string> {
    let db = sql.open(DB_PATH)?
    let old_tree = tree_map(tip_tree_text(db)?)
    let new_tree = tree_map(scan(".", ""))
    var n = 0
    for path in new_tree.keys() {
        let was = map_get(old_tree, path)
        if was == "" {
            println("  added     {path}")
            n = n + 1
        } else if was != map_get(new_tree, path) {
            println("  modified  {path}")
            n = n + 1
        }
    }
    for path in old_tree.keys() {
        if !new_tree.has(path) {
            println("  deleted   {path}")
            n = n + 1
        }
    }
    if n == 0 {
        println("clean — nothing changed since the last save")
    }
    return Ok(0)
}


// _lines splits file content into lines, dropping the single trailing empty line a newline-terminated
// file produces (so it isn't shown as a spurious blank context line in the diff).
fn _lines(content: string) -> [string] {
    var c = content
    if str.ends_with(c, "\n") {
        c = str.substring(c, 0, str.cp_count(c) - 1)
    }
    if c == "" {
        var empty: [string] = []
        return empty
    }
    return c.split("\n")
}


// _diff_file prints a labelled unified diff of one file between its saved content (`old_id`, "" = a new
// file) and its working content (`work_path`, "" = a deleted file).
fn _diff_file(db: sql.Db, path: string, old_id: string, work_path: string) -> Result<int, string> {
    var old_content = ""
    if old_id != "" {
        old_content = from_bytes(get_object(db, old_id)?)
    }
    var new_content = ""
    if work_path != "" {
        new_content = read_file(work_path)
    }
    let edits = diff.diff_lines(_lines(old_content), _lines(new_content))
    println("=== {path}  (+{diff.added_count(edits)} -{diff.removed_count(edits)}) ===")
    print(diff.unified(edits))
    return Ok(0)
}


// cmd_diff shows the line changes since the last save — every added / modified / deleted file.
fn cmd_diff() -> Result<int, string> {
    let db = sql.open(DB_PATH)?
    let old_tree = tree_map(tip_tree_text(db)?)
    let new_tree = tree_map(scan(".", ""))
    var any = 0
    for path in new_tree.keys() {
        let was = map_get(old_tree, path)
        if was != map_get(new_tree, path) {
            let _ = _diff_file(db, path, was, "./" + path)?
            any = any + 1
        }
    }
    for path in old_tree.keys() {
        if !new_tree.has(path) {
            let _ = _diff_file(db, path, map_get(old_tree, path), "")?
            any = any + 1
        }
    }
    if any == 0 {
        println("clean — nothing changed since the last save")
    }
    return Ok(0)
}


// commit_tree_text returns the tree text (path\tid lines) of the snapshot a commit points at.
fn commit_tree_text(db: sql.Db, commit_id: string) -> Result<string, string> {
    let commit = from_bytes(get_object(db, commit_id)?)
    return Ok(from_bytes(get_object(db, commit_header(commit, "tree "))?))
}


// mkdir_p creates every parent directory of file path `fs_path` (like `mkdir -p` on its dirname).
fn mkdir_p(fs_path: string) {
    let parts = fs_path.split("/")
    var prefix = ""
    var i = 0
    loop {
        if i >= parts.len() - 1 {
            break
        }
        if i == 0 {
            prefix = parts[0]
        } else {
            prefix = prefix + "/" + parts[i]
        }
        let _ = fs.mkdir(prefix)
        i = i + 1
    }
}


// checkout makes the working tree match `tree_text` (a snapshot): every file in it is written out, and
// any working file NOT in it is removed. Callers snapshot first, so a pruned file is never truly lost.
fn checkout(db: sql.Db, tree_text: string) -> Result<int, string> {
    let target = tree_map(tree_text)
    for path in target.keys() {
        let fs_path = "./" + path
        mkdir_p(fs_path)
        write_file(fs_path, from_bytes(get_object(db, map_get(target, path))?))
    }
    let current = tree_map(scan(".", ""))
    for path in current.keys() {
        if !target.has(path) {
            let _ = fs.remove("./" + path)
        }
    }
    return Ok(0)
}


// checkout_branch lays down a branch's tip snapshot (an empty tree if the branch has no commits).
fn checkout_branch(db: sql.Db, branch: string) -> Result<int, string> {
    let tip = get_ref(db, "branch:" + branch)?
    var tree = ""
    if tip != "" {
        tree = commit_tree_text(db, tip)?
    }
    return checkout(db, tree)
}


// ref_exists reports whether a ref row exists — distinguishing an empty branch from an absent one.
fn ref_exists(db: sql.Db, name: string) -> Result<bool, string> {
    let st = sql.prepare(db, "SELECT 1 FROM ref WHERE name = ?")?
    let _ = sql.bind_text(st, 1, name)
    return sql.step(st)
}


// cmd_branch lists branches (marking the current with '*'), or with a name creates one at the current tip.
fn cmd_branch(argv: [string]) -> Result<int, string> {
    let db = sql.open(DB_PATH)?
    if argv.len() < 2 {
        let cur = head_branch(db)?
        let st = sql.prepare(db, "SELECT name FROM ref WHERE name LIKE 'branch:%' ORDER BY name")?
        loop {
            let more = sql.step(st)?
            if !more {
                break
            }
            let full = sql.column_text(st, 0)
            let bname = str.substring(full, 7, str.cp_count(full))
            if bname == cur {
                println("* {bname}")
            } else {
                println("  {bname}")
            }
        }
        return Ok(0)
    }
    let name = argv[1]
    let tip = get_ref(db, tip_ref(db)?)?
    let _ = set_ref(db, "branch:" + name, tip)?
    if tip == "" {
        println("created branch {name} (empty)")
    } else {
        println("created branch {name} at {_short(tip)}")
    }
    return Ok(0)
}


// cmd_switch moves to another branch. Invariant #4 (switching never loses work): it snapshots any
// uncommitted changes on the current branch FIRST, then points HEAD at the target and checks out its
// snapshot (writing its files, pruning the rest — all recoverable from the snapshot just taken).
fn cmd_switch(argv: [string]) -> Result<int, string> {
    if argv.len() < 2 {
        return Err("switch needs a branch name: quog switch <name>")
    }
    let db = sql.open(DB_PATH)?
    let target = argv[1]
    let cur = head_branch(db)?
    if target == cur {
        println("already on {target}")
        return Ok(0)
    }
    if !ref_exists(db, "branch:" + target)? {
        return Err("no such branch: " + target + " (create it with: quog branch " + target + ")")
    }
    let cur_tr = tip_ref(db)?
    let cur_tip = get_ref(db, cur_tr)?
    var cur_tree_id = ""
    if cur_tip != "" {
        cur_tree_id = commit_header(from_bytes(get_object(db, cur_tip)?), "tree ")
    }
    // Invariant #4: if the working tree differs from the current tip, commit it before leaving.
    if object_id(scan(".", "").bytes()) != cur_tree_id {
        let tree_id = put_object(db, "tree", walk(db, ".", "")?.bytes())?
        let snap = commit_serialize(tree_id, cur_tip, now(), "auto-snapshot before switching to " + target)
        let snap_id = put_object(db, "commit", snap.bytes())?
        let _ = set_ref(db, cur_tr, snap_id)?
        let _ = log_op(db, "save", cur_tip, snap_id)?
        println("auto-snapshot: saved your changes on {cur} as {_short(snap_id)}")
    }
    let _ = checkout_branch(db, target)?
    let _ = set_ref(db, "HEAD", target)?
    let _ = log_op(db, "switch", cur, target)?
    println("switched to {target}")
    return Ok(0)
}


// is_dirty reports whether the working tree differs from the current branch's tip snapshot.
fn is_dirty(db: sql.Db) -> Result<bool, string> {
    let tip = get_ref(db, tip_ref(db)?)?
    var tip_tree_id = ""
    if tip != "" {
        tip_tree_id = commit_header(from_bytes(get_object(db, tip)?), "tree ")
    }
    return Ok(object_id(scan(".", "").bytes()) != tip_tree_id)
}


// attic_save stores the current working tree (blobs + a tree object) and records an attic row, so the
// snapshot is fully recoverable. Returns the attic entry's number. Invariant #6: nothing goes to
// /dev/null — a "thrown away" change lands here.
fn attic_save(db: sql.Db, reason: string) -> Result<int, string> {
    let tree_id = put_object(db, "tree", walk(db, ".", "")?.bytes())?
    let st = sql.prepare(db, "INSERT INTO attic(tree, reason, ts) VALUES(?, ?, ?)")?
    let _ = sql.bind_text(st, 1, tree_id)
    let _ = sql.bind_text(st, 2, reason)
    let _ = sql.bind_int(st, 3, now())
    let _ = sql.step(st)?
    return Ok(sql.last_insert_id(db))
}


// cmd_discard throws away uncommitted working changes — but to the attic, not /dev/null (invariant #6):
// it snapshots the current tree into the attic first, then reverts the working files to the last save.
fn cmd_discard() -> Result<int, string> {
    let db = sql.open(DB_PATH)?
    if !is_dirty(db)? {
        println("nothing to discard — the working tree already matches the last save")
        return Ok(0)
    }
    let seq = attic_save(db, "discarded working changes")?
    let tip = get_ref(db, tip_ref(db)?)?
    var tip_tree = ""
    if tip != "" {
        tip_tree = commit_tree_text(db, tip)?
    }
    let _ = checkout(db, tip_tree)?
    let _ = log_op(db, "discard", "", "attic")?
    println("discarded working changes — recoverable with: quog restore {seq}")
    return Ok(0)
}


// cmd_restore lists the attic (no arg) or brings an attic entry back into the working tree. Restoring
// first stashes any current uncommitted work to the attic, so restore itself can never lose work.
fn cmd_restore(argv: [string]) -> Result<int, string> {
    let db = sql.open(DB_PATH)?
    if argv.len() < 2 {
        let st = sql.prepare(db, "SELECT seq, ts, reason FROM attic ORDER BY seq DESC")?
        var any = 0
        loop {
            let more = sql.step(st)?
            if !more {
                break
            }
            println("  {sql.column_int(st, 0)}  t={sql.column_int(st, 1)}  {sql.column_text(st, 2)}")
            any = any + 1
        }
        if any == 0 {
            println("attic is empty")
        } else {
            println("restore one with: quog restore <n>")
        }
        return Ok(0)
    }
    let seq = _atoi(argv[1])
    let st = sql.prepare(db, "SELECT tree FROM attic WHERE seq = ?")?
    let _ = sql.bind_int(st, 1, seq)
    let found = sql.step(st)?
    if !found {
        return Err("no attic entry " + argv[1])
    }
    let tree_id = sql.column_text(st, 0)
    if is_dirty(db)? {
        let stashed = attic_save(db, "auto-stash before restore")?
        println("(stashed your current changes as {stashed} first)")
    }
    let _ = checkout(db, from_bytes(get_object(db, tree_id)?))?
    println("restored attic {seq} into the working tree")
    return Ok(0)
}


// serve_log renders the branch history as an HTML page — each commit a link to its detail page.
fn serve_log(db: sql.Db, conn: hs.Conn) -> Result<int, string> {
    var md = "# Quog — history\n\n"
    var id = get_ref(db, tip_ref(db)?)?
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


// diff_lines_html renders an edit script as colored <span> lines inside a <pre class="diff">.
fn diff_lines_html(edits: [diff.Edit]) -> string {
    var h = ""
    for e in edits {
        match e {
            case Keep(t) {
                h = h + "<span>  " + html.escape(t) + "</span>"
            }
            case Add(t) {
                h = h + "<span class=\"add\">+ " + html.escape(t) + "</span>"
            }
            case Remove(t) {
                h = h + "<span class=\"rem\">- " + html.escape(t) + "</span>"
            }
        }
    }
    return h
}


// render_diff_html renders a commit's diff against its parent as colored, per-file diff blocks — the
// "what changed in this commit" review view. A file present here but not in the parent is a full add;
// one only in the parent is a full delete.
fn render_diff_html(db: sql.Db, this_text: string) -> Result<string, string> {
    let this_tree = tree_map(from_bytes(get_object(db, commit_header(this_text, "tree "))?))
    let parent = commit_header(this_text, "parent ")
    var parent_tree = tree_map("")
    if parent != "" {
        let ptext = from_bytes(get_object(db, parent)?)
        parent_tree = tree_map(from_bytes(get_object(db, commit_header(ptext, "tree "))?))
    }
    var h = "<h2>Changes</h2>"
    var any = 0
    for path in this_tree.keys() {
        let oldid = map_get(parent_tree, path)
        let newid = map_get(this_tree, path)
        if oldid != newid {
            var oldc = ""
            if oldid != "" {
                oldc = from_bytes(get_object(db, oldid)?)
            }
            let edits = diff.diff_lines(_lines(oldc), _lines(from_bytes(get_object(db, newid)?)))
            h = h + "<h3>{html.escape(path)} <small>+{diff.added_count(edits)} -{diff.removed_count(edits)}</small></h3>"
            h = h + "<pre class=\"diff\">" + diff_lines_html(edits) + "</pre>"
            any = any + 1
        }
    }
    for path in parent_tree.keys() {
        if !this_tree.has(path) {
            let edits = diff.diff_lines(_lines(from_bytes(get_object(db, map_get(parent_tree, path))?)), _lines(""))
            h = h + "<h3>{html.escape(path)} <small>deleted</small></h3>"
            h = h + "<pre class=\"diff\">" + diff_lines_html(edits) + "</pre>"
            any = any + 1
        }
    }
    if any == 0 {
        h = h + "<p><em>No file changes (identical to the parent).</em></p>"
    }
    return Ok(h)
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
            let body = html.render_markdown(md) + render_diff_html(db, text)?
            let _ = hs.ok_html(conn, html.page("Commit " + _short(id), body))
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


// serve_loop is the accept loop over an already-bound listener: one connection at a time (per-connection
// fibers are a follow-on); a bad request or transient accept error is swallowed so the server stays up.
fn serve_loop(db: sql.Db, server: hs.Server, port: int, public: bool) -> Result<int, string> {
    if public {
        println("quog serving PUBLICLY on http://0.0.0.0:{port} — reachable from your network, NO auth. Ctrl-C to stop")
    } else {
        println("quog serving on http://localhost:{port} (loopback only) — Ctrl-C to stop")
    }
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


// cmd_serve runs the read-only web view over the repo's history. It binds LOOPBACK ONLY by default
// (reachable only from this machine — the safe default); `--public` opts into exposing it to the
// network (no auth/TLS, so only behind a trusted network or a proxy). Usage: quog serve [port] [--public]
fn cmd_serve(argv: [string]) -> Result<int, string> {
    let db = sql.open(DB_PATH)?
    var port = 8017
    var public = false
    var i = 1
    loop {
        if i >= argv.len() {
            break
        }
        if argv[i] == "--public" {
            public = true
        } else {
            port = _atoi(argv[i])
        }
        i = i + 1
    }
    if public {
        return serve_loop(db, hs.listen_public(port)?, port, true)
    }
    return serve_loop(db, hs.listen(port)?, port, false)
}


// cmd_verify proves the repo's integrity — the safety/security backbone that content addressing makes
// cheap. (1) Every object's stored bytes must still hash to its id: a mismatch means corruption or
// tampering (someone edited history in place). (2) Every commit's tree + parent and every tree's blobs
// must resolve, and (3) every branch tip must exist — no dangling links. Exits non-zero on any problem,
// so it drops straight into CI or a pre-sync check.
fn cmd_verify() -> Result<int, string> {
    let db = sql.open(DB_PATH)?
    var ids = map.Map<string, string>{ buckets: [], count: 0 }   // id -> kind; doubles as the exists-set
    var n_blob = 0
    var n_tree = 0
    var n_commit = 0
    var problems = 0

    // (1) content-address integrity: id must equal SHA-256(data).
    let st = sql.prepare(db, "SELECT id, kind, data FROM object")?
    loop {
        let more = sql.step(st)?
        if !more {
            break
        }
        let id = sql.column_text(st, 0)
        let kind = sql.column_text(st, 1)
        ids.set(id, kind)
        if object_id(sql.column_blob(st, 2)) != id {
            println("  TAMPERED  {_short(id)} — its content no longer hashes to its id")
            problems = problems + 1
        }
        if kind == "blob" {
            n_blob = n_blob + 1
        } else if kind == "tree" {
            n_tree = n_tree + 1
        } else if kind == "commit" {
            n_commit = n_commit + 1
        }
    }

    // (2) link integrity: commit -> tree/parent, tree -> blobs.
    let cs = sql.prepare(db, "SELECT id, data FROM object WHERE kind = 'commit'")?
    loop {
        let more = sql.step(cs)?
        if !more {
            break
        }
        let cid = sql.column_text(cs, 0)
        let text = from_bytes(sql.column_blob(cs, 1))
        if !ids.has(commit_header(text, "tree ")) {
            println("  BROKEN    commit {_short(cid)} points at a missing tree")
            problems = problems + 1
        }
        let parent = commit_header(text, "parent ")
        if parent != "" && !ids.has(parent) {
            println("  BROKEN    commit {_short(cid)} points at a missing parent {_short(parent)}")
            problems = problems + 1
        }
    }
    let ts = sql.prepare(db, "SELECT id, data FROM object WHERE kind = 'tree'")?
    loop {
        let more = sql.step(ts)?
        if !more {
            break
        }
        let tid = sql.column_text(ts, 0)
        for line in from_bytes(sql.column_blob(ts, 1)).split("\n") {
            if line != "" {
                let parts = line.split("\t")
                if parts.len() == 2 && !ids.has(parts[1]) {
                    println("  BROKEN    tree {_short(tid)} references a missing blob for {parts[0]}")
                    problems = problems + 1
                }
            }
        }
    }

    // (3) refs: every branch tip must exist.
    let rs = sql.prepare(db, "SELECT name, target FROM ref WHERE name LIKE 'branch:%'")?
    loop {
        let more = sql.step(rs)?
        if !more {
            break
        }
        let target = sql.column_text(rs, 1)
        if target != "" && !ids.has(target) {
            println("  BROKEN    {sql.column_text(rs, 0)} points at a missing commit")
            problems = problems + 1
        }
    }

    if problems == 0 {
        println("verified {n_commit} commits, {n_tree} trees, {n_blob} blobs — every object intact, every link resolves")
        return Ok(0)
    }
    println("FAILED — {problems} integrity problem(s) found")
    return Ok(1)
}


// dispatch runs the requested verb, returning a Result so any store error routes to one place.
fn dispatch(argv: [string]) -> Result<int, string> {
    if argv.len() == 0 {
        println("usage: quog <init|save|status|diff|log|show|undo|discard|restore|branch|switch|verify|serve> [args]")
        return Ok(0)
    }
    let verb = argv[0]
    if verb == "init" {
        return cmd_init()
    }
    if verb == "verify" {
        return cmd_verify()
    }
    if verb == "discard" {
        return cmd_discard()
    }
    if verb == "restore" {
        return cmd_restore(argv)
    }
    if verb == "status" {
        return cmd_status()
    }
    if verb == "diff" {
        return cmd_diff()
    }
    if verb == "branch" {
        return cmd_branch(argv)
    }
    if verb == "switch" {
        return cmd_switch(argv)
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


fn main() {
    // exit() (not return) so the process exit code is the command's status — `quog verify` failing a
    // CI/pre-sync check must fail the shell too — and so the VM runner's "=> N" line stays out of the
    // CLI's output, matching how a native `quog` binary behaves.
    match dispatch(args()) {
        case Ok(code) {
            exit(code)
        }
        case Err(e) {
            println("quog: {e}")
            exit(1)
        }
    }
}
