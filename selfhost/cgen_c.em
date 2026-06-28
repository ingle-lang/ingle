// selfhost/cgen_c.em — the M5 self-hosted C-EMIT backend (AST → C), mirroring src/cgen_c.c. It is the
// 5th and final component of stage-0 ported to Ember: completing it makes the self-hosted compiler a full
// mirror of stage-0 (lexer → parser → checker → bytecode → C-emit), able to produce native binaries the
// same way (`emberc -o`), and is the path to the kernel's bare-metal codegen. Verified byte-identical to
// stage-0 `emberc --emit=c` via tools/ccdiff.sh — the same differential methodology as every other stage.
//
// Built incrementally (like the bytecode codegen.em was): M5a = the program SCAFFOLD + scalar bodies, then
// strings, structs, control flow, etc. The driver is selfhost/cgen_c_dump.em.

import "parser" as ps
import "lexer" as lx


// build_fn_names lists every body-bearing function (struct methods as `Struct.method`, then free fns) in
// DECLARATION order — the em_fn_N numbering, so a call resolves to the right `em_fn_<index>`.
fn build_fn_names(decls: [ps.Decl]) -> [string] {
    var out: [string] = []
    var i = 0
    loop {
        if i >= decls.len() {
            break
        }
        match decls[i] {
            case DFn(f) {
                if f.has_body {
                    out.append(f.name)
                }
            }
            case DStruct(name, generics, impls, fields, methods, kind) {
                var mi = 0
                loop {
                    if mi >= methods.len() {
                        break
                    }
                    if methods[mi].has_body {
                        out.append(name + "." + methods[mi].name)
                    }
                    mi = mi + 1
                }
            }
            case _ {
            }
        }
        i = i + 1
    }
    return out
}


// ty_scalar_kind maps a numeric type annotation to its C width-kind (0 i64 … 9 f64), or -1 for any
// non-scalar (string/struct/array/etc). M5a handles the i64 (`int`/`i64`) subset; sized/float follow.
fn ty_scalar_kind(t: ps.Ty) -> int {
    match t {
        case TyName(qual, name) {
            if qual != "" {
                return 0 - 1
            }
            if name == "int" || name == "i64" {
                return 0
            }
            return 0 - 1
        }
        case _ {
            return 0 - 1
        }
    }
}


// ret_scalar_kind is a function's return-type width-kind (-1 if it returns a non-scalar / nothing).
fn ret_scalar_kind(f: ps.FnDecl) -> int {
    if f.ret.len() == 0 {
        return 0 - 1
    }
    return ty_scalar_kind(f.ret[0])
}


// build_fn_ret_kinds is the return width-kind of every body-bearing fn, parallel to build_fn_names.
fn build_fn_ret_kinds(decls: [ps.Decl]) -> [int] {
    var out: [int] = []
    var i = 0
    loop {
        if i >= decls.len() {
            break
        }
        match decls[i] {
            case DFn(f) {
                if f.has_body {
                    out.append(ret_scalar_kind(f))
                }
            }
            case DStruct(name, generics, impls, fields, methods, kind) {
                var mi = 0
                loop {
                    if mi >= methods.len() {
                        break
                    }
                    if methods[mi].has_body {
                        out.append(ret_scalar_kind(methods[mi]))
                    }
                    mi = mi + 1
                }
            }
            case _ {
            }
        }
        i = i + 1
    }
    return out
}


// scalar_ctype maps a width-kind to its C storage type (mirrors cgen_c.c:scalar_ctype; M5a uses 0 = i64).
fn scalar_ctype(kind: int) -> string {
    if kind == 0 {
        return "int64_t"
    }
    if kind == 1 {
        return "int8_t"
    }
    if kind == 2 {
        return "int16_t"
    }
    if kind == 3 {
        return "int32_t"
    }
    if kind == 4 {
        return "uint8_t"
    }
    if kind == 5 {
        return "uint16_t"
    }
    if kind == 6 {
        return "uint32_t"
    }
    if kind == 7 {
        return "uint64_t"
    }
    if kind == 8 {
        return "float"
    }
    if kind == 9 {
        return "double"
    }
    return "int64_t"
}


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


