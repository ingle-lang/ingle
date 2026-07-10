// selfhost/codegen_dump.ig — the M4 differential driver. Parses the entry file AND every module it
// transitively imports (BFS, deduped by resolved path — mirroring src/main.c load_modules), merges their
// declarations end-to-end, then prints each function's disassembly in stage-0's `--emit=bytecode` format.
// The merged order matters: enum/struct ids and variant tags are numbered over [entry, import1, …, prelude],
// so an imported enum's `match` tags resolve correctly.
//
//   inglec --emit=run selfhost/codegen_dump.ig <file.ig>

import "parser" as ps
import "codegen" as cg
import "lexer" as lex


// last_slash returns the index of the final '/' in a path, or -1.
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


// dirname returns the directory part of a path ("" if there is no '/').
fn dirname(s: string) -> string {
    let ls = last_slash(s)
    if ls < 0 {
        return ""
    }
    return byte_slice(s, 0, ls)
}


// resolve_import joins an import path against the importing file's directory and appends ".ig"; a "std/"
// prefix resolves against the repo root (cwd), like g_std_dir in stage-0.
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


// Loaded is the merged program: the flat decl list plus each decl's owning MODULE index (BFS load order),
// so codegen can resolve an unqualified free-fn call to its same-module definition.
struct Loaded {
    decls: [ps.Decl]
    mod_of: [int]
    imp_from: [int]        // per-import: the IMPORTING module's index (parallel to imp_alias/imp_to)
    imp_alias: [string]    // ...its alias (`lay`)
    imp_to: [int]          // ...the imported module's index (so `lay.new()` resolves in layout's module)
}


// load_modules parses the entry module and every module it transitively imports, BFS over imports, deduped
// by resolved path, returning the merged declaration list ([entry decls, import1 decls, …]).
// prelude_src is stage-0's PRELUDE_SOURCE (src/main.c), byte-for-byte. It is parsed so the Option/Result
// COMBINATORS land at the SAME source lines as stage-0 (the enums + Hash/Eq/Show interfaces occupy lines
// 1-17, is_some at 18, …) — so an injected combinator's bytecode source-map is byte-identical. Only the
// combinator DECL_FNs are injected downstream; the enums/interfaces are here purely for line positioning
// (Option/Result stay OUT of the enum table — the C-emit resolves Some/Ok/… by the prelude fallback, OFI-204).
// Braces are `\{`/`\}` — a bare `{` starts string interpolation.
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


// collect_idents returns every IDENTIFIER lexeme across the user sources (dups kept — membership is a
// scan). Comments/strings never reach the token stream, so a combinator name mentioned in a comment is
// NOT a false hit — mirrors stage-0's NameSet in src/main.c.
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


fn load_modules(entry: string) -> Loaded {
    var seen: [string] = []
    var queue: [string] = []
    var combined: [ps.Decl] = []
    var mod_of: [int] = []
    var imp_from: [int] = []
    var imp_alias: [string] = []
    var imp_to: [int] = []
    var sources: [string] = []    // each module's source text, for the combinator usage gate
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
            mod_of.append(qi)                    // this decl's owning module = its BFS load order (matches stage-0)
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
                    imp_from.append(qi)          // `lay.new()` in module qi resolves `new` in module tidx (layout)
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
    // Inject each prelude combinator the program actually references (usage-gated, like stage-0's
    // NameSet) — appended AFTER every user module, in a synthetic prelude module (queue.len()), so its
    // function index matches stage-0 (the prelude module is last). Only the DECL_FNs; the parsed
    // Option/Result enums are discarded (kept out of the enum table — the OFI-204 fallback path).
    let used = collect_idents(sources)
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
                    mod_of.append(pmod)
                }
            }
            case _ {
            }
        }
        pi = pi + 1
    }
    return Loaded { decls: combined, mod_of: mod_of, imp_from: imp_from, imp_alias: imp_alias, imp_to: imp_to }
}


fn main() -> int {
    let argv = args()
    if argv.len() < 1 {
        println("usage: inglec --emit=run selfhost/codegen_dump.ig <file.ig>")
        return 1
    }
    let lm = load_modules(argv[0])
    let fn_names = cg.build_fn_names(lm.decls)
    let structs = cg.build_structs(lm.decls)
    let enums = cg.build_enums(lm.decls, structs)
    let fn_rets = cg.build_fn_rets(lm.decls, structs, enums.e_names, lm.mod_of, lm.imp_from, lm.imp_alias, lm.imp_to)
    let globals = cg.build_globals(lm.decls)
    let instances = cg.build_struct_instances(lm.decls, structs.names)
    cg.disassemble_program(lm.decls, lm.mod_of, fn_names, fn_rets, structs, enums, globals, instances)
    return 0
}
