// blob.ig — std/sqlite BLOB round-trip (OFI-209): bind_blob / column_bytes / column_blob over a
// payload with an embedded NUL and a high byte, which the TEXT path (bind_text/column_text) would
// truncate at the NUL. Content-addressed by SHA-256 so the id is deterministic. Needs inglec-db.
import "std/sqlite" as sql
import "std/sha256" as sha
import "std/encoding" as enc

fn work() -> Result<int, string> {
    let db = sql.open(":memory:")?
    let _ = sql.exec(db, "CREATE TABLE object(id TEXT PRIMARY KEY, data BLOB)")?

    var payload: [u8] = []
    payload.append(72u8)     // 'H'
    payload.append(0u8)      // embedded NUL — TEXT would stop here
    payload.append(105u8)    // 'i'
    payload.append(255u8)    // 0xFF — non-UTF-8
    let id = enc.to_hex(sha.digest(payload))

    let ins = sql.prepare(db, "INSERT INTO object(id, data) VALUES(?, ?)")?
    let _ = sql.bind_text(ins, 1, id)
    let _ = sql.bind_blob(ins, 2, payload)
    let _ = sql.step(ins)?

    let sel = sql.prepare(db, "SELECT data FROM object WHERE id = ?")?
    let _ = sql.bind_text(sel, 1, id)
    let _ = sql.step(sel)?
    println("bytes={sql.column_bytes(sel, 0)}")           // 4
    let got = sql.column_blob(sel, 0)
    println("len={got.len()} b0={got[0]} nul={got[1]} b2={got[2]} b3={got[3]}")
    println("content_id_stable={enc.to_hex(sha.digest(got)) == id}")
    return Ok(0)
}

fn main() -> int {
    match work() {
        case Ok(n) { return 0 }
        case Err(e) { println("err={e}") return 1 }
    }
}
