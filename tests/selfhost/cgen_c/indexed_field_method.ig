// C-emit OFI-173 un-dodged (OFI-218 Phase 4): a method call on an indexed struct-FIELD-array element, and a
// method on an array-returning METHOD's result. Both previously tripwired the self-hosted C-emit (the
// "unresolved callee" hole), forcing bind-to-local dodges in selfhost/codegen.ig; the C-emit now lowers them
// directly (is_string_expr recognises a string-array field element; is_string_expr no longer mistakes a boxed
// STRUCT binding for a string, so an array-returning method receiver resolves as an array). Byte-identical.
struct Tags {
    parts: [string]

    fn first_len(self) -> int {
        return self.parts[0].len()          // .len() on an indexed string-array FIELD element
    }
    fn head_pieces(self) -> [string] {
        return self.parts[0].split("_")     // .split() on the same — returns a fresh [string]
    }
    fn all(self) -> [string] {
        return self.head_pieces()           // an array-returning method calling another
    }
}
fn main() -> int {
    let t = Tags { parts: ["a_b_c", "d_e"] }
    return t.first_len() + t.head_pieces().len() + t.all().len()   // 5 + 3 + 3 = 11
}
