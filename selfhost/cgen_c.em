// selfhost/cgen_c.em — the M5 self-hosted C-EMIT backend (AST → C), mirroring src/cgen_c.c. It is the
// 5th and final component of stage-0 ported to Ember: completing it makes the self-hosted compiler a full
// mirror of stage-0 (lexer → parser → checker → bytecode → C-emit), able to produce native binaries the
// same way (`emberc -o`), and is the path to the kernel's bare-metal codegen. Verified byte-identical to
// stage-0 `emberc --emit=c` via tools/ccdiff.sh — the same differential methodology as every other stage.
//
// Built incrementally (like the bytecode codegen.em was): M5a = the program SCAFFOLD + scalar bodies, then
// strings, structs, control flow, etc. The driver is selfhost/cgen_c_dump.em.

import "parser" as ps


// fn_param_list renders a function's C parameter list: `void` for no value params, else `Value a0, Value
// a1, …` (one per non-self parameter; a method's receiver is the leading `Value a0`).
fn fn_param_list(f: ps.FnDecl, has_self: bool) -> string {
    var n = 0
    if has_self {
        n = 1
    }
    var p = 0
    loop {
        if p >= f.params.len() {
            break
        }
        if f.params[p].is_self == false {
            n = n + 1
        }
        p = p + 1
    }
    if n == 0 {
        return "void"
    }
    var s = ""
    var i = 0
    loop {
        if i >= n {
            break
        }
        if i > 0 {
            s = s + ", "
        }
        s = s + "Value a{i}"
        i = i + 1
    }
    return s
}


// ---- expression emission (M5a: scalar literals; the operand machinery grows per increment) ----------
// emit_expr returns the C expression text for `e`. Unmodelled forms emit a `0` placeholder for now — the
// ccdiff differential drives each form to byte-identity as it is built.
fn emit_expr(e: ps.Expr) -> string {
    match e {
        case EInt(v) {
            return "INT_VAL({v}LL)"
        }
        case EBool(b) {
            if b {
                return "BOOL_VAL(1)"
            }
            return "BOOL_VAL(0)"
        }
        case _ {
            return "INT_VAL(0)"
        }
    }
}


// emit_stmt prints the C for one statement (4-space indented inside a function body).
fn emit_stmt(s: ps.Stmt) {
    match s {
        case SReturn(value, line) {
            if value.len() > 0 {
                println("    return {emit_expr(value[0].value)};")
            } else {
                println("    return UNIT_VAL;")
            }
        }
        case _ {
        }
    }
}


// emit_fn_body prints a single function's C definition: `static Value em_fn_N(params) { … }` with the
// implicit trailing `return INT_VAL(0);` stage-0 always emits. (C braces are escaped `\{`/`\}` — bare
// braces are Ember interpolation holes.)
fn emit_fn_body(f: ps.FnDecl, idx: int, has_self: bool) {
    println("static Value em_fn_{idx}({fn_param_list(f, has_self)}) \{")
    var i = 0
    loop {
        if i >= f.body.len() {
            break
        }
        emit_stmt(f.body[i])
        i = i + 1
    }
    println("    return INT_VAL(0);")
    println("\}")
}


// ---- program-level emission: the scaffold mirroring src/cgen_c.c's whole-module output ----------------
// Functions are numbered em_fn_0, em_fn_1, … over body-bearing free functions + struct methods in
// DECLARATION order (the same order stage-0 numbers em_fn_N / the bytecode CALL indices). An array element
// struct (a method) can't be moved out into an intermediate list, so emit_program iterates `decls` directly
// — once per section (forward decls / em_invoke / bodies) — keeping a shared per-fn counter.

// value_arity counts a function's value parameters (a method's `self` counts as the leading slot).
fn value_arity(f: ps.FnDecl, has_self: bool) -> int {
    var n = 0
    if has_self {
        n = 1
    }
    var p = 0
    loop {
        if p >= f.params.len() {
            break
        }
        if f.params[p].is_self == false {
            n = n + 1
        }
        p = p + 1
    }
    return n
}


// invoke_args renders the `slots[0], slots[1], …` argument list for an em_invoke case of the given arity.
fn invoke_args(arity: int) -> string {
    var argl = ""
    var a = 0
    loop {
        if a >= arity {
            break
        }
        if a > 0 {
            argl = argl + ", "
        }
        argl = argl + "slots[{a}]"
        a = a + 1
    }
    return argl
}


// fn_count returns the number of body-bearing functions (free + methods) — for trailing-blank-line logic.
fn fn_count(decls: [ps.Decl]) -> int {
    var n = 0
    var i = 0
    loop {
        if i >= decls.len() {
            break
        }
        match decls[i] {
            case DFn(f) {
                if f.has_body {
                    n = n + 1
                }
            }
            case DStruct(name, generics, impls, fields, methods, kind) {
                var mi = 0
                loop {
                    if mi >= methods.len() {
                        break
                    }
                    if methods[mi].has_body {
                        n = n + 1
                    }
                    mi = mi + 1
                }
            }
            case _ {
            }
        }
        i = i + 1
    }
    return n
}


