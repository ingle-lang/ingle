// error_scope_exit.ig — a block-local is not visible after its block.
fn main() -> int {
    if true {
        let x = 1
    }
    return x
}
