// tests/graphics/flare_toast.ig — regression for the toast primitive (f.toast / f.toast_layer), built on
// presence(): a toast is raised once, enters (fade+slide up), holds ~3.3s (200 frames), then auto-dismisses
// (presence → 0) and is dropped from the queue. toast_count() reports how many are alive. Asserts the full
// lifecycle deterministically: present right after raising and while held, gone well after the hold expires.
import "std/draw" as draw
import "std/flare" as flare

fn main() -> int {
    draw.window(300, 200, "flaretoasttest")
    var f = flare.new()
    var frame = 0
    loop {
        if frame == 250 {
            break
        }
        draw.begin(f.bg())
        f.begin()
        if frame == 0 {
            f.toast("Saved")          // raise one toast on the first frame
        }
        f.label("body")
        f.finish()
        f.toast_layer()               // render + age the queue, after finish()
        draw.finish()
        if frame == 5 || frame == 120 || frame == 210 || frame == 245 {
            print("frame {frame}: toasts {f.toast_count()}\n")
        }
        frame = frame + 1
    }
    draw.close()
    return 0
}
