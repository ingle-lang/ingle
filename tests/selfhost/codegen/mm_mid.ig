// multi-module fixture (mid): imports mm_base, matches its enum (cross-module variant tags), returns its
// struct (cross-module struct return type), and constructs it via base constructors.
import "mm_base" as base


fn mid_name(k: base.Kind) -> int {
    return base.name(k)
}


fn mk(id: int) -> base.Node {
    return base.Node { id: id, kind: base.ka() }
}
