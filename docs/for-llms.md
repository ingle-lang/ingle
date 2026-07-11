---
title: For LLMs — the priors cheat-sheet
nav_order: 6
description: A priors cheat-sheet for language models writing Ingle — where Ingle diverges from C, Rust, Go, and Python habits. Paste it before asking a model to generate Ingle.
---

# Ingle for LLMs — the priors cheat-sheet

**Paste this whole page into a model's context before asking it to write Ingle.** It is the short
list of places where Ingle diverges from the habits a model carries over from C, Rust, Go, Python,
Swift, and TypeScript — i.e. the exact spots where zero-/few-shot Ingle goes wrong. It is also a fast
human reference.

Ingle is *designed* for least surprise to a language model, but a few things still trip up code
trained on other languages. Each row below pairs the habit a model tends to reach for (✗) with the
Ingle form (✓). Every snippet on this page was compiled with `inglec` before it was written down; the
[complete program](#a-complete-program-compiles-and-runs) at the end compiles and runs as shown, and
the fragments above it are extracted from programs that do.

> Do not feed a model `grammar.ebnf`. A formal grammar makes a model emit *derivations*
> (`IFStatement: IF Expression …`) instead of *programs*. Use this page and the
> [examples](https://github.com/ingle-lang/ingle/tree/main/examples) instead — concrete code is
> what models generalise from.

## The cheat table

| ✗ Habit from another language | ✓ Ingle | Why |
|---|---|---|
| `func f()`, `def f()`, `function f()` | `fn f() { … }` | functions are `fn`; return type is `-> T` |
| `let mut x = 0` | `var x = 0` | `let` is immutable, `var` is mutable — **there is no `let mut`** |
| reassigning a `let` | declare it `var` | `error: cannot assign to an immutable 'let' binding` |
| `fn f() -> int { 5 }` (last-expr return) | `fn f() -> int { return 5 }` | no implicit last-expression return; `return` is required |
| `println("x =", n)` | `println("x = {n}")` | `print`/`println` take **exactly one argument**; compose with interpolation |
| `"{shape}"` where `shape` is a struct/interface | works **if the type has `fn show(self) -> string`** (the `Show` contract); else `"{shape.area()}"`, `"{p.x}"` | bare interpolation renders a number/string/bool directly, or any value whose type provides `show` (structural, like Go's `Stringer` — no `implements Show` needed) |
| `null`, `nil`, `None` as a bare value | `Option<T>` with `Some(v)` / `None` | there is no null; absence is an `Option` |
| `String`, `Vec<int>`, `int64`, `double` | `string`, `[int]`, `i64`, `f64` | primitives are lowercase; arrays are `[T]`; `int`=64-bit, `float`=`f64` |
| `type Id = int` assumed to be a transparent alias (Go/TS `type`) | a **distinct** nominal type: `Id(7)` constructs; `int` and `Id` don't interchange | newtypes erase to the base (zero cost) but the compiler keeps them apart; arithmetic needs an explicit `int(x)` unwrap |
| a hand-written validated wrapper (private field + checking constructor) | `type Percent = int where 0 <= self && self <= 100` | a **refinement**: the `where` predicate is checked at construction (`Percent(150)` traps `refinement_violation`), elided in `--release` |
| `ch.send(x)`, `ch.recv()` | `send(ch, x)`, `recv(ch)`, `close(ch)` | channel ops are **free functions**, not methods |
| `let c = channel(10)` | `let c: Channel<int> = channel(10)` | annotate the element type at the binding (it can't be inferred) |
| `case X => { … }` (arrow) | `case X { … }` | match arms are `case PATTERN { … }` — **no `=>`** |
| `impl Trait for T { … }` | put methods **inside** the `struct` body | there are no `impl` blocks (see below) |
| `0..=3` (inclusive range) | `0..3`, or `0..n+1` | ranges are **half-open**: `0..3` is `0,1,2`; there is no `..=` |
| `Shape.Origin` / `Shape::Origin` | `Origin` | enum variants are referenced **bare** (a qualified form also parses) |
| assuming `Circle(radius: 2.0)` is illegal | `Circle(2.0)` **or** `Circle(radius: 2.0)` | enum variants construct **positionally or by field name** (named mirrors a struct literal) — both are valid |
| `use std::x`, `from x import y`, `import x` | `import "std/string" as str` | imports are a **quoted path** with an `as` alias |
| `x = x + 1` for every update | `x += 1` (also `-= *= /= %= &= |= ^=`) | compound assignment exists; **no `<<=` / `>>=`** |
| `0x`/`0b`/`0o` or `_` unsupported | `0xFF`, `0b1010`, `0o17`, `1_000_000` | hex/binary/octal literals + `_` digit separators; a leading `0` is **decimal**, not octal |
| `unwrap_or(o, 0)` (free fn only) | also `o.unwrap_or(0)` | UFCS: a free fn can be called method-style **on an enum or scalar** receiver (not string/array/struct) |

## Structs, methods, interfaces — no `impl` blocks

Methods live **inside** the `struct` body. Conformance is declared with `implements` in the header and
checked by the compiler. An interface used as a type gives you dynamic dispatch — no inheritance.

```ember
interface Drawable {
    fn area(self) -> float
}

struct Rect implements Drawable {
    w: float
    h: float

    fn area(self) -> float { return self.w * self.h }   // method in the body, `self` receiver
}

// An interface as the element type holds a mix of concrete types; an interface-typed
// parameter dispatches dynamically.
fn total(shapes: [Drawable]) -> float {
    var sum = 0.0
    for s in shapes { sum = sum + s.area() }
    return sum
}
```

## Enums and pattern matching

Variants are **newline-separated**. Payload fields are *named in the declaration* but *bound
positionally* in a `match`. Every arm is `case PATTERN { … }` — no arrows.

```ember
enum Shape {
    Circle(radius: float)
    Rect(w: float, h: float)
    Origin
}

fn area(s: Shape) -> float {
    match s {
        case Circle(r)  { return 3.14159 * r * r }
        case Rect(w, h) { return w * h }
        case Origin     { return 0.0 }
    }
}
```

**Richer patterns:** literal (`case 0` / `case "q"` / `case true`), or-pattern (`case 1 | 2 | 3`),
guard (`case n if n < 0` — doesn't count toward exhaustiveness on its own), and one-level nesting
(`case Some(Point(x, y))`, `case Some(Ok(v))`). Matching an `int`/`string` needs a `case _`; a `bool`
is covered by `true` + `false`. Deeper than one level: `match` again inside the arm.

## Option instead of null

```ember
let o: Option<int> = Some(5)
match o {
    case Some(v) { println("got {v}") }
    case None    { println("empty") }
}
```

The prelude provides **combinators**, callable method-style (UFCS) on an `Option`/`Result`:
`is_some`/`is_none`, `is_ok`/`is_err`, `unwrap_or(default)`, `map(f)`, `and_then(f)`, `ok_or(err)`.
`map`/`and_then` take a function — a named fn or a lambda. (There is **no `unwrap`/`expect`** yet.)

```ember
let a: Option<int> = Some(5)
println(a.unwrap_or(0))                  // 5, or the default if None
println(a.map(|x| x * 2).unwrap_or(0))   // 10
```

## Concurrency: nursery, spawn, channels

`nursery` is a structured-concurrency scope that joins every fiber it `spawn`s before control leaves
the block. Channels are typed and buffered; `recv` yields `Option<T>` and returns `None` once the
channel is closed and drained.

```ember
let results: Channel<float> = channel(10)   // annotate the element type

nursery {
    for s in shapes {
        spawn work(s, results)               // spawn only inside a nursery
    }
}                                            // all spawned fibers have finished here

close(results)

var total = 0.0
loop {
    match recv(results) {
        case Some(v) { total = total + v }
        case None    { break }               // closed + drained
    }
}
```

## A complete program (compiles and runs)

This exercises interfaces, dynamic dispatch, structured concurrency, and pattern matching together —
it compiles and runs with `inglec --emit=run`.

```ember
interface Drawable {
    fn area(self) -> float
}

struct Rect implements Drawable {
    w: float
    h: float

    fn area(self) -> float { return self.w * self.h }
}

struct Circle implements Drawable {
    radius: float

    fn area(self) -> float { return 3.14159 * self.radius * self.radius }
}

// A worker fiber: compute one shape's area and send it down the channel.
fn process_shape(shape: Drawable, results: Channel<float>) {
    let a = shape.area()
    println("processing a shape — area: {a}")
    send(results, a)
}

fn main() {
    let shapes: [Drawable] = [
        Rect { w: 10.0, h: 5.0 },
        Circle { radius: 2.5 },
        Rect { w: 3.0, h: 4.0 }
    ]

    let results: Channel<float> = channel(10)

    nursery {
        for shape in shapes {
            spawn process_shape(shape, results)
        }
    }

    close(results)

    var total_area = 0.0
    loop {
        match recv(results) {
            case Some(area) { total_area = total_area + area }
            case None       { break }
        }
    }

    println("total area: {total_area}")
}
```

---

For the full language, read the [language reference](/language) and [The Ingle Book](/guide/);
for the design philosophy, the
[manifesto](https://github.com/ingle-lang/ingle/blob/main/MANIFESTO.md).
