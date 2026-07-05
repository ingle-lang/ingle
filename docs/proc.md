---
title: std/proc — Child processes
nav_order: 10
description: Ingle runs a command and captures what it did — std/proc, a blocking capture-all child process over posix_spawn, with the result as a compile-time-checked linear handle.
---

# Ingle `std/proc` — Child processes

Ingle runs another program through **`std/proc`**: spawn a command, wait for it, and read back its
**exit code, stdout, and stderr**. It is `posix_spawn` + pipes + `poll` under the hood — pure libc, **no
dependency**, so it rides in the **default build** exactly like `read_file`. (Unlike `std/http` and
`std/sqlite`, which link external libraries and need `make net` / `make db`.)

The captured result is a **`resource`**: a `Run` owns its buffers and frees them automatically when its
binding leaves scope, on every path — the same compile-time-checked linear ownership that makes a
SQLite handle impossible to leak.

```ember
import "std/proc" as proc

fn main() -> int {
    let r = proc.run("echo hello && echo oops 1>&2")
    println("code: {r.code()}")     // 0
    println("out:  {r.out()}")      // hello
    println("err:  {r.err()}")      // oops
    if r.ok() {
        println("it worked")
    }
    return 0
}                                    // r frees its captured output here, automatically
```

## The surface

- **`run(cmd: string) -> Run`** — runs `cmd` under `/bin/sh -c`, blocking until it finishes. Because it
  goes through the shell, `cmd` may use pipes, redirection, and globs. Like any shell command, build it
  only from **trusted input** — there is no sandbox (see *Determinism and safety* below).
- **`run_argv(argv: [string]) -> Run`** — the safer sibling for a fixed program plus arguments: it
  **shell-quotes** each element, so a path or argument containing spaces or shell metacharacters is
  passed through literally instead of being re-parsed. Prefer this whenever an argument comes from a
  variable.
- **`Run.code() -> int`** — the exit status: `0` on success, the program's exit code on a normal
  failure, `128 + signal` if it was killed by a signal, or `-1` if it could not be spawned at all.
- **`Run.ok() -> bool`** — `code() == 0`, the common "did it work?" check.
- **`Run.out() -> string`** / **`Run.err() -> string`** — everything the child wrote to stdout / stderr.
- **`Run.combined() -> string`** — stdout then stderr, for a caller that just wants all the output.

## Run it off the render thread

`run` **blocks** until the child exits. In a CLI that is exactly right. In a **live UI** (a Flare app),
call it on a **worker fiber** so a slow child never stalls the 60 fps render loop — the same discipline
`std/http`'s streaming transport uses:

```ember
nursery {
    spawn work(req_ch, resp_ch)      // the worker owns the blocking proc.run(...)
    loop {
        // ... each frame, drain resp_ch with try_recv — never blocks the frame ...
    }
}
```

This is exactly how [Inglenook](https://github.com/ingle-lang/ingle/tree/main/public/inglenook)'s
**Verified Loop** runs the compiler on the model's code — compile, `--check` the contracts, and run it,
all on a worker fiber — then renders the verdict without ever freezing the editor.

## Determinism and safety

A child process is a **nondeterministic input**, like a file read or a network call. Ingle's stance is
its usual one: it **records** what ran (on the execution tape) rather than pretending to gate it. There
is no in-language sandbox — `run` executes what you give it — so untrusted command strings are a
validation problem for the caller (use `run_argv`, or check the command against a contract), not
something the shell layer decides for you. Under `--emit=replay`, `std/proc`'s captured output travels
the same FFI record/replay path as `std/http` and `std/sqlite` (bounded today by the FFI string-replay
limitation, OFI-044 — fixing it lifts all three at once).

`std/proc` is **hosted-only**: a freestanding / bare-metal build has no process model, so a call there
has no implementation (like `read_file`), which is correct — there are no child processes on bare metal.
