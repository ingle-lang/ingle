// tests/selfhost/symtab.em — Stage A self-hosting spike (docs/design/self-hosting.md §4 "Stage A",
// the "compiler-shaped data spike").
//
// A type checker lives or dies on its symbol tables: a string interner that maps every identifier to a
// small integer id (so later passes compare ints, not strings), a keyword set, and a stack of scopes
// with shadowing. This spike builds all three in pure Ember and drives them at the scale a real checker
// reaches — thousands of symbols, deliberate collisions and repeats — confirming the erased-generic
// `Map`/`Set` containers and the leak-until-exit batch model behave with no surprises on BOTH backends.
//
// Output is a handful of deterministic totals; the harness requires VM == native byte-for-byte.

import "std/map" as mp
import "std/set" as st


// Interner assigns each distinct string a dense integer id, in first-seen order, and can map an id back
// to its name. This is exactly how the compiler will intern identifiers: `intern` is idempotent — the
// same spelling always returns the same id — which is what lets every downstream pass key on a cheap int.
struct Interner {
    table: mp.Map<string, int>
    names: [string]


    fn intern(mut self, s: string) -> int {
        match self.table.get(s) {
            case Some(id) {
                return id
            }
            case None {
                let id = self.names.len()
                self.table.set(s, id)
                self.names.append(s)
                return id
            }
        }
    }


    fn name(self, id: int) -> string {
        return self.names[id]
    }


    fn count(self) -> int {
        return self.names.len()
    }
}


// _digits renders a non-negative int in base 10 without the stdlib, so the spike has no dependency on
// number formatting beyond the language core. Used to manufacture a large family of identifiers.
fn _digits(n: int) -> string {
    if n == 0 {
        return "0"
    }
    var v = n
    var out = ""
    loop {
        if v == 0 {
            break
        }
        out = from_char_code(48 + v % 10) + out
        v = v / 10
    }
    return out
}


// resolve searches a scope stack from the innermost frame outward for `name`, returning the first
// binding found (so an inner frame shadows an outer one) or None. This is the checker's name-resolution
// inner loop, over `[Map<string,int>]` — an array of move-type containers, the OFI-062/063 corner.
fn resolve(scopes: [mp.Map<string, int>], name: string) -> Option<int> {
    var i = scopes.len() - 1
    loop {
        if i < 0 {
            break
        }
        match scopes[i].get(name) {
            case Some(v) {
                return Some(v)
            }
            case None {
            }
        }
        i = i - 1
    }
    return None
}


// check_i / check_s assert a computed result against its expected value. A mismatch returns Err, which —
// because main returns Result — exits the program non-zero (a Fault on the VM) so the harness scores it
// FAIL. They give the differential an oracle: VM == native proves the backends AGREE, these prove they
// agree on the RIGHT answer (e.g. a non-idempotent interner would print 8000/a larger checksum on BOTH
// backends and stay VM==native green — these checks catch that). Expected values are hand-derived.
fn check_i(label: string, got: int, want: int) -> Result<int, string> {
    if got != want {
        return Err("CHECK FAILED [{label}]: expected {want} got {got}")
    }
    return Ok(0)
}


fn check_s(label: string, got: string, want: string) -> Result<int, string> {
    if got != want {
        return Err("CHECK FAILED [{label}]: expected ({want}) got ({got})")
    }
    return Ok(0)
}


fn main() -> Result<int, string> {
    // 1. String interning at scale. Intern N*K identifiers drawn from a vocabulary of N distinct names,
    //    each repeated K times in a fixed pattern. The interner must collapse them to exactly N ids and
    //    hand back the same id every time a spelling recurs.
    var it = Interner{ table: mp.Map<string, int>{ buckets: [], count: 0 }, names: [] }
    let distinct = 2000
    let repeats = 4
    var id_checksum = 0
    var r = 0
    loop {
        if r >= repeats {
            break
        }
        var n = 0
        loop {
            if n >= distinct {
                break
            }
            let sym = "id_" + _digits(n)
            id_checksum = id_checksum + it.intern(sym)
            n = n + 1
        }
        r = r + 1
    }
    println("distinct = {it.count()}")
    let _ = check_i("distinct", it.count(), 2000)?
    // Each pass interns the same `distinct` symbols, so every spelling resolves to a stable id 0..N-1;
    // the per-pass id sum is therefore N*(N-1)/2 = 1 999 000, and the checksum is that times `repeats` = 4.
    println("id_checksum = {id_checksum}")
    let _ = check_i("id_checksum", id_checksum, 7996000)?
    // Round-trip a few ids back to names through the reverse table.
    println("name(0) = {it.name(0)}, name(1999) = {it.name(1999)}")
    let _ = check_s("name(0)", it.name(0), "id_0")?
    let _ = check_s("name(1999)", it.name(1999), "id_1999")?

    // 2. Keyword membership via a Set. Build the reserved-word set once, then probe it.
    var kw = st.Set<string>{ slots: [], count: 0 }
    kw.add("fn")
    kw.add("let")
    kw.add("var")
    kw.add("if")
    kw.add("else")
    kw.add("match")
    kw.add("return")
    kw.add("fn")    // duplicate add is a no-op
    var kw_hits = 0
    var probes: [string] = ["fn", "let", "x", "match", "id_7", "return", "while"]
    var p = 0
    loop {
        if p >= probes.len() {
            break
        }
        if kw.has(probes[p]) {
            kw_hits = kw_hits + 1
        }
        p = p + 1
    }
    println("keyword count = {kw.size()}, hits = {kw_hits}")
    let _ = check_i("keyword count", kw.size(), 7)?
    let _ = check_i("keyword hits", kw_hits, 4)?

    // 3. A scope stack with shadowing — the checker's name resolver over `[Map<string,int>]`.
    var scopes: [mp.Map<string, int>] = []
    var global = mp.Map<string, int>{ buckets: [], count: 0 }
    global.set("pi", 3)
    global.set("e", 2)
    global.set("answer", 42)
    scopes.append(global)
    var local = mp.Map<string, int>{ buckets: [], count: 0 }
    local.set("answer", 99)   // shadows the global
    local.set("tmp", 7)
    scopes.append(local)

    let answer = _show(resolve(scopes, "answer"))   // inner shadows global -> 99
    println("answer = {answer}")
    let _ = check_s("shadow answer", answer, "99")?
    let pi = _show(resolve(scopes, "pi"))           // only in global -> 3
    println("pi = {pi}")
    let _ = check_s("outer pi", pi, "3")?
    let missing = _show(resolve(scopes, "missing")) // bound nowhere
    println("missing = {missing}")
    let _ = check_s("missing", missing, "<unbound>")?

    println("selfhost symtab: OK")
    return Ok(0)
}


// _show renders a resolver result for both printing and checking: the bound value, or "<unbound>".
fn _show(r: Option<int>) -> string {
    match r {
        case Some(v) {
            return "{v}"
        }
        case None {
            return "<unbound>"
        }
    }
}
