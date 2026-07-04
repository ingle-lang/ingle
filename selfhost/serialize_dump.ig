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


fn load_modules(entry: string) -> Loaded {
    var seen: [string] = []
    var queue: [string] = []
    var combined: [ps.Decl] = []
    var sources: [string] = []
    var mod_of: [int] = []
    var imp_from: [int] = []
    var imp_alias: [string] = []
    var imp_to: [int] = []
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
