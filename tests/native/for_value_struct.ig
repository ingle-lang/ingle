// for_value_struct.ig — OFI-215 regression: `for e in [ValueStruct]` binds each element as an owned
// per-iteration copy. Was a heap-buffer-overflow: array_box read the struct's first field as garbage
// (value_box had no AEK_INLINE_STRUCT case), so the loop var was junk and any field read / append
// crashed. Exercises a read-only body, a consuming (append) body — which CLONES, so the source array
// stays live — an int-field struct, a nested loop over the same array, and the always-correct arr[i].
struct TE {
    path: string
    id: string
}

struct IntS {
    n: int
    m: int
}

fn main() -> int {
    var s: [TE] = []
    s.append(TE { path: "a", id: "x" })
    s.append(TE { path: "b", id: "y" })

    // read-only body
    var joined = ""
    for e in s {
        joined = joined + e.path + "=" + e.id + ";"
    }
    println("read={joined}")

    // consuming body: append clones the element, so the source `s` is untouched
    var d: [TE] = []
    for e in s {
        d.append(e)
    }
    println("moved={d.len()} src={s.len()}")

    // int-field struct + a nested loop over the same array
    var ii: [IntS] = []
    ii.append(IntS { n: 1, m: 10 })
    ii.append(IntS { n: 2, m: 20 })
    var sum = 0
    for a in ii {
        for b in ii {
            sum = sum + a.n * b.m
        }
    }
    println("sum={sum}")

    // arr[i] — the path that was always correct, as a cross-check
    println("idx={ii[1].n},{ii[1].m}")

    // indexed `for (i, e)` form + a NESTED inline-struct field, and an empty array
    var os: [Outer] = []
    os.append(Outer { tag: "p", inner: IntS { n: 5, m: 6 } })
    os.append(Outer { tag: "q", inner: IntS { n: 7, m: 8 } })
    for (i, e) in os {
        println("{i}:{e.tag}:{e.inner.n},{e.inner.m}")
    }
    var empty: [Outer] = []
    var cnt = 0
    for e in empty {
        cnt = cnt + 1
    }
    println("empty={cnt}")
    return 0
}


// Outer holds a NESTED inline value struct (IntS) — exercises struct_elem_retain over a boxed-free
// nested field on the per-iteration copy.
struct Outer {
    tag: string
    inner: IntS
}
