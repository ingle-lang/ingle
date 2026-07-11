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
    fn em_tcp_listen(port: i64, public: i64) -> i64
    fn em_tcp_accept(fd: i64) -> i64
    fn em_tcp_connect(host: string, port: i64) -> i64
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


// A parsed request — the method + path from the request line, the raw request body (byte-exact, empty
// for a GET), and the X-Quog-Token header value (or "") used to authorize a push.
struct Request {
    method: string
    path: string
    body: [u8]
    token: string
}


// listen opens a TCP listener on `port` bound to LOOPBACK ONLY (127.0.0.1) — reachable from this
// machine, not the network. This is the safe default; use listen_public to expose it deliberately.
fn listen(port: int) -> Result<Server, string> {
    let fd = em_tcp_listen(port, 0)
    if fd < 0 {
        return Err("could not listen on port {port} (in use, or needs privilege for < 1024)")
    }
    return Ok(Server { fd: fd })
}


// listen_public opens a listener on ALL interfaces (INADDR_ANY) — reachable from the network. Opt-in,
// because a server with no auth/TLS exposed to the network is a real risk; prefer `listen` + a proxy.
fn listen_public(port: int) -> Result<Server, string> {
    let fd = em_tcp_listen(port, 1)
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


// _header_value returns the value of header `name` (including its trailing colon, e.g. "X-Quog-Token:")
// from the ASCII header block — up to the end of that line, trimmed — or "" if absent.
fn _header_value(header: string, name: string) -> string {
    let idx = str.index_of(header, name)
    if idx < 0 {
        return ""
    }
    let rest = str.substring(header, idx + str.cp_count(name), str.cp_count(header))
    let end = str.index_of(rest, "\r")
    var val = rest
    if end >= 0 {
        val = str.substring(rest, 0, end)
    }
    return str.trim(val)
}


// _content_length parses the Content-Length header value from the (ASCII) header block, or 0.
fn _content_length(header: string) -> int {
    let idx = str.index_of(header, "Content-Length:")
    if idx < 0 {
        return 0
    }
    var n = 0
    var started = false
    for c in str.substring(header, idx + 15, str.cp_count(header)).bytes() {
        if c >= 48u8 && c <= 57u8 {
            n = n * 10 + (i64(c) - 48)
            started = true
        } else if started {
            break
        }
    }
    return n
}


// read_request reads a whole request byte-exact: the header block (to the CR-LF-CR-LF terminator),
// then the body extended to Content-Length. Byte-based so a binary POST body (an object push) is
// preserved. Parses the request line into method + path.
fn read_request(conn: Conn) -> Result<Request, string> {
    var raw: [u8] = []
    loop {
        if _crlfcrlf(raw) >= 0 || raw.len() > 65536 {
            break
        }
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
            break
        }
        var k = 0
        loop {
            if k == n {
                break
            }
            raw.append(buf[k])
            k = k + 1
        }
    }
    let sep = _crlfcrlf(raw)
    if sep < 0 {
        return Err("malformed request")
    }
    var hb: [u8] = []
    var h = 0
    loop {
        if h >= sep {
            break
        }
        hb.append(raw[h])
        h = h + 1
    }
    let header = from_bytes(hb)
    let line_end = str.index_of(header, "\r\n")
    var line = header
    if line_end >= 0 {
        line = str.substring(header, 0, line_end)
    }
    let parts = line.split(" ")
    if parts.len() < 2 {
        return Err("malformed request line")
    }
    // Body: whatever followed the header terminator, extended to the full Content-Length.
    let clen = _content_length(header)
    var body: [u8] = []
    var b = sep + 4
    loop {
        if b >= raw.len() {
            break
        }
        body.append(raw[b])
        b = b + 1
    }
    loop {
        if body.len() >= clen {
            break
        }
        var buf: [u8] = []
        var i = 0
        loop {
            if i == 8192 {
                break
            }
            buf.append(0u8)
            i = i + 1
        }
        let n = em_recv(conn.fd, buf)
        if n <= 0 {
            break
        }
        var k = 0
        loop {
            if k == n {
                break
            }
            body.append(buf[k])
            k = k + 1
        }
    }
    return Ok(Request { method: parts[0], path: parts[1], body: body, token: _header_value(header, "X-Quog-Token:") })
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


// --- client side: a minimal HTTP/1.1 client over the same sockets, for Quog's sync transport. All
// byte-level, because responses carry binary object data. ------------------------------------------


// A client response: the HTTP status code and the raw body bytes (byte-exact — objects are binary).
struct Response {
    status: int
    body: [u8]
}


// _crlfcrlf returns the index where the CR-LF-CR-LF header terminator begins in `bytes`, or -1.
fn _crlfcrlf(bytes: [u8]) -> int {
    var i = 0
    loop {
        if i + 3 >= bytes.len() {
            return -1
        }
        if bytes[i] == 13u8 && bytes[i + 1] == 10u8 && bytes[i + 2] == 13u8 && bytes[i + 3] == 10u8 {
            return i
        }
        i = i + 1
    }
}


// _read_all reads a connection to EOF (the server replies Connection: close) into a byte buffer.
fn _read_all(conn: Conn) -> [u8] {
    var acc: [u8] = []
    loop {
        var buf: [u8] = []
        var i = 0
        loop {
            if i == 8192 {
                break
            }
            buf.append(0u8)
            i = i + 1
        }
        let n = em_recv(conn.fd, buf)
        if n <= 0 {
            break
        }
        var k = 0
        loop {
            if k == n {
                break
            }
            acc.append(buf[k])
            k = k + 1
        }
    }
    return acc
}


// _status_code parses the numeric status from an HTTP status line ("HTTP/1.1 200 OK" -> 200).
fn _status_code(head: [u8]) -> int {
    var i = 0
    loop {
        if i >= head.len() {
            return 0
        }
        if head[i] == 32u8 {
            break                       // the space after "HTTP/1.1"
        }
        i = i + 1
    }
    i = i + 1
    var code = 0
    loop {
        if i >= head.len() {
            break
        }
        let c = head[i]
        if c < 48u8 || c > 57u8 {
            break
        }
        code = code * 10 + (i64(c) - 48)
        i = i + 1
    }
    return code
}


// request sends one HTTP/1.1 request to host:port and returns the response. Connection: close, so the
// whole reply is read to EOF; the body is returned byte-exact.
fn request(host: string, port: int, method: string, path: string, body: [u8], token: string) -> Result<Response, string> {
    let fd = em_tcp_connect(host, port)
    if fd < 0 {
        return Err("could not connect to {host}:{port}")
    }
    let conn = Conn { fd: fd }
    var reqhead = "{method} {path} HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\nContent-Length: {body.len()}\r\n"
    if token != "" {
        reqhead = reqhead + "X-Quog-Token: {token}\r\n"
    }
    reqhead = reqhead + "\r\n"
    var req: [u8] = []
    for b in reqhead.bytes() {
        req.append(b)
    }
    for b in body {
        req.append(b)
    }
    let _ = em_send(conn.fd, req)
    let raw = _read_all(conn)
    let sep = _crlfcrlf(raw)
    if sep < 0 {
        return Err("malformed response from {host}:{port}")
    }
    var head: [u8] = []
    var i = 0
    loop {
        if i >= sep {
            break
        }
        head.append(raw[i])
        i = i + 1
    }
    var out: [u8] = []
    var j = sep + 4
    loop {
        if j >= raw.len() {
            break
        }
        out.append(raw[j])
        j = j + 1
    }
    return Ok(Response { status: _status_code(head), body: out })
}


// get / post are the two verbs Quog's sync uses. post carries a token to authorize a write.
fn get(host: string, port: int, path: string) -> Result<Response, string> {
    var empty: [u8] = []
    return request(host, port, "GET", path, empty, "")
}


fn post(host: string, port: int, path: string, body: [u8], token: string) -> Result<Response, string> {
    return request(host, port, "POST", path, body, token)
}
