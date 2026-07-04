// tests/selfhost/nested_store.ig — writing a field of a transient-copy place (self-hosting).
//
// Assigning `target = value` where the target's OBJECT reads as a COPY — an INLINE-struct array element
// (`arr[i].leaf = v`) or a nested INLINE struct field (`self.style.pad = v`) — cannot use a plain SET_FIELD:
// that mutates the transient copy and loses it. The backend must materialise the object into a scratch slot,
// SET_FIELD the leaf on it, then write the modified copy BACK (via SET_INDEX for an array element; recursively
// for a nested field). Before that path the self-hosted codegen dropped the whole statement. Output is
// deterministic; the harness requires VM == native.


struct Style {
    pad: int
    gap: int
}


struct Box {
    w: int
    h: int
}


struct Scene {
    boxes: [Box]
    style: Style


    // mutate an INLINE-struct ARRAY element's field: boxes[i].w = ...
    fn widen(mut self, i: int, by: int) {
        self.boxes[i].w = self.boxes[i].w + by
    }


    // mutate a NESTED INLINE struct field: self.style.pad = ...
    fn set_pad(mut self, p: int) {
        self.style.pad = p
    }


    fn total_w(self) -> int {
        var sum = 0
        var i = 0
        loop {
            if i >= self.boxes.len() {
                break
            }
            sum = sum + self.boxes[i].w
            i = i + 1
        }
        return sum
    }
}


fn main() {
    var s = Scene { boxes: [], style: Style { pad: 0, gap: 4 } }
    s.boxes.append(Box { w: 10, h: 1 })
    s.boxes.append(Box { w: 20, h: 2 })
    s.boxes.append(Box { w: 30, h: 3 })
    s.widen(0, 5)
    s.widen(2, 100)
    s.set_pad(7)
    println("total_w = {s.total_w()}")
    println("pad = {s.style.pad}")
    println("nested store: OK")
}
