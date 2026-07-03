// M4 codegen fixture: `extern "c"` FFI with Ptr / buffer / move. A `Ptr` return (fopen) binds a LINEAR
// handle — a plain non-droppable slot (must-consume, so NOT auto-dropped at exit); a `[u8]` buffer arg is a
// borrow; a `move Ptr` param (fclose) move-CONSUMES its arg — the call site zeroes the slot (GET_LOCAL;
// CONST 0; SET_LOCAL; POP) so the handle isn't reachable, hence not double-closed, afterward. fopen's "w"
// string-literal arg is a fresh owning temp (kept + PICK'd + DROP_UNDER'd). Deterministic: writes N bytes to
// a temp file and reports the count.
extern "c" {
    fn fopen(path: string, mode: string) -> Ptr
    fn fwrite(buf: [u8], n: i64, f: Ptr) -> i64
    fn fclose(move f: Ptr) -> i64
}


fn write_bytes(path: string, count: int) -> i64 {
    var f = fopen(path, "w")
    var buf: [u8] = []
    buf.append(65u8)                 // 'A'
    var w: i64 = 0
    var i = 0
    loop {
        if i == count {
            break
        }
        w = w + fwrite(buf, 1, f)    // borrow f each iteration
        i = i + 1
    }
    let _c = fclose(f)               // move f: consumed on the only exit
    return w
}


fn main() -> int {
    let w = write_bytes("/tmp/ember_selfhost_ffi_ptr.bin", 4)
    println("wrote {w}")             // 4
    return 0
}