// ---- the C-emit generator state (mirrors src/cgen_c.c's CgcGen) -------------------------------------
// next_var is the per-function `v%d` temp counter (retain temps + scalar `let` bindings share it). The
// scope maps an in-scope binding NAME to its C expression (`a0` for a param, `v3` for a `let`) and its
// scalar width-kind (0 i64 … 9 f64, or -1 for a Value/struct binding). fn_names lets a call resolve to
// `em_fn_<index>`. Built per increment, like the bytecode codegen.em was.
struct CgcGen {
    next_var: int
    sc_name: [string]          // binding name
    sc_cname: [string]         // ...its C expression (a param `aN`, or a `let` temp `vN`)
    sc_kind: [int]             // ...its scalar TYPE width-kind (for `let` inference), or -1 for a non-scalar
    sc_unboxed: [bool]         // ...is the STORAGE an unboxed C scalar (a scalar `let` vN, re-box on read)?
                               // a param is a Value (a0, read as-is) even when its TYPE is a scalar.
    fn_names: [string]         // every body-bearing fn in em_fn_N order (free fns + `Struct.method`)
    fn_ret_kind: [int]         // ...each fn's return width-kind (for a `let x = f()` scalar binding)


    fn fresh_var(mut self) -> int {
        let v = self.next_var
        self.next_var = self.next_var + 1
        return v
    }


    fn push(mut self, name: string, cname: string, kind: int, unboxed: bool) {
        self.sc_name.append(name)
        self.sc_cname.append(cname)
        self.sc_kind.append(kind)
        self.sc_unboxed.append(unboxed)
    }


    fn lookup_unboxed(self, name: string) -> bool {
        var i = self.sc_name.len() - 1
        loop {
            if i < 0 {
                break
            }
            if self.sc_name[i] == name {
                return self.sc_unboxed[i]
            }
            i = i - 1
        }
        return false
    }


    // lookup_cname / lookup_kind resolve the nearest in-scope binding `name` (-1 kind / "" cname if none).
    fn lookup_cname(self, name: string) -> string {
        var i = self.sc_name.len() - 1
        loop {
            if i < 0 {
                break
            }
            if self.sc_name[i] == name {
                return self.sc_cname[i]
            }
            i = i - 1
        }
        return ""
    }


    fn lookup_kind(self, name: string) -> int {
        var i = self.sc_name.len() - 1
        loop {
            if i < 0 {
                break
            }
            if self.sc_name[i] == name {
                return self.sc_kind[i]
            }
            i = i - 1
        }
        return 0 - 1
    }


    fn fn_index(self, name: string) -> int {
        var i = 0
        loop {
            if i >= self.fn_names.len() {
                break
            }
            if self.fn_names[i] == name {
                return i
            }
            i = i + 1
        }
        return 0 - 1
    }


