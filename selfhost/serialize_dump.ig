// selfhost/serialize_dump.ig — driver for the self-hosted bytecode serializer (selfhost/serialize.ig). It
// parses an entry program and every module it transitively imports (BFS, deduped — the same load_modules as
// inglec.ig / codegen_dump.ig), serializes the merged program to the `.igb` container, and writes it via
// from_bytes + write_file.
//
//   inglec --emit=run selfhost/serialize_dump.ig <file.ig> <out.igb>
//
// tools/embdiff.sh diffs the result against stage 0's `inglec --emit=bytecode-bin -o <a.igb> <file.ig>`.

import "parser" as ps
import "serialize" as sz
import "lexer" as lex


// Loaded is the merged program plus, parallel to it, the source file each declaration came from (so a
// function's source_file is its OWN module's path, not the entry's — needed for multi-module byte-identity).
struct Loaded {
    decls: [ps.Decl]
    sources: [string]
    mod_of: [int]
    imp_from: [int]
    imp_alias: [string]
    imp_to: [int]
}


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


// prelude_src is stage-0's PRELUDE_SOURCE (src/main.c), byte-for-byte, so an injected combinator parses at the
// same source lines as stage-0. Only the combinator DECL_FNs are injected; the enums are line-positioning
// (Option/Result stay out of the enum table — the OFI-204 fallback). Braces are `\{`/`\}`.
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
           "\}\n" +
           "fn ok_or<T, E>(o: Option<T>, e: E) -> Result<T, E> \{\n" +
           "    match o \{\n" +
           "        case Some(v) \{ return Ok(v) \}\n" +
           "        case None \{ return Err(e) \}\n" +
           "    \}\n" +
           "\}\n" +
           "fn map<T, U>(o: Option<T>, f: fn(T) -> U) -> Option<U> \{\n" +
           "    match o \{\n" +
           "        case Some(v) \{ return Some(f(v)) \}\n" +
           "        case None \{ return None \}\n" +
           "    \}\n" +
           "\}\n" +
           "fn and_then<T, U>(o: Option<T>, f: fn(T) -> Option<U>) -> Option<U> \{\n" +
           "    match o \{\n" +
           "        case Some(v) \{ return f(v) \}\n" +
           "        case None \{ return None \}\n" +
           "    \}\n" +
           "\}\n"
}


// collect_idents returns every IDENTIFIER lexeme across the user sources (comments/strings never reach the
// token stream, so a combinator mentioned in a comment is not a false hit) — mirrors stage-0's NameSet.
fn collect_idents(srcs: [string]) -> [string] {
    var out: [string] = []
    var si = 0
    loop {
        if si >= srcs.len() {
            break
        }
        let toks = lex.lex(srcs[si])
        var ti = 0
        loop {
            if ti >= toks.len() {
                break
            }
            // Only a CALL-POSITION identifier (immediately followed by `(` — a free call `f(…)` or a
            // method/UFCS call `x.f(…)`) gates injection, so a combinator NAME used as a variable / struct
            // field (`s.map`) / type is not a false hit. Mirrors stage-0's nameset_collect.
            if ti + 1 < toks.len() {
                match toks[ti].kind {
                    case TIdent {
                        match toks[ti + 1].kind {
                            case TLParen {
                                out.append(toks[ti].text)
                            }
                            case _ {
                            }
                        }
                    }
                    case _ {
                    }
                }
            }
            ti = ti + 1
        }
        si = si + 1
    }
    return out
}


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


// declares_fn — a user's own `unwrap_or`/… shadows the prelude combinator (mirrors stage-0's program_declares_fn).
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


fn load_modules(entry: string) -> Loaded {
    var seen: [string] = []
    var queue: [string] = []
    var combined: [ps.Decl] = []
    var sources: [string] = []
    var mod_of: [int] = []
    var imp_from: [int] = []
    var imp_alias: [string] = []
    var imp_to: [int] = []
    var src_texts: [string] = []    // each module's source text, for the combinator usage gate
    seen.append(entry)
    queue.append(entry)
    var qi = 0
    loop {
        if qi >= queue.len() {
            break
        }
        let src = read_file(queue[qi])
        let decls = ps.parse(src)
        src_texts.append(src)
        var di = 0
        loop {
            if di >= decls.len() {
                break
            }
            combined.append(decls[di])
            sources.append(queue[qi])
            mod_of.append(qi)
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
                    var tidx = 0 - 1
                    var si = 0
                    loop {
                        if si >= queue.len() {
                            break
                        }
                        if queue[si] == rpath {
                            tidx = si
                            break
                        }
                        si = si + 1
                    }
                    if tidx < 0 {
                        tidx = queue.len()
                        seen.append(rpath)
                        queue.append(rpath)
                    }
                    imp_from.append(qi)
                    imp_alias.append(alias)
                    imp_to.append(tidx)
                }
                case _ {
                }
            }
            ii = ii + 1
        }
        qi = qi + 1
    }
    // Inject each referenced prelude combinator (usage-gated + shadow-guarded), appended after all user decls
    // in a synthetic prelude module (queue.len()); its per-decl source path is "<prelude>" so the serialized
    // .igb's per-function source_file matches stage-0's prelude module (src/main.c).
    let used = collect_idents(src_texts)
    let pdecls = ps.parse(prelude_src())
    let pmod = queue.len()
    var pi = 0
    loop {
        if pi >= pdecls.len() {
            break
        }
        match pdecls[pi] {
            case DFn(f) {
                if name_used(used, f.name) && declares_fn(combined, f.name) == false {
                    combined.append(pdecls[pi])
                    sources.append("<prelude>")
                    mod_of.append(pmod)
                }
            }
            case _ {
            }
        }
        pi = pi + 1
    }
    return Loaded { decls: combined, sources: sources, mod_of: mod_of, imp_from: imp_from, imp_alias: imp_alias, imp_to: imp_to }
}


fn main() -> int {
    let argv = args()
    if argv.len() < 2 {
        println("usage: serialize_dump <file.ig> <out.igb>")
        exit(1)
    }
    let entry = argv[0]
    let out = argv[1]
    let loaded = load_modules(entry)
    sz.serialize_program(loaded.decls, loaded.mod_of, loaded.sources, loaded.imp_from, loaded.imp_alias, loaded.imp_to, out)
    exit(0)
    return 0
}
