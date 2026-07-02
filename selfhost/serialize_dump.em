// selfhost/serialize_dump.em — driver for the self-hosted bytecode serializer (selfhost/serialize.em). It
// parses an entry program and every module it transitively imports (BFS, deduped — the same load_modules as
// emberc.em / codegen_dump.em), serializes the merged program to the `.emb` container, and writes it via
// from_bytes + write_file.
//
//   emberc --emit=run selfhost/serialize_dump.em <file.em> <out.emb>
//
// tools/embdiff.sh diffs the result against stage 0's `emberc --emit=bytecode-bin -o <a.emb> <file.em>`.

import "parser" as ps
import "serialize" as sz


// Loaded is the merged program plus, parallel to it, the source file each declaration came from (so a
// function's source_file is its OWN module's path, not the entry's — needed for multi-module byte-identity).
struct Loaded {
    decls: [ps.Decl]
    sources: [string]
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


fn main() -> int {
    let argv = args()
    if argv.len() < 2 {
        println("usage: serialize_dump <file.em> <out.emb>")
        exit(1)
    }
    let entry = argv[0]
    let out = argv[1]
    let loaded = load_modules(entry)
    sz.serialize_program(loaded.decls, loaded.sources, out)
    exit(0)
    return 0
}
