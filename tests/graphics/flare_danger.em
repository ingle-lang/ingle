// tests/graphics/flare_danger.em — regression for the button family, incl. the destructive variant
// (std/flare). A secondary (panel), a primary (clay accent), and a danger (red) button render in one
// row; the tape records each one's fill colour, so the golden asserts that f.danger() paints with the
// theme's `danger` token and its text in `danger_ink` — distinct from primary's accent.
import "std/draw" as draw
import "std/flare" as flare

fn main() -> int {
    draw.window(420, 160, "dangertest")
    var f = flare.new()
    f.use_dark()
    draw.tape_on("/tmp/ember_danger_test.tape")

    draw.begin(f.bg())
    f.begin()
    f.row(flare.START, flare.CENTER)
    if f.button("Cancel") { }
    if f.primary("Save") { }
    if f.danger("Delete") { }
    f.end()
    f.finish()
    draw.finish()

    draw.tape_off()
    draw.close()
    print(read_file("/tmp/ember_danger_test.tape"))
    return 0
}
