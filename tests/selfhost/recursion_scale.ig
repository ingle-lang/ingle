// tests/selfhost/recursion_scale.ig — Stage A self-hosting spike (docs/design/self-hosting.md §2
// "scale, watched not assumed" and §8 "erased generics shape the compiler's own data structures").
//
// The calc spike proves the recursive AST shapes are EXPRESSIBLE; this one proves they hold up at the
// SIZE a compiler actually produces, with identical results on both backends. It builds three trees and
// folds each:
//
//   * a deep single-child spine (150 levels) — recursion through `Box<Tree>`, kept safely under the
//     VM's 256-frame call cap (vm.c FRAMES_MAX); the reference parser/checker, running on the VM, must
//     respect the same ceiling, so the spike documents where it sits.
//   * a wide n-ary node (8000 children) — recursion through `[Tree]`, the large-heap-array case.
//   * a perfectly balanced binary tree (depth 16 -> 65 536 leaves) — breadth via recursion within the
//     depth cap, the closest shape to a real AST.
//
// leak-until-exit inside generic bodies is the accepted batch-process model (OFI-009 tail); a compiler
// builds an arena and exits, so the point here is correctness and identical VM/native output, which the
// harness checks byte-for-byte.

struct Box<T> {
    value: T
}


enum Tree {
    Leaf(n: int)
    Node(left: Box<Tree>, right: Box<Tree>)
    Many(kids: [Tree])
}


// sum folds a tree to the total of its leaves. `Node` recurses through the two boxed children; `Many`
// iterates its array, recursing into each — the exhaustive match a real AST walker is built from.
fn sum(t: Tree) -> int {
    match t {
        case Leaf(n) {
            return n
        }
        case Node(left, right) {
            return sum(left.value) + sum(right.value)
        }
        case Many(kids) {
            var total = 0
            var i = 0
            loop {
                if i >= kids.len() {
                    break
                }
                total = total + sum(kids[i])
                i = i + 1
            }
            return total
        }
    }
}


// count returns the number of leaves, a second independent walk so the structure is exercised by more
// than one consumer (as the AST is by checker, codegen, printer…).
fn count(t: Tree) -> int {
    match t {
        case Leaf(n) {
            return 1
        }
        case Node(left, right) {
            return count(left.value) + count(right.value)
        }
        case Many(kids) {
            var total = 0
            var i = 0
            loop {
                if i >= kids.len() {
                    break
                }
                total = total + count(kids[i])
                i = i + 1
            }
            return total
        }
    }
}


// deep_spine builds a left-leaning chain of `depth` Nodes ending in a Leaf — recursion depth on the
// fold equals `depth`, so this is the knob that probes how close to the VM frame cap we can walk.
fn deep_spine(depth: int) -> Tree {
    var t: Tree = Leaf(1)
    var d = 0
    loop {
        if d >= depth {
            break
        }
        t = Node(Box<Tree>{ value: Leaf(1) }, Box<Tree>{ value: t })
        d = d + 1
    }
    return t
}


// wide_node builds one n-ary node with `width` Leaf(1) children — the large `[Tree]` array case.
fn wide_node(width: int) -> Tree {
    var kids: [Tree] = []
    var i = 0
    loop {
        if i >= width {
            break
        }
        kids.append(Leaf(1))
        i = i + 1
    }
    return Many(kids)
}


// balanced builds a perfect binary tree of the given depth: 2^depth Leaf(1) leaves.
fn balanced(depth: int) -> Tree {
    if depth == 0 {
        return Leaf(1)
    }
    return Node(Box<Tree>{ value: balanced(depth - 1) }, Box<Tree>{ value: balanced(depth - 1) })
}


// check asserts a fold result against its hand-derived expected value. A mismatch returns Err, exiting
// non-zero (a Fault on the VM) so the harness scores it FAIL — the oracle the VM==native differential
// lacks on its own (a shared-wrong fold would otherwise stay green).
fn check(label: string, got: int, want: int) -> Result<int, string> {
    if got != want {
        return Err("CHECK FAILED [{label}]: expected {want} got {got}")
    }
    return Ok(0)
}


fn main() -> Result<int, string> {
    let spine = deep_spine(150)                                            // initial Leaf + 150 Nodes
    println("spine leaves = {count(spine)}, sum = {sum(spine)}")
    let _ = check("spine leaves", count(spine), 151)?
    let _ = check("spine sum", sum(spine), 151)?

    let wide = wide_node(8000)
    println("wide leaves = {count(wide)}, sum = {sum(wide)}")
    let _ = check("wide leaves", count(wide), 8000)?
    let _ = check("wide sum", sum(wide), 8000)?

    let tree = balanced(16)                                               // 2^16 leaves
    println("balanced leaves = {count(tree)}, sum = {sum(tree)}")
    let _ = check("balanced leaves", count(tree), 65536)?
    let _ = check("balanced sum", sum(tree), 65536)?

    let grand = Many([spine, wide, tree])
    println("grand total = {sum(grand)}")
    let _ = check("grand total", sum(grand), 73687)?                      // 151 + 8000 + 65536

    println("selfhost recursion_scale: OK")
    return Ok(0)
}
