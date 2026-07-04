// M4 codegen fixture: generic-struct MONOMORPHIZATION. Each distinct instantiation of a generic struct
// (`Box<int>`, `Box<string>`, `Pair<int>`) is its OWN runtime struct type, numbered AFTER the declared
// structs in first-construction (pre-order) order. The NEW_STRUCT *operand* is that instance id
// (struct_count + first-seen index); the field LAYOUT (count/order) is shared with the generic base. A
// second construction of an already-seen instantiation reuses the same id — it does not allocate a new one.

struct Box<T> {
    value: T
    line: int
}


struct Pair<T> {
    a: T
    b: T
}


fn boxed_int(n: int) -> Box<int> {
    return Box<int>{ value: n, line: 0 }       // first instance seen (pre-order) -> id = struct_count + 0
}


fn main() -> int {
    let bs = Box<string>{ value: "hi", line: 1 } // second instance -> id = struct_count + 1
    let bi = Box<int>{ value: 9, line: 2 }       // reuses Box<int>  -> same id as boxed_int's
    let p = Pair<int>{ a: 4, b: 5 }              // third instance  -> id = struct_count + 2
    return bi.value + p.a + p.b + bs.line
}
