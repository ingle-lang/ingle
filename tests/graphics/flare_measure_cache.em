// tests/graphics/flare_measure_cache.em — regression for the measure_text cache (Fix A). Text metrics are a
// pure function of (string, font, size, scale), but MeasureTextEx walks every glyph and an immediate-mode UI
// re-measures the SAME strings every frame (twice — layout then paint). The cache memoises the width so a warm
// frame does ~zero FreeType work. measure_misses() reports the real FreeType measures since the last
// frame_begin; this test asserts a string MISSES on first sight and HITS (0 misses) when re-measured next
// frame, while a never-seen string still misses once. The 37 paint goldens already prove the cached WIDTHS
// are correct (byte-identical); this proves the cache actually warms, which a correct-but-never-hitting
// regression would not. Font slot + size are reset by frame_begin, so both frames key the cache identically.
import "std/draw" as draw


fn main() -> int {
    draw.window(200, 100, "measurecachetest")

    // Frame 1: first measure of "Hello world" is a cold MISS.
    draw.begin(0)
    let _w1 = measure_text("Hello world", 19)
    print("f1 misses {measure_misses()}\n")
    draw.finish()

    // Frame 2: the SAME (string, font, size) now HITS — zero FreeType — and a fresh string misses exactly once.
    draw.begin(0)
    let _w2 = measure_text("Hello world", 19)
    print("f2 repeat {measure_misses()}\n")
    let _w3 = measure_text("A brand new string", 19)
    print("f2 novel {measure_misses()}\n")
    draw.finish()

    draw.close()
    return 0
}