// main_index returns the em_fn_N index of the entry `main` free function (the C `main` calls it), or -1.
fn main_index(decls: [ps.Decl]) -> int {
    var idx = 0
    var i = 0
    loop {
        if i >= decls.len() {
            break
        }
        match decls[i] {
            case DFn(f) {
                if f.has_body {
                    if f.name == "main" {
                        return idx
                    }
                    idx = idx + 1
                }
            }
            case DStruct(name, generics, impls, fields, methods, kind) {
                var mi = 0
                loop {
                    if mi >= methods.len() {
                        break
                    }
                    if methods[mi].has_body {
                        idx = idx + 1
                    }
                    mi = mi + 1
                }
            }
            case _ {
            }
        }
        i = i + 1
    }
    return 0 - 1
}


// emit_program writes the whole C translation unit for the merged module declarations, byte-identical to
// stage-0 `emberc --emit=c`. It iterates `decls` once per section, keeping a shared em_fn_N counter.
fn emit_program(decls: [ps.Decl], filename: string) {
    let total = fn_count(decls)
    println("// Generated by `emberc --emit=c` from {filename}. Do not edit.")
    println("// The bytecode VM is the reference semantics; tests/native diffs the two.")
    println("#include \"ember_rt.h\"")
    println("")
    println("static EmberRt g_em;")
    println("")
    // forward declarations, in em_fn_N order
    var fwd = 0
    var i = 0
    loop {
        if i >= decls.len() {
            break
        }
        match decls[i] {
            case DFn(f) {
                if f.has_body {
                    println("static Value em_fn_{fwd}({fn_param_list(f, false)});")
                    fwd = fwd + 1
                }
            }
            case DStruct(name, generics, impls, fields, methods, kind) {
                var mi = 0
                loop {
                    if mi >= methods.len() {
                        break
                    }
                    if methods[mi].has_body {
                        println("static Value em_fn_{fwd}({fn_param_list(methods[mi], true)});")
                        fwd = fwd + 1
                    }
                    mi = mi + 1
                }
            }
            case _ {
            }
        }
        i = i + 1
    }
    println("")
    // the em_invoke dispatcher
    println("Value em_invoke(EmberRt *ctx, int fn_index, Value *slots) \{")
    println("    (void)ctx; (void)slots;")
    println("    switch (fn_index) \{")
    var inv = 0
    var j = 0
    loop {
        if j >= decls.len() {
            break
        }
        match decls[j] {
            case DFn(f) {
                if f.has_body {
                    println("        case {inv}: \{")
                    println("            Value _r = em_fn_{inv}({invoke_args(value_arity(f, false))});")
                    println("            return _r;")
                    println("        \}")
                    inv = inv + 1
                }
            }
            case DStruct(name, generics, impls, fields, methods, kind) {
                var mi = 0
                loop {
                    if mi >= methods.len() {
                        break
                    }
                    if methods[mi].has_body {
                        println("        case {inv}: \{")
                        println("            Value _r = em_fn_{inv}({invoke_args(value_arity(methods[mi], true))});")
                        println("            return _r;")
                        println("        \}")
                        inv = inv + 1
                    }
                    mi = mi + 1
                }
            }
            case _ {
            }
        }
        j = j + 1
    }
    println("        default: break;")
    println("    \}")
    println("    em_panic(\"em_invoke: not a callable function\");")
    println("    return INT_VAL(0);")
    println("\}")
    println("")
    // the function bodies
    var b = 0
    var k = 0
    loop {
        if k >= decls.len() {
            break
        }
        match decls[k] {
            case DFn(f) {
                if f.has_body {
                    emit_fn_body(f, b, false)
                    b = b + 1
                    if b < total {
                        println("")
                    }
                }
            }
            case DStruct(name, generics, impls, fields, methods, kind) {
                var mi = 0
                loop {
                    if mi >= methods.len() {
                        break
                    }
                    if methods[mi].has_body {
                        emit_fn_body(methods[mi], b, true)
                        b = b + 1
                        if b < total {
                            println("")
                        }
                    }
                    mi = mi + 1
                }
            }
            case _ {
            }
        }
        k = k + 1
    }
    println("")
    // the C main wrapper, invoking the Ember `main`
    let mi = main_index(decls)
    println("int main(int argc, char **argv) \{")
    println("    em_argc = argc - 1; em_argv = argv + 1;")
    println("    g_em.structs = 0;")
    println("    g_em.struct_count = 0;")
    println("    g_em.invoke = em_invoke;")
    println("    Value r = em_fn_{mi}();")
    println("    if (IS_INT(r)) printf(\"=> %lld\\n\", (long long)AS_INT(r));")
    println("    else if (IS_FLOAT(r)) printf(\"=> %g\\n\", AS_FLOAT(r));")
    println("    else if (IS_STRING(r)) printf(\"=> %s\\n\", AS_CSTRING(r));")
    println("    else printf(\"=> <obj>\\n\");")
    println("    rt_free_objects(&g_em);")
    println("    return 0;")
    println("\}")
}
