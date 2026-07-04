// selfhost/codegen_dump.em — the M4 differential driver. Parses the entry file AND every module it
// transitively imports (BFS, deduped by resolved path — mirroring src/main.c load_modules), merges their
// declarations end-to-end, then prints each function's disassembly in stage-0's `--emit=bytecode` format.
// The merged order matters: enum/struct ids and variant tags are numbered over [entry, import1, …, prelude],
// so an imported enum's `match` tags resolve correctly.
//
//   emberc --emit=run selfhost/codegen_dump.em <file.em>

import "parser" as ps
import "codegen" as cg


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


// resolve_import joins an import path against the importing file's directory and appends ".em"; a "std/"
// prefix resolves against the repo root (cwd), like g_std_dir in stage-0.
fn resolve_import(importer: string, imp: string) -> string {
    if imp.len() >= 4 && byte_slice(imp, 0, 4) == "std/" {
        return imp + ".em"
    }
    let d = dirname(importer)
    if d == "" {
        return imp + ".em"
    }
    return d + "/" + imp + ".em"
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
}


// load_modules parses the entry module and every module it transitively imports, BFS over imports, deduped
// by resolved path, returning the merged declaration list ([entry decls, import1 decls, …]).
fn load_modules(entry: string) -> Loaded {
    var seen: [string] = []
    var queue: [string] = []
    var combined: [ps.Decl] = []
    var mod_of: [int] = []
    seen.append(entry)
    queue.append(entry)
    var qi = 0
    loop {
        if qi >= queue.len() {
            break
        }
        let decls = ps.parse(read_file(queue[qi]))
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
    return Loaded { decls: combined, mod_of: mod_of }
}


fn main() -> int {
    let argv = args()
    if argv.len() < 1 {
        println("usage: emberc --emit=run selfhost/codegen_dump.em <file.em>")
        return 1
    }
    let lm = load_modules(argv[0])
    let fn_names = cg.build_fn_names(lm.decls)
    let structs = cg.build_structs(lm.decls)
    let enums = cg.build_enums(lm.decls, structs)
    let fn_rets = cg.build_fn_rets(lm.decls, structs, enums.e_names, lm.mod_of)
    let globals = cg.build_globals(lm.decls)
    let instances = cg.build_struct_instances(lm.decls, structs.names)
    cg.disassemble_program(lm.decls, lm.mod_of, fn_names, fn_rets, structs, enums, globals, instances)
    return 0
}
