// try_recv across threads with the PRODUCER/CONSUMER-IN-BODY shape (the Flare app's transport): a
// worker is spawned INSIDE the nursery and produces onto a channel while the parent polls it with the
// non-blocking try_recv in the same body. This requires SPAWN-AT-SPAWN-TIME — the worker must run
// concurrently with the poll, not at the nursery join (which would poll an empty channel forever).
// Deterministic total; VM and native must agree.

fn sender(ch: Channel<int>) {
    var i = 1
    loop {
        if i > 5 { break }
        send(ch, i * 10)
        i = i + 1
    }
    close(ch)
}


fn main() -> int {
    let ch: Channel<int> = channel(8)
    var total = 0
    var got = 0
    nursery {
        spawn sender(ch)
        loop {
            match try_recv(ch) {
                case Some(v) {
                    total = total + v
                    got = got + 1
                }
                case None {}
            }
            if got >= 5 { break }        // all five produced values consumed
        }
    }
    println("total={total} got={got}")   // 10+20+30+40+50 = 150, 5 values
    return 0
}
