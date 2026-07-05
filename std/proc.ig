// std/proc — run a child process and capture what it did. A `Run` OWNS the captured result of one
// command (its exit code + stdout + stderr); it is a `resource`, so it FREES itself when its binding
// leaves scope, on every path — the captured buffers can never leak. This is the blocking, capture-
// everything shape: `run(cmd)` spawns `/bin/sh -c <cmd>`, waits for it, and hands back a Run to read.
// It is meant to be called on a WORKER FIBER (spawn/nursery) when the caller is a live UI, so a slow
// child never stalls the render thread — the same discipline std/http's stream_worker uses.
//
//   let r = proc.run("inglec --emit=run " + path)
//   if r.ok() {
//       println(r.out())
//   } else {
//       println("exit {r.code()}: {r.err()}")
//   }
//
// The C primitives (posix_spawn + pipe + poll, all libc — no dependency) live in src/cextern.c and are
// in the DEFAULT build, like read_file. The captured stdout/stderr cross the boundary copied-and-freed.
import "std/string" as sstr


// The C FFI leaf layer (src/cextern.c). proc_run returns an opaque result handle; the accessors read
// it; proc_free (taking the handle by `move`, so the compiler forbids any use after) releases it.
extern "c" {
    fn proc_run(cmd: string) -> Ptr
    fn proc_exit(h: Ptr) -> i64
    fn proc_stdout(h: Ptr) -> string
    fn proc_stderr(h: Ptr) -> string
    fn proc_free(move h: Ptr) -> i64
}


// Run OWNS one command's captured result. It is a `resource`: its handle frees itself (proc_free) when
// the Run's binding leaves scope, on every path — so a captured process result can never leak. Obtain
// one with run(); read it with code()/out()/err()/ok(); never free it by hand (the compiler does).
resource struct Run {
    h: Ptr


    fn drop(self) {
        let _ = proc_free(self.h)
    }


    // code returns the child's exit status: 0 on success, its exit code on a normal failure, 128+signal
    // if it was killed by a signal, or -1 if the process could not be spawned at all.
    fn code(self) -> int {
        return proc_exit(self.h)
    }


    // ok reports whether the child exited successfully (status 0) — the common "did it work?" check.
    fn ok(self) -> bool {
        return proc_exit(self.h) == 0
    }


    // out returns everything the child wrote to STDOUT (empty if it wrote nothing).
    fn out(self) -> string {
        return proc_stdout(self.h)
    }


    // err returns everything the child wrote to STDERR — where a compiler's diagnostics usually go.
    fn err(self) -> string {
        return proc_stderr(self.h)
    }


    // combined returns stdout followed by stderr, so a caller that just wants "all the output" (a log
    // view) needn't join them itself. Skips the separator when either stream is empty.
    fn combined(self) -> string {
        let o = proc_stdout(self.h)
        let e = proc_stderr(self.h)
        if o.len() == 0 {
            return e
        }
        if e.len() == 0 {
            return o
        }
        return o + "\n" + e
    }
}


// run executes `cmd` under `/bin/sh -c` and BLOCKS until it finishes, returning a Run that captures its
// exit code, stdout, and stderr. Because it runs through the shell, `cmd` may use pipes, redirection,
// and quoting — and, like any shell command, MUST be built from trusted input (there is no sandbox;
// std/proc records what ran on the tape, it does not gate it). Call it on a worker fiber from a UI.
fn run(cmd: string) -> Run {
    return Run { h: proc_run(cmd) }
}


// run_argv is the safer sibling for a fixed program + arguments: it shell-QUOTES each argv element
// (wrapping it in single quotes, escaping any embedded quote) and joins them, so a path or argument
// containing spaces or shell metacharacters is passed through literally instead of being re-parsed by
// the shell. Prefer this over run() when any argument comes from a variable (a filename, user input).
fn run_argv(argv: [string]) -> Run {
    var cmd = ""
    var i = 0
    loop {
        if i == argv.len() {
            break
        }
        if i > 0 {
            cmd = cmd + " "
        }
        cmd = cmd + shell_quote(argv[i])
        i = i + 1
    }
    return run(cmd)
}


// shell_quote wraps `s` in single quotes for /bin/sh, rendering every embedded single quote as the
// classic `'\''` (close-quote, escaped-quote, reopen-quote) so the result is one literal shell word.
fn shell_quote(s: string) -> string {
    return "'" + sstr.replace(s, "'", "'\\''") + "'"
}
