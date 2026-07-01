# Kernel / freestanding runtime — kickoff brief (PROPOSED)

> **Status: planning.** This is the seed for the dedicated kernel chat, written at the moment the
> native C-emit **self-hosting reproduction fixed point** landed (2026-07-01). It lays out the plan and the
> **design forks to confirm** — nothing here is decided; the first job in the kernel chat is to confirm the
> target and scope with Karl, then build the smallest possible bare-metal spike. Per CLAUDE.md: discuss
> design before implementing.

## Why now

Writing an **OS kernel in Ember** is the north star (see [[ember-kernel-endgame]] in memory / MANIFESTO). The
self-hosting campaign was the maturity play and it's done: the native **C-emit backend** (`selfhost/cgen_c.em`,
`emberc --emit=c` / `-o`) now reproduces the whole compiler byte-identical **and rebuilds itself into a
native binary**. That C-emit backend is the **on-ramp to bare-metal codegen** — the same AST→C path, but
producing code that runs with **no OS and no libc**.

## The gaps between "compiles to C" and "boots on bare metal"

1. **Freestanding runtime.** The current `em_*` runtime (`src/runtime.c`, `src/vm.c`) uses `malloc`/`free`,
   `printf`/stdio, `pthread`, etc. Bare metal has none of these. A freestanding target needs either **no
   runtime at all** (a scalar-only subset) or a **tiny freestanding runtime** (a bump allocator over a fixed
   region, no stdio, MMIO for output).
2. **A low/no-alloc language subset.** A kernel can't lean on a general heap for everything. We want to know
   *exactly* which Ember constructs need the allocator (strings, arrays, boxed structs, enums with payloads,
   closures) vs which are heap-free (scalars, value structs, `extern "c"` calls). The first spike stays
   entirely in the heap-free subset.
3. **Bare-metal codegen.** A `--freestanding` / `--target=bare` emit mode: no libc includes, a custom entry
   (`_start` / `kmain`), and MMIO instead of stdio. Most of the AST→C machinery is reused unchanged; the
   difference is the *preamble* (includes, runtime shims) and the *entry*.
4. **MMIO + a boot stub.** Reading/writing hardware registers (via `extern "c"` C helpers to start, an
   intrinsic later) and a tiny assembly `_start` that sets up a stack and branches to Ember `main`.

## Toolchain reality (checked 2026-07-01 on Karl's arm64 Mac)

- **Apple clang cross-compiles bare-metal aarch64 with zero extra install:**
  `clang -target aarch64-none-elf -ffreestanding -nostdlib …` works. **No cross-gcc needed.**
- **`qemu-system-aarch64` is NOT installed** → `brew install qemu` (per "install the tool, don't work
  around"). This is the only missing piece.
- **`extern "c"` FFI reaches the native C-emit backend** (`examples/16_ffi.em`) — so an Ember program can
  `extern "c" fn uart_putc(c: i32)` and we supply the C body in the freestanding shim. That is the MMIO
  output mechanism for the first spike.

## Design forks to confirm FIRST (in the kernel chat)

1. **Target board.** **Recommended: QEMU `aarch64 virt`** — matches Karl's arm64 Mac, trivial to install,
   a well-documented **PL011 UART** at `0x0900_0000` for output, RAM at `0x4000_0000`, `-kernel` loads a flat
   binary at `0x4008_0000`. Alternatives: `riscv virt` (simplest ISA, also fine) or x86_64 (more boot
   ceremony — BIOS/multiboot). arm64 virt is the least-friction path to first light.
2. **Toolchain.** **Recommended: Apple clang cross** (`-target aarch64-none-elf -ffreestanding -nostdlib`),
   already present — vs a `brew install`ed `aarch64-elf-gcc`. Clang cross is zero-install.
3. **First-spike scope.** **Recommended: UART "hello" only** — the smallest program that exercises the WHOLE
   seam (freestanding codegen → boot stub → linker script → QEMU → MMIO). Defer the allocator, exceptions,
   and interrupts until "hello" boots.

## The first milestone — "Hello from Ember on bare metal"

A minimal Ember program compiled through a freestanding path that **boots on QEMU `aarch64 virt` and prints a
string to the PL011 UART**, with **no libc and no heap**. This proves the entire toolchain seam; everything
after (allocator, interrupts, the no-alloc subset, a richer runtime) is incremental.

### Concrete steps to first light

1. `brew install qemu` (the only missing tool).
2. **Heap-free Ember source** (`kernel/hello.em` or similar): a `main` that calls `extern "c" fn uart_putc`
   in a loop over the bytes of a message. First cut can even hardcode the bytes (no string type) to stay
   100% heap-free; a fixed-size byte array is the next step.
3. **Freestanding emit.** Start the SIMPLEST way possible before touching the compiler: hand-write a tiny
   `kernel/rt.c` shim (`uart_putc` writing to `*(volatile uint32_t*)0x09000000 = c;`, plus any `em_*`
   stubs the emitted C references for the heap-free subset — ideally none) and compile the stock
   `emberc --emit=c hello.em` output against it with `-ffreestanding -nostdlib`. If the emitted C pulls in
   libc/runtime the heap-free subset shouldn't need, that tells us exactly what a `--freestanding` preamble
   must strip — the first real compiler task.
4. **Boot stub + linker script.** `kernel/boot.S` (aarch64 `_start`: set `sp`, `bl main`, then spin) and
   `kernel/kernel.ld` (entry `_start`, `.text`/`.rodata`/`.data`/`.bss` from `0x40080000`).
5. **Link + run.** `clang -target aarch64-none-elf -ffreestanding -nostdlib -T kernel.ld boot.S hello.c rt.c
   -o kernel.elf`; `qemu-system-aarch64 -M virt -cpu cortex-a53 -nographic -kernel kernel.elf`.
6. **Verify.** QEMU's stdout shows the message (the PL011 UART is wired to the terminal under `-nographic`).

### Then, incrementally (post-hello, separate milestones)

- A **`--freestanding` emit mode** in `main.c` / `cgen_c` (strip libc includes, emit `_start` glue or a
  documented entry contract) so the C-emit path targets bare metal directly, not via a hand-shim.
- Map the **heap-free subset** precisely (which constructs emit `em_*` runtime calls) → a **tiny freestanding
  runtime** (a bump allocator over a fixed `.bss` arena, no stdio) to unlock strings/arrays/structs on bare
  metal.
- **MMIO/asm intrinsics** (volatile load/store, barriers) so hardware access isn't via `extern "c"` forever.
- Interrupts / the exception vector table; a timer; then the actual kernel surface (memory map, a trivial
  scheduler) — all in Ember.

## Guardrails (from MANIFESTO / CLAUDE.md)

- Default build stays **dependency-free**; the kernel target is **opt-in** (a build flag / separate make
  target), like `make graphics` / `make net`.
- Every increment lands with a **runnable** artifact + a test (a QEMU-run smoke test that greps the UART
  output), mirroring the differential discipline that carried self-hosting.
- Freestanding codegen is a **new emit target**, not a rewrite — reuse the AST→C machinery; the delta is the
  preamble + entry + which runtime symbols exist.
