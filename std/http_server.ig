// std/http_server — a minimal HTTP/1.1 server, in pure Ingle over a tiny TCP socket FFI (OFI-211).
// The server-side counterpart to std/http (the libcurl client). This is the leaf Ingle's web story
// stands on: `listen` a port, `accept` connections, `read_request` the method+path, `respond` with a
// body. Sequential (one connection at a time) — correct and simple for a local view/dev server;
// per-connection fibers (nursery/spawn) are a follow-on. TLS is out of scope (put a proxy in front).
//
// `Server` and `Conn` are `resource struct`s: each owns its socket fd and its `drop` closes it, so a
// connection can never leak — it closes when its binding leaves scope, including on an early `?`.
import "std/string" as str


extern "c" {
    fn em_tcp_listen(port: i64) -> i64
    fn em_tcp_accept(fd: i64) -> i64
    fn em_recv(fd: i64, mut buf: [u8]) -> i64
    fn em_send(fd: i64, buf: [u8]) -> i64
    fn em_close(fd: i64) -> i64
}


// A listening socket. Obtain with listen(); accept() connections off it; it closes itself at scope end.
resource struct Server {
    fd: int
    fn drop(self) {
        let _ = em_close(self.fd)
    }
}


// A single accepted connection. read_request() it, respond() to it; it closes itself at scope end.
resource struct Conn {
    fd: int
    fn drop(self) {
        let _ = em_close(self.fd)
    }
}


// A parsed request — just the method and path from the request line, which is all a read-only view
// needs. (Headers and body are read off the wire but not surfaced yet.)
struct Request {
    method: string
    path: string
}


// listen opens a TCP listener on `port` (all interfaces), erring if the port can't be bound.
fn listen(port: int) -> Result<Server, string> {
    let fd = em_tcp_listen(port)
    if fd < 0 {
        return Err("could not listen on port {port} (in use, or needs privilege for < 1024)")
    }
    return Ok(Server { fd: fd })
}


// accept blocks for the next connection and returns it (its fd owned by the returned Conn).
fn accept(server: Server) -> Result<Conn, string> {
    let fd = em_tcp_accept(server.fd)
    if fd < 0 {
        return Err("accept failed")
    }
    return Ok(Conn { fd: fd })
}


// _chunk copies the first `n` bytes of `buf` into a fresh string (recv fills a fixed-size buffer, but
// only its first `n` bytes are the data just read).
fn _chunk(buf: [u8], n: int) -> string {
    var out: [u8] = []
    var i = 0
    loop {
        if i == n {
            break
        }
        out.append(buf[i])
        i = i + 1
    }
    return from_bytes(out)
}


// read_request reads the request head (up to the blank line ending the headers, or a size cap) and
// parses the request line into a method + path. A malformed or empty request errs.
fn read_request(conn: Conn) -> Result<Request, string> {
    var acc = ""
    loop {
        var buf: [u8] = []
        var i = 0
        loop {
            if i == 4096 {
                break
            }
            buf.append(0u8)
            i = i + 1
        }
        let n = em_recv(conn.fd, buf)
        if n <= 0 {
            break                                    // peer closed or error
        }
        acc = acc + _chunk(buf, n)
        if str.contains(acc, "\r\n\r\n") || acc.len() > 65536 {
            break                                    // whole header block in hand (or too big)
        }
    }
    let line_end = str.index_of(acc, "\r\n")
    var line = acc
    if line_end >= 0 {
        line = str.substring(acc, 0, line_end)       // the request line: "METHOD PATH HTTP/1.1"
    }
    let parts = line.split(" ")
    if parts.len() < 2 {
        return Err("malformed request line")
    }
    return Ok(Request { method: parts[0], path: parts[1] })
}


// respond writes a complete HTTP/1.1 response (status line, a couple of headers, then the body) and
// closes the connection semantics (`Connection: close`). Content-Length is the body's byte length.
fn respond(conn: Conn, status: int, reason: string, content_type: string, body: string) -> int {
    let head = "HTTP/1.1 {status} {reason}\r\n" +
        "Content-Type: {content_type}\r\n" +
        "Content-Length: {body.len()}\r\n" +
        "Connection: close\r\n\r\n"
    return em_send(conn.fd, (head + body).bytes())
}


// ok_html is the common case: a 200 response carrying an HTML page.
fn ok_html(conn: Conn, body: string) -> int {
    return respond(conn, 200, "OK", "text/html; charset=utf-8", body)
}


// not_found is a plain 404 for an unknown path.
fn not_found(conn: Conn, body: string) -> int {
    return respond(conn, 404, "Not Found", "text/html; charset=utf-8", body)
}
