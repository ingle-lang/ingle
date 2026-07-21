// graphics_headless.c — the raylib-free graphics runtime for the WEB build (EMBER_GFX_HEADLESS).
//
// The `web` flavor defines EMBER_GRAPHICS=1 (so Flare type-checks and the gfx builtins resolve) AND
// EMBER_GFX_HEADLESS=1 (so graphics.c's raylib body is compiled out — see its guard). This file then
// supplies every ember_gfx_* symbol as a pure-C stub: no window, no GL, no FreeType, no dependency.
//
// It exists for server-side rendering (SSR): a Flare component's BUILD pass runs here — measure_text
// returns a codepoint-based width estimate, input reads return nothing, draw calls are no-ops — and
// flare.html() walks the resulting layout-intent tree + paint queue to HTML+CSS, which the browser
// lays out. So an Ingle program can serve Flare web pages on a machine with no display and a binary
// that links no game library. (The desktop path is graphics.c, unchanged.)
#include "graphics.h"

typedef int ember_gfx_headless_unit_placeholder;   // keeps the TU non-empty when this flavor is off

#if EMBER_GRAPHICS && EMBER_GFX_HEADLESS

// gfx_estimate_width approximates a text width with no font: ~0.55em average advance per codepoint.
// The HTML backend discards widths (the browser measures and wraps), so this only has to be
// non-degenerate for any build-pass wrap heuristic — it must never be zero (guards against div-by-0).
static int gfx_estimate_width(const char *text, int size) {
    int cps = 0;
    for (const unsigned char *p = (const unsigned char *)text; *p != '\0'; p++) {
        if ((*p & 0xC0) != 0x80) {          // count UTF-8 lead bytes = codepoints
            cps++;
        }
    }
    return cps * size * 55 / 100;
}


// ---- lifecycle: no window is ever opened -----------------------------------------------------------
void ember_gfx_window_open(int width, int height, const char *title) { (void)width; (void)height; (void)title; }
void ember_gfx_window_close(void) {}
int  ember_gfx_should_close(void) { return 0; }         // a server loops on accept(), not on this
void ember_gfx_frame_begin(int bg_color) { (void)bg_color; }
void ember_gfx_frame_end(void) {}
void ember_gfx_set_event_waiting(int on) { (void)on; }
int  ember_gfx_had_input(void) { return 0; }
int  ember_gfx_measure_misses(void) { return 0; }
int  ember_gfx_frame_steps(void) { return 1; }          // deterministic single step (no wall-clock)
int  ember_gfx_frame_capture(const char *path) { (void)path; return 0; }

// ---- text metrics: the SSR oracle (no GL) ----------------------------------------------------------
int  ember_gfx_measure_text(const char *text, int size) { return gfx_estimate_width(text, size); }
int  ember_gfx_text_line_height(int size) { return size * 4 / 3; }
int  ember_gfx_load_font(const char *path) { (void)path; return -1; }
void ember_gfx_set_font(int id) { (void)id; }

// ---- screen: a sane default page box ---------------------------------------------------------------
int  ember_gfx_screen_width(void) { return 1280; }
int  ember_gfx_screen_height(void) { return 800; }

// ---- input: nothing is driving it ------------------------------------------------------------------
int  ember_gfx_key_down(int keycode) { (void)keycode; return 0; }
int  ember_gfx_key_pressed(int keycode) { (void)keycode; return 0; }
int  ember_gfx_key_repeat(int keycode) { (void)keycode; return 0; }
int  ember_gfx_char_pressed(void) { return 0; }
int  ember_gfx_mouse_x(void) { return 0; }
int  ember_gfx_mouse_y(void) { return 0; }
int  ember_gfx_mouse_down(void) { return 0; }
int  ember_gfx_mouse_right_down(void) { return 0; }
int  ember_gfx_mouse_wheel(void) { return 0; }

// ---- draw + paint state: all no-ops (SSR never paints; it walks the queue instead) -----------------
void ember_gfx_set_alpha(int a) { (void)a; }
void ember_gfx_set_layer(int z) { (void)z; }
void ember_gfx_set_cursor(int shape) { (void)shape; }
void ember_gfx_clip_push(int x, int y, int w, int h) { (void)x; (void)y; (void)w; (void)h; }
void ember_gfx_clip_pop(void) {}
void ember_gfx_draw_rect(int x, int y, int w, int h, int color) { (void)x; (void)y; (void)w; (void)h; (void)color; }
void ember_gfx_draw_text(const char *text, int x, int y, int size, int color) { (void)text; (void)x; (void)y; (void)size; (void)color; }
void ember_gfx_fill_round(int x, int y, int w, int h, int radius, int color, int alpha) { (void)x; (void)y; (void)w; (void)h; (void)radius; (void)color; (void)alpha; }
void ember_gfx_stroke_round(int x, int y, int w, int h, int radius, int thick, int color, int alpha) { (void)x; (void)y; (void)w; (void)h; (void)radius; (void)thick; (void)color; (void)alpha; }
void ember_gfx_fill_grad(int x, int y, int w, int h, int radius, int top, int bottom, int alpha) { (void)x; (void)y; (void)w; (void)h; (void)radius; (void)top; (void)bottom; (void)alpha; }
void ember_gfx_shadow(int x, int y, int w, int h, int radius, int alpha) { (void)x; (void)y; (void)w; (void)h; (void)radius; (void)alpha; }
void ember_gfx_fill_circle(int cx, int cy, int r, int color, int alpha) { (void)cx; (void)cy; (void)r; (void)color; (void)alpha; }

// ---- clipboard / files / tape: inert ---------------------------------------------------------------
void ember_gfx_clipboard_set(const char *text) { (void)text; }
const char *ember_gfx_clipboard_get(void) { return ""; }
const char *ember_gfx_dropped_files(void) { return ""; }
int  ember_gfx_tape_open(const char *path) { (void)path; return 0; }
void ember_gfx_tape_close(void) {}
void ember_gfx_tape_mark(const char *kind, const char *label) { (void)kind; (void)label; }

#endif // EMBER_GRAPHICS && EMBER_GFX_HEADLESS
