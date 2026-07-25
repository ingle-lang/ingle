// selfhost/compile_c.ig — the self-hosted CHECKED C-emit compiler (OFI-224 G4). It is cgen_c_dump.ig's
// load-and-emit path (BFS module load + prelude injection + selfhost/cgen_c.ig C-emit) with the
// selfhost/checker.ig type-check gate from emberc.ig fused IN FRONT: an ill-typed program is REJECTED with
// exit 65 (stage-0's check-error code) instead of emitting garbage C. This is the driver destined to be the
// default `inglec` — `cgen_c_dump.ig` stays the untyped byte-identical differential driver, this one is the
// safe compiler. (The load_modules machinery is duplicated from cgen_c_dump.ig for now; consolidating the
// two drivers into one flag-dispatched front end is later cutover work — Fork 2.)
//
//   inglec -o inglec-self selfhost/compile_c.ig   →   ./inglec-self <file.ig>   # checked Ingle→C

import "parser" as ps
import "cgen_c" as cc
import "lexer" as lex
import "checker" as ck


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


// Loaded is load_modules' result: the merged decls, each decl's SOURCE-MODULE path (parallel to `decls`), and
// the global import alias->resolved-module-path map (imp_alias[k] -> imp_path[k]). The module info lets the
// C-emit resolve a QUALIFIED call to a free fn whose bare name collides across modules (`json.get` vs
// `http.get`, `ui.new` vs `flare.new`) — pick the same-named fn defined in the aliased module. (OFI-218)
struct Loaded {
    decls: [ps.Decl]
    decl_mods: [string]
    imp_alias: [string]
    imp_path: [string]
}


fn load_modules(entry: string) -> Loaded {
    var seen: [string] = []
    var queue: [string] = []
    var combined: [ps.Decl] = []
    var decl_mods: [string] = []
    var imp_alias: [string] = []
    var imp_path: [string] = []
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
            decl_mods.append(queue[qi])
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
                    imp_alias.append(alias)
                    imp_path.append(rpath)
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
                    decl_mods.append("<prelude>")
                }
            }
            case _ {
            }
        }
        pi = pi + 1
    }
    return Loaded { decls: combined, decl_mods: decl_mods, imp_alias: imp_alias, imp_path: imp_path }
}


fn main() -> int {
    let argv = args()
    if argv.len() < 1 {
        println("usage: inglec-self <file.ig>   (checked Ingle→C)")
        exit(1)
    }
    let entry = argv[0]
    // 1. TYPE-CHECK the entry program. A diagnostic → REJECT with exit 65 (stage-0's check-error code),
    //    so this compiler accepts/rejects the same programs stage-0 does. The self-hosted checker is
    //    single-module + import-lenient (it carries no source positions yet, so the reject is code-only,
    //    not a `file:line:col` message — the precise-diagnostic/LSP port is deferred cutover work).
    if ck.check(read_file(entry)) {
        exit(65)
    }
    // 2. C-EMIT the whole (merged, prelude-injected) program via the same backend the differential gates.
    //    `exit(0)` sets the success code AND suppresses the runtime's `=> 0` echo, so stdout is exactly the
    //    C translation unit (as stage-0 `--emit=c`) — pipe straight to cc.
    let ld = load_modules(entry)
    cc.emit_program(ld.decls, ld.decl_mods, ld.imp_alias, ld.imp_path, entry)
    exit(0)
    return 0
}
