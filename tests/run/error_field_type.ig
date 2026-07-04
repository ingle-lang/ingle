// error_field_type.ig — a field value must match the declared field type.
struct P { x: int  y: int }
fn main() -> int { let p = P { x: true, y: 4 }  return p.y }
