// selfhost/cgen_c_dump.ig — the M5 C-emit differential driver. Parses the entry file + every transitively
// imported module (BFS, deduped — mirroring src/main.c load_modules), merges their declarations, and emits
// the whole C translation unit via selfhost/cgen_c.ig, byte-identical to stage-0 `inglec --emit=c`.
//
//   inglec --emit=run selfhost/cgen_c_dump.ig <file.ig>

import "parser" as ps
import "cgen_c" as cc
import "lexer" as lex


fn last_slash(s: string) -> int {
    let bs = s.bytes()
    var last = 0 - 1
    var i = 0
    loop {
        if i >= bs.len() {
            break
        }
        if int(bs[i]) == 47 {
            last = i
        }
        i = i + 1
    }
    return last
}


fn dirname(s: string) -> string {
    let ls = last_slash(s)
    if ls < 0 {
        return ""
    }
    return byte_slice(s, 0, ls)
}


fn resolve_import(importer: string, imp: string) -> string {
    if imp.len() >= 4 && byte_slice(imp, 0, 4) == "std/" {
        return imp + ".ig"
    }
    let d = dirname(importer)
    if d == "" {
        return imp + ".ig"
    }
    return d + "/" + imp + ".ig"
}


fn seen_has(seen: [string], p: string) -> bool {
    var i = 0
    loop {
        if i >= seen.len() {
            break
        }
        if seen[i] == p {
            return true
        }
        i = i + 1
    }
    return false
}


// prelude_src is stage-0's PRELUDE_SOURCE (src/main.c), byte-for-byte, so an injected combinator parses
// at the same source lines as stage-0 (the C-emit carries no line info, but the SAME source keeps this
// driver in lockstep with codegen_dump.ig). Only the combinator DECL_FNs are injected; the enums are
// line-positioning (Option/Result stay OUT of the enum table — the C-emit resolves Some/Ok/… by the
// prelude fallback, OFI-204). Braces are `\{`/`\}` — a bare `{` starts string interpolation.
fn prelude_src() -> string {
    return "enum Option<T> \{\n" +
           "    Some(value: T)\n" +
           "    None\n" +
           "\}\n" +
           "enum Result<T, E> \{\n" +
           "    Ok(value: T)\n" +
           "    Err(error: E)\n" +
           "\}\n" +
           "interface Hash \{\n" +
           "    fn hash(self) -> int\n" +
           "\}\n" +
           "interface Eq \{\n" +
           "    fn eq(self, other: Self) -> bool\n" +
           "\}\n" +
           "interface Show \{\n" +
           "    fn show(self) -> string\n" +
           "\}\n" +
           "fn is_some<T>(o: Option<T>) -> bool \{\n" +
           "    match o \{\n" +
           "        case Some(v) \{ return true \}\n" +
           "        case None \{ return false \}\n" +
           "    \}\n" +
           "\}\n" +
           "fn is_none<T>(o: Option<T>) -> bool \{\n" +
           "    match o \{\n" +
           "        case Some(v) \{ return false \}\n" +
           "        case None \{ return true \}\n" +
           "    \}\n" +
           "\}\n" +
           "fn unwrap_or<T: Copy>(o: Option<T>, d: T) -> T \{\n" +
           "    match o \{\n" +
           "        case Some(v) \{ return v \}\n" +
           "        case None \{ return d \}\n" +
           "    \}\n" +
           "\}\n" +
           "fn is_ok<T, E>(r: Result<T, E>) -> bool \{\n" +
           "    match r \{\n" +
           "        case Ok(v) \{ return true \}\n" +
           "        case Err(e) \{ return false \}\n" +
           "    \}\n" +
           "\}\n" +
           "fn is_err<T, E>(r: Result<T, E>) -> bool \{\n" +
           "    match r \{\n" +
           "        case Ok(v) \{ return false \}\n" +
           "        case Err(e) \{ return true \}\n" +
           "    \}\n" +
           "\}\n"
}


// collect_idents returns every IDENTIFIER lexeme across the user sources (comments/strings never reach the
// token stream, so a combinator mentioned in a comment is not a false hit) — mirrors stage-0's NameSet.
fn collect_idents(sources: [string]) -> [string] {
    var out: [string] = []
    var si = 0
    loop {
        if si >= sources.len() {
            break
        }
        let toks = lex.lex(sources[si])
        var ti = 0
        loop {
            if ti >= toks.len() {
                break
            }
            match toks[ti].kind {
                case TIdent {
                    out.append(toks[ti].text)
                }
                case _ {
                }
            }
            ti = ti + 1
        }
        si = si + 1
    }
    return out
}


// name_used reports whether `n` appears in the collected identifier set.
fn name_used(names: [string], n: string) -> bool {
    var i = 0
    loop {
        if i >= names.len() {
            break
        }
        if names[i] == n {
            return true
        }
        i = i + 1
    }
    return false
}


// declares_fn reports whether the program already declares a top-level function named `n` — a user's own
// `unwrap_or`/… shadows the prelude combinator (mirrors stage-0's program_declares_fn in src/main.c).
fn declares_fn(decls: [ps.Decl], n: string) -> bool {
    var i = 0
    loop {
        if i >= decls.len() {
            break
        }
        match decls[i] {
            case DFn(f) {
                if f.name == n {
                    return true
                }
            }
            case _ {
            }
        }
        i = i + 1
    }
    return false
}


fn load_modules(entry: string) -> [ps.Decl] {
    var seen: [string] = []
    var queue: [string] = []
    var combined: [ps.Decl] = []
    var sources: [string] = []
    seen.append(entry)
    queue.append(entry)
    var qi = 0
    loop {
        if qi >= queue.len() {
            break
        }
        let src = read_file(queue[qi])
        let decls = ps.parse(src)
        sources.append(src)
        var di = 0
        loop {
            if di >= decls.len() {
                break
            }
            combined.append(decls[di])
            di = di + 1
        }
        var ii = 0
        loop {
            if ii >= decls.len() {
                break
            }
            match decls[ii] {
                case DImport(ipath, alias) {
                    let rpath = resolve_import(queue[qi], ipath)
                    if seen_has(seen, rpath) == false {
                        seen.append(rpath)
                        queue.append(rpath)
                    }
                }
                case _ {
                }
            }
            ii = ii + 1
        }
        qi = qi + 1
    }
    // Inject each prelude combinator the program references (usage-gated, like stage-0's NameSet),
    // appended after all user decls (Option/Result enums discarded — kept out of the enum table, OFI-204).
    let used = collect_idents(sources)
    let pdecls = ps.parse(prelude_src())
    var pi = 0
    loop {
        if pi >= pdecls.len() {
            break
        }
        match pdecls[pi] {
            case DFn(f) {
                if name_used(used, f.name) && declares_fn(combined, f.name) == false {
                    combined.append(pdecls[pi])
                }
            }
            case _ {
            }
        }
        pi = pi + 1
    }
    return combined
}


fn main() -> int {
    let argv = args()
    if argv.len() < 1 {
        println("usage: inglec --emit=run selfhost/cgen_c_dump.ig <file.ig>")
        return 1
    }
    cc.emit_program(load_modules(argv[0]), argv[0])
    return 0
}
