// multi-module fixture (base): an enum + struct + constructor/accessor functions imported by mm_mid/mm_top.
// Exercises the merged symbol universe — stable enum variant tags + struct layout across module boundaries.
enum Kind {
    KA
    KB
}


struct Node {
    id: int
    kind: Kind
}


fn ka() -> Kind {
    return KA
}


fn name(k: Kind) -> int {
    match k {
        case KA {
            return 1
        }
        case KB {
            return 2
        }
    }
}
