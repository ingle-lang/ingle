// selfhost/cgen_c_dump.em — the M5 C-emit differential driver. Parses the entry file + every transitively
// imported module (BFS, deduped — mirroring src/main.c load_modules), merges their declarations, and emits
// the whole C translation unit via selfhost/cgen_c.em, byte-identical to stage-0 `emberc --emit=c`.
//
//   emberc --emit=run selfhost/cgen_c_dump.em <file.em>

import "parser" as ps
import "cgen_c" as cc


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


fn main() -> int {
    let argv = args()
    if argv.len() < 1 {
        println("usage: emberc --emit=run selfhost/cgen_c_dump.em <file.em>")
        return 1
    }
    cc.emit_program(load_modules(argv[0]), argv[0])
    return 0
}
