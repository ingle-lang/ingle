// M4d method-bodies fixture: a method's `self` is a BOXED struct in slot 0 (so `self.field` is GET_FIELD
// even for an all-scalar struct) and a borrow (not dropped); `mut self` field assignment is SET_FIELD.
// The disassembly header is `Struct.method`, arity counts `self`. (Method CALLS are a separate step.)
struct Counter {
    n: int


    fn get(self) -> int {
        return self.n
    }


    fn bumped(self) -> int {
        return self.n + 1
    }


    fn reset(mut self) {
        self.n = 0
    }


    fn set_to(mut self, k: int) {
        self.n = k
    }
}


struct Tok {
    kind: int
    text: string


    fn kind_of(self) -> int {
        return self.kind
    }


    fn text_of(self) -> string {
        return self.text
    }


    fn retag(mut self, t: string) {
        self.text = t
    }
}
