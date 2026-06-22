// tests/graphics/flare_dock_tabs.em — regression for TAB GROUPS (std/flare: redock side 4 = tabify, the
// tab strip in _dock_chrome, set_active, close_tab, and dock_panel rendering only the ACTIVE tab). Tabify
// is driven by the geometry drag (dropping a panel on another's CENTRE third), switching by the set_active
// data path, so every assertion is leaf order / tab counts / active id / ds-membership — font-metric-drift
// immune (no chip pixel hit-testing, which would depend on measure_text). flare_dock_ui covers single-panel
// chrome; this covers the multi-tab leaf.
import "std/draw" as draw
import "std/flare" as flare


fn order(t: flare.DockTree) -> string {
    let ls = t.leaves()
    var s = ""
    var i = 0
    loop {
        if i == ls.len() { break }
        if i > 0 { s = s + "|" }
        s = s + ls[i]
        i = i + 1
    }
    return s
}


// tabinfo prints a leaf's tab list + active, found by one of its panel ids.
fn tabinfo(t: flare.DockTree, id: string) -> string {
    let l = t.leaf_of(id)
    if l == -1 { return "gone" }
    let tabs = t.tabs_of(l)
    var s = "["
    var i = 0
    loop {
        if i == tabs.len() { break }
        if i > 0 { s = s + "," }
        s = s + tabs[i]
        i = i + 1
    }
    return s + "]act=" + tabs[t.active_tab(l)]
}


// shown reports whether each panel currently has a recorded body rect (i.e. dock_begin chose to render it —
// true only for the active tab of each leaf).
fn shown(mut f: flare.Flare, a: string, b: string) -> string {
    var sa = "no"
    match f.ds.get(a) {
        case Some(r) { sa = "yes" }
        case None { sa = "no" }
    }
    var sb = "no"
    match f.ds.get(b) {
        case Some(r) { sb = "yes" }
        case None { sb = "no" }
    }
    return "{a}={sa} {b}={sb}"
}


fn frame(mut f: flare.Flare, mut t: flare.DockTree, mx: int, my: int, down: bool, was: bool) {
    draw.begin(f.bg())
    f.begin()
    f.ui.mx = mx  f.ui.my = my  f.ui.down = down  f.ui.was = was
    let _ = f.dock_begin(t, 0, 0, 1000, 600)
    let ids = t.leaves()
    var i = 0
    loop {
        if i == ids.len() { break }
        f.key(ids[i])
        if f.dock_panel(ids[i]) {
            f.label("body")
            f.dock_panel_end()
        }
        i = i + 1
    }
    f.finish()
    draw.finish()
}


fn main() -> int {
    draw.window(1000, 600, "flaredocktabs")
    var f = flare.new()
    var t = flare.dock_new()
    let a = t.add_root("A")
    let _ = t.split(a, "B", true, 0.5)               // A | B  → A=(0,0,496,600), B=(504,0,496,600)

    // ---- tabify: drag B onto A's CENTRE third → A's leaf becomes a tab group, B active ----
    frame(f, t, 600, 18, true, false)                // press B's bar → latch
    frame(f, t, 250, 300, true, true)                // drag to A's centre (250 ∈ [168,327], 300 ∈ [204,396])
    frame(f, t, 250, 300, false, true)               // release → tabify
    print("tabify  {order(t)} tabs={tabinfo(t, "A")} count={t.tab_count(t.leaf_of("A"))}\n")

    // ---- only the active tab renders (B); the inactive one (A) has no body rect ----
    frame(f, t, -1, -1, false, false)
    print("render  {shown(f, "A", "B")}\n")        // A=no B=yes

    // ---- switch active to A (the data path a chip click drives) → A renders, B hidden ----
    let la = t.leaf_of("A")
    t.set_active(la, 0)
    frame(f, t, -1, -1, false, false)
    print("switch  active={tabinfo(t, "A")}  {shown(f, "A", "B")}\n")

    // ---- ✕ closes the ACTIVE tab (A) → leaf survives with B ----
    let gone = t.close_tab(t.leaf_of("A"))
    frame(f, t, -1, -1, false, false)
    print("close   gone={gone} {order(t)} tabs={tabinfo(t, "B")} nodes={t.node_count()}\n")

    let ids = t.leaves()
    var i = 0
    loop {
        if i == ids.len() { break }
        f.forget(ids[i])
        i = i + 1
    }
    draw.close()
    return 0
}
