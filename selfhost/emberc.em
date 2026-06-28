// selfhost/emberc.em — the UNIFIED self-hosted compiler driver: lex → parse → CHECK → codegen, run as
// ONE program (the per-stage `*_dump.em` drivers each run only a slice for the differentials). It
// type-checks the entry program — rejecting an ill-typed one with exit 65, exactly like stage-0's check
// error — and otherwise emits each function's bytecode in stage-0's `--emit=bytecode` disassembly format.
//
// This is the first standalone-bootstrap milestone: the self-hosted compiler as a single program. It both
// runs on the stage-0 VM and compiles to a native self-built compiler BINARY:
//
//   emberc --emit=run selfhost/emberc.em <file.em>          # run on the stage-0 VM
//   emberc -o emberc-self selfhost/emberc.em && ./emberc-self <file.em>   # a self-built compiler binary
//
// The checker is single-module and lenient about imports (mirrors check_dump.em); codegen is multi-module
// over the merged declaration list (mirrors codegen_dump.em). Making the emitted bytecode RUNNABLE (a
// serialization format + a stage-0 loader) is the next increment.

import "parser" as ps
import "checker" as ck
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


// load_modules parses the entry module and every module it transitively imports, BFS over imports, deduped
// by resolved path, returning the merged declaration list ([entry decls, import1 decls, …]).
fn load_modules(entry: string) -> [ps.Decl] {
    var seen: [string] = []
    var queue: [string] = []
    var combined: [ps.Decl] = []
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
    return combined
}


// emit_program codegens every function of every module (merged decls) and prints its disassembly, in
// stage-0's `--emit=bytecode` format — a struct's methods are emitted as `Struct.method` in declaration
// order so CALL indices line up.
fn emit_program(decls: [ps.Decl]) {
    let fn_names = cg.build_fn_names(decls)
    let structs = cg.build_structs(decls)
    let enums = cg.build_enums(decls, structs)
    let fn_rets = cg.build_fn_rets(decls, structs, enums.e_names)
    let globals = cg.build_globals(decls)
    let instances = cg.build_struct_instances(decls, structs.names)
    var sid = 0
    var i = 0
    loop {
        if i >= decls.len() {
            break
        }
        match decls[i] {
            case DStruct(name, generics, impls, fields, methods, kind) {
                var mi = 0
                loop {
                    if mi >= methods.len() {
                        break
                    }
                    if methods[mi].has_body {
                        println("== fn {name}.{methods[mi].name} (arity {methods[mi].params.len()}) ==")
                        let ch = cg.compile_fn(methods[mi], fn_names, fn_rets, structs, enums, globals, instances, sid)
                        cg.disassemble(ch)
                    }
                    mi = mi + 1
                }
                sid = sid + 1
            }
            case DFn(f) {
                if f.has_body {
                    println("== fn {f.name} (arity {f.params.len()}) ==")
                    let ch = cg.compile_fn(f, fn_names, fn_rets, structs, enums, globals, instances, 0 - 1)
                    cg.disassemble(ch)
                }
            }
            case _ {
            }
        }
        i = i + 1
    }
}


fn main() -> int {
    let argv = args()
    if argv.len() < 1 {
        println("usage: emberc-self <file.em>")
        exit(1)
    }
    let entry = argv[0]
    // 1. TYPE-CHECK the entry program. A diagnostic → reject with exit 65 (stage-0's check-error code).
    //    The checker is import-lenient, so it accepts every valid program (including this compiler).
    if ck.check(read_file(entry)) {
        println("error: '{entry}' did not type-check")
        exit(65)
    } else {
        // 2. CODEGEN every (merged) module → emit the bytecode.
        emit_program(load_modules(entry))
    }
    // `exit` sets the real process code AND suppresses the runtime's `=> N` echo, so emberc-self's output
    // is exactly stage-0's `--emit=bytecode` and `$?` reflects success/failure (a usable compiler binary).
    exit(0)
    return 0
}
