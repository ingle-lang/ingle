// kernel/timerdemo.em — the timer/interrupt demo (kernel milestone 4;
// docs/design/kernel-freestanding.md). Brings up the GIC + generic timer, then busy-polls a tick
// counter that ONLY advances from the timer IRQ handler (kernel/timer.c em_irq). Seeing it climb
// proves asynchronous hardware interrupts are being taken and handled on bare metal. Returns the tick
// count as the exit code (5), the boot stub forwards it via semihosting.
extern "c" {
    fn timer_init()
    fn tick_count() -> int
}


fn main() -> int {
    timer_init()
    println("timer: waiting for interrupts...")

    var last = 0
    loop {
        let t = tick_count()      // advanced only by the IRQ handler, asynchronously
        if t > last {
            println("tick {t}")
            last = t
        }
        if last == 5 { break }
    }

    println("timer: 5 ticks delivered by IRQ — interrupts work!")
    return last
}
