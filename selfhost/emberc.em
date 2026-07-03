// selfhost/emberc.em — the UNIFIED self-hosted compiler: lex → parse → CHECK → codegen → SERIALIZE, run
// as ONE program (the per-stage `*_dump.em` drivers each run only a slice for the differentials). It
// type-checks the entry program — rejecting an ill-typed one with exit 65, exactly like stage-0's check
// error — then, given an output path, emits a RUNNABLE `.emb` bytecode container (docs/design/bytecode-
// container.md); with no output path it prints stage-0's `--emit=bytecode` disassembly (the differential).
//
// This is the standalone-bootstrap milestone: the self-hosted compiler as a single program that produces
// executable bytecode. It runs on the stage-0 VM and compiles to a native self-built compiler BINARY:
//
//   emberc --emit=run selfhost/emberc.em <file.em>                    # disassembly, on the stage-0 VM
//   emberc -o emberc-self selfhost/emberc.em                          # a self-built compiler binary
//   ./emberc-self <file.em> <out.emb> && emberc --run-bytecode out.emb  # emit + run a bytecode image
//
// The checker is single-module and lenient about imports (mirrors check_dump.em); codegen + serialize run
// multi-module over the merged declaration list. The emitted image runs identically to the source (it is
// byte-identical to stage 0 wherever the self-hosted codegen is; generic-method monomorphization is the
// one residual numbering difference — internally consistent, so the image still runs correctly).

import "parser" as ps
import "checker" as ck
import "codegen" as cg
import "serialize" as sz


// Loaded is the merged program plus, parallel to it, the source module each declaration came from — so a
// serialized function's source_file is its OWN module's path (multi-module byte-identity).
struct Loaded {
    decls: [ps.Decl]
    sources: [string]
}


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
// by resolved path, returning the merged declaration list plus each declaration's source module.
fn load_modules(entry: string) -> Loaded {
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
        let decls = ps.parse(read_file(queue[qi]))
        var di = 0
        loop {
            if di >= decls.len() {
                break
            }
            combined.append(decls[di])
            sources.append(queue[qi])
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
    return Loaded { decls: combined, sources: sources }
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
    cg.disassemble_program(decls, fn_names, fn_rets, structs, enums, globals, instances)
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
        // 2. CODEGEN every (merged) module. With an output path, write a RUNNABLE `.emb` container (the
        //    unified self-hosted compiler emits executable bytecode, not just a disassembly); without one,
        //    print the `--emit=bytecode` disassembly (the differential path, byte-identical to stage 0).
        let loaded = load_modules(entry)
        if argv.len() >= 2 {
            sz.serialize_program(loaded.decls, loaded.sources, argv[1])
        } else {
            emit_program(loaded.decls)
        }
    }
    // `exit` sets the real process code AND suppresses the runtime's `=> N` echo, so emberc-self's output
    // is exactly stage-0's `--emit=bytecode` and `$?` reflects success/failure (a usable compiler binary).
    exit(0)
    return 0
}
