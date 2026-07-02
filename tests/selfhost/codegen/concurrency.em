// M4 codegen fixture: structured concurrency. Exercises every channel/task opcode the self-hosted codegen
// lowers — channel(cap) -> CHANNEL_NEW, send(ch, v) -> SEND, recv(ch) -> RECV (which carries the Some enum
// id + Some/None tags to build Option<T> at runtime), close(ch) -> CLOSE, and `nursery { spawn f(a) }` ->
// NURSERY_BEGIN / SPAWN <fn> <argslots> / NURSERY_END. A Channel<T> `let`/param is an OWNED refcounted handle
// (dropped at every exit; INCREF'd when passed to a spawn/call). Output is deterministic: the producer runs
// to completion inside the nursery (the join is structural), THEN main drains the buffered channel and sums —
// so the total does not depend on task scheduling.
enum Option<T> {
    Some(value: T)
    None
}


fn produce(ch: Channel<int>) {
    var i = 1
    loop {
        if i > 5 {
            break
        }
        send(ch, i * 10)
        i = i + 1
    }
    close(ch)                        // no more values; recv will yield None once drained
}


fn drain(ch: Channel<int>) -> int {
    var total = 0
    loop {
        match recv(ch) {
            case Some(n) {
                total = total + n
            }
            case None {
                break
            }
        }
    }
    return total
}


fn main() -> int {
    let ch: Channel<int> = channel(8)
    nursery {
        spawn produce(ch)            // runs to completion before the block exits
    }
    println("total={drain(ch)}")     // 10 + 20 + 30 + 40 + 50 = 150
    return 0
}
