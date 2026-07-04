// M4d method-CALL fixture: `recv.method(args)`. A method takes a boxed `self`, so a boxed receiver (self,
// or a boxed-struct local) is pushed and CALL'd directly; a MULTI-SLOT receiver is boxed first
// (push slots, BOX_STRUCT), PICK'd, CALL'd, then DROP_UNDER'd. CALL uses the method's fn-index (methods
// interleave with free functions in declaration order); argc counts self.
struct Counter {
    n: int


    fn get(self) -> int {
        return self.n
    }


    fn plus(self, k: int) -> int {
        return self.n + k
    }


    fn twice(self) -> int {
        return self.get() + self.get()
    }
}


struct Tok {
    kind: int
    text: string


    fn kind_of(self) -> int {
        return self.kind
    }
}


fn use_local() -> int {
    let c = Counter { n: 5 }
    return c.get()
}


fn use_param(c: Counter) -> int {
    return c.plus(3)
}


fn boxed_recv(tk: Tok) -> int {
    return tk.kind_of()
}


fn boxed_local(k: int) -> int {
    let tk = Tok { kind: k, text: "x" }
    return tk.kind_of()
}
