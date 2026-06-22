// tests/graphics/flare_dock_persist.em — regression for OFI-112: a DockTree serialises to JSON and round-trips
// back identically, so a custom workspace survives relaunch. Drives the FULL path the app uses — to_json →
// json.stringify → json.parse → dock_from_json — and asserts the rebuilt tree matches the original: leaf order,
// each leaf's tab list + active index, every split's ratio, the root index, and the live node count. All
// integers / ids (no rendering, no measure_text), so the golden is font-metric-drift immune.
import "std/flare" as flare
import "std/json" as json


fn istr(n: int) -> string {
    return "{n}"
}


// shape renders the tree's persistent structure as one comparable string.
fn shape(t: flare.DockTree) -> string {
    var s = "root=" + istr(t.root) + " nodes=" + istr(t.node_count()) + " ["
    let ls = t.leaves()
    var i = 0
    loop {
        if i == ls.len() { break }
        if i > 0 { s = s + " " }
        let lf = t.leaf_of(ls[i])
        let tabs = t.tabs_of(lf)
        s = s + "act" + istr(t.active_tab(lf)) + ":"
        var j = 0
        loop {
            if j == tabs.len() { break }
            if j > 0 { s = s + "," }
            s = s + tabs[j]
            j = j + 1
        }
        i = i + 1
    }
    s = s + "] r="
    var k = 0
    loop {
        if k == t.dk_kind.len() { break }
        if t.dk_kind[k] == 2 { s = s + istr(to_int(t.dk_ratio[k] * 1000.0)) + "," }
        k = k + 1
    }
    return s
}


fn main() -> int {
    // A non-trivial workspace: Conversations | (Chat,Inspector as TABS) with custom ratios.
    var t = flare.dock_new()
    let chat = t.add_root("Chat")
    let _ = t.split(chat, "Inspector", true, 0.66)
    let _ = t.split_before(chat, "Conversations", true, 0.22)
    let _ = t.redock("Inspector", "Chat", 4)        // tabify Inspector into the Chat leaf
    print("orig:   {shape(t)}\n")

    // Full round-trip through a STRING (exactly the store path).
    let text = json.stringify(t.to_json())
    match json.parse(text) {
        case Ok(j) {
            let t2 = flare.dock_from_json(j)
            print("loaded: {shape(t2)}\n")
            var ok = "MISMATCH"
            if shape(t) == shape(t2) { ok = "ROUND-TRIP OK" }
            print("{ok}\n")
        }
        case Err(e) { print("parse error: {e}\n") }
    }

    // An empty tree (no panels) round-trips to an empty tree (root -1).
    var e = flare.dock_new()
    let et = json.stringify(e.to_json())
    match json.parse(et) {
        case Ok(j) {
            let e2 = flare.dock_from_json(j)
            print("empty: root={e2.root} nodes={e2.node_count()}\n")
        }
        case Err(er) {}
    }
    return 0
}
