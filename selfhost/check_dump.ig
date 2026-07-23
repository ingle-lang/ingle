// selfhost/check_dump.ig — the verdict driver for the self-hosted checker (M3a). It parses + checks the
// entry file AND every module it transitively imports (BFS over `import`s, deduped by resolved path —
// mirroring src/main.c load_modules), and prints ACCEPT (no module had a diagnostic) or REJECT (at least
// one did). The differential (tests/run-selfhost.sh) compares the verdict against stage-0's
// `inglec --emit=bytecode` (exit 0 = accept, 65 = a check error).
//
//   inglec --emit=run selfhost/check_dump.ig <file.ig>
//
// WHOLE-PROGRAM, but by CLOSURE-OR rather than a merged global scope. Each module is checked on its OWN
// (exactly as a single-file check), and the program is rejected iff ANY module rejects. This is what lets
// the checker see an imported declaration's own violation — e.g. a `std/web` DIRECT extern with a string
// parameter (stage-0 rejects it, and so does the single-file checker) — closing the examples/web/*.ig
// misses. It is provably false-reject-free: the corpus already proves every single module single-file-checks
// with 0 false-rejects, and OR-ing over the closure only ever turns an ACCEPT into a REJECT.
//
// Why NOT a merged global scope: the checker's name resolution is not MODULE-SCOPED (OFI-073) — two modules
// may legally share a variant/helper name, and one merged scope collides them (verified: merging yielded 84
// false-rejects). Per-module checking sidesteps collisions entirely; module-scoped MERGED checking (via
// checker.ig's check_decls) remains a future option if cross-module type-flow ever needs to be checked.

import "parser" as ps
import "checker" as ck


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


fn main() -> int {
    let argv = args()
    if argv.len() < 1 {
        println("usage: inglec --emit=run selfhost/check_dump.ig <file.ig>")
        return 1
    }
    // BFS the transitive import closure (deduped by resolved path), checking each module on its own; the
    // program REJECTs iff any single module does.
    var queue: [string] = []
    queue.append(argv[0])
    var rejected = false
    var qi = 0
    loop {
        if qi >= queue.len() {
            break
        }
        let src = read_file(queue[qi])
        if ck.check(src) {
            rejected = true
        }
        // enqueue this module's not-yet-seen imports
        let decls = ps.parse(src)
        var di = 0
        loop {
            if di >= decls.len() {
                break
            }
            match decls[di] {
                case DImport(ipath, alias) {
                    let rpath = resolve_import(queue[qi], ipath)
                    var found = false
                    var si = 0
                    loop {
                        if si >= queue.len() {
                            break
                        }
                        if queue[si] == rpath {
                            found = true
                            break
                        }
                        si = si + 1
                    }
                    if found == false {
                        queue.append(rpath)
                    }
                }
                case _ {
                }
            }
            di = di + 1
        }
        qi = qi + 1
    }
    if rejected {
        println("REJECT")
    } else {
        println("ACCEPT")
    }
    return 0
}
