// vectors.S — the aarch64 EL1 exception vector table (kernel milestone 3;
// docs/design/kernel-freestanding.md).
//
// Without a vector table, any CPU exception (a data abort, an undefined instruction, …) branches to
// VBAR's reset value and — with nothing there — spins forever: a silent hang, which is how the M1
// FP/SIMD trap and the M2 alignment fault first presented. This table catches all 16 exception
// entries and routes them to a common stub that reads the syndrome registers (ESR/ELR/FAR) and calls
// the C handler em_exception (kernel/platform.c), which prints a diagnostic panic and halts — so a
// fault is READABLE, not a mystery.
//
// The table must be 2 KiB-aligned (VBAR_EL1 requires bits[10:0]==0); each of the 16 entries occupies
// 0x80 bytes. boot.S sets VBAR_EL1 = vector_table once the stack is up.

.macro VECTOR kind
.align 7                         // each entry is 0x80 bytes
    mov     x0, #\kind           // the vector index (0..15), for the panic message
    b       exc_common
.endm

.section .text
.align 11                        // 2 KiB alignment for VBAR_EL1
.global vector_table
vector_table:
    VECTOR 0        // Current EL, SP0     : Synchronous
    VECTOR 1        //                     : IRQ
    VECTOR 2        //                     : FIQ
    VECTOR 3        //                     : SError
    VECTOR 4        // Current EL, SPx      : Synchronous  <- EL1h faults land here
.align 7
    b       irq_entry   //                 : IRQ  <- the timer interrupt lands here (kernel M4)
    VECTOR 6        //                     : FIQ
    VECTOR 7        //                     : SError
    VECTOR 8        // Lower EL, AArch64    : Synchronous
    VECTOR 9        //                     : IRQ
    VECTOR 10       //                     : FIQ
    VECTOR 11       //                     : SError
    VECTOR 12       // Lower EL, AArch32    : Synchronous
    VECTOR 13       //                     : IRQ
    VECTOR 14       //                     : FIQ
    VECTOR 15       //                     : SError

// Common stub: gather the exception syndrome and hand off to the C handler. We never return to the
// faulting context (there is nothing to recover to), so no register state is preserved — em_exception
// prints and halts. SP is SP_EL1 (the boot stack, 16-aligned), so the C call's ABI is satisfied.
exc_common:
    mrs     x1, esr_el1          // exception syndrome (EC in [31:26])
    mrs     x2, elr_el1          // faulting instruction address
    mrs     x3, far_el1          // faulting data address (for aborts)
    bl      em_exception
0:  wfe
    b       0b

// IRQ entry (kernel M4): unlike a fault, an IRQ RETURNS to the interrupted code, so it must preserve
// ALL general-purpose registers (the interrupt can land on any instruction) and finish with `eret`.
// Save x0..x30 (256-byte frame, 16-aligned), call the C handler em_irq, restore, and return. em_irq
// is integer-only, so no FP/SIMD state is saved.
irq_entry:
    sub     sp, sp, #256
    stp     x0, x1,   [sp, #0]
    stp     x2, x3,   [sp, #16]
    stp     x4, x5,   [sp, #32]
    stp     x6, x7,   [sp, #48]
    stp     x8, x9,   [sp, #64]
    stp     x10, x11, [sp, #80]
    stp     x12, x13, [sp, #96]
    stp     x14, x15, [sp, #112]
    stp     x16, x17, [sp, #128]
    stp     x18, x19, [sp, #144]
    stp     x20, x21, [sp, #160]
    stp     x22, x23, [sp, #176]
    stp     x24, x25, [sp, #192]
    stp     x26, x27, [sp, #208]
    stp     x28, x29, [sp, #224]
    str     x30,      [sp, #240]
    bl      em_irq
    ldp     x0, x1,   [sp, #0]
    ldp     x2, x3,   [sp, #16]
    ldp     x4, x5,   [sp, #32]
    ldp     x6, x7,   [sp, #48]
    ldp     x8, x9,   [sp, #64]
    ldp     x10, x11, [sp, #80]
    ldp     x12, x13, [sp, #96]
    ldp     x14, x15, [sp, #112]
    ldp     x16, x17, [sp, #128]
    ldp     x18, x19, [sp, #144]
    ldp     x20, x21, [sp, #160]
    ldp     x22, x23, [sp, #176]
    ldp     x24, x25, [sp, #192]
    ldp     x26, x27, [sp, #208]
    ldp     x28, x29, [sp, #224]
    ldr     x30,      [sp, #240]
    add     sp, sp, #256
    eret
