// M4 codegen fixture: accessing a struct produced by a CALL (an owning temporary, not a borrowed place).
//  - a field read off a boxed call-result uses GET_FIELD_OWNED (extract the field, drop the receiver box);
//  - a METHOD call on a struct returned MULTI-SLOT from a call (an all-scalar return) boxes it (BOX_STRUCT)
//    before the receiver protocol.

struct Tok {
    text: string
    kind: int
}


struct Box2 {
    w: int
    h: int


    fn area(self) -> int {
        return self.w * self.h
    }
}


fn mk_tok() -> Tok {
    return Tok { text: "abc", kind: 1 }
}


fn mk_box() -> Box2 {
    return Box2 { w: 2, h: 3 }
}


fn main() -> int {
    let n = mk_tok().text.len()        // GET_FIELD_OWNED off a boxed call result
    let a = mk_box().area()            // BOX_STRUCT a multi-slot call result, then call the method
    return n + a
}
