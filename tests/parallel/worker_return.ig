// Regression for OFI-183: a spawned worker fiber must run with a fully-initialised VM. Each nursery
// iteration creates a FRESH worker VM; the worker does recursive (multi-frame) work and returns it over a
// channel. With an uninitialised `reentry_floor`, the worker's OP_RETURNs either bailed out of run() early
// (result never sent → main hangs) or ran past frame_count 0 (crash). The returned total is the assertion:
// 5 rounds x 4 sends x compute(10)=55  ==  1100.
fn compute(n: int) -> int {
    if n <= 1 {
        return 1
    }
    return n + compute(n - 1)
}

fn worker(req: Channel<int>, resp: Channel<int>) {
    loop {
        match recv(req) {
            case Some(n) { send(resp, compute(n)) }
            case None { break }
        }
    }
}

fn main() -> int {
    var total = 0
    var r = 0
    loop {
        if r == 5 {
            break
        }
        let req: Channel<int> = channel(2)
        let resp: Channel<int> = channel(2)
        nursery {
            spawn worker(req, resp)
            var i = 0
            loop {
                if i == 4 {
                    break
                }
                send(req, 10)
                match recv(resp) {
                    case Some(v) { total = total + v }
                    case None {}
                }
                i = i + 1
            }
            close(req)
        }
        r = r + 1
    }
    return total
}