    // ---- expression emission (M5a: int scalars — literals, idents, binops, user calls) --------------
    // emit_expr returns the C expression text for `e`. An in-scope SCALAR binding is re-boxed
    // `INT_VAL((int64_t)vN)`; a Value binding/param is its C name as-is.
    fn emit_expr(mut self, e: ps.Expr) -> string {
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
            case EIdent(name) {
                let cn = self.lookup_cname(name)
                if self.lookup_unboxed(name) {
                    return "INT_VAL((int64_t){cn})"      // an unboxed scalar `let` boxes back to a Value
                }
                return cn                                // a param / Value binding is read as-is
            }
            case EBinary(op, l, r) {
                return self.emit_binary(op, l.value, r.value)
            }
            case ECall(callee, args) {
                return self.emit_call(callee.value, args)
            }
            case _ {
                return "INT_VAL(0)"
            }
        }
    }


    // emit_binary mirrors cgen_c.c:emit_binary — each operator maps to an em_* runtime call; em_add /
    // em_eq_op / em_neq_op take the runtime ctx (`&g_em`) and RETAIN a borrowed operand (they consume),
    // every other op reads its operands directly. The numeric ops carry the width as a trailing num_kind
    // (0 = i64 for the int subset).
    fn emit_binary(mut self, op: lx.Tk, l: ps.Expr, r: ps.Expr) -> string {
        let bid = ps.binop_id(op)
        // short-circuit && / || — a truthy test, not an em_ call (binop_id 12 && / 13 ||)
        if bid == 12 || bid == 13 {
            var c = "&&"
            if bid == 13 {
                c = "||"
            }
            return "INT_VAL((em_truthy({self.emit_expr(l)}) {c} em_truthy({self.emit_expr(r)})) ? 1 : 0)"
        }
        let cf = binop_cfn(bid)
        let ctx = binop_wants_ctx(bid)
        var s = "{cf}("
        if ctx {
            s = s + "&g_em, "
        }
        if ctx {
            s = s + self.emit_concat_operand(l) + ", " + self.emit_concat_operand(r)
        } else {
            s = s + self.emit_expr(l) + ", " + self.emit_expr(r)
        }
        if binop_has_nk(bid) {
            s = s + ", 0"                                // num_kind 0 (i64) for the int subset
        }
        return s + ")"
    }


    // emit_concat_operand wraps a BORROWED operand (an ident read / field read / array index) in the
    // retain dance so a consuming op (em_add/eq/neq) keeps the owner's reference balanced; anything else
    // (a literal/call/computed temp) is emitted as-is. (M5a: only the ident-borrow case arises.)
    fn emit_concat_operand(mut self, e: ps.Expr) -> string {
        var borrow = false
        match e {
            case EIdent(name) {
                borrow = true
            }
            case _ {
            }
        }
        if borrow {
            let v = self.fresh_var()
            return "(\{ Value v{v} = {self.emit_expr(e)}; if (IS_OBJ(v{v})) OBJ_RETAIN(AS_OBJ(v{v})); v{v}; \})"
        }
        return self.emit_expr(e)
    }


    // emit_call emits a user free-function call `f(args)` → `em_fn_<index>(<args>)`.
    fn emit_call(mut self, callee: ps.Expr, args: [ps.Expr]) -> string {
        match callee {
            case EIdent(name) {
                let fi = self.fn_index(name)
                if fi >= 0 {
                    var s = "em_fn_{fi}("
                    var i = 0
                    loop {
                        if i >= args.len() {
                            break
                        }
                        if i > 0 {
                            s = s + ", "
                        }
                        s = s + self.emit_expr(args[i])
                        i = i + 1
                    }
                    return s + ")"
                }
            }
            case _ {
            }
        }
        return "INT_VAL(0)"
    }


    // scalar_kind_of statically classifies an expression's numeric width-kind (0 i64 … for the M5a int
    // subset), or -1 if it is not a known scalar (a string/struct/Value). Drives the `let` storage choice.
    fn scalar_kind_of(self, e: ps.Expr) -> int {
        match e {
            case EInt(v) {
                return 0
            }
            case EBinary(op, l, r) {
                let bid = ps.binop_id(op)
                // arithmetic / bitwise / shift produce a numeric value; comparisons/logic produce a bool
                if bid >= 1 && bid <= 5 {
                    return 0
                }
                if bid >= 14 && bid <= 18 {
                    return 0
                }
                return 0 - 1
            }
            case ECall(callee, args) {
                match callee.value {
                    case EIdent(name) {
                        let fi = self.fn_index(name)
                        if fi >= 0 {
                            return self.fn_ret_kind[fi]
                        }
                    }
                    case _ {
                    }
                }
                return 0 - 1
            }
            case EIdent(name) {
                return self.lookup_kind(name)
            }
            case _ {
                return 0 - 1
            }
        }
    }


    // emit_stmt prints the C for one statement (4-space indented inside a function body).
    fn emit_stmt(mut self, s: ps.Stmt) {
        match s {
            case SReturn(value, line) {
                if value.len() > 0 {
                    println("    return {self.emit_expr(value[0].value)};")
                } else {
                    println("    return UNIT_VAL;")
                }
            }
            case SLet(is_var, name, ty, value) {
                // The binding's C variable number is taken BEFORE the initialiser (so a `let` is vN and the
                // initialiser's retain temps follow as v(N+1)…). A scalar binding lowers to a typed C scalar
                // unboxed from the Value (`int64_t vN = (int64_t)AS_INT(<rhs>)`); a Value binding retains a
                // borrowed initialiser. (cgen_c.c:STMT_LET; M5a covers the i64 scalar + plain Value cases.)
                let id = self.fresh_var()
                let kind = self.scalar_kind_of(value.value)
                if kind >= 0 {
                    let ct = scalar_ctype(kind)
                    println("    {ct} v{id} = ({ct})AS_INT({self.emit_expr(value.value)});")
                    self.push(name, "v{id}", kind, true)        // unboxed C scalar storage
                } else {
                    println("    Value v{id} = {self.emit_concat_operand(value.value)};")
                    self.push(name, "v{id}", 0 - 1, false)
                }
            }
            case _ {
            }
        }
    }
}


