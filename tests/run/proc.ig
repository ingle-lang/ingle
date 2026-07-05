// std/proc — run a child process under /bin/sh and capture its stdout, stderr, and exit code. A Run
// is a `resource` (auto-freed on scope exit). Uses only POSIX tools (echo/printf) so the golden is
// stable on macOS + Linux CI. Exercises: stdout + zero exit, stderr + non-zero exit, ok(), and the
// shell-quoting run_argv (each argument stays one literal word).
import "std/proc" as proc
import "std/string" as sstr

fn main() -> int {
    let a = proc.run("echo hello")
    println("out={sstr.trim(a.out())} code={a.code()} ok={a.ok()}")

    let b = proc.run("echo boom 1>&2; exit 5")
    println("err={sstr.trim(b.err())} code={b.code()} ok={b.ok()}")

    let c = proc.run_argv(["printf", "%s-%s", "x", "y"])
    println("argv={c.out()} ok={c.ok()}")

    return 0
}
