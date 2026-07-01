// kernel/hello.em — Ember on bare metal (kernel milestones 1–2; docs/design/kernel-freestanding.md).
//
// A freestanding Ember program that boots on QEMU `aarch64 virt` with NO OS and NO libc. Milestone 1
// proved the scalar subset (heap-free, output via a direct `extern "c"` to the UART); milestone 2
// links the REAL Ember runtime compiled `-DEMBER_FREESTANDING` over a bump allocator, so HEAP-BACKED
// values work too: arrays, strings, string interpolation, and `println` (its output funnels through
// the platform's fwrite -> the PL011 UART). `main`'s int result is the process exit code.
fn main() -> int {
    // Arrays allocate on the freestanding bump arena; the loop sums them.
    var xs: [int] = []
    xs.append(10)
    xs.append(20)
    xs.append(12)

    var sum = 0
    var i = 0
    loop {
        if i == xs.len() { break }
        sum = sum + xs[i]
        i = i + 1
    }

    // Strings + interpolation + println — the runtime's heap + print path, on bare metal.
    println("Hello from Ember — running on bare metal with a heap!")
    println("sum of [10, 20, 12] = {sum}")

    // The freestanding entry surfaces this as the exit code; the boot stub forwards it via
    // semihosting, so QEMU exits 42 — a value computed by Ember, with aggregates, on bare metal.
    return sum
}