// binop_cfn maps a binop id (ps.binop_id) to its em_* runtime C function.
fn binop_cfn(bid: int) -> string {
    if bid == 1 { return "em_add" }
    if bid == 2 { return "em_sub" }
    if bid == 3 { return "em_mul" }
    if bid == 4 { return "em_div" }
    if bid == 5 { return "em_mod" }
    if bid == 6 { return "em_eq_op" }
    if bid == 7 { return "em_neq_op" }
    if bid == 8 { return "em_lt" }
    if bid == 9 { return "em_le" }
    if bid == 10 { return "em_gt" }
    if bid == 11 { return "em_ge" }
    if bid == 14 { return "em_bitand" }
    if bid == 15 { return "em_bitor" }
    if bid == 16 { return "em_bitxor" }
    if bid == 17 { return "em_shl" }
    if bid == 18 { return "em_shr" }
    return "em_add"
}


// binop_wants_ctx: em_add / em_eq_op / em_neq_op take `&g_em` and retain their (consumed) operands.
fn binop_wants_ctx(bid: int) -> bool {
    return bid == 1 || bid == 6 || bid == 7
}


// binop_has_nk: the numeric ops (arithmetic + ordered compares + shifts) carry a trailing num_kind;
// equality and bitwise ops do not.
fn binop_has_nk(bid: int) -> bool {
    return bid == 1 || bid == 2 || bid == 3 || bid == 4 || bid == 5 || bid == 8 || bid == 9 || bid == 10 || bid == 11 || bid == 17 || bid == 18
}


// emit_fn_body prints a single function's C definition: `static Value em_fn_N(params) { … }` with the
// implicit trailing `return INT_VAL(0);` stage-0 always emits. The params are pushed into scope as the
// Value bindings a0, a1, … (a method's `self` is the leading a0). (C braces escaped `\{`/`\}`.)
fn emit_fn_body(f: ps.FnDecl, idx: int, has_self: bool, fn_names: [string], fn_ret_kind: [int]) {
    var g = CgcGen{ next_var: 0, sc_name: [], sc_cname: [], sc_kind: [], sc_unboxed: [], fn_names: fn_names, fn_ret_kind: fn_ret_kind }
    var ai = 0
    if has_self {
        g.push("self", "a0", 0 - 1, false)
        ai = 1
    }
    var p = 0
    loop {
        if p >= f.params.len() {
            break
        }
        if f.params[p].is_self == false {
            // a param's TYPE scalar-kind (so `let x = a` infers a scalar) — but its STORAGE is the Value aN.
            var pk = 0 - 1
            if f.params[p].ty.len() > 0 {
                pk = ty_scalar_kind(f.params[p].ty[0])
            }
            g.push(f.params[p].name, "a{ai}", pk, false)
            ai = ai + 1
        }
        p = p + 1
    }
    println("static Value em_fn_{idx}({fn_param_list(f, has_self)}) \{")
    var i = 0
    loop {
        if i >= f.body.len() {
            break
        }
        g.emit_stmt(f.body[i])
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
    let fn_names = build_fn_names(decls)
    let fn_ret_kind = build_fn_ret_kinds(decls)
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
                    emit_fn_body(f, b, false, fn_names, fn_ret_kind)
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
                        emit_fn_body(methods[mi], b, true, fn_names, fn_ret_kind)
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
