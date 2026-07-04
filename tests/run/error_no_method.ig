// error_no_method.ig — calling a method that doesn't exist is a compile error.
struct C { v: int  fn get(self) -> int { return self.v } }
fn main() -> int { let c = C { v: 1 }  return c.missing() }
