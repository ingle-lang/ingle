// Native backend regressions (OFI-158 residual + value-struct-return-with-drops), the shapes that
// surfaced native-compiling std/flare (Flare._apply_zoom). The tests/native harness runs this on BOTH
// backends and diffs — VM is the reference, so a native miscompile shows as a divergence.
//
// 1. Nested value-struct field assignment through a BOXED parent reached by `self.field` (not a bare
//    local): `self.ui.style.text_size = v`. The boxed parent `self.ui` is an ident-rooted field chain,
//    so it is re-emittable (a field read is idempotent) — the OFI-158 guard now allows it.
// 2. A value-struct RETURN from a function that also drops an owned local: the hoist temp must be the
//    raw `em_s<sid>`, not a boxed `Value` (else clang rejects `Value = (em_s){…}`).

struct Style {
    text_size: int
    row_h: int
    pad: int
}

struct Ui {
    data: [int]      // makes Ui a BOXED struct, so `style` is a value-struct field unboxed on read
    style: Style
}

struct App {
    ui: Ui
    zoom: int

    // (1) three nested assignments through the boxed `self.ui` parent — the flare _apply_zoom shape.
    fn apply_zoom(mut self) {
        self.ui.style.text_size = 19 * self.zoom / 100
        self.ui.style.row_h     = 36 * self.zoom / 100
        self.ui.style.pad       = 10 * self.zoom / 100
    }
}


// (2) a value-struct return preceded by an owned-local drop (`tag` is a fresh owned string).
fn make_style(label: string, base: int) -> Style {
    let tag = label + "!"
    return Style { text_size: base, row_h: base * 2, pad: base / 2 }
}


fn main() -> int {
    var a = App { ui: Ui { data: [1, 2], style: Style { text_size: 0, row_h: 0, pad: 0 } }, zoom: 200 }
    a.apply_zoom()
    println("zoom: {a.ui.style.text_size} {a.ui.style.row_h} {a.ui.style.pad}")   // 38 72 20

    let s = make_style("hello", 24)
    println("ret: {s.text_size} {s.row_h} {s.pad}")                               // 24 48 12

    // sequential re-zoom to confirm the writeback re-reads the same boxed Ui each time
    a.zoom = 100
    a.apply_zoom()
    println("re: {a.ui.style.text_size} {a.ui.style.row_h} {a.ui.style.pad}")     // 19 36 10
    return 0
}
