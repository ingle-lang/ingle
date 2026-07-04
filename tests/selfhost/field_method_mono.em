// tests/selfhost/field_method_mono.em — the generic-struct-FIELD method-call case (self-hosting).
//
// A method call whose receiver is a generic-struct FIELD — `self.wins.keys()` where `wins: Map<int,int>` —
// must monomorphize to the field's method instance (`Map.keys<int_int>`), exactly as a call on a local
// binding (`m.keys()` with `m: Map<int,int>`) does. The self-hosted codegen resolves this by (a) classifying
// the field's `TyGeneric` type to its base struct id, (b) reading the field's borrowed value as a direct
// (un-PICKed) receiver, and (c) registering the field's method instance in the monomorphization worklist
// from the owning struct's declaration. Before that machinery the call retargeted to the BASE method (wrong
// fn index) or wasn't emitted at all. Output is deterministic totals; the harness requires VM == native.

import "std/map" as mp


struct Tally {
    wins: mp.Map<int, int>


    fn record(mut self, team: int, points: int) {
        match self.wins.get(team) {
            case Some(prev) {
                self.wins.set(team, prev + points)
            }
            case None {
                self.wins.set(team, points)
            }
        }
    }


    // total() calls `.keys()` AND `.get()` on the `wins` FIELD — the field-method-mono path.
    fn total(self) -> int {
        var sum = 0
        let ks = self.wins.keys()
        var i = 0
        loop {
            if i >= ks.len() {
                break
            }
            match self.wins.get(ks[i]) {
                case Some(v) {
                    sum = sum + v
                }
                case None {
                }
            }
            i = i + 1
        }
        return sum
    }


    fn team_count(self) -> int {
        return self.wins.keys().len()
    }
}


fn main() {
    var t = Tally { wins: mp.Map<int, int>{ buckets: [], count: 0 } }
    t.record(1, 10)
    t.record(2, 7)
    t.record(1, 5)
    t.record(3, 3)
    t.record(2, 8)
    println("total = {t.total()}")
    println("teams = {t.team_count()}")
    println("field-method mono: OK")
}
