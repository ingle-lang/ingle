// tests/graphics/flare_idle.ig — regression for the idle frame-gating support. f.is_animating() reports
// whether a spring/FLIP moved this frame: it is the signal the app reads after finish() to choose between
// free-running and event-waiting (set_event_waiting), so a static UI burns ~0% CPU instead of redrawing 60
// identical frames/second. A spring is AT REST the frame it is first seen (it snaps to the target, no jump
// from zero) and IN FLIGHT the frame its target moves. Also smoke-tests that the set_event_waiting()/
// had_input() builtins are wired through the checker + VM. NOTE: never ENABLE event-waiting before a finish()
// in a headless run — EndDrawing would block on an event that never arrives; we only enable it last, with no
// finish after, so CloseWindow tears it down harmlessly.
import "std/draw" as draw
import "std/flare" as flare


fn main() -> int {
    draw.window(200, 120, "flareidletest")

    var f = flare.new()

    // Frame 1: first sight of the "x" spring → it snaps to 0.0, nothing moves → not animating.
    draw.begin(f.bg())
    f.begin()
    let _a = f.spring("x", 0.0)
    f.finish()
    draw.finish()
    let rest = f.is_animating()
    print("rest {rest}\n")

    // Frame 2: move the target → the spring is now in flight → animating.
    draw.begin(f.bg())
    f.begin()
    let _b = f.spring("x", 160.0)
    f.finish()
    draw.finish()
    let moving = f.is_animating()
    print("moving {moving}\n")

    // The idle builtins are callable (resolved by the checker, dispatched by the VM). had_input() just
    // returns (its value depends on the window manager, so it is not asserted); set_event_waiting(false)
    // is the safe free-run state; enabling it is the very last thing, with no finish to block on.
    let _seen = had_input()
    set_event_waiting(false)
    set_event_waiting(true)

    // The real-time animation controls are wired (frame_steps() builtin + the set_realtime gate). We only
    // smoke-test that they are callable here — enabling realtime BEFORE the spring asserts above would make
    // the fixed-timestep physics depend on wall-clock frame timing and break determinism, which is the whole
    // reason the catch-up is opt-in. frame_steps() returns >= 1 (its value is wall-time-dependent, not asserted).
    let _steps = frame_steps()
    f.set_realtime(true)
    f.set_realtime(false)

    draw.close()
    return 0
}
