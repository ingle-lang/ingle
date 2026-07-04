// tests/graphics/flare_ellipsis.ig — regression for single-line text-overflow: ellipsis (std/flare).
// A heading, a label, and a muted line are each given text far wider than the narrow window. Each must
// TRIM to its solved box width with a trailing "…" instead of spilling off-screen, while a short label
// that already fits is left untouched. The tape records one draw_text per line carrying the SHOWN text,
// so the golden asserts the truncation directly. (Trim points depend on FreeType glyph widths, so this
// golden is font-version-sensitive, like the rest of the suite — OFI-068.)
import "std/draw" as draw
import "std/flare" as flare

fn main() -> int {
    draw.window(360, 260, "ellipsistest")
    var f = flare.new()
    f.use_dark()
    draw.tape_on("/tmp/ember_ellipsis_test.tape")

    draw.begin(f.bg())
    f.begin()
    f.heading("A heading too wide to fit this narrow window")
    f.label("A single-line label whose text far exceeds the column width and must trim with an ellipsis.")
    f.text_muted("A muted line that is also too long to fit and should ellipsize.")
    f.label("Fits.")
    f.finish()
    draw.finish()

    draw.tape_off()
    draw.close()
    print(read_file("/tmp/ember_ellipsis_test.tape"))
    return 0
}
