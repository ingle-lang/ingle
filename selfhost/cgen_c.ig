// selfhost/cgen_c.ig — the M5 self-hosted C-EMIT backend (AST → C), mirroring src/cgen_c.c. It is the
// 5th and final component of stage-0 ported to Ingle: completing it makes the self-hosted compiler a full
// mirror of stage-0 (lexer → parser → checker → bytecode → C-emit), able to produce native binaries the
// same way (`inglec -o`), and is the path to the kernel's bare-metal codegen. Verified byte-identical to
// stage-0 `inglec --emit=c` via tools/ccdiff.sh — the same differential methodology as every other stage.
//
// Built incrementally (like the bytecode codegen.ig was): M5a = the program SCAFFOLD + scalar bodies, then
// strings, structs, control flow, etc. The driver is selfhost/cgen_c_dump.ig.

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


// cgc_internal_error mirrors stage-0's internal_error (exit 70): an emitter coverage hole must FAIL
// LOUDLY, never lower to a silent `INT_VAL(0)` placeholder that miscompiles (the OFI-173/202/206
// silent-stub class, closed as OFI-218 Phase 0). The unreachable trailing return satisfies the
// checker — Ingle has no diverging primitive yet (the OFI-187 `panic` gap, OFI-218 Phase 5).
fn cgc_internal_error(what: string) -> string {
    println("inglec (selfhost cgen_c): internal error: {what}")
    exit(70)
    return "INT_VAL(0)"
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


// render_kind_of_ty maps a type annotation to its interpolation render-kind (check.c int_kind + the bool
// special-case): 0 int/i64/non-numeric · 1 i8 · 2 i16 · 3 i32 · 4 u8 · 5 u16 · 6 u32 · 7 u64 · 8 f32 ·
// 9 float(f64) · 10 bool. em_to_string's 3rd arg — how the runtime formats the (untagged) numeric Value.
fn render_kind_of_ty(t: ps.Ty) -> int {
    match t {
        case TyName(qual, name) {
            if qual != "" {
                return 0
            }
            if name == "bool" {
                return 10
            }
            if name == "f32" {
                return 8
            }
            if name == "float" || name == "f64" {
                return 9
            }
            if name == "i8" {
                return 1
            }
            if name == "i16" {
                return 2
            }
            if name == "i32" {
                return 3
            }
            if name == "u8" {
                return 4
            }
            if name == "u16" {
                return 5
            }
            if name == "u32" {
                return 6
            }
            if name == "u64" {
                return 7
            }
            return 0
        }
        case _ {
            return 0
        }
    }
}


// is_array_ty reports whether a type annotation is an array `[T]`.
fn is_array_ty(t: ps.Ty) -> bool {
    match t {
        case TyArray(elem) {
            return true
        }
        case _ {
            return false
        }
    }
}


// elem_ty_of returns the element type of an array annotation `[T]` (or the type itself if not an array).
fn elem_ty_of(t: ps.Ty) -> ps.Ty {
    match t {
        case TyArray(elem) {
            return elem.value
        }
        case _ {
            return t
        }
    }
}


// array_elem_kind_ty maps an element TYPE to its runtime ArrayElemKind byte (value.h AEK_*): BOXED 0,
// i8..i64 1..4, u8..u64 5..8, f32 9, f64 10, bool 11. A string/struct/array element is BOXED (0).
fn array_elem_kind_ty(t: ps.Ty) -> int {
    match t {
        case TyName(qual, name) {
            if qual != "" {
                return 0
            }
            if name == "i8" { return 1 }
            if name == "i16" { return 2 }
            if name == "i32" { return 3 }
            if name == "int" || name == "i64" { return 4 }
            if name == "u8" { return 5 }
            if name == "u16" { return 6 }
            if name == "u32" { return 7 }
            if name == "u64" { return 8 }
            if name == "f32" { return 9 }
            if name == "f64" || name == "float" { return 10 }
            if name == "bool" { return 11 }
            return 0
        }
        case _ {
            return 0
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


// build_extern_names lists every `extern "c"` fn name (the hosted-registry + direct externs a program
// DECLARES), so a call site can resolve the extern's declared signature — cgen_c has no body for these,
// so they are absent from build_fn_names; this is their parallel side table. OFI-218 P6 FFI.
fn build_extern_names(decls: [ps.Decl]) -> [string] {
    var out: [string] = []
    var i = 0
    loop {
        if i >= decls.len() {
            break
        }
        match decls[i] {
            case DExtern(abi, fns) {
                var e = 0
                loop {
                    if e >= fns.len() {
                        break
                    }
                    out.append(fns[e].name)
                    e = e + 1
                }
            }
            case _ {
            }
        }
        i = i + 1
    }
    return out
}


// build_extern_ret_kinds is each declared extern's return width-kind (parallel to build_extern_names) — so a
// `let s = sin(0.0)` binds a native `double` (kind 9) not a boxed Value, matching stage-0. The DECLARED
// return type drives it (i32 vs i64 differ only in the declaration — the comment in tests/…/ffi.ig).
fn build_extern_ret_kinds(decls: [ps.Decl]) -> [int] {
    var out: [int] = []
    var i = 0
    loop {
        if i >= decls.len() {
            break
        }
        match decls[i] {
            case DExtern(abi, fns) {
                var e = 0
                loop {
                    if e >= fns.len() {
                        break
                    }
                    out.append(ret_scalar_kind(fns[e]))
                    e = e + 1
                }
            }
            case _ {
            }
        }
        i = i + 1
    }
    return out
}


// build_extern_ret_str marks each declared extern that returns a `string` (parallel to build_extern_names),
// so `let o = proc_stdout(h)` / `let body = http_get(url)` binds an OWNED string (dropped at scope exit) and
// `o.len()` resolves to em_str_len. The registry copies+owns such returns (g_sigs' returns-owned flag).
fn build_extern_ret_str(decls: [ps.Decl]) -> [bool] {
    var out: [bool] = []
    var i = 0
    loop {
        if i >= decls.len() {
            break
        }
        match decls[i] {
            case DExtern(abi, fns) {
                var e = 0
                loop {
                    if e >= fns.len() {
                        break
                    }
                    out.append(fns[e].ret.len() > 0 && is_string_ty(fns[e].ret[0]))
                    e = e + 1
                }
            }
            case _ {
            }
        }
        i = i + 1
    }
    return out
}


// build_fn_ret_render is each body-bearing fn's return-type INTERPOLATION render-kind (parallel to
// build_fn_names): 0 int · 8 f32 · 9 float · 10 bool · 1..7 sized. So a hole over a call `{r.ok()}` renders
// its bool as "true"/"false" (tag 10), not "1"/"0" — the checker stamps this per hole; the self-hosted
// C-emit recovers it from the callee's declared return type. Distinct from fn_ret_kind (a numeric WIDTH).
fn build_fn_ret_render(decls: [ps.Decl]) -> [int] {
    var out: [int] = []
    var i = 0
    loop {
        if i >= decls.len() {
            break
        }
        match decls[i] {
            case DFn(f) {
                if f.has_body {
                    out.append(fn_ret_render_kind(f))
                }
            }
            case DStruct(name, generics, impls, fields, methods, kind) {
                var mi = 0
                loop {
                    if mi >= methods.len() {
                        break
                    }
                    if methods[mi].has_body {
                        out.append(fn_ret_render_kind(methods[mi]))
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


// fn_ret_render_kind is a fn's return-type render-kind (0 for a unit/non-numeric return).
fn fn_ret_render_kind(f: ps.FnDecl) -> int {
    if f.ret.len() == 0 {
        return 0
    }
    return render_kind_of_ty(f.ret[0])
}


// generic_index returns the 0-based position of type-param `name` in `generics`, or -1.
fn generic_index(generics: [ps.GenericParam], name: string) -> int {
    var i = 0
    loop {
        if i >= generics.len() {
            break
        }
        if generics[i].name == name {
            return i
        }
        i = i + 1
    }
    return 0 - 1
}


// method_opt_payload_param inspects a METHOD's return type: if it is `Option<Vp>` or `Result<Vp, …>` where
// `Vp` is one of the OWNER struct's generic params, it returns that param's INDEX in `owner_generics` (so a
// call site can read the receiver's concrete type-arg at that index — `Map<string,Rect>.get()` → Option<V>,
// V is param 1, so the Some payload is the receiver's arg[1] = Rect). Returns -1 otherwise. The self-hosted
// re-derivation of stage-0's `subst(inst, var->fields[b])` — there is no checker to stamp the concrete sid.
fn method_opt_payload_param(m: ps.FnDecl, owner_generics: [ps.GenericParam]) -> int {
    if m.ret.len() == 0 {
        return 0 - 1
    }
    match m.ret[0] {
        case TyGeneric(q, n, args) {
            if q == "" && (n == "Option" || n == "Result") && args.len() >= 1 {
                match args[0] {
                    case TyName(q2, pname) {
                        if q2 == "" {
                            return generic_index(owner_generics, pname)   // the Some/Ok payload param's index
                        }
                    }
                    case _ {
                    }
                }
            }
        }
        case _ {
        }
    }
    return 0 - 1
}


// build_ret_opt_param is parallel to build_fn_names: for a method whose return is Option/Result of an OWNER
// generic param, the param INDEX (so a `match recv.get(k) { case Some(r) … }` types `r` from recv's concrete
// type-arg); -1 for a free fn or a non-generic-payload return. Keyed by em_fn index like the other ret tables.
fn build_ret_opt_param(decls: [ps.Decl]) -> [int] {
    var out: [int] = []
    var i = 0
    loop {
        if i >= decls.len() {
            break
        }
        match decls[i] {
            case DFn(f) {
                if f.has_body {
                    out.append(0 - 1)          // a free fn is not a container method
                }
            }
            case DStruct(name, generics, impls, fields, methods, kind) {
                var mi = 0
                loop {
                    if mi >= methods.len() {
                        break
                    }
                    if methods[mi].has_body {
                        out.append(method_opt_payload_param(methods[mi], generics))
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


// ---- generic return-type resolution (OFI-206 follow-on) — the C-emit mirror of the VM's gret machinery -
// A generic fn returning a bare type-param T or `[T]` (`reduce<T,U>(…, init:U, …)->U`, `sort<T>(xs:[T],…)->[T]`)
// has an unknown static return kind (ty_scalar_kind(T) = -1). We resolve T at a call site from the value
// arg that determines it (init for reduce, xs's element for sort), so `let total = reduce(…)` binds int not
// Value and `bylen[i]` types as its element. Mirrors codegen.ig's ret_tparam_name / param_of_shape_index.

// ret_tparam_name returns the type-param NAME a fn's return exposes: `T` for a `-> T` or `-> [T]` return
// (T one of the fn's generics), else "".
fn ret_tparam_name(ret: ps.Ty, generics: [ps.GenericParam]) -> string {
    match ret {
        case TyName(qual, name) {
            if qual == "" && generic_named(generics, name) {
                return name
            }
        }
        case TyArray(elem) {
            match elem.value {
                case TyName(q2, n2) {
                    if q2 == "" && generic_named(generics, n2) {
                        return n2
                    }
                }
                case _ {
                }
            }
        }
        case _ {
        }
    }
    return ""
}


// generic_named reports whether `name` is one of a fn's generic type-param names.
fn generic_named(generics: [ps.GenericParam], name: string) -> bool {
    var i = 0
    loop {
        if i >= generics.len() {
            break
        }
        if generics[i].name == name {
            return true
        }
        i = i + 1
    }
    return false
}


// ret_det_arg returns the VALUE-arg index that determines a fn's return type-param (the first value param
// typed exactly `tp` or `[tp]`), or -1. `out_elem` companion below reports whether it was `[tp]` (element).
fn ret_det_arg(f: ps.FnDecl, tp: string) -> int {
    var i = 0
    var vidx = 0
    loop {
        if i >= f.params.len() {
            break
        }
        if f.params[i].is_self == false {
            if f.params[i].ty.len() > 0 {
                match f.params[i].ty[0] {
                    case TyName(q, n) {
                        if q == "" && n == tp {
                            return vidx
                        }
                    }
                    case TyArray(elem) {
                        match elem.value {
                            case TyName(q2, n2) {
                                if q2 == "" && n2 == tp {
                                    return vidx
                                }
                            }
                            case _ {
                            }
                        }
                    }
                    case _ {
                    }
                }
            }
            vidx = vidx + 1
        }
        i = i + 1
    }
    return 0 - 1
}


// ret_det_is_elem reports whether the determining value arg (at ret_det_arg) is typed `[tp]` (so the return
// type-param is the arg's ELEMENT — sort) rather than `tp` (the whole arg — reduce).
fn ret_det_is_elem(f: ps.FnDecl, tp: string) -> bool {
    var i = 0
    loop {
        if i >= f.params.len() {
            break
        }
        if f.params[i].is_self == false && f.params[i].ty.len() > 0 {
            match f.params[i].ty[0] {
                case TyName(q, n) {
                    if q == "" && n == tp {
                        return false
                    }
                }
                case TyArray(elem) {
                    match elem.value {
                        case TyName(q2, n2) {
                            if q2 == "" && n2 == tp {
                                return true
                            }
                        }
                        case _ {
                        }
                    }
                }
                case _ {
                }
            }
        }
        i = i + 1
    }
    return false
}


// build_ret_det builds, per em_fn slot, the determining value-arg index for a type-param return (-1 if the
// return is not a bare `T`/`[T]`) — parallel to build_fn_ret_kinds.
fn build_ret_det_arg(decls: [ps.Decl]) -> [int] {
    var out: [int] = []
    var i = 0
    loop {
        if i >= decls.len() {
            break
        }
        match decls[i] {
            case DFn(f) {
                if f.has_body {
                    let tp = ret_tparam_name_of(f)
                    if tp == "" {
                        out.append(0 - 1)
                    } else {
                        out.append(ret_det_arg(f, tp))
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
                        out.append(0 - 1)             // struct methods: no bare-tparam-return resolution needed yet
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


fn build_ret_det_elem(decls: [ps.Decl]) -> [bool] {
    var out: [bool] = []
    var i = 0
    loop {
        if i >= decls.len() {
            break
        }
        match decls[i] {
            case DFn(f) {
                if f.has_body {
                    let tp = ret_tparam_name_of(f)
                    if tp == "" {
                        out.append(false)
                    } else {
                        out.append(ret_det_is_elem(f, tp))
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
                        out.append(false)
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


// ret_tparam_name_of returns a free fn's return type-param name (or "") — the fn-decl convenience wrapper.
fn ret_tparam_name_of(f: ps.FnDecl) -> string {
    if f.ret.len() == 0 {
        return ""
    }
    return ret_tparam_name(f.ret[0], f.generics)
}


// ---- map-style return inference: a fn returning `[U]` where U is a fn-arg's RETURN type (map) -----------
// `map<T,U>(xs:[T], f:fn(T)->U)->[U]` has its return ELEMENT = the lambda arg's return type — which needs
// the lambda body typed with its param typed from xs's element. ret_lam_arg = the lambda value-arg index,
// ret_lam_in = the input-array value-arg index (typing the lambda's param). Both -1 if not map-shaped.

// tyfn_ret_tparam returns a fn-typed param's RETURN type-param name (`fn(T)->U` -> "U"), or "".
fn tyfn_ret_tparam(t: ps.Ty) -> string {
    match t {
        case TyFn(fparams, fret) {
            if fret.len() > 0 {
                match fret[0] {
                    case TyName(q, n) {
                        if q == "" {
                            return n
                        }
                    }
                    case _ {
                    }
                }
            }
        }
        case _ {
        }
    }
    return ""
}


// tyfn_param0_tparam returns a fn-typed param's FIRST-param type-param name (`fn(T)->U` -> "T"), or "".
fn tyfn_param0_tparam(t: ps.Ty) -> string {
    match t {
        case TyFn(fparams, fret) {
            if fparams.len() > 0 {
                match fparams[0] {
                    case TyName(q, n) {
                        if q == "" {
                            return n
                        }
                    }
                    case _ {
                    }
                }
            }
        }
        case _ {
        }
    }
    return ""
}


// value_param_typed_array returns the value-arg index of the first param typed `[tp]`, or -1.
fn value_param_typed_array(f: ps.FnDecl, tp: string) -> int {
    var i = 0
    var vidx = 0
    loop {
        if i >= f.params.len() {
            break
        }
        if f.params[i].is_self == false {
            if f.params[i].ty.len() > 0 {
                match f.params[i].ty[0] {
                    case TyArray(elem) {
                        match elem.value {
                            case TyName(q, n) {
                                if q == "" && n == tp {
                                    return vidx
                                }
                            }
                            case _ {
                            }
                        }
                    }
                    case _ {
                    }
                }
            }
            vidx = vidx + 1
        }
        i = i + 1
    }
    return 0 - 1
}


// build_ret_lam_arg / build_ret_lam_in build the map-style tables per em_fn slot.
fn build_ret_lam_arg(decls: [ps.Decl]) -> [int] {
    var out: [int] = []
    var i = 0
    loop {
        if i >= decls.len() {
            break
        }
        match decls[i] {
            case DFn(f) {
                if f.has_body {
                    out.append(map_lam_arg_of(f))
                }
            }
            case DStruct(name, generics, impls, fields, methods, kind) {
                var mi = 0
                loop {
                    if mi >= methods.len() {
                        break
                    }
                    if methods[mi].has_body {
                        out.append(0 - 1)
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


fn build_ret_lam_in(decls: [ps.Decl]) -> [int] {
    var out: [int] = []
    var i = 0
    loop {
        if i >= decls.len() {
            break
        }
        match decls[i] {
            case DFn(f) {
                if f.has_body {
                    out.append(map_lam_in_of(f))
                }
            }
            case DStruct(name, generics, impls, fields, methods, kind) {
                var mi = 0
                loop {
                    if mi >= methods.len() {
                        break
                    }
                    if methods[mi].has_body {
                        out.append(0 - 1)
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


// map_lam_arg_of returns a map-shaped fn's LAMBDA value-arg index (the `f:fn(T)->U` returning the `[U]`
// return's element U), or -1. map_lam_in_of returns the INPUT-array value-arg index (typed `[T]`).
fn map_lam_arg_of(f: ps.FnDecl) -> int {
    let u = map_ret_elem_tparam(f)
    if u == "" {
        return 0 - 1
    }
    var i = 0
    var vidx = 0
    loop {
        if i >= f.params.len() {
            break
        }
        if f.params[i].is_self == false {
            if f.params[i].ty.len() > 0 && tyfn_ret_tparam(f.params[i].ty[0]) == u {
                return vidx
            }
            vidx = vidx + 1
        }
        i = i + 1
    }
    return 0 - 1
}


fn map_lam_in_of(f: ps.FnDecl) -> int {
    let u = map_ret_elem_tparam(f)
    if u == "" {
        return 0 - 1
    }
    // find the fn param returning U, get its first-param type-param T, then the value param typed [T].
    var i = 0
    loop {
        if i >= f.params.len() {
            break
        }
        if f.params[i].is_self == false && f.params[i].ty.len() > 0 && tyfn_ret_tparam(f.params[i].ty[0]) == u {
            let tin = tyfn_param0_tparam(f.params[i].ty[0])
            if tin == "" {
                return 0 - 1
            }
            return value_param_typed_array(f, tin)
        }
        i = i + 1
    }
    return 0 - 1
}


// map_ret_elem_tparam returns a fn's return-ELEMENT type-param name when the return is `[U]` (U a generic),
// or "".
fn map_ret_elem_tparam(f: ps.FnDecl) -> string {
    if f.ret.len() == 0 {
        return ""
    }
    match f.ret[0] {
        case TyArray(elem) {
            match elem.value {
                case TyName(q, n) {
                    if q == "" && generic_named(f.generics, n) {
                        return n
                    }
                }
                case _ {
                }
            }
        }
        case _ {
        }
    }
    return ""
}


// value_param_typed_scalar returns the value-arg index of the first param typed exactly `tp` (a bare generic
// type-param, `init: U`), or -1 — the "whole-value" source companion to value_param_typed_array.
fn value_param_typed_scalar(f: ps.FnDecl, tp: string) -> int {
    var i = 0
    var vidx = 0
    loop {
        if i >= f.params.len() {
            break
        }
        if f.params[i].is_self == false {
            if f.params[i].ty.len() > 0 {
                match f.params[i].ty[0] {
                    case TyName(q, n) {
                        if q == "" && n == tp {
                            return vidx
                        }
                    }
                    case _ {
                    }
                }
            }
            vidx = vidx + 1
        }
        i = i + 1
    }
    return 0 - 1
}


// hof_srcs_of returns a FIXED stride-6 param-source block for a higher-order fn `f` — [lam_arg, np, p0_arg,
// p0_elem, p1_arg, p1_elem] — mapping each of the fn-typed param's OWN params (≤2) to the value-arg (whole=0 /
// element=1) that fixes its type: map's `f:fn(T)->U` param0 ← the `[T]` input's element; reduce's `f:fn(U,T)`
// param0 ← the `U` init (whole), param1 ← the `[T]` input's element; sort's `less:fn(T,T)` both ← the input
// element. lam_arg is -1 when `f` has no fn-typed param, >2 lambda params, or a source can't be resolved (the
// lambda body then stays untyped, as before). OFI-206 — recovers the lambda-param types the C-emit lacks.
fn hof_srcs_of(f: ps.FnDecl) -> [int] {
    var out: [int] = []
    out.append(0 - 1)                                // [0] lam_arg  (filled on success)
    out.append(0)                                    // [1] np
    out.append(0 - 1)                                // [2] p0_arg
    out.append(0 - 1)                                // [3] p0_elem
    out.append(0 - 1)                                // [4] p1_arg
    out.append(0 - 1)                                // [5] p1_elem
    // find the fn-typed value param and destructure its TyFn payload (OFI-220 closed — a payload array assigned
    // out is now own_into_slot'd, so we store `fparams` directly rather than routing through helper accessors).
    var i = 0
    var vidx = 0
    var lam_arg = 0 - 1
    var fparams: [ps.Ty] = []
    loop {
        if i >= f.params.len() {
            break
        }
        if f.params[i].is_self == false {
            if lam_arg < 0 && f.params[i].ty.len() > 0 {
                match f.params[i].ty[0] {
                    case TyFn(fps, fret) {
                        lam_arg = vidx
                        fparams = fps
                    }
                    case _ {
                    }
                }
            }
            vidx = vidx + 1
        }
        i = i + 1
    }
    if lam_arg < 0 || fparams.len() > 2 {            // not a HOF, or more lambda params than the stride holds
        return out
    }
    var p = 0
    loop {
        if p >= fparams.len() {
            break
        }
        var tp = ""
        match fparams[p] {
            case TyName(q, n) {
                if q == "" {
                    tp = n
                }
            }
            case _ {
            }
        }
        if tp == "" {
            return out                               // unresolved param → leave lam_arg -1 (block stays inert)
        }
        let ea = value_param_typed_array(f, tp)
        if ea >= 0 {
            out[2 + p * 2] = ea
            out[3 + p * 2] = 1                        // an element source ([T] input)
        } else {
            let wa = value_param_typed_scalar(f, tp)
            if wa < 0 {
                return out
            }
            out[2 + p * 2] = wa
            out[3 + p * 2] = 0                        // a whole-value source (U init)
        }
        p = p + 1
    }
    out[0] = lam_arg
    out[1] = fparams.len()
    return out
}


// build_hof_srcs builds the per-em_fn HOF param-source table as a FLAT stride-6 array (fn slot k occupies
// [k*6 .. k*6+6)); a non-HOF's block has lam_arg -1. (A flat encoding — nested `[[int]]` arrays now compile
// correctly on the self-hosted C-emit, OFI-219 closed, so this is a simplicity choice, no longer required.)
fn build_hof_srcs(decls: [ps.Decl]) -> [int] {
    var out: [int] = []
    var i = 0
    loop {
        if i >= decls.len() {
            break
        }
        match decls[i] {
            case DFn(f) {
                if f.has_body {
                    let blk = hof_srcs_of(f)         // a fresh 6-int block (bind a fn result, then copy scalars)
                    var j = 0
                    loop {
                        if j >= blk.len() {
                            break
                        }
                        out.append(blk[j])
                        j = j + 1
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
                        let blk = hof_srcs_of(methods[mi])
                        var j = 0
                        loop {
                            if j >= blk.len() {
                                break
                            }
                            out.append(blk[j])
                            j = j + 1
                        }
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


// gen_param_mask_of returns a per-value-param bitmask for a fn: bit v is set iff value-param v is a bare
// ERASED generic type-param passed by BORROW (`x: T`, not `move T`). Stage-0's drop_mask masks a fresh owning
// temp at such a param (it is NOT refcounted under erasure, so the callee borrows it and the CALLER drops) —
// unlike a concrete refcounted param (moved/adopted, no caller drop). check.c:3196 `!is_refcounted(param)`.
fn gen_param_mask_of(f: ps.FnDecl, owner_generics: [ps.GenericParam]) -> int {
    var mask = 0
    var i = 0
    var vidx = 0
    loop {
        if i >= f.params.len() {
            break
        }
        if f.params[i].is_self == false {
            // A param is erased (a Value slot) if its type names a type-param of the METHOD or the OWNER struct
            // (`val: V` in a Map<K,V> method) — both are erased in the C-emit's representation.
            if f.params[i].qual != 2 && f.params[i].ty.len() > 0 && (ty_is_generic_param(f.params[i].ty[0], f.generics) || ty_is_generic_param(f.params[i].ty[0], owner_generics)) {
                mask = mask | (1 << vidx)
            }
            vidx = vidx + 1
        }
        i = i + 1
    }
    return mask
}


// build_fn_param_gen_mask builds the per-em_fn generic-borrow-param bitmask table (index = the fn's em_fn
// slot), parallel to build_fn_names. Used by emit_free_call to mask a string temp passed to a generic-T param.
fn build_fn_param_gen_mask(decls: [ps.Decl]) -> [int] {
    var out: [int] = []
    var i = 0
    loop {
        if i >= decls.len() {
            break
        }
        match decls[i] {
            case DFn(f) {
                if f.has_body {
                    out.append(gen_param_mask_of(f, []))
                }
            }
            case DStruct(name, generics, impls, fields, methods, kind) {
                var mi = 0
                loop {
                    if mi >= methods.len() {
                        break
                    }
                    if methods[mi].has_body {
                        out.append(gen_param_mask_of(methods[mi], generics))
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


// c_escape renders a string's bytes as the contents of a C string literal (no surrounding quotes),
// mirroring cgen_c.c:emit_c_string_literal: `"`/`\` are backslash-escaped, newline/tab/CR use their named
// escapes, printable ASCII passes through, and any other byte is a 3-digit octal escape.
fn c_escape(s: string) -> string {
    let bs = s.bytes()
    var out = ""
    var i = 0
    loop {
        if i >= bs.len() {
            break
        }
        let c = int(bs[i])
        if c == 34 || c == 92 {
            out = out + "\\" + from_char_code(c)        // " or \
        } else if c == 10 {
            out = out + "\\n"
        } else if c == 9 {
            out = out + "\\t"
        } else if c == 13 {
            out = out + "\\r"
        } else if c >= 32 && c < 127 {
            out = out + from_char_code(c)
        } else {
            out = out + "\\" + from_char_code(48 + (c / 64)) + from_char_code(48 + ((c / 8) % 8)) + from_char_code(48 + (c % 8))
        }
        i = i + 1
    }
    return out
}


// build_fn_ret_str marks each body-bearing fn (parallel to build_fn_names) that returns a `string`, so a
// `let g = f()` of a string-returning call is tracked as an owned (droppable) binding.
fn build_fn_ret_str(decls: [ps.Decl]) -> [bool] {
    var out: [bool] = []
    var i = 0
    loop {
        if i >= decls.len() {
            break
        }
        match decls[i] {
            case DFn(f) {
                if f.has_body {
                    out.append(f.ret.len() > 0 && is_string_ty(f.ret[0]))
                }
            }
            case DStruct(name, generics, impls, fields, methods, kind) {
                var mi = 0
                loop {
                    if mi >= methods.len() {
                        break
                    }
                    if methods[mi].has_body {
                        out.append(methods[mi].ret.len() > 0 && is_string_ty(methods[mi].ret[0]))
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


// build_fn_ret_array marks each body-bearing fn (parallel to build_fn_names) that returns an array `[T]`,
// so a `let xs = f()` of an array-returning call is tracked as an owned (droppable) array binding.
fn build_fn_ret_array(decls: [ps.Decl]) -> [bool] {
    var out: [bool] = []
    var i = 0
    loop {
        if i >= decls.len() {
            break
        }
        match decls[i] {
            case DFn(f) {
                if f.has_body {
                    out.append(f.ret.len() > 0 && is_array_ty(f.ret[0]))
                }
            }
            case DStruct(name, generics, impls, fields, methods, kind) {
                var mi = 0
                loop {
                    if mi >= methods.len() {
                        break
                    }
                    if methods[mi].has_body {
                        out.append(methods[mi].ret.len() > 0 && is_array_ty(methods[mi].ret[0]))
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


// ret_elem_kind is the ELEMENT scalar width-kind of a fn's array return type `[T]` (so `f()[i]` is a scalar),
// or -1 if it does not return an array / the element is non-scalar.
fn ret_elem_kind(ret: [ps.Ty]) -> int {
    if ret.len() > 0 && is_array_ty(ret[0]) {
        return ty_scalar_kind(elem_ty_of(ret[0]))
    }
    return 0 - 1
}


// ret_elem_struct is the ELEMENT struct sid of an array-returning fn's return type `[Struct]` (or -1) —
// so `let xs = f()` of a `[Struct]` return tracks `xs[i]` as a boxed struct (a borrow, not own_into_slot'd).
fn ret_elem_struct(ret: [ps.Ty], names: [string]) -> int {
    if ret.len() > 0 && is_array_ty(ret[0]) {
        return ty_struct_sid(elem_ty_of(ret[0]), names)
    }
    return 0 - 1
}


// build_fn_ret_elem_structs is the array-element struct sid of every body-bearing fn (parallel to build_fn_names).
fn build_fn_ret_elem_structs(decls: [ps.Decl], names: [string]) -> [int] {
    var out: [int] = []
    var i = 0
    loop {
        if i >= decls.len() {
            break
        }
        match decls[i] {
            case DFn(f) {
                if f.has_body {
                    out.append(ret_elem_struct(f.ret, names))
                }
            }
            case DStruct(name, generics, impls, fields, methods, kind) {
                var mi = 0
                loop {
                    if mi >= methods.len() {
                        break
                    }
                    if methods[mi].has_body {
                        out.append(ret_elem_struct(methods[mi].ret, names))
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


// build_fn_ret_elem_kinds is the array-element scalar kind of every body-bearing fn (parallel to build_fn_names).
fn build_fn_ret_elem_kinds(decls: [ps.Decl]) -> [int] {
    var out: [int] = []
    var i = 0
    loop {
        if i >= decls.len() {
            break
        }
        match decls[i] {
            case DFn(f) {
                if f.has_body {
                    out.append(ret_elem_kind(f.ret))
                }
            }
            case DStruct(name, generics, impls, fields, methods, kind) {
                var mi = 0
                loop {
                    if mi >= methods.len() {
                        break
                    }
                    if methods[mi].has_body {
                        out.append(ret_elem_kind(methods[mi].ret))
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
// param_value_sid returns the VALUE-struct sid of C parameter position `pi` of `f` (self is a0 when present,
// typed as the owning struct `owner_sid`), or -1 if that parameter is not a value struct. Drives the C type.
fn param_value_sid(f: ps.FnDecl, has_self: bool, stab: StructTab, owner_sid: int, pi: int) -> int {
    var ci = 0
    if has_self {
        if ci == pi {
            if owner_sid >= 0 && stab.is_value(owner_sid) {
                return owner_sid
            }
            return 0 - 1
        }
        ci = 1
    }
    var p = 0
    loop {
        if p >= f.params.len() {
            break
        }
        if f.params[p].is_self == false {
            if ci == pi {
                if f.params[p].ty.len() > 0 {
                    let s = ty_struct_sid(f.params[p].ty[0], stab.names)
                    if s >= 0 && stab.is_value(s) {
                        return s
                    }
                }
                return 0 - 1
            }
            ci = ci + 1
        }
        p = p + 1
    }
    return 0 - 1
}


// fn_ret_value_struct returns the VALUE-struct sid `f` returns (a `em_s<sid>` C return type), or -1.
fn fn_ret_value_struct(f: ps.FnDecl, stab: StructTab) -> int {
    if f.ret.len() > 0 {
        let sid = ty_struct_sid(f.ret[0], stab.names)
        if sid >= 0 && stab.is_value(sid) {
            return sid
        }
    }
    return 0 - 1
}


// fn_ret_ctype is `f`'s C return type: `em_s<sid>` for a value-struct return, else `Value`.
fn fn_ret_ctype(f: ps.FnDecl, stab: StructTab) -> string {
    let sid = fn_ret_value_struct(f, stab)
    if sid >= 0 {
        return "em_s{sid}"
    }
    return "Value"
}


// fn_param_list renders `f`'s C parameter list. A value-struct parameter is `em_s<sid> a<i>` (passed by
// value), everything else is `Value a<i>`; a method's `self` is the leading a0, typed as its owning struct.
fn fn_param_list(f: ps.FnDecl, has_self: bool, stab: StructTab, owner_sid: int) -> string {
    let n = value_arity(f, has_self)
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
        let psid = param_value_sid(f, has_self, stab, owner_sid, i)
        if psid >= 0 {
            s = s + "em_s{psid} a{i}"
        } else {
            s = s + "Value a{i}"
        }
        i = i + 1
    }
    return s
}


// ---- generic-struct monomorphization (mirrors codegen.ig's InstColl / build_struct_instances) ----------
// A generic struct `Box<T>` gets one runtime struct id PER distinct instantiation used (`Box<Ty>`,
// `Box<Expr>`, …). The instances are numbered AFTER the declared structs (id = declared_count + index) and
// collected in stage-0's order: a PRE-ORDER walk of every body in declaration order, registering each
// generic `Box<X>{…}` construction the first time it is seen. Each instance's C type ALIASES the generic
// base (`typedef em_s<base> em_s<inst>;`) and its metadata equals the base's (T is erased to a boxed Value).

// ty_key renders a type as its monomorphization key: `Box<Ty>`, `[Expr]`, a bare `Foo`, or `fn` (mirrors
// codegen.ig:ty_key). Used to dedup generic instances and to look up an instance's runtime id.
fn ty_key(ty: ps.Ty) -> string {
    match ty {
        case TyName(qual, name) {
            return name
        }
        case TyGeneric(qual, name, args) {
            var s = name + "<"
            var i = 0
            loop {
                if i >= args.len() {
                    break
                }
                if i > 0 {
                    s = s + ","
                }
                s = s + ty_key(args[i])
                i = i + 1
            }
            return s + ">"
        }
        case _ {
            return "fn"
        }
    }
}


// ty_base_name returns the (unqualified) base name of a generic type `Box<…>` → `Box`, or "" if not generic.
fn ty_base_name(ty: ps.Ty) -> string {
    match ty {
        case TyGeneric(qual, name, args) {
            return name
        }
        case _ {
            return ""
        }
    }
}


// base_name_of_key returns the generic base name of an instance key: `Box<Ty>` → `Box` (the prefix before `<`).
fn base_name_of_key(key: string) -> string {
    let bs = key.bytes()
    var i = 0
    loop {
        if i >= bs.len() {
            break
        }
        if int(bs[i]) == 60 {                     // '<'
            return byte_slice(key, 0, i)
        }
        i = i + 1
    }
    return key
}


// InstColl walks every body PRE-ORDER, registering a generic-struct instantiation `Box<X>{…}` the first time
// its struct literal is seen (before its field values — matching check.c). `snames` = declared struct names,
// so a generic ENUM (Option<int>) is skipped. Mirrors codegen.ig:InstColl exactly for byte-identical order.
struct InstColl {
    keys: [string]
    snames: [string]


    fn register(mut self, ty: ps.Ty) {
        match ty {
            case TyGeneric(qual, name, args) {
                if index_of_str(self.snames, name) >= 0 {
                    let k = ty_key(ty)
                    if index_of_str(self.keys, k) < 0 {
                        self.keys.append(k)
                    }
                }
            }
            case _ {
            }
        }
    }


    fn walk_expr(mut self, e: ps.Expr) {
        match e {
            case EStructLit(ty, fields) {
                self.register(ty.value)
                var i = 0
                loop {
                    if i >= fields.len() {
                        break
                    }
                    self.walk_expr(fields[i].value)
                    i = i + 1
                }
            }
            case ECall(callee, args) {
                self.walk_expr(callee.value)
                var i = 0
                loop {
                    if i >= args.len() {
                        break
                    }
                    self.walk_expr(args[i])
                    i = i + 1
                }
            }
            case EBinary(op, l, r) {
                self.walk_expr(l.value)
                self.walk_expr(r.value)
            }
            case EGet(object, name) {
                self.walk_expr(object.value)
            }
            case EIndex(object, index) {
                self.walk_expr(object.value)
                self.walk_expr(index.value)
            }
            case EArray(elems, lines) {
                var i = 0
                loop {
                    if i >= elems.len() {
                        break
                    }
                    self.walk_expr(elems[i])
                    i = i + 1
                }
            }
            case EStr(parts) {
                var i = 0
                loop {
                    if i >= parts.len() {
                        break
                    }
                    if parts[i].hole.len() > 0 {
                        self.walk_expr(parts[i].hole[0])
                    }
                    i = i + 1
                }
            }
            case ERange(lo, hi) {
                self.walk_expr(lo.value)
                self.walk_expr(hi.value)
            }
            case _ {
            }
        }
    }


    fn walk_body(mut self, body: [ps.Stmt]) {
        var i = 0
        loop {
            if i >= body.len() {
                break
            }
            self.walk_stmt(body[i])
            i = i + 1
        }
    }


    fn walk_stmt(mut self, s: ps.Stmt) {
        match s {
            case SLet(v, n, ty, value) {
                self.walk_expr(value.value)
            }
            case SReturn(value, line) {
                if value.len() > 0 {
                    self.walk_expr(value[0].value)
                }
            }
            case SExpr(expr) {
                self.walk_expr(expr.value)
            }
            case SAssign(target, value) {
                self.walk_expr(target.value)
                self.walk_expr(value.value)
            }
            case SIf(cond, then_blk, els) {
                self.walk_expr(cond.value)
                self.walk_body(then_blk)
                self.walk_body(els)
            }
            case SMatch(value, cases) {
                self.walk_expr(value.value)
                var i = 0
                loop {
                    if i >= cases.len() {
                        break
                    }
                    self.walk_body(cases[i].body)
                    i = i + 1
                }
            }
            case SLoop(body) {
                self.walk_body(body)
            }
            case SFor(vn, iv, iter, body) {
                self.walk_expr(iter.value)
                self.walk_body(body)
            }
            case SBlock(body) {
                self.walk_body(body)
            }
            case _ {
            }
        }
    }
}


// index_of_str returns the index of `s` in `xs` (or -1) — the small helper InstColl / instance lookup need.
fn index_of_str(xs: [string], s: string) -> int {
    var i = 0
    loop {
        if i >= xs.len() {
            break
        }
        if xs[i] == s {
            return i
        }
        i = i + 1
    }
    return 0 - 1
}


// clone_strs copies a string array (cgen_c.ig-local; codegen.ig has its own) — the CgcFv capture walker
// saves/restores the bound set across scopes (OFI-206).
fn clone_strs(xs: [string]) -> [string] {
    var out: [string] = []
    var i = 0
    loop {
        if i >= xs.len() {
            break
        }
        out.append(xs[i])
        i = i + 1
    }
    return out
}


// build_struct_instances returns the generic-struct INSTANCE keys in stage-0's monomorphization order — each
// instance's runtime struct id is `declared_struct_count + its index here` (appended after the declared
// structs, which include the generic base `Box<T>` itself).
fn build_struct_instances(decls: [ps.Decl], snames: [string]) -> [string] {
    var c = InstColl { keys: [], snames: snames }
    var i = 0
    loop {
        if i >= decls.len() {
            break
        }
        match decls[i] {
            case DFn(f) {
                if f.has_body {
                    c.walk_body(f.body)
                }
            }
            case DStruct(name, generics, impls, fields, methods, kind) {
                var mi = 0
                loop {
                    if mi >= methods.len() {
                        break
                    }
                    if methods[mi].has_body {
                        c.walk_body(methods[mi].body)
                    }
                    mi = mi + 1
                }
            }
            case _ {
            }
        }
        i = i + 1
    }
    var out: [string] = []                             // clone (can't move a value out of a struct field)
    var k = 0
    loop {
        if k >= c.keys.len() {
            break
        }
        out.append(c.keys[k])
        k = k + 1
    }
    return out
}


// ---- the struct table (mirrors src/cgen_c.c's StructLayout, computed from the AST — the self-hosted
// backend has no checker, so it classifies every declared struct itself, like codegen.ig's build_structs).
// A struct is a VALUE-TYPE (a real C `em_s<sid>`, value semantics, no drop) iff it is recursively all-scalar
// and not an rc/resource struct; otherwise it is BOXED (an ObjStruct Value). Fields are a flat table keyed
// by a running index, f_owner mapping each field back to its struct sid (sids are declaration order).
struct StructTab {
    names: [string]            // sid -> struct name
    kinds: [int]               // sid -> 0 plain, 1 rc, 2 resource
    f_owner: [int]             // flat field -> owning struct sid
    f_name: [string]           // flat field -> field name (declared order within its struct)
    f_aek: [int]               // flat field -> its ArrayElemKind byte (the metadata `knd`)
    f_scalar: [bool]           // flat field -> is it a scalar type? (drives is_value / storage)
    f_struct: [int]            // flat field -> nested struct sid (or -1); the metadata `fst`
    f_array: [bool]            // flat field -> is it an array `[T]`? (so `s.field.len()` / `s.field[i]` resolve)
    f_elem: [int]              // ...for an array field: its ELEMENT scalar kind (so `s.field[i]` is a scalar), else -1
    f_elem_struct: [int]       // ...for a `[Struct]` field: its element struct sid (so `s.field[i]` / `s.field[i].f` resolve), else -1
    f_elem_aek: [int]          // ...for an array field: its ELEMENT ArrayElemKind (so `s.field = []` builds em_array(0, aek)), else -1
    f_ty: [ps.Ty]              // flat field -> its DECLARED type node (WITH generic args, e.g. `Map<string, Rect>`) — the
                               // only place the value type of a generic-container field survives, for typing `s.field.get(k)`
    f_tpname: [string]         // flat field -> its bare type-param NAME (`key: K` -> "K"), else "" — so a bounded-method call
                               // on a type-param FIELD receiver (`e.key.eq(x)`) dispatches through the witness (OFI-174)
    sg_owner: [int]            // struct-generics table: owning struct sid (one row per type-param of a generic struct)
    sg_tparam: [string]        // ...that type-param's name
    sg_bound: [string]         // ...its bounds joined by "+" ("" if unbounded; Copy already excluded) — bounded iff != ""
    inst_keys: [string]        // generic-struct INSTANCE keys (`Box<Ty>`, …); instance sid = names.len() + index


    fn sid_of(self, name: string) -> int {
        var i = 0
        loop {
            if i >= self.names.len() {
                break
            }
            if self.names[i] == name {
                return i
            }
            i = i + 1
        }
        return 0 - 1
    }


    // struct_count is the TOTAL number of runtime structs (declared + generic instances) — the em_structs[] size.
    fn struct_count(self) -> int {
        return self.names.len() + self.inst_keys.len()
    }


    // base_of maps a runtime struct sid to the sid whose FIELD table it uses: a declared struct is itself; a
    // generic INSTANCE (sid >= names.len()) resolves to its generic base (e.g. Box<Ty> → Box), whose fields it
    // shares (T erased to a boxed Value). A monomorphized instance has the base's field layout.
    fn base_of(self, sid: int) -> int {
        if sid < self.names.len() {
            return sid
        }
        let key = self.inst_keys[sid - self.names.len()]
        return self.sid_of(base_name_of_key(key))
    }


    // inst_sid_of returns the runtime struct sid of a generic instance KEY (`Box<Ty>`), or -1 if not an instance.
    fn inst_sid_of(self, key: string) -> int {
        let idx = index_of_str(self.inst_keys, key)
        if idx < 0 {
            return 0 - 1
        }
        return self.names.len() + idx
    }


    // base_sid_of_ty resolves a TYPE to its DECLARED base struct sid: a generic `Map<K,V>` → the Map base sid
    // (ignoring the args), a plain name via sid_of. -1 for a non-struct. Used for an ERASED construction whose
    // instance sid is a bounded base or an uncollected type-param instantiation (`MapEntry<K,V>{…}`).
    fn base_sid_of_ty(self, ty: ps.Ty) -> int {
        match ty {
            case TyGeneric(qual, name, args) {
                return self.sid_of(name)
            }
            case _ {
                return self.sid_of_ty(ty)
            }
        }
    }


    // sid_of_ty resolves a TYPE to its runtime struct sid — a declared struct name, or a generic instance
    // `Box<Ty>` (via its collected instance key), or -1.
    fn sid_of_ty(self, ty: ps.Ty) -> int {
        match ty {
            case TyName(qual, name) {
                return self.sid_of(name)   // a module qualifier (`lx.Token`) resolves to the merged bare-name struct
            }
            case TyGeneric(qual, name, args) {
                // The qualifier is a MODULE ALIAS (`map.Map<…>`); the merged instance table keys by bare name
                // (ty_key drops the qualifier), so ignore it — a qualified generic instance still resolves. A
                // generic ENUM (Option<int>) isn't in inst_keys, so it stays -1 regardless.
                return self.inst_sid_of(ty_key(ty))
            }
            case _ {
                return 0 - 1
            }
        }
    }


    fn field_count(self, sid0: int) -> int {
        let sid = self.base_of(sid0)
        var n = 0
        var i = 0
        loop {
            if i >= self.f_owner.len() {
                break
            }
            if self.f_owner[i] == sid {
                n = n + 1
            }
            i = i + 1
        }
        return n
    }


    // flat_index returns the flat-table index of struct `sid`'s `idx`-th (declared-order) field, or -1.
    fn flat_index(self, sid0: int, idx: int) -> int {
        let sid = self.base_of(sid0)
        var seen = 0
        var i = 0
        loop {
            if i >= self.f_owner.len() {
                break
            }
            if self.f_owner[i] == sid {
                if seen == idx {
                    return i
                }
                seen = seen + 1
            }
            i = i + 1
        }
        return 0 - 1
    }


    // field_is_array reports whether field `fname` of struct `sid` is an array (so `s.field.len()` resolves).
    fn field_is_array(self, sid: int, fname: string) -> bool {
        let flat = self.field_flat(sid, fname)
        if flat < 0 {
            return false
        }
        return self.f_array[flat]
    }


    // field_is_refcounted reports whether field `fname` of struct `sid` is a REFCOUNTED single Value — a
    // string or an enum (a boxed, non-array, non-struct field) — so passing it to a call MOVES it in
    // (own_into_slot), like a string/enum binding. A scalar / array / struct field is passed as-is.
    fn field_is_refcounted(self, sid: int, fname: string) -> bool {
        let flat = self.field_flat(sid, fname)
        if flat < 0 {
            return false
        }
        return self.f_scalar[flat] == false && self.f_array[flat] == false && self.f_struct[flat] < 0
    }


    // field_scalar_kind returns the C width-kind of a SCALAR field `fname` of struct `sid` (so `let x =
    // s.field` types as a C scalar), or -1 for a non-scalar field.
    fn field_scalar_kind(self, sid: int, fname: string) -> int {
        let flat = self.field_flat(sid, fname)
        if flat < 0 || self.f_scalar[flat] == false {
            return 0 - 1
        }
        return aek_to_scalar_kind(self.f_aek[flat])
    }


    // field_elem returns the ELEMENT scalar kind of array field `fname` of struct `sid` (or -1).
    fn field_elem(self, sid: int, fname: string) -> int {
        let flat = self.field_flat(sid, fname)
        if flat < 0 {
            return 0 - 1
        }
        return self.f_elem[flat]
    }


    // field_flat returns the flat-table index of field `fname` within struct `sid` (or -1).
    fn field_flat(self, sid0: int, fname: string) -> int {
        let sid = self.base_of(sid0)
        var i = 0
        loop {
            if i >= self.f_owner.len() {
                break
            }
            if self.f_owner[i] == sid && self.f_name[i] == fname {
                return i
            }
            i = i + 1
        }
        return 0 - 1
    }


    // field_ty returns the DECLARED type node of field `fname` of struct `sid` (with its generic args, e.g.
    // `Map<string, Rect>`), or a sentinel `TyName("", "")` (sid_of_ty → -1) if there is no such field. The one
    // way to recover a generic-container field's value type when typing `s.field.get(k)` : Option<V>.
    fn field_ty(self, sid: int, fname: string) -> ps.Ty {
        let flat = self.field_flat(sid, fname)
        if flat < 0 {
            return ps.TyName("", "")
        }
        return self.f_ty[flat]
    }


    // struct_is_bounded reports whether struct `sid` (resolved through its generic base) has any BOUNDED
    // type-param — so it carries hidden $wit witness fields. Mirrors codegen.ig's struct_is_bounded (OFI-174).
    fn struct_is_bounded(self, sid0: int) -> bool {
        let sid = self.base_of(sid0)
        var i = 0
        loop {
            if i >= self.sg_owner.len() {
                break
            }
            if self.sg_owner[i] == sid && self.sg_bound[i] != "" {
                return true
            }
            i = i + 1
        }
        return false
    }


    // struct_declared_field_count is a struct's DECLARED field count EXCLUDING the hidden $wit witness fields —
    // the flat index at which the witness fields begin (the base for a witness field index).
    fn struct_declared_field_count(self, sid0: int) -> int {
        let sid = self.base_of(sid0)
        var n = 0
        var i = 0
        loop {
            if i >= self.f_owner.len() {
                break
            }
            if self.f_owner[i] == sid && self.f_name[i] != "$wit" {
                n = n + 1
            }
            i = i + 1
        }
        return n
    }


    // field_tpname_of returns struct `sid`'s field `fname` bare type-param name (`e.key` on MapEntry<K,V> →
    // "K"), or "". Drives witness dispatch on a type-param FIELD receiver.
    fn field_tpname_of(self, sid0: int, fname: string) -> string {
        let flat = self.field_flat(sid0, fname)
        if flat < 0 {
            return ""
        }
        return self.f_tpname[flat]
    }


    // struct_bound_of returns the "+"-joined bounds of struct `sid`'s type-param `tpname` ("Hash+Eq"), or "".
    fn struct_bound_of(self, sid0: int, tpname: string) -> string {
        let sid = self.base_of(sid0)
        var i = 0
        loop {
            if i >= self.sg_owner.len() {
                break
            }
            if self.sg_owner[i] == sid && self.sg_tparam[i] == tpname {
                return self.sg_bound[i]
            }
            i = i + 1
        }
        return ""
    }


    // field_index returns the DECLARED-order index of field `fname` within struct `sid` (or -1).
    fn field_index(self, sid0: int, fname: string) -> int {
        let sid = self.base_of(sid0)
        var idx = 0
        var i = 0
        loop {
            if i >= self.f_owner.len() {
                break
            }
            if self.f_owner[i] == sid {
                if self.f_name[i] == fname {
                    return idx
                }
                idx = idx + 1
            }
            i = i + 1
        }
        return 0 - 1
    }


    // field_elem_aek returns the ELEMENT ArrayElemKind of struct `sid0`'s array field `fname` (so `s.field =
    // []` builds em_array(&g_em, 0, aek) at the field's declared element kind), or -1 (not an array field).
    fn field_elem_aek(self, sid0: int, fname: string) -> int {
        let sid = self.base_of(sid0)
        var i = 0
        loop {
            if i >= self.f_owner.len() {
                break
            }
            if self.f_owner[i] == sid && self.f_name[i] == fname {
                return self.f_elem_aek[i]
            }
            i = i + 1
        }
        return 0 - 1
    }


    // field_elem_struct returns the element struct sid of struct `sid0`'s `[Struct]` array field `fname`
    // (so `s.field[i]` / `s.field[i].f` resolve), or -1 (a scalar-element array / not an array / no field).
    fn field_elem_struct(self, sid0: int, fname: string) -> int {
        let sid = self.base_of(sid0)
        var i = 0
        loop {
            if i >= self.f_owner.len() {
                break
            }
            if self.f_owner[i] == sid && self.f_name[i] == fname {
                return self.f_elem_struct[i]
            }
            i = i + 1
        }
        return 0 - 1
    }


    // is_value reports whether struct `sid` is a VALUE-TYPE (a C em_s struct): recursively all-scalar (only
    // scalars / nested value structs), and not an rc / resource struct. Mirrors cgen_c.c:is_value_struct.
    fn is_value(self, sid: int) -> bool {
        if sid < 0 || sid >= self.names.len() {
            return false
        }
        if self.kinds[sid] != 0 {
            return false               // an rc / resource struct is BOXED, never a C value-type
        }
        var seen = false
        var i = 0
        loop {
            if i >= self.f_owner.len() {
                break
            }
            if self.f_owner[i] == sid {
                seen = true
                if self.f_scalar[i] == false {
                    // a non-scalar field is value-ok ONLY if it is a nested VALUE struct
                    let nested_value = self.f_struct[i] >= 0 && self.is_value(self.f_struct[i])
                    if nested_value == false {
                        return false
                    }
                }
            }
            i = i + 1
        }
        return seen
    }


    // field_aek returns the runtime ArrayElemKind byte of flat field `flat`: a nested VALUE-struct field is
    // AEK_INLINE_STRUCT (12); everything else keeps its scalar/boxed AEK.
    fn field_aek(self, flat: int) -> int {
        if self.f_struct[flat] >= 0 && self.is_value(self.f_struct[flat]) {
            return 12
        }
        return self.f_aek[flat]
    }


    // fst_of is the metadata `field_struct` of flat field `flat`: the nested struct sid ONLY for an inline
    // VALUE-struct field, else -1 (a BOXED-struct field is a Value pointer, not laid out inline).
    fn fst_of(self, flat: int) -> int {
        if self.f_struct[flat] >= 0 && self.is_value(self.f_struct[flat]) {
            return self.f_struct[flat]
        }
        return 0 - 1
    }


    // field_size / total_size compute the PACKED byte size of a field and of a whole struct: a nested value-
    // struct field occupies its struct's total_size (packed inline), a scalar its size_of_aek.
    fn field_size(self, flat: int) -> int {
        if self.f_struct[flat] >= 0 && self.is_value(self.f_struct[flat]) {
            return self.total_size(self.f_struct[flat])
        }
        return size_of_aek(self.f_aek[flat])
    }


    fn total_size(self, sid: int) -> int {
        var total = 0
        let fc = self.field_count(sid)
        var f = 0
        loop {
            if f >= fc {
                break
            }
            total = total + self.field_size(self.flat_index(sid, f))
            f = f + 1
        }
        return total
    }


    // is_inline_packable reports whether a struct is stored INLINE-PACKED in an array (its fields laid out
    // consecutively in the element buffer, no boxed ObjStruct pointer) — mirrors cgen_c.c/check.c
    // array_inline_struct_id. Such an array's `arr[i]` read MATERIALISES a fresh owned COPY (an owning temp:
    // its refcounted fields retained), unlike a boxed-pointer array (`arr[i]` is a borrow). Packable iff: a
    // struct (not rc/resource), every field is a scalar OR a refcounted single Value (string / enum) — NO
    // array field and NO nested struct field (a nested value-struct = a later stage; a boxed struct = a
    // unique-owner that can't be shallow-copied) — and the packed size is in (0, 255].
    fn is_inline_packable(self, sid: int) -> bool {
        if sid < 0 || sid >= self.names.len() {
            return false
        }
        if self.kinds[sid] != 0 {
            return false                    // an rc / resource struct is boxed, never inline-packed
        }
        let fc = self.field_count(sid)
        if fc == 0 {
            return false
        }
        var total = 0
        var f = 0
        loop {
            if f >= fc {
                break
            }
            let flat = self.flat_index(sid, f)
            if self.f_array[flat] {
                return false                // an array field → a unique-owner boxed field, can't shallow-copy
            }
            if self.f_struct[flat] >= 0 {
                return false                // a nested struct field (value = later stage / boxed = unique-owner)
            }
            total = total + self.field_size(flat)
            f = f + 1
        }
        if total <= 0 || total > 255 {
            return false
        }
        return true
    }
}


// ty_struct_sid resolves a type annotation to a declared struct's sid (by name), or -1 if it is not a
// (bare, unqualified) struct type. `names` is the sid-ordered struct-name list.
fn ty_struct_sid(t: ps.Ty, names: [string]) -> int {
    match t {
        case TyName(qual, name) {
            // The qualifier is a module alias (`lx.Token`); the merged struct table registers each struct by
            // its BARE name (ast_print drops the qualifier), so match on `name` regardless of `qual`.
            var i = 0
            loop {
                if i >= names.len() {
                    break
                }
                if names[i] == name {
                    return i
                }
                i = i + 1
            }
            return 0 - 1
        }
        case _ {
            return 0 - 1
        }
    }
}


// field_struct_sid_g resolves a struct FIELD's type to its struct sid, GENERIC-AWARE: a generic-struct field
// (`Map<K, V>`) resolves to its BASE struct sid (the method table + field layout live on the base; the value
// type-args ride separately in f_ty), while a plain-named field defers to ty_struct_sid. This is what lets
// `self.rects.get(id)` dispatch to `Map.get`. Mirrors codegen.ig's ty_struct_id (the VM already does this).
// A generic ENUM field (`Option<int>`) has no struct-table entry, so it stays -1. OFI-218 generic keystone.
fn field_struct_sid_g(t: ps.Ty, names: [string]) -> int {
    match t {
        case TyGeneric(qual, name, args) {
            return index_of_str(names, name)
        }
        case _ {
            return ty_struct_sid(t, names)
        }
    }
}


// aek_to_scalar_kind maps a NUMERIC ArrayElemKind byte (i8..f64) to its C width-kind (0 i64 … 9 f64) for
// the unboxed-scalar-binding decision, or -1 for a non-numeric kind. Matches the checker's
// `is_numeric_type(t) ? int_kind(t) : -1` (check.c) — BOOL is NOT numeric, so a `let x = s.boolField` keeps
// a Value (INT_VAL), not an unboxed C scalar. The inverse of the numeric side of array_elem_kind_ty.
// aek_to_render_kind maps an ArrayElemKind to its interpolation render-kind (the em_to_string 3rd arg):
// f32 (9) -> 8, f64/float (10) -> 9, bool (11) -> 10, else 0 (int / non-numeric). Mirrors int_kind on the
// element type, so `{floatArr[i]}` formats as a float.
fn aek_to_render_kind(aek: int) -> int {
    if aek == 9 {
        return 8
    }
    if aek == 10 {
        return 9
    }
    if aek == 11 {
        return 10
    }
    return 0
}


// scalar_kind_to_aek is the inverse of aek_to_scalar_kind: a scalar width-kind → its ArrayElemKind (int
// kind 0 → AEK 4), so a map lambda's inferred scalar return element records a scalar AEK (not boxed 0),
// and `lens[i]` reads plain instead of own_into_slot'd (OFI-206 follow-on).
fn scalar_kind_to_aek(k: int) -> int {
    if k == 0 { return 4 }
    if k == 1 { return 1 }
    if k == 2 { return 2 }
    if k == 3 { return 3 }
    if k == 4 { return 5 }
    if k == 5 { return 6 }
    if k == 6 { return 7 }
    if k == 7 { return 8 }
    if k == 8 { return 9 }
    if k == 9 { return 10 }
    if k == 10 { return 11 }
    return 0
}


fn aek_to_scalar_kind(aek: int) -> int {
    if aek == 4 {
        return 0                       // i64 / int
    }
    if aek == 1 {
        return 1                       // i8
    }
    if aek == 2 {
        return 2                       // i16
    }
    if aek == 3 {
        return 3                       // i32
    }
    if aek == 5 {
        return 4                       // u8
    }
    if aek == 6 {
        return 5                       // u16
    }
    if aek == 7 {
        return 6                       // u32
    }
    if aek == 8 {
        return 7                       // u64
    }
    if aek == 9 {
        return 8                       // f32
    }
    if aek == 10 {
        return 9                       // f64
    }
    return 0 - 1                        // bool (11, not numeric) / AEK_BOXED / inline-struct — kept as a Value
}


// size_of_aek is the PACKED byte size of a struct field of ArrayElemKind `aek` (the runtime data buffer;
// fields are packed with NO alignment padding — offsets are a running sum). A boxed field is pointer-sized.
fn size_of_aek(aek: int) -> int {
    if aek == 1 {
        return 1                       // i8
    }
    if aek == 2 {
        return 2                       // i16
    }
    if aek == 3 {
        return 4                       // i32
    }
    if aek == 4 {
        return 8                       // i64
    }
    if aek == 5 {
        return 1                       // u8
    }
    if aek == 6 {
        return 2                       // u16
    }
    if aek == 7 {
        return 4                       // u32
    }
    if aek == 8 {
        return 8                       // u64
    }
    if aek == 9 {
        return 4                       // f32
    }
    if aek == 10 {
        return 8                       // f64
    }
    if aek == 11 {
        return 1                       // bool
    }
    return 16                          // AEK_BOXED — a full 16-byte Value (a heap field of a boxed struct)
}


// build_struct_tab classifies every declared struct from the AST (names + a flat field table).
fn build_struct_tab(decls: [ps.Decl]) -> StructTab {
    // Pass 1: collect struct names + kinds (so a field typed as a later-declared struct still resolves).
    var names: [string] = []
    var kinds: [int] = []
    var i = 0
    loop {
        if i >= decls.len() {
            break
        }
        match decls[i] {
            case DStruct(name, generics, impls, fields, methods, kind) {
                names.append(name)
                kinds.append(kind)
            }
            case _ {
            }
        }
        i = i + 1
    }
    // Pass 2: the flat field table (classification needs all struct names known).
    var fo: [int] = []
    var fnm: [string] = []
    var fa: [int] = []
    var fsc: [bool] = []
    var fsd: [int] = []
    var far: [bool] = []
    var fel: [int] = []
    var fes: [int] = []
    var fea: [int] = []
    var fty_arr: [ps.Ty] = []
    var ftpn: [string] = []
    var sgo: [int] = []
    var sgt: [string] = []
    var sgb: [string] = []
    var sid = 0
    var j = 0
    loop {
        if j >= decls.len() {
            break
        }
        match decls[j] {
            case DStruct(name, generics, impls, fields, methods, kind) {
                var fi = 0
                loop {
                    if fi >= fields.len() {
                        break
                    }
                    let fty = fields[fi].ty
                    fo.append(sid)
                    fnm.append(fields[fi].name)
                    fty_arr.append(fty)                 // keep the declared field type (with generic args) for later
                    ftpn.append(field_tpname_ty(fty, generics))   // "K" for a bare type-param field, else "" (witness dispatch)
                    fsd.append(field_struct_sid_g(fty, names))   // generic-aware: a Map<K,V> field → base Map sid (method dispatch)
                    let aek = array_elem_kind_ty(fty)   // 0 for string/array/struct (boxed), 1..11 for a scalar
                    fa.append(aek)
                    fsc.append(aek != 0)
                    let is_a = is_array_ty(fty)
                    far.append(is_a)
                    if is_a {
                        fel.append(ty_scalar_kind(elem_ty_of(fty)))
                        fes.append(ty_struct_sid(elem_ty_of(fty), names))   // `[Struct]` field element sid, so s.field[i].f resolves
                        fea.append(array_elem_kind_ty(elem_ty_of(fty)))     // element AEK, so `s.field = []` builds em_array(0, aek)
                    } else {
                        fel.append(0 - 1)
                        fes.append(0 - 1)
                        fea.append(0 - 1)
                    }
                    fi = fi + 1
                }
                // A BOUNDED generic struct carries one HIDDEN WITNESS FIELD per (type-param, bound), appended
                // AFTER the declared fields (so declared indices are unchanged) — the method-dictionary for the
                // concrete type-arg that a `k.hash()`/`k.eq(..)` call dispatches through. Copy is already split
                // out (parser is_copy), so bounds holds only real interfaces. Mirrors codegen.ig:620-653 (OFI-174).
                var gwi = 0
                loop {
                    if gwi >= generics.len() {
                        break
                    }
                    sgo.append(sid)
                    sgt.append(generics[gwi].name)
                    sgb.append(join_plus(generics[gwi].bounds))
                    var bwi = 0
                    loop {
                        if bwi >= generics[gwi].bounds.len() {
                            break
                        }
                        fo.append(sid)
                        fnm.append("$wit")
                        fty_arr.append(ps.TyName("", ""))
                        ftpn.append("")
                        fsd.append(0 - 1)
                        fa.append(0)                    // a boxed enum record (16-byte Value slot)
                        fsc.append(false)
                        far.append(false)
                        fel.append(0 - 1)
                        fes.append(0 - 1)
                        fea.append(0 - 1)
                        bwi = bwi + 1
                    }
                    gwi = gwi + 1
                }
                sid = sid + 1
            }
            case _ {
            }
        }
        j = j + 1
    }
    let insts = build_struct_instances(decls, names)
    return StructTab { names: names, kinds: kinds, f_owner: fo, f_name: fnm, f_aek: fa, f_scalar: fsc, f_struct: fsd, f_array: far, f_elem: fel, f_elem_struct: fes, f_elem_aek: fea, f_ty: fty_arr, f_tpname: ftpn, sg_owner: sgo, sg_tparam: sgt, sg_bound: sgb, inst_keys: insts }
}


// owner_tparam_name returns the bare type-param NAME of `ty` if it names one of struct `owner_sid`'s type
// params (`key: K` in a Map<K,V> method → "K"), else "". Detects a param typed as an OWNER type-param (whose
// bounded methods dispatch through self's witness), distinct from the method's own generics.
fn owner_tparam_name(ty: ps.Ty, st: StructTab, owner_sid: int) -> string {
    if owner_sid < 0 {
        return ""
    }
    match ty {
        case TyName(qual, name) {
            if qual == "" && st.struct_bound_of(owner_sid, name) != "" {
                return name
            }
        }
        case _ {
        }
    }
    return ""
}


// field_tpname_ty returns a field's bare type-param NAME if its type is exactly one of the struct's generics
// (`key: K` in `struct MapEntry<K, V>` -> "K"), else "". Enables witness dispatch on a type-param field
// receiver (`e.key.eq(x)`). Mirrors codegen.ig's field_tpname.
fn field_tpname_ty(fty: ps.Ty, generics: [ps.GenericParam]) -> string {
    match fty {
        case TyName(qual, name) {
            if qual == "" && generic_named(generics, name) {
                return name
            }
        }
        case _ {
        }
    }
    return ""
}


// join_plus joins interface bounds with "+" (["Hash", "Eq"] -> "Hash+Eq", [] -> ""), the sg_bound encoding.
fn join_plus(bounds: [string]) -> string {
    var s = ""
    var i = 0
    loop {
        if i >= bounds.len() {
            break
        }
        if i > 0 {
            s = s + "+"
        }
        s = s + bounds[i]
        i = i + 1
    }
    return s
}


// split_plus_list splits a "Hash+Eq" bound string back into ["Hash", "Eq"].
fn split_plus_list(s: string) -> [string] {
    var out: [string] = []
    let bs = s.bytes()
    var cur = ""
    var i = 0
    loop {
        if i >= bs.len() {
            break
        }
        if int(bs[i]) == 43 {              // '+'
            out.append(cur)
            cur = ""
        } else {
            cur = cur + from_char_code(int(bs[i]))
        }
        i = i + 1
    }
    if cur.len() > 0 {
        out.append(cur)
    }
    return out
}


// ty_head_name returns a type's base NAME: `string`/`Rect` (TyName) or `Map` (TyGeneric base), else "".
fn ty_head_name(ty: ps.Ty) -> string {
    match ty {
        case TyName(qual, name) {
            return name
        }
        case TyGeneric(qual, name, args) {
            return name
        }
        case _ {
            return ""
        }
    }
}


// nth_targ_head returns the base NAME of a generic type's k-th type-argument (`Map<string,int>`, k=1 -> "int"),
// or "" if `ty` is not generic or k is out of range. Avoids returning a borrowed [Ty] out of the match.
fn nth_targ_head(ty: ps.Ty, k: int) -> string {
    match ty {
        case TyGeneric(qual, name, args) {
            if k >= 0 && k < args.len() {
                return ty_head_name(args[k])
            }
        }
        case _ {
        }
    }
    return ""
}


// iface_methods returns a built-in bound interface's method names, in declaration order (the witness record's
// field order AND the CALL_INDIRECT method index): Hash -> ["hash"], Eq -> ["eq"]. A USER interface's methods
// would come from its DInterface decl — deferred (the stdlib's bounded structs use only Hash/Eq). OFI-174.
fn iface_methods(iface: string) -> [string] {
    if iface == "Hash" {
        return ["hash"]
    }
    if iface == "Eq" {
        return ["eq"]
    }
    return []
}


// ---- the enum table (enums are BOXED runtime values `em_enum(enum_id, tag, fcount, fields…)` — no C type
// and no metadata preamble; the table just resolves a variant NAME to its enum id + tag + payload arity,
// computed from the DEnum decls, mirroring codegen.ig's build_enums). ----------------------------------
struct EnumTab {
    names: [string]            // enum id -> name (declaration order)
    v_owner: [int]             // flat variant table -> owning enum id
    v_name: [string]           // ...variant name
    v_tag: [int]               // ...tag (index within its enum)
    v_arity: [int]             // ...payload field count
    pf_variant: [int]          // flat PAYLOAD-field table -> owning flat-variant index
    pf_refc: [bool]            // ...is the field a REFCOUNTED single Value (string / enum / struct / generic)?
    pf_array: [bool]           // ...is the payload field an array `[T]`? (so a `case V(xs)` binding is an array)
    pf_elem: [int]             // ...for an array payload field: its ELEMENT scalar kind (so `xs[i]` is a scalar), else -1
    pf_elem_struct: [int]      // ...for a STRUCT-array payload field `[StrPart]`: its element struct sid (so `xs[i].f` resolves), else -1
    pf_ty: [ps.Ty]             // ...the payload field's declared type (resolved to a struct sid at the match site via sid_of_ty, so `elem.value` on a `Box<Ty>` payload resolves — generics need the instance table build_enum_tab lacks)


    // variant_flat returns the flat-table index of variant `name` (-1 if `name` is not a known variant).
    fn variant_flat(self, name: string) -> int {
        var i = 0
        loop {
            if i >= self.v_name.len() {
                break
            }
            if self.v_name[i] == name {
                return i
            }
            i = i + 1
        }
        return 0 - 1
    }


    // prelude_variant_tag returns the tag of a PRELUDE enum variant (Some/Ok = 0, None/Err = 1), or -1.
    // The prelude Option/Result are NOT in the C-emit variant table (construction has its own path), so a
    // `match` on a generic Option/Result PARAMETER can't resolve Some/Ok/… via variant_flat — this fallback
    // lets the match classify + tag them like stage-0, WITHOUT disturbing the enum table (OFI-204).
    fn prelude_variant_tag(self, name: string) -> int {
        if name == "Some" {
            return 0
        }
        if name == "Ok" {
            return 0
        }
        if name == "None" {
            return 1
        }
        if name == "Err" {
            return 1
        }
        return 0 - 1
    }


    // prelude_enum_id returns the enum id a PRELUDE Option/Result variant CONSTRUCTS into: the user-enum
    // count for Option (Some/None), +1 for Result (Ok/Err) — matching stage-0's DECL_ENUM numbering
    // (user enums first, then prelude Option, then Result). -1 if `name` is not a prelude variant.
    fn prelude_enum_id(self, name: string) -> int {
        if name == "Some" {
            return self.names.len()
        }
        if name == "None" {
            return self.names.len()
        }
        if name == "Ok" {
            return self.names.len() + 1
        }
        if name == "Err" {
            return self.names.len() + 1
        }
        return 0 - 1
    }


    // is_case_variant reports whether a case name is a real variant (user enum, or a prelude Some/Ok/…).
    fn is_case_variant(self, name: string) -> bool {
        return self.variant_flat(name) >= 0 || self.prelude_variant_tag(name) >= 0
    }


    // case_tag returns a case's variant tag — from the user enum table, or the prelude fallback.
    fn case_tag(self, name: string) -> int {
        let f = self.variant_flat(name)
        if f >= 0 {
            return self.v_tag[f]
        }
        return self.prelude_variant_tag(name)
    }


    fn is_variant(self, name: string) -> bool {
        return self.variant_flat(name) >= 0
    }


    // payload_flat returns the flat payload-field-table index of variant `vname`'s `idx`-th field (or -1).
    fn payload_flat(self, vname: string, idx: int) -> int {
        let vf = self.variant_flat(vname)
        if vf < 0 {
            return 0 - 1
        }
        var seen = 0
        var i = 0
        loop {
            if i >= self.pf_variant.len() {
                break
            }
            if self.pf_variant[i] == vf {
                if seen == idx {
                    return i
                }
                seen = seen + 1
            }
            i = i + 1
        }
        return 0 - 1
    }


    // payload_refc reports whether the `idx`-th payload field of variant `vname` is a REFCOUNTED single Value
    // (string / enum / struct) — so binding it and CONSUMING it (a `+` / `==` operand) is own_into_slot.
    fn payload_refc(self, vname: string, idx: int) -> bool {
        let f = self.payload_flat(vname, idx)
        if f < 0 {
            // A generic prelude payload (Some/Ok/Err's T/E) is possibly-refcounted-of-unknown-type: it is
            // NOT known-refcounted (which would emit own_into_slot), so leave it non-refc — the return
            // retain-dance then emits the runtime IS_OBJ wrapper, matching stage-0 (OFI-204).
            return false
        }
        return self.pf_refc[f]
    }


    // payload_array reports whether variant `vname`'s `idx`-th payload field is an ARRAY (so `case V(xs)`
    // binds an array — `xs.len()` / `xs[i]` resolve).
    fn payload_array(self, vname: string, idx: int) -> bool {
        let f = self.payload_flat(vname, idx)
        if f < 0 {
            return false
        }
        return self.pf_array[f]
    }


    // payload_elem_struct returns the element struct sid of a STRUCT-array payload field (or -1).
    fn payload_elem_struct(self, vname: string, idx: int) -> int {
        let f = self.payload_flat(vname, idx)
        if f < 0 {
            return 0 - 1
        }
        return self.pf_elem_struct[f]
    }


    // payload_ty returns the declared type of variant `vname`'s `idx`-th payload field (a unit TyName if
    // out of range). Resolved to a struct sid at the match site (sid_of_ty handles generic instances).
    fn payload_ty(self, vname: string, idx: int) -> ps.Ty {
        let f = self.payload_flat(vname, idx)
        return self.pf_ty[f]
    }


    // has_payload_field reports whether variant `vname`'s `idx`-th payload is in the field table — false
    // for a generic prelude payload (Some/Ok/Err's T/E, OFI-163), so a caller must not read payload_ty then.
    fn has_payload_field(self, vname: string, idx: int) -> bool {
        return self.payload_flat(vname, idx) >= 0
    }


    // payload_elem returns the ELEMENT scalar kind of an array payload field (or -1).
    fn payload_elem(self, vname: string, idx: int) -> int {
        let f = self.payload_flat(vname, idx)
        if f < 0 {
            return 0 - 1
        }
        return self.pf_elem[f]
    }
}


// ---- the global-constant table. Module-level `let NAME: int = <literal>` (e.g. the parser's TAG_* token
// tags) are compile-time constants the stage-0 CHECKER folds inline (native codegen rejects unresolved
// globals). The self-hosted path has no checker, so we collect the int-literal ones and fold a reference to
// `INT_VAL(<value>LL)` in emit_expr — matching stage-0's inlined constant. ------------------------------
struct ConstTab {
    names: [string]            // const name
    vals: [int]                // ...its int literal value


    // lookup_idx returns the table index of const `name`, or -1 (not a known folded constant).
    fn lookup_idx(self, name: string) -> int {
        var i = 0
        loop {
            if i >= self.names.len() {
                break
            }
            if self.names[i] == name {
                return i
            }
            i = i + 1
        }
        return 0 - 1
    }
}


// build_const_tab collects module-level `let NAME: int = <int literal>` declarations across all merged
// modules — the folded compile-time constants (the parser's TAG_* token tags). Non-int-literal lets are
// skipped (the corpus has none; extend if a global string/expr constant appears).
fn build_const_tab(decls: [ps.Decl]) -> ConstTab {
    var names: [string] = []
    var vals: [int] = []
    var i = 0
    loop {
        if i >= decls.len() {
            break
        }
        match decls[i] {
            case DLet(is_var, name, ty, value) {
                match value.value {
                    case EInt(v, _) {
                        names.append(name)
                        vals.append(v)
                    }
                    case _ {
                    }
                }
            }
            case _ {
            }
        }
        i = i + 1
    }
    return ConstTab { names: names, vals: vals }
}


// build_enum_tab collects every enum's variants from the AST (enum ids + per-enum variant tags). `snames`
// is the declared struct-name list (sid order) so a STRUCT-array payload field's element sid resolves.
fn build_enum_tab(decls: [ps.Decl], snames: [string]) -> EnumTab {
    var names: [string] = []
    var vo: [int] = []
    var vn: [string] = []
    var vt: [int] = []
    var va: [int] = []
    var pfv: [int] = []
    var pfr: [bool] = []
    var pfa: [bool] = []
    var pfe: [int] = []
    var pfs: [int] = []
    var pft: [ps.Ty] = []
    var i = 0
    loop {
        if i >= decls.len() {
            break
        }
        match decls[i] {
            case DEnum(name, generics, impls, variants) {
                let id = names.len()
                names.append(name)
                var vi = 0
                loop {
                    if vi >= variants.len() {
                        break
                    }
                    let vflat = vo.len()
                    vo.append(id)
                    vn.append(variants[vi].name)
                    vt.append(vi)
                    va.append(variants[vi].fields.len())
                    var fi = 0
                    loop {
                        if fi >= variants[vi].fields.len() {
                            break
                        }
                        let fty = variants[vi].fields[fi].ty
                        pfv.append(vflat)
                        pft.append(variants[vi].fields[fi].ty)
                        let fa = is_array_ty(fty)
                        // a REFCOUNTED single Value = a BOXED (aek 0), non-array field: string / enum / struct
                        // / generic. A scalar (aek 1..11) or an array is not.
                        pfr.append(array_elem_kind_ty(fty) == 0 && fa == false)
                        pfa.append(fa)
                        if fa {
                            pfe.append(ty_scalar_kind(elem_ty_of(fty)))   // element scalar kind, so `xs[i]` types
                            pfs.append(ty_struct_sid(elem_ty_of(fty), snames))   // element struct sid, so `xs[i].f` resolves
                        } else {
                            pfe.append(0 - 1)
                            pfs.append(0 - 1)
                        }
                        fi = fi + 1
                    }
                    vi = vi + 1
                }
            }
            case _ {
            }
        }
        i = i + 1
    }
    return EnumTab { names: names, v_owner: vo, v_name: vn, v_tag: vt, v_arity: va, pf_variant: pfv, pf_refc: pfr, pf_array: pfa, pf_elem: pfe, pf_elem_struct: pfs, pf_ty: pft }
}


// build_fn_ret_structs is the struct sid (VALUE or BOXED) each body-bearing fn returns (parallel to
// build_fn_names), so a `let p = mk()` of a struct-returning call resolves its type (an em_s for a value
// struct / a boxed ObjStruct otherwise). The is_value gate is applied at the use site (struct_sid_of /
// boxed_sid_of), not here.
fn build_fn_ret_structs(decls: [ps.Decl], stab: StructTab) -> [int] {
    var out: [int] = []
    var i = 0
    loop {
        if i >= decls.len() {
            break
        }
        match decls[i] {
            case DFn(f) {
                if f.has_body {
                    out.append(fn_ret_struct_id(f, stab))
                }
            }
            case DStruct(name, generics, impls, fields, methods, kind) {
                var mi = 0
                loop {
                    if mi >= methods.len() {
                        break
                    }
                    if methods[mi].has_body {
                        out.append(fn_ret_struct_id(methods[mi], stab))
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


// fn_ret_struct_id is the struct sid (value OR boxed) `f` returns, or -1 if it does not return a struct.
fn fn_ret_struct_id(f: ps.FnDecl, stab: StructTab) -> int {
    if f.ret.len() > 0 {
        return stab.sid_of_ty(f.ret[0])
    }
    return 0 - 1
}


// build_fn_ret_enum marks each body-bearing fn (parallel to build_fn_names) that returns an ENUM type, so a
// `let o = f()` of an enum-returning call is tracked as an OWNED (droppable, move-into-call) binding.
fn build_fn_ret_enum(decls: [ps.Decl], en: EnumTab) -> [bool] {
    var out: [bool] = []
    var i = 0
    loop {
        if i >= decls.len() {
            break
        }
        match decls[i] {
            case DFn(f) {
                if f.has_body {
                    out.append(f.ret.len() > 0 && is_enum_ty(f.ret[0], en))
                }
            }
            case DStruct(name, generics, impls, fields, methods, kind) {
                var mi = 0
                loop {
                    if mi >= methods.len() {
                        break
                    }
                    if methods[mi].has_body {
                        out.append(methods[mi].ret.len() > 0 && is_enum_ty(methods[mi].ret[0], en))
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


// ---- the C-emit generator state (mirrors src/cgen_c.c's CgcGen) -------------------------------------
// next_var is the per-function `v%d` temp counter (retain temps + scalar `let` bindings share it). The
// scope maps an in-scope binding NAME to its C expression (`a0` for a param, `v3` for a `let`) and its
// scalar width-kind (0 i64 … 9 f64, or -1 for a Value/struct binding). fn_names lets a call resolve to
// `em_fn_<index>`. Built per increment, like the bytecode codegen.ig was.
// A lifted lambda's inferred param typing is recorded as a FLAT int row (arrays copy freely between arrays,
// unlike move-only structs): [slot, nparams, s0, k0, s1, k1…] where slot is the em_fn index, si=1 marks an
// owned STRING param (dropped at exit) and ki carries a scalar param's width-kind (-1 = untyped). Discovered
// at the HOF call site (where the enclosing scope is live) because the C-emit lifts lambdas globally with no
// checker to stamp param types, so the globally-emitted body dispatches `.len()`/concat/arithmetic correctly
// only once we route this back to it (OFI-206 follow-on).
struct CgcGen {
    next_var: int
    sc_name: [string]          // binding name
    sc_cname: [string]         // ...its C expression (a param `aN`, or a `let` temp `vN`)
    sc_kind: [int]             // ...its scalar TYPE width-kind (for `let` inference), or -1 for a non-scalar
    sc_unboxed: [bool]         // ...is the STORAGE an unboxed C scalar (a scalar `let` vN, re-box on read)?
                               // a param is a Value (a0, read as-is) even when its TYPE is a scalar.
    sc_drop: [bool]            // ...is this binding an OWNED heap value (a string/array local) dropped at exit?
    sc_array: [bool]           // ...is this binding an ARRAY? (passed to a call by BORROW, not moved like a string)
    sc_elem_kind: [int]        // ...for an array binding: its ELEMENT scalar width-kind (so `arr[i]` is a scalar), else -1
    sc_elem_aek: [int]         // ...for an array binding: its ELEMENT ArrayElemKind (0 boxed refcounted / 1..11 scalar) — so a `[bool]` element (11) is not mistaken for a refcounted one, else -1
    sc_elem_is_array: [bool]   // ...for an array binding: is its ELEMENT itself an ARRAY (`[[T]]`)? so `grid[i].len()` is em_array_len, NOT em_str_len — a boxed (AEK-0) element that is an array, not a string (OFI-219)
    sc_elem_elem_kind: [int]   // ...for a `[[T]]` binding: the INNER element's scalar width-kind (T's, so `grid[i][j]` reads plain, not own_into_slot'd), else -1 (OFI-219)
    sc_elem_struct: [int]      // ...for a STRUCT-array binding: its element struct sid (so `arr[i]` / `arr[i].f` resolve), else -1
    sc_refc: [bool]            // ...is this a REFCOUNTED BORROW (a string/enum enum-payload binding)? consuming it → own_into_slot
    sc_tyvar: [bool]           // ...is this an OWNED erased TYPE-PARAM local (`var acc = init`, init: U)? a whole-value
                               // consume MOVES it (nil-slot), not own_into_slot — stage-0's moves_local==1 (OFI-176, F2)
    sc_struct: [int]           // ...for a VALUE-STRUCT binding: its struct sid (so `p.f` / storage type resolve), else -1
    sc_render: [int]           // ...its interpolation render-kind (int_kind: 0 int, 8 f32, 9 float, 10 bool, 1..7 sized), for `{x}`
    indent: int                // current C indentation depth (1 = the function-body level, 4 spaces each)
    st: StructTab              // the declared-struct table (value/boxed classification + field resolution)
    en: EnumTab                // the declared-enum table (variant -> enum id / tag / payload arity)
    fn_names: [string]         // every body-bearing fn in em_fn_N order (free fns + `Struct.method`)
    fn_ret_kind: [int]         // ...each fn's return width-kind (for a `let x = f()` scalar binding)
    fn_ret_render: [int]       // ...each fn's return-type interp render-kind (so `{r.ok()}` renders bool, not int)
    fn_ret_opt_param: [int]    // ...for a method returning Option/Result of an owner generic param: that param's
                               // index (so `match recv.get(k) { case Some(r) }` types r from recv's concrete arg), else -1
    fn_ret_str: [bool]         // ...does each fn return a string (a `let x = f()` owned binding)?
    fn_ret_array: [bool]       // ...does each fn return an array (a `let x = f()` owned array binding)?
    fn_ret_elem_kind: [int]    // ...for an array-returning fn: its element scalar kind (so `f()[i]` is a scalar), else -1
    fn_ret_elem_struct: [int]  // ...for a `[Struct]`-returning fn: its element struct sid (so `let xs = f()` tracks `xs[i]` as a boxed struct), else -1
    fn_ret_struct: [int]       // ...for a value-struct-returning fn: the struct sid (so `let p = f()` is an em_s), else -1
    fn_ret_enum: [bool]        // ...does each fn return an enum (a `let o = f()` OWNED refcounted binding)?
    consts: ConstTab           // module-level `let NAME: int = <literal>` folded constants (TAG_*), inlined by emit_expr
    cur_gopt: [string]         // param names whose type is a GENERIC Option/Result (Some/Ok payload is an erased
                               // type param T) — so a `case Some(v)` payload binds as a refcounted borrow
                               // (own_into_slot on return), matching stage-0's erased-generic ownership (OFI-205)
    cur_owner: int             // the current method's OWNER struct sid (-1 for a free fn) — the witness fields live
                               // on `self` of this struct, so a bounded-method call reads em_enum_field(self, idx)
    cur_tp_pname: [string]     // param names typed as one of the owner's TYPE-PARAMS (`key: K`) — a bounded-method
    cur_tp_tname: [string]     // ...call on such a param dispatches through a witness; parallel tparam name ("K")
    cur_lambda: int            // the em_fn index of the NEXT lambda this body lifts (fn_count + prior lambdas),
                               // incremented at each `em_closure` site so a lambda VALUE gets its lifted slot (OFI-206)
    fn_ret_det_arg: [int]      // ...per em_fn: the value-arg index determining a bare-`T`/`[T]` return (else -1),
    fn_ret_det_elem: [bool]    // ...and whether that arg is `[T]` (return type-param = its element) — OFI-206 follow-on
    fn_ret_lam_arg: [int]      // ...map-style: the LAMBDA value-arg whose return type is a `[U]` return's element,
    fn_ret_lam_in: [int]       // ...and the INPUT-array value-arg typing that lambda's param (else -1) — OFI-206
    fn_param_gen_mask: [int]   // ...per fn: a bitmask of value-params that are erased generic-T BORROW params
                               // (`x: T`) — a fresh string temp at such a param is caller-dropped (OFI-176, F1)
    fn_hof_srcs: [int]         // ...per HOF fn, a FIXED stride-6 block [lam_arg, np, p0_arg, p0_elem, p1_arg,
                               // p1_elem] (lam_arg -1 = not a HOF / >2 lambda params): the value-arg each
                               // lifted-lambda param draws its type from (whole vs element) — OFI-206. Flat
                               // (not [[int]]) because the self-hosted C-emit still mistypes a nested-array
                               // element's `.len()` as a string (OFI-219) — every access here is a scalar index.
    lam_recs: [int]            // lifted-lambda param typings discovered while emitting THIS body, as flat self-
                               // describing blocks [slot, nparams, s0, k0, s1, k1…] (s=1 → owned string param,
                               // k = scalar width-kind); returned to emit_program, which routes each into the
                               // matching globally-emitted lifted body
    extern_names: [string]     // every DECLARED `extern "c"` fn name (no em_fn slot — a side table, since cgen_c
                               // has no body for them); an FFI call resolves its return type through this (P6 FFI)
    extern_ret_kind: [int]     // ...each extern's return width-kind (so `let s = sin(x)` binds an unboxed double)
    extern_ret_str: [bool]     // ...does each extern return a `string` (so `let o = proc_stdout(h)` owns + `.len()`s)?


    fn fresh_var(mut self) -> int {
        let v = self.next_var
        self.next_var = self.next_var + 1
        return v
    }


    fn push(mut self, name: string, cname: string, kind: int, unboxed: bool, drop: bool, is_arr: bool, elem_kind: int) {
        self.sc_name.append(name)
        self.sc_cname.append(cname)
        self.sc_kind.append(kind)
        self.sc_unboxed.append(unboxed)
        self.sc_drop.append(drop)
        self.sc_array.append(is_arr)
        self.sc_elem_kind.append(elem_kind)
        self.sc_elem_aek.append(0 - 1)        // default: unknown element AEK (set_last_elem_aek overrides for array bindings)
        self.sc_elem_is_array.append(false)   // default: element is not itself an array (set_last_elem_is_array overrides)
        self.sc_elem_elem_kind.append(0 - 1)  // default: unknown inner element kind (set_last_elem_elem_kind overrides for [[T]])
        self.sc_elem_struct.append(0 - 1)     // default: not a struct-array binding (set_last_elem_struct overrides)
        self.sc_refc.append(false)            // default: not a refcounted borrow (set_last_refc overrides)
        self.sc_tyvar.append(false)           // default: not an owned type-param local (set_last_tyvar overrides)
        self.sc_struct.append(0 - 1)          // default: not a struct binding (set_last_struct overrides)
        self.sc_render.append(0)              // default: int render-kind (set_last_render overrides for float/bool/sized)
    }


    // set_last_render records the interpolation render-kind of the most-recently pushed binding (so a `{x}`
    // hole on a float/bool/sized-int binding emits em_to_string(…, <kind>) matching the checker's render_kind).
    fn set_last_render(mut self, k: int) {
        self.sc_render[self.sc_render.len() - 1] = k
    }


    fn lookup_render(self, name: string) -> int {
        var i = self.sc_name.len() - 1
        loop {
            if i < 0 {
                break
            }
            if self.sc_name[i] == name {
                return self.sc_render[i]
            }
            i = i - 1
        }
        return 0
    }


    // set_last_refc marks the most-recently pushed binding as a REFCOUNTED borrow (a string/enum enum-payload
    // binding), so consuming it in a `+` / `==` op is own_into_slot (a retain into the consume), not the
    // generic retain-dance.
    fn set_last_refc(mut self, v: bool) {
        self.sc_refc[self.sc_refc.len() - 1] = v
    }


    fn lookup_refc(self, name: string) -> bool {
        var i = self.sc_name.len() - 1
        loop {
            if i < 0 {
                break
            }
            if self.sc_name[i] == name {
                return self.sc_refc[i]
            }
            i = i - 1
        }
        return false
    }


    // set_last_tyvar marks the most-recently pushed binding as an OWNED erased TYPE-PARAM local, so a whole-
    // value consume MOVES it (nil-slot) rather than own_into_slot — stage-0's moves_local==1 (OFI-176, F2).
    fn set_last_tyvar(mut self, v: bool) {
        self.sc_tyvar[self.sc_tyvar.len() - 1] = v
    }


    fn lookup_tyvar(self, name: string) -> bool {
        var i = self.sc_name.len() - 1
        loop {
            if i < 0 {
                break
            }
            if self.sc_name[i] == name {
                return self.sc_tyvar[i]
            }
            i = i - 1
        }
        return false
    }


    // subject_is_gopt reports whether a match scrutinee is a GENERIC Option/Result param (recorded in cur_gopt),
    // so its `case Some(v)` / `case Ok(v)` payload binds an erased T — a refcounted borrow (OFI-205).
    fn subject_is_gopt(self, e: ps.Expr) -> bool {
        match e {
            case EIdent(name) {
                var i = 0
                loop {
                    if i >= self.cur_gopt.len() {
                        break
                    }
                    if self.cur_gopt[i] == name {
                        return true
                    }
                    i = i + 1
                }
                return false
            }
            case _ {
                return false
            }
        }
    }


    // set_last_struct records the struct sid of the most-recently pushed binding (a value-struct local),
    // so `p.field` reads and the binding's C storage type resolve. Called right after push for a struct let.
    fn set_last_struct(mut self, sid: int) {
        self.sc_struct[self.sc_struct.len() - 1] = sid
    }


    // set_last_elem_struct records the ELEMENT struct sid of the most-recently pushed STRUCT-array binding,
    // so `arr[i]` types as a boxed struct and `arr[i].field` resolves. Called right after push.
    fn set_last_elem_struct(mut self, sid: int) {
        self.sc_elem_struct[self.sc_elem_struct.len() - 1] = sid
    }


    // set_last_elem_aek records the ELEMENT ArrayElemKind of the most-recently pushed array binding (so a
    // consumed `[bool]` element (AEK 11) is not mistaken for a refcounted string/enum element (AEK 0)).
    fn set_last_elem_aek(mut self, aek: int) {
        self.sc_elem_aek[self.sc_elem_aek.len() - 1] = aek
    }


    fn lookup_elem_aek(self, name: string) -> int {
        var i = self.sc_name.len() - 1
        loop {
            if i < 0 {
                break
            }
            if self.sc_name[i] == name {
                return self.sc_elem_aek[i]
            }
            i = i - 1
        }
        return 0 - 1
    }


    // set_last_elem_is_array marks the most-recently pushed array binding's ELEMENT as itself an array (`[[T]]`),
    // so `grid[i].len()` dispatches to em_array_len, not em_str_len (OFI-219).
    fn set_last_elem_is_array(mut self, v: bool) {
        self.sc_elem_is_array[self.sc_elem_is_array.len() - 1] = v
    }


    fn lookup_elem_is_array(self, name: string) -> bool {
        var i = self.sc_name.len() - 1
        loop {
            if i < 0 {
                break
            }
            if self.sc_name[i] == name {
                return self.sc_elem_is_array[i]
            }
            i = i - 1
        }
        return false
    }


    // set_last_elem_elem_kind records the INNER element scalar kind of the most-recently pushed `[[T]]` binding.
    fn set_last_elem_elem_kind(mut self, k: int) {
        self.sc_elem_elem_kind[self.sc_elem_elem_kind.len() - 1] = k
    }


    fn lookup_elem_elem_kind(self, name: string) -> int {
        var i = self.sc_name.len() - 1
        loop {
            if i < 0 {
                break
            }
            if self.sc_name[i] == name {
                return self.sc_elem_elem_kind[i]
            }
            i = i - 1
        }
        return 0 - 1
    }


    // lookup_struct returns the value-struct sid of binding `name` (-1 if not a value-struct binding).
    fn lookup_struct(self, name: string) -> int {
        var i = self.sc_name.len() - 1
        loop {
            if i < 0 {
                break
            }
            if self.sc_name[i] == name {
                return self.sc_struct[i]
            }
            i = i - 1
        }
        return 0 - 1
    }


    // lookup_elem_struct returns the ELEMENT struct sid of struct-array binding `name` (-1 if none).
    fn lookup_elem_struct(self, name: string) -> int {
        var i = self.sc_name.len() - 1
        loop {
            if i < 0 {
                break
            }
            if self.sc_name[i] == name {
                return self.sc_elem_struct[i]
            }
            i = i - 1
        }
        return 0 - 1
    }


    // lookup_elem_kind returns array binding `name`'s ELEMENT scalar width-kind (-1 if not an array / unknown).
    fn lookup_elem_kind(self, name: string) -> int {
        var i = self.sc_name.len() - 1
        loop {
            if i < 0 {
                break
            }
            if self.sc_name[i] == name {
                return self.sc_elem_kind[i]
            }
            i = i - 1
        }
        return 0 - 1
    }


    fn lookup_array(self, name: string) -> bool {
        var i = self.sc_name.len() - 1
        loop {
            if i < 0 {
                break
            }
            if self.sc_name[i] == name {
                return self.sc_array[i]
            }
            i = i - 1
        }
        return false
    }


    // ind returns the current indentation (4 spaces per level).
    fn ind(self) -> string {
        var s = ""
        var i = 0
        loop {
            if i >= self.indent {
                break
            }
            s = s + "    "
            i = i + 1
        }
        return s
    }


    // scope_has_drops reports whether any in-scope binding is an owned heap value needing a drop at exit.
    fn scope_has_drops(self) -> bool {
        var i = 0
        loop {
            if i >= self.sc_drop.len() {
                break
            }
            if self.sc_drop[i] {
                return true
            }
            i = i + 1
        }
        return false
    }


    // emit_drops prints `drop_value(&g_em, <cname>);` for every owned binding in [from, len), innermost
    // (latest) first — the order the runtime releases scope-exit owners (cgen_c.c:emit_drops). `from` = 0
    // at a function exit; a block/loop passes its scope mark to drop only what the block declared.
    fn emit_drops(self, from: int) {
        var i = self.sc_drop.len() - 1
        loop {
            if i < from {
                break
            }
            if self.sc_drop[i] {
                println("{self.ind()}drop_value(&g_em, {self.sc_cname[i]});")
            }
            i = i - 1
        }
    }


    // truncate_scope drops scope entries past `mark` (a block's locals leave scope at its `}`). Rebuilds the
    // parallel arrays (Ingle has no array pop), mirroring cgen_c.c's `g->scope_len = mark`.
    fn truncate_scope(mut self, mark: int) {
        var nn: [string] = []
        var nc: [string] = []
        var nk: [int] = []
        var nu: [bool] = []
        var nd: [bool] = []
        var na: [bool] = []
        var ne: [int] = []
        var nea: [int] = []
        var neia: [bool] = []
        var neek: [int] = []
        var nes: [int] = []
        var nrc: [bool] = []
        var ntv: [bool] = []
        var ns: [int] = []
        var nrd: [int] = []
        var i = 0
        loop {
            if i >= mark {
                break
            }
            nn.append(self.sc_name[i])
            nc.append(self.sc_cname[i])
            nk.append(self.sc_kind[i])
            nu.append(self.sc_unboxed[i])
            nd.append(self.sc_drop[i])
            na.append(self.sc_array[i])
            ne.append(self.sc_elem_kind[i])
            nea.append(self.sc_elem_aek[i])
            neia.append(self.sc_elem_is_array[i])
            neek.append(self.sc_elem_elem_kind[i])
            nes.append(self.sc_elem_struct[i])
            nrc.append(self.sc_refc[i])
            ntv.append(self.sc_tyvar[i])
            ns.append(self.sc_struct[i])
            nrd.append(self.sc_render[i])
            i = i + 1
        }
        self.sc_elem_struct = nes
        self.sc_elem_is_array = neia
        self.sc_elem_elem_kind = neek
        self.sc_refc = nrc
        self.sc_tyvar = ntv
        self.sc_name = nn
        self.sc_cname = nc
        self.sc_kind = nk
        self.sc_unboxed = nu
        self.sc_drop = nd
        self.sc_array = na
        self.sc_elem_kind = ne
        self.sc_elem_aek = nea
        self.sc_struct = ns
        self.sc_render = nrd
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


    // extern_index returns the position of a DECLARED `extern "c"` fn in the extern side table, or -1 —
    // the handle for resolving an FFI call's declared return type (its width-kind / string-ness). P6 FFI.
    fn extern_index(self, name: string) -> int {
        var i = 0
        loop {
            if i >= self.extern_names.len() {
                break
            }
            if self.extern_names[i] == name {
                return i
            }
            i = i + 1
        }
        return 0 - 1
    }


    // recv_container_ty returns the DECLARED type of a method-call receiver when it is a struct FIELD access
    // (`self.rects` / `obj.field`) — a `TyGeneric` carrying the container's value type-args (`Map<string,
    // Rect>`). Returns the sentinel `TyName("","")` for anything else (a local, a call result, …). P6 keystone.
    fn recv_container_ty(self, recv: ps.Expr) -> ps.Ty {
        match recv {
            case EGet(object, fname) {
                let osid = self.struct_sid_any(object.value)
                if osid >= 0 {
                    return self.st.field_ty(osid, fname)
                }
            }
            case _ {
            }
        }
        return ps.TyName("", "")
    }


    // match_payload_sid resolves the CONCRETE struct sid of a `Some(r)`/`Ok(r)` payload for a match scrutinee
    // shaped `recv.get(k)` — a generic-container method returning Option<V>/Result<V,…>. It reads the receiver
    // FIELD's declared type-args and the method's payload-param index (fn_ret_opt_param), indexing the former
    // by the latter: `self.rects.get(id)` with rects: Map<string,Rect>, get's payload param = 1 → Rect. This
    // is the self-hosted stand-in for stage-0's checker `subst(inst, var->fields[b])` (no checker in this
    // pipeline to stamp Pattern.binding_struct). Returns -1 when not resolvable — the caller leaves the payload
    // erased, exactly as before. OFI-218 generic-payload keystone.
    fn match_payload_sid(self, scrut: ps.Expr) -> int {
        match scrut {
            case ECall(callee, args) {
                match callee.value {
                    case EGet(recv, mname) {
                        match self.recv_container_ty(recv.value) {
                            case TyGeneric(q, cname, cargs) {
                                let fi = self.fn_index("{cname}.{mname}")
                                if fi < 0 {
                                    return 0 - 1
                                }
                                let idx = self.fn_ret_opt_param[fi]
                                if idx < 0 || idx >= cargs.len() {
                                    return 0 - 1
                                }
                                return self.st.sid_of_ty(cargs[idx])
                            }
                            case _ {
                            }
                        }
                    }
                    case _ {
                    }
                }
            }
            case EIndex(arr, idx) {
                // An ARRAY-element scrutinee `self.buckets[i]` of a `[Option<MapEntry>]` field: the Some payload
                // is the array's element Option/Result payload (MapEntry). Resolve the field's declared element
                // type and extract the enum payload. (Map.get matches self.buckets[i].)
                match arr.value {
                    case EGet(obj, fname) {
                        let osid = self.struct_sid_any(obj.value)
                        if osid >= 0 {
                            return self.option_payload_base_sid(elem_ty_of(self.st.field_ty(osid, fname)))
                        }
                    }
                    case EIdent(aname) {
                        // a local array binding whose element enum-payload struct was tracked at the binding
                        return self.lookup_elem_struct(aname)
                    }
                    case _ {
                    }
                }
            }
            case _ {
            }
        }
        return 0 - 1
    }


    // option_payload_base_sid returns the DECLARED base struct sid of an `Option<X>` / `Result<X, _>` type's
    // payload X (`Option<MapEntry<K,V>>` -> MapEntry base sid), or -1 if not an Option/Result of a struct.
    fn option_payload_base_sid(self, ty: ps.Ty) -> int {
        match ty {
            case TyGeneric(q, n, args) {
                if (n == "Option" || n == "Result") && args.len() >= 1 {
                    return self.st.base_sid_of_ty(args[0])
                }
            }
            case _ {
            }
        }
        return 0 - 1
    }


    // lookup_tp_tname returns the OWNER type-param name a param-name is typed as (`key` → "K"), or "".
    fn lookup_tp_tname(self, name: string) -> string {
        var i = 0
        loop {
            if i >= self.cur_tp_pname.len() {
                break
            }
            if self.cur_tp_pname[i] == name {
                return self.cur_tp_tname[i]
            }
            i = i + 1
        }
        return ""
    }


    // bound_for_method returns which of owner type-param `tpname`'s bounds declares method `mname` (hash→Hash,
    // eq→Eq), or "".
    fn bound_for_method(self, owner: int, tpname: string, mname: string) -> string {
        let bounds = split_plus_list(self.st.struct_bound_of(owner, tpname))
        var bi = 0
        loop {
            if bi >= bounds.len() {
                break
            }
            if index_of_str(iface_methods(bounds[bi]), mname) >= 0 {
                return bounds[bi]
            }
            bi = bi + 1
        }
        return ""
    }


    // witness_field_index returns the flat field index of owner `owner`'s (tparam, bound) witness — the base
    // (declared field count) plus the running position of (tparam, bound) in $wit layout order.
    fn witness_field_index(self, owner: int, tpname: string, bound: string) -> int {
        let base = self.st.struct_declared_field_count(owner)
        let obase = self.st.base_of(owner)
        var pos = 0
        var row = 0
        loop {
            if row >= self.st.sg_owner.len() {
                break
            }
            if self.st.sg_owner[row] == obase && self.st.sg_bound[row] != "" {
                let bounds = split_plus_list(self.st.sg_bound[row])
                var bi = 0
                loop {
                    if bi >= bounds.len() {
                        break
                    }
                    if self.st.sg_tparam[row] == tpname && bounds[bi] == bound {
                        return base + pos
                    }
                    pos = pos + 1
                    bi = bi + 1
                }
            }
            row = row + 1
        }
        return 0 - 1
    }


    // emit_witness_call lowers a bounded-method call on a type-param receiver (`key.hash()`, `e.key.eq(k)`) to a
    // witness dispatch: read self's witness field, extract the method-ref at the interface method index, and
    // rt_call_indirect it. Receiver + args are BORROWS (no retain/release), matching the VM. OFI-174.
    fn emit_witness_call(mut self, recv: ps.Expr, tpname: string, mname: string, args: [ps.Expr]) -> string {
        let bound = self.bound_for_method(self.cur_owner, tpname, mname)
        let widx = self.witness_field_index(self.cur_owner, tpname, bound)
        let midx = index_of_str(iface_methods(bound), mname)
        let selfc = self.lookup_cname("self")
        var s = "rt_call_indirect(&g_em, AS_INT(em_enum_field(&g_em, em_enum_field(&g_em, {selfc}, {widx}), {midx})), {1 + args.len()}, (Value[])\{ "
        s = s + self.emit_expr(recv)
        var i = 0
        loop {
            if i >= args.len() {
                break
            }
            s = s + ", " + self.emit_expr(args[i])
            i = i + 1
        }
        return s + " \}, em_invoke)"
    }


    // object_is_owning_temp reports whether `e` produces a fresh OWNING temp whose field read must be a
    // materialise-retain-drop (cgen_c.c's is_owning_temp / drop_object): `arr[i]` on an INLINE-PACKABLE
    // (boxed) struct array (em_index materialises an owned COPY), or a CALL returning a refcounted (boxed)
    // struct. Consuming such a field read in a `+` owns it (own_into_slot) WITHOUT the borrow retain-dance
    // (emit_concat_operand's `!drop_object` gate).
    fn object_is_owning_temp(self, e: ps.Expr) -> bool {
        match e {
            case EIndex(object, index) {
                let esid = self.struct_sid_any(e)
                return esid >= 0 && self.st.is_inline_packable(esid) && self.st.is_value(esid) == false
            }
            case ECall(callee, args) {
                let sid = self.struct_sid_any(e)
                return sid >= 0 && self.st.is_value(sid) == false   // a call returning a boxed struct is a fresh owned temp
            }
            case _ {
                return false
            }
        }
    }


    // ---- expression emission (M5a: int scalars — literals, idents, binops, user calls) --------------
    // emit_expr returns the C expression text for `e`. An in-scope SCALAR binding is re-boxed
    // `INT_VAL((int64_t)vN)`; a Value binding/param is its C name as-is.
    fn emit_expr(mut self, e: ps.Expr) -> string {
        match e {
            case EInt(v, _) {
                return "INT_VAL({v}LL)"
            }
            case EBool(b) {
                // A bool literal is an INT_VAL(0/1) — the runtime has no distinct bool tag (cgen_c.c:EXPR_BOOL).
                if b {
                    return "INT_VAL(1)"
                }
                return "INT_VAL(0)"
            }
            case EFloat(v) {
                // A float literal → FLOAT_VAL(<value>). Stage-0 renders %.17g (exact round-trip); the corpus's
                // only float literal is 0.0, where Ingle's %g interpolation coincides ("0"). A NON-round float
                // literal would need a %.17g formatter builtin (an orthogonal follow-up, unused so far).
                return "FLOAT_VAL({v})"
            }
            case EIdent(name) {
                if self.en.is_case_variant(name) && self.lookup_cname(name) == "" {
                    var no_args: [ps.Expr] = []
                    return self.emit_enum_ctor(name, no_args)   // a bare (zero-payload) enum variant `Dot` / prelude `None`
                }
                if self.lookup_cname(name) == "" {
                    let ci = self.consts.lookup_idx(name)   // a module-level folded constant `TAG_IDENT` → its literal
                    if ci >= 0 {
                        return "INT_VAL({self.consts.vals[ci]}LL)"
                    }
                }
                let cn = self.lookup_cname(name)
                if cn == "" {
                    let fvi = self.fn_index(name)
                    if fvi >= 0 {
                        return "em_closure(&g_em, {fvi}, 0)"   // a named function used as a VALUE — a zero-capture closure (cgen_c.c EXPR_FN_VALUE)
                    }
                }
                if self.lookup_unboxed(name) {
                    return "INT_VAL((int64_t){cn})"      // an unboxed scalar `let` boxes back to a Value
                }
                return cn                                // a param / Value binding is read as-is
            }
            case EBinary(op, l, r) {
                return self.emit_binary(op, l.value, r.value)
            }
            case EUnary(op, operand) {
                // prefix unary: `-x` → em_neg(x, num_kind) · `!x` → em_not(x) · `~x` → em_bitnot(x, num_kind).
                // num_kind is the result width (0 = i64 for the int subset), like emit_binary. (cgen_c.c:emit_unary.)
                let uid = ps.unop_id(op)
                if uid == 2 {
                    return "em_not({self.emit_expr(operand.value)})"
                }
                if uid == 3 {
                    return "em_bitnot({self.emit_expr(operand.value)}, 0)"
                }
                return "em_neg({self.emit_expr(operand.value)}, 0)"
            }
            case ECall(callee, args) {
                return self.emit_call(callee.value, args)
            }
            case EStr(parts) {
                return self.emit_str(parts)
            }
            case EArray(elems, lines) {
                // A non-empty array literal → em_array(&g_em, n, elem_kind, e0, e1, …). The element kind is
                // inferred from the first element (codegen.ig's rule); each element is emitted in source order
                // (a left-to-right loop, so any side-effecting element keeps a deterministic var number — the
                // OFI-166 eval-order discipline). An empty `[]` is lowered by the binding site (it needs the
                // annotation for its element kind); a bare `[]` here defaults to a boxed empty array.
                if elems.len() == 0 {
                    return "em_array(&g_em, 0, 0)"
                }
                let ek = self.elem_kind_of_expr(elems[0])
                var s = "em_array(&g_em, {elems.len()}, {ek}"
                var i = 0
                loop {
                    if i >= elems.len() {
                        break
                    }
                    let el = self.emit_consume_arg(elems[i])   // em_array CONSUMES its elements (an owned one moved in; a scalar as-is)
                    s = s + ", " + el
                    i = i + 1
                }
                return s + ")"
            }
            case EIndex(object, index) {
                // An index read `arr[i]` → em_index(&g_em, arr, i) (bounds-checked; returns the element
                // WITHOUT retaining — the array keeps ownership). Object then index in source order (OFI-166).
                let o = self.emit_expr(object.value)
                let ix = self.emit_expr(index.value)
                return "em_index(&g_em, {o}, {ix})"
            }
            case EStructLit(ty, fields) {
                return self.emit_struct_lit(ty.value, fields)
            }
            case EGet(object, name) {
                // An OWNING-TEMP receiver `arr[i].field` where the array's element is INLINE-PACKABLE
                // (a boxed struct materialised by em_index into a fresh owned COPY, cgen_c.c drop_object):
                // read the field, RETAIN it (survive the copy's drop), then DROP the element copy —
                // materialise-retain-drop. Without this the materialised element leaks.
                if self.object_is_owning_temp(object.value) {
                    let esid = self.struct_sid_any(object.value)
                    let fidx = self.st.field_index(esid, name)
                    if fidx >= 0 {
                        let ov = self.fresh_var()
                        let fv = self.fresh_var()
                        return "(\{ Value v{ov} = {self.emit_expr(object.value)}; Value v{fv} = em_enum_field(&g_em, v{ov}, {fidx}); if (IS_OBJ(v{fv})) OBJ_RETAIN(AS_OBJ(v{fv})); drop_value(&g_em, v{ov}); v{fv}; \})"
                    }
                }
                // A VALUE-struct field read is a direct C member access `<obj>.f<idx>` (no heap, no ownership).
                // A BOXED-struct field read is `em_enum_field(&g_em, <obj>, <idx>)` — a BORROW (the struct
                // still owns the field; a consuming op retains it, see emit_concat_operand).
                let vsid = self.struct_sid_of(object.value)
                if vsid >= 0 {
                    let fidx = self.st.field_index(vsid, name)
                    if fidx >= 0 {
                        return "{self.emit_expr(object.value)}.f{fidx}"
                    }
                }
                let bsid = self.boxed_sid_of(object.value)
                if bsid >= 0 {
                    let fidx = self.st.field_index(bsid, name)
                    if fidx >= 0 {
                        return "em_enum_field(&g_em, {self.emit_expr(object.value)}, {fidx})"
                    }
                }
                // A MODULE-QUALIFIED CONSTANT `verify.VERIFY_CAP` — the receiver is an import ALIAS (not a
                // binding / struct), the name a module-level folded int constant. Emit its literal (the
                // qualifier is erased, like an unqualified constant read).
                match object.value {
                    case EIdent(recv) {
                        if self.lookup_cname(recv) == "" && self.lookup_struct(recv) < 0 {
                            let ci = self.consts.lookup_idx(name)
                            if ci >= 0 {
                                return "INT_VAL({self.consts.vals[ci]}LL)"
                            }
                        }
                    }
                    case _ {
                    }
                }
                return cgc_internal_error("unsupported field access `.{name}` — boxed-generic element or qualified variant (OFI-173/OFI-202)")
            }
            case ELambda(params, body) {
                // A lambda VALUE → `em_closure(&g_em, <lifted slot>, <ncap>, <cap0>, …)`. The captures are the
                // lifted fn's leading params; each is the enclosing local's C expr — a scalar boxed to a Value,
                // a heap value emitted as-is (em_closure retains it). The slot counter matches collect_lambdas'
                // discovery order (OFI-206).
                let caps = cgc_lambda_captures(params, body)
                var s = "em_closure(&g_em, {self.cur_lambda}, {caps.len()}"
                var ci = 0
                loop {
                    if ci >= caps.len() {
                        break
                    }
                    let cn = self.lookup_cname(caps[ci])
                    if self.lookup_unboxed(caps[ci]) {
                        s = s + ", INT_VAL((int64_t){cn})"
                    } else {
                        s = s + ", {cn}"
                    }
                    ci = ci + 1
                }
                self.cur_lambda = self.cur_lambda + 1
                return s + ")"
            }
            case _ {
                return cgc_internal_error("unhandled expression kind (OFI-173; a lambda argument needs lambda lifting, OFI-206)")
            }
        }
    }


    // struct_sid_any returns the struct sid (VALUE or BOXED) an expression produces, or -1: a struct literal,
    // a struct binding, a struct-returning call / method, or a nested struct field read. The two public
    // accessors gate it by is_value. Mirrors cgen_c.c:struct_sid_of (value) / the boxed-receiver paths.
    fn struct_sid_any(self, e: ps.Expr) -> int {
        match e {
            case EStructLit(ty, fields) {
                return self.st.sid_of_ty(ty.value)
            }
            case EIdent(name) {
                return self.lookup_struct(name)
            }
            case EIndex(object, index) {
                // an element read of a STRUCT array `arr[i]` → the array's element struct sid (a boxed clone):
                // a binding array `xs[i]`, or a struct-FIELD array `s.items[i]` (resolve the field's element sid).
                match object.value {
                    case EIdent(aname) {
                        return self.lookup_elem_struct(aname)
                    }
                    case EGet(gobj, gname) {
                        let osid = self.struct_sid_any(gobj.value)
                        if osid >= 0 {
                            return self.st.field_elem_struct(osid, gname)
                        }
                    }
                    case _ {
                    }
                }
                return 0 - 1
            }
            case ECall(callee, args) {
                match callee.value {
                    case EIdent(name) {
                        let fi = self.fn_index(name)
                        if fi >= 0 {
                            return self.fn_ret_struct[fi]
                        }
                    }
                    case EGet(object, mname) {
                        let rsid = self.struct_sid_any(object.value)
                        if rsid >= 0 {
                            let fi = self.fn_index("{self.st.names[rsid]}.{mname}")
                            if fi >= 0 {
                                return self.fn_ret_struct[fi]
                            }
                        }
                        // A MODULE-QUALIFIED free call `proc.run(…)` whose return is a (boxed/resource) struct —
                        // the receiver is an import alias, not a struct binding, so resolve `run` in the merged
                        // fn table and read its return struct sid, so `let r = proc.run(cmd)` tracks `r` as a Run
                        // and `r.code()` dispatches. Mirrors emit_call's qual_free_fi path.
                        let qfi = self.qual_free_fi(object.value, mname)
                        if qfi >= 0 {
                            return self.fn_ret_struct[qfi]
                        }
                    }
                    case _ {
                    }
                }
                return 0 - 1
            }
            case EGet(object, name) {
                let osid = self.struct_sid_any(object.value)
                if osid >= 0 {
                    let fidx = self.st.field_index(osid, name)
                    if fidx >= 0 {
                        return self.st.f_struct[self.st.flat_index(osid, fidx)]   // nested field's struct sid (or -1)
                    }
                }
                return 0 - 1
            }
            case _ {
                return 0 - 1
            }
        }
    }


    // struct_sid_of is the VALUE-struct sid an expression produces (an em_s: value semantics, `.fN` reads).
    fn struct_sid_of(self, e: ps.Expr) -> int {
        let s = self.struct_sid_any(e)
        if s >= 0 && self.st.is_value(s) {
            return s
        }
        return 0 - 1
    }


    // boxed_sid_of is the BOXED-struct sid an expression produces (a heap ObjStruct: em_struct / em_enum_field
    // field access, owned local / borrow param — like an array).
    fn boxed_sid_of(self, e: ps.Expr) -> int {
        let s = self.struct_sid_any(e)
        if s >= 0 && self.st.is_value(s) == false {
            return self.st.base_of(s)   // a generic INSTANCE binding tracks its BASE (declared) sid, so method/
                                        // field resolution (`names[sid]`) works — the erased layout is the base's
        }
        return 0 - 1
    }


    // slit_index returns the position in a struct literal's field list of declared field `fname` (or -1) —
    // the literal may list fields in any order, but the compound literal must place them in DECLARED order.
    fn slit_index(self, fields: [ps.SLitField], fname: string) -> int {
        var i = 0
        loop {
            if i >= fields.len() {
                break
            }
            if fields[i].name == fname {
                return i
            }
            i = i + 1
        }
        return 0 - 1
    }


    // emit_struct_lit renders a struct construction. A VALUE struct is a C compound literal
    // `((em_s<sid>){ f0, f1, … })` in DECLARED field order (fields emitted left-to-right — OFI-166).
    // A boxed struct (em_struct) is a later increment (M5e.2).
    // witness_method_ref resolves a (concrete type, interface method) to the fn-id baked into a witness
    // record: a USER type's custom impl (`{Type}.{method}` in fn_names), else a native sentinel —
    // WITNESS_NATIVE_BASE(1000000)+NATIVE_HASH_ANY(20)=1000020 for hash, +NATIVE_VALUE_EQ(21)=1000021 for eq.
    fn witness_method_ref(self, concrete: string, mname: string) -> int {
        let fi = self.fn_index("{concrete}.{mname}")
        if fi >= 0 {
            return fi
        }
        if mname == "hash" {
            return 1000020
        }
        if mname == "eq" {
            return 1000021
        }
        return 0
    }


    // emit_witness renders ONE bound's witness record for a concrete type-arg: em_enum(&g_em, 0, 0, <method
    // count>, INT_VAL(id0), …) — a generic record enum (id 0 / tag 0, NOT Some, so it can't collide with an
    // Option enum id). One INT_VAL per interface method, in declaration order.
    fn emit_witness(self, bound: string, concrete: string) -> string {
        let methods = iface_methods(bound)
        var s = "em_enum(&g_em, 0, 0, {methods.len()}"
        var i = 0
        loop {
            if i >= methods.len() {
                break
            }
            s = s + ", INT_VAL({self.witness_method_ref(concrete, methods[i])})"
            i = i + 1
        }
        return s + ")"
    }


    // emit_struct_witnesses renders the trailing witness field values for a BOUNDED struct construction, in
    // (type-param, then split-plus bound) order — exactly the layout order build_struct_tab appended the $wit
    // fields. The k-th type-param's concrete type-arg is `ty`'s k-th argument. Returns ", w0, w1, …" (leading
    // comma per witness) to splice after the declared field values.
    fn emit_struct_witnesses(self, sid: int, ty: ps.Ty) -> string {
        let base = self.st.base_of(sid)
        var s = ""
        var k = 0
        var row = 0
        loop {
            if row >= self.st.sg_owner.len() {
                break
            }
            if self.st.sg_owner[row] == base {
                if self.st.sg_bound[row] != "" {
                    let concrete = nth_targ_head(ty, k)
                    let bounds = split_plus_list(self.st.sg_bound[row])
                    var bi = 0
                    loop {
                        if bi >= bounds.len() {
                            break
                        }
                        s = s + ", " + self.emit_witness(bounds[bi], concrete)
                        bi = bi + 1
                    }
                }
                k = k + 1
            }
            row = row + 1
        }
        return s
    }


    fn emit_struct_lit(mut self, ty: ps.Ty, fields: [ps.SLitField]) -> string {
        var sid = self.st.sid_of_ty(ty)
        let base = self.st.base_sid_of_ty(ty)
        // An ERASED construction of a BOUNDED generic (Map<string,int>) uses the BASE sid (witness VALUES ride
        // as trailing fields; the layout is the base's). A type-param generic construction (`MapEntry<K,V>{…}`
        // inside a generic body) has no concrete collected instance, so also falls back to the base. Mirrors
        // codegen.ig's struct_is_bounded / lit_struct_id. OFI-218 (erased generics).
        if base >= 0 && self.st.struct_is_bounded(base) {
            sid = base
        } else if sid < 0 {
            sid = base
        }
        if sid < 0 {
            return cgc_internal_error("struct literal with an unresolved struct id (OFI-173)")
        }
        let fc = self.st.field_count(sid)
        if self.st.is_value(sid) {
            // VALUE struct → a C compound literal `((em_s<sid>){ f0, f1, … })` in DECLARED field order.
            var s = "((em_s{sid})\{ "
            var f = 0
            loop {
                if f >= fc {
                    break
                }
                if f > 0 {
                    s = s + ", "
                }
                let fname = self.st.f_name[self.st.flat_index(sid, f)]
                let fpos = self.slit_index(fields, fname)
                if fpos >= 0 {
                    s = s + self.emit_expr(fields[fpos].value)
                }
                f = f + 1
            }
            return s + " \})"
        }
        // BOXED struct → em_struct(&g_em, <sid>, <fcount>, f0, f1, …) — a heap ObjStruct whose fields are
        // dropped by drop_value. DECLARED fields in order (a field value is CONSUMED — an owned binding MOVED
        // in, a scalar / fresh temp as-is); then, for a BOUNDED generic, the hidden witness records are
        // appended (fcount already counts them, via field_count). OFI-174.
        var s = "em_struct(&g_em, {sid}, {fc}"
        let declared = self.st.struct_declared_field_count(sid)
        var f = 0
        loop {
            if f >= declared {
                break
            }
            let fname = self.st.f_name[self.st.flat_index(sid, f)]
            let fpos = self.slit_index(fields, fname)
            if fpos >= 0 {
                s = s + ", " + self.emit_field_consume(sid, fname, fields[fpos].value)   // a boxed struct CONSUMES its fields (owned ones moved in; `[]` at the field's kind)
            }
            f = f + 1
        }
        if self.st.struct_is_bounded(sid) {
            s = s + self.emit_struct_witnesses(sid, ty)    // trailing $wit records: em_enum(0,0,count,INT_VAL(id)…)
        }
        return s + ")"
    }


    // emit_enum_ctor renders an enum-variant construction (a bare `Dot` or a payload `Circle(4)`) →
    // `em_enum(&g_em, <enum_id>, <tag>, <arity>, payload…)`. The payload values are emitted in source order
    // (a left-to-right loop — OFI-166). A fresh em_enum is an OWNED refcounted value.
    fn emit_enum_ctor(mut self, name: string, args: [ps.Expr]) -> string {
        let flat = self.en.variant_flat(name)
        var eid = 0
        var tag = 0
        var arity = 0
        if flat >= 0 {
            eid = self.en.v_owner[flat]
            tag = self.en.v_tag[flat]
            arity = self.en.v_arity[flat]
        } else {
            // A PRELUDE Option/Result variant (Some/None/Ok/Err) — absent from the user enum table
            // (OFI-203/204). Its enum id is the user-enum count for Option or +1 for Result, its tag is
            // Some/Ok=0 / None/Err=1, and its arity is the construction payload count — all matching
            // stage-0's DECL_ENUM order (user enums, then prelude Option, then Result).
            eid = self.en.prelude_enum_id(name)
            tag = self.en.prelude_variant_tag(name)
            arity = args.len()
        }
        var s = "em_enum(&g_em, {eid}, {tag}, {arity}"
        var i = 0
        loop {
            if i >= args.len() {
                break
            }
            s = s + ", " + self.emit_consume_arg(args[i])   // em_enum CONSUMES its payloads (an owned one is moved in)
            i = i + 1
        }
        return s + ")"
    }


    // emit_consume_arg renders a value moved INTO a container (an enum payload, a boxed-struct field, an
    // array append element — cgen_c.c's emit_value_arg). The container takes ownership: an OWNED binding is
    // MOVED in (move_binding — own_into_slot for a string/enum, slot-niling for an array/boxed struct); a
    // refcounted FIELD / ELEMENT / owning-temp read is owned in (own_into_slot); a scalar / literal / fresh
    // temp is passed as-is.
    fn emit_consume_arg(mut self, e: ps.Expr) -> string {
        match e {
            case EIdent(name) {
                if self.lookup_drop(name) {
                    return self.move_binding(name)
                }
                let sid = self.lookup_struct(name)
                let is_boxed_struct = sid >= 0 && self.st.is_value(sid) == false
                if self.lookup_refc(name) && is_boxed_struct == false {
                    // a REFCOUNTED (string / enum) PAYLOAD binding moved into a container — own_into_slot
                    // retains it for the container's consume, leaving the enum's own borrow untouched.
                    return "own_into_slot(&g_em, {self.lookup_cname(name)})"
                }
                if self.lookup_array(name) || is_boxed_struct {
                    // a BORROWED unique-owner (an array OR a boxed struct — an `st: StructTab` param) stored
                    // into a container is owned in: own_into_slot CLONES it (neither is refcounted), so the
                    // container gets an independent copy and the borrow's owner keeps its own (moves_local==2).
                    return "own_into_slot(&g_em, {self.lookup_cname(name)})"
                }
            }
            case _ {
            }
        }
        // a refcounted BORROW read (a field / string-or-enum element) is owned into the container
        // (own_into_slot); an owning-temp read (a materialise field read, an inline element) already owns its
        // result — ret_owns returns false for it (the own_into_slot rides the FIELD refcount / element kind).
        if self.ret_owns(e) {
            return "own_into_slot(&g_em, {self.emit_expr(e)})"
        }
        return self.emit_expr(e)
    }


    // emit_field_consume renders a struct FIELD value (a struct literal field or an `s.f = v` write): an
    // empty `[]` builds the array at the FIELD's declared element kind (an inline `[Struct]` field →
    // em_struct_array; else em_array(0, aek)), not the default 0; otherwise it consumes like any container arg.
    fn emit_field_consume(mut self, sid: int, fname: string, value: ps.Expr) -> string {
        match value {
            case EArray(elems, lines) {
                if elems.len() == 0 {
                    let fes = self.st.field_elem_struct(sid, fname)
                    if fes >= 0 && self.st.is_inline_packable(fes) {
                        return "em_struct_array(&g_em, 0, {fes})"
                    }
                    return "em_array(&g_em, 0, {self.st.field_elem_aek(sid, fname)})"
                }
            }
            case _ {
            }
        }
        // A VALUE-STRUCT value flowing into a boxed-Value field SLOT — an ERASED type-param field
        // (`Cell<V>.slot` under Cell<Rect>{ slot: Rect{…} }): the field is a `Value` in the erased base
        // layout, so the em_s must be BOXED (em_box_struct) before it goes into em_struct's Value slot;
        // a raw em_s would blow the varargs ABI (a 32-byte struct where a 16-byte Value is read → SEGV).
        // An INLINE value-struct field (f_struct is a value struct) keeps its em_s. The compiler's own code
        // has no value-struct-into-generic-field, so this is dead in the reproduction gate. OFI-218 (erased).
        let vsid = self.struct_sid_of(value)
        if vsid >= 0 {
            let flat = self.st.field_flat(sid, fname)
            let inline = flat >= 0 && self.st.f_struct[flat] >= 0 && self.st.is_value(self.st.f_struct[flat])
            if inline == false {
                let bv = self.fresh_var()
                return "(\{ em_s{vsid} v{bv} = {self.emit_expr(value)}; em_box_struct(&g_em, {vsid}, (Value*)&v{bv}, {self.st.field_count(vsid)}); \})"
            }
        }
        return self.emit_consume_arg(value)
    }


    // is_enum_expr reports whether an expression CONSTRUCTS an enum value (a bare variant, or a variant with
    // payload) — an OWNED refcounted value, dropped at scope exit / moved into a call like a string.
    fn is_enum_expr(self, e: ps.Expr) -> bool {
        match e {
            case EIdent(name) {
                return self.en.is_case_variant(name) && self.lookup_cname(name) == ""
            }
            case ECall(callee, args) {
                match callee.value {
                    case EIdent(name) {
                        if self.en.is_case_variant(name) {
                            return true                       // a payload variant construction `Circle(4)` / prelude `Some(5)`
                        }
                        let fi = self.fn_index(name)
                        if fi >= 0 {
                            return self.fn_ret_enum[fi]       // an enum-returning free-function call `wrap(7)`
                        }
                    }
                    case EGet(object, mname) {
                        // an enum-returning METHOD call `let k = self.scan_token(…)`.
                        let sid = self.struct_sid_any(object.value)
                        if sid >= 0 {
                            let fi = self.fn_index("{self.st.names[sid]}.{mname}")
                            if fi >= 0 {
                                return self.fn_ret_enum[fi]
                            }
                        }
                        let qfi = self.qual_free_fi(object.value, mname)   // a module-qualified enum-returning call
                        if qfi >= 0 {
                            return self.fn_ret_enum[qfi]
                        }
                        // a UFCS enum-returning free-function call `a.ok_or(e)` (a NON-struct receiver prepended
                        // as arg 0 — its result is an owned Result/Option temp, dropped at scope exit).
                        if sid < 0 {
                            let ufi = self.fn_index(mname)
                            if ufi >= 0 {
                                return self.fn_ret_enum[ufi]
                            }
                        }
                    }
                    case _ {
                    }
                }
                return false
            }
            case _ {
                return false
            }
        }
    }


    // emit_cached_str renders a literal string run as an interned, function-local `static` em_str, retained
    // on read (so the caller can consume it) — the cgen_c.c cached-string-literal form.
    fn emit_cached_str(self, text: string) -> string {
        let bytes = c_escape(text)
        let blen = text.bytes().len()
        return "(\{ static Value _li; static char _ls; if (!_ls) \{ _ls = 1; _li = em_str(&g_em, \"{bytes}\", {blen}); \} if (IS_OBJ(_li)) OBJ_RETAIN(AS_OBJ(_li)); _li; \})"
    }


    // hole_is_string_temp reports whether an interpolation hole is ALREADY a fresh OWNING-TEMP string (a
    // string-returning call, a string concat, or a nested interpolation) — such a hole is concatenated
    // DIRECTLY (em_add consumes the temp), skipping em_to_string. A string BINDING / param / field read (a
    // borrow) and any non-string value go through em_to_string.
    fn hole_is_string_temp(self, e: ps.Expr) -> bool {
        if self.is_string_expr(e) == false {
            return false
        }
        match e {
            case ECall(callee, args) {
                return true
            }
            case EStr(parts) {
                return true
            }
            case EBinary(op, l, r) {
                return true                          // is_string_expr already confirmed a string `+` concat
            }
            case _ {
                return false
            }
        }
    }


    // emit_str_part renders one part of a string: a HOLE `{expr}` → `em_to_string(&g_em, <expr>, 0)` (a fresh
    // owned string; the hole value is BORROWED) — unless the hole is already an owning-temp string, then it is
    // concatenated directly. A literal text run → the cached-static string. Fields read inline (parts[i].*) —
    // passing an array-element field to a fn would be a partial move.
    fn emit_str_part(mut self, parts: [ps.StrPart], i: int) -> string {
        if parts[i].hole.len() == 1 {
            if self.hole_is_string_temp(parts[i].hole[0]) {
                return self.emit_expr(parts[i].hole[0])
            }
            let rk = self.render_kind_of_expr(parts[i].hole[0])   // int 0 · float 9 · bool 10 · sized 1..8
            return "em_to_string(&g_em, {self.emit_expr(parts[i].hole[0])}, {rk})"
        }
        return self.emit_cached_str(parts[i].text)
    }


    // render_kind_of_expr returns an interpolation hole's render-kind (em_to_string's 3rd arg): a numeric
    // LITERAL by its form, a binding by its tracked render-kind (float/bool/sized payload or scalar local),
    // else 0 (int / non-numeric — em_to_string ignores the kind for a string/struct/enum value). Mirrors
    // the checker's per-part render_kind (check.c int_kind).
    fn render_kind_of_expr(self, e: ps.Expr) -> int {
        match e {
            case EFloat(v) {
                return 9
            }
            case EInt(v, kind) {
                return kind
            }
            case EBool(b) {
                return 10
            }
            case EIdent(name) {
                return self.lookup_render(name)
            }
            case EIndex(object, index) {
                // a float/bool/sized ARRAY element hole (`{chunk.const_float[i]}`) renders at its element kind.
                return aek_to_render_kind(self.index_elem_aek(object.value))
            }
            case ECall(callee, args) {
                // a hole over a CALL `{r.ok()}` / `{is_ready()}` renders at the callee's return-type kind, so a
                // bool method prints "true"/"false" not "1"/"0". Resolve free / method / module-qualified calls.
                match callee.value {
                    case EIdent(name) {
                        let fi = self.fn_index(name)
                        if fi >= 0 {
                            return self.fn_ret_render[fi]
                        }
                    }
                    case EGet(object, mname) {
                        let rsid = self.struct_sid_any(object.value)
                        if rsid >= 0 {
                            let fi = self.fn_index("{self.st.names[rsid]}.{mname}")
                            if fi >= 0 {
                                return self.fn_ret_render[fi]
                            }
                        }
                        let qfi = self.qual_free_fi(object.value, mname)
                        if qfi >= 0 {
                            return self.fn_ret_render[qfi]
                        }
                    }
                    case _ {
                    }
                }
                return 0
            }
            case _ {
                return 0
            }
        }
    }


    // index_elem_aek returns the ELEMENT ArrayElemKind of an indexed array: a struct-FIELD array via
    // field_elem_aek, a binding/param array via its tracked sc_elem_aek, else -1.
    fn index_elem_aek(self, object: ps.Expr) -> int {
        match object {
            case EGet(gobj, gname) {
                let sid = self.struct_sid_any(gobj.value)
                if sid >= 0 {
                    return self.st.field_elem_aek(sid, gname)
                }
            }
            case EIdent(name) {
                return self.lookup_elem_aek(name)
            }
            case _ {
            }
        }
        return 0 - 1
    }


    // emit_str renders a string. A single literal run (no interpolation) is an interned cached em_str; an
    // interpolated string `"a{x}b"` LEFT-FOLDS em_add (string concat) over its parts — a literal run is the
    // cached string, a hole is em_to_string of its value (each part an owned temp em_add consumes). Parts are
    // emitted in source order (a sequential loop — the OFI-166 discipline).
    fn emit_str(mut self, parts: [ps.StrPart]) -> string {
        if parts.len() == 0 {
            return self.emit_cached_str("")
        }
        if parts.len() == 1 && parts[0].hole.len() == 0 {
            return self.emit_cached_str(parts[0].text)
        }
        var acc = self.emit_str_part(parts, 0)
        var i = 1
        loop {
            if i >= parts.len() {
                break
            }
            let p = self.emit_str_part(parts, i)
            acc = "em_add(&g_em, {acc}, {p}, 0)"
            i = i + 1
        }
        return acc
    }


    // emit_binary mirrors cgen_c.c:emit_binary — each operator maps to an em_* runtime call; em_add /
    // em_eq_op / em_neq_op take the runtime ctx (`&g_em`) and RETAIN a borrowed operand (they consume),
    // every other op reads its operands directly. The numeric ops carry the width as a trailing num_kind
    // (0 = i64 for the int subset).
    fn emit_binary(mut self, op: lx.Tk, l: ps.Expr, r: ps.Expr) -> string {
        let bid = ps.binop_id(op)
        // The two operands are emitted into LOCALS first, in source (left-to-right) order. Each emit_
        // bumps the shared `next_var`, and we must NOT depend on the C compiler's UNSPECIFIED operand
        // evaluation order — gcc evaluates a `+`/call's operands right-to-left where clang and the VM go
        // left-to-right, which would otherwise SWAP the retain-temp v-numbers (a VM/native divergence the
        // ccdiff differential caught on Linux gcc). Sequencing them as statements forces the order. OFI-166.
        // short-circuit && / || — a truthy test, not an em_ call (binop_id 12 && / 13 ||)
        if bid == 12 || bid == 13 {
            var c = "&&"
            if bid == 13 {
                c = "||"
            }
            let lc = self.emit_expr(l)
            let rc = self.emit_expr(r)
            return "INT_VAL((em_truthy({lc}) {c} em_truthy({rc})) ? 1 : 0)"
        }
        let cf = binop_cfn(bid)
        let ctx = binop_wants_ctx(bid)
        var opl = ""
        var opr = ""
        if ctx {
            // `+` (bid 1) CONSUMES its operands (an owned operand is moved in); `==` / `!=` (10/11) only
            // COMPARE (borrow), so an owned operand is retained, not moved — it is read again later.
            let consuming = bid == 1
            opl = self.emit_concat_operand(l, consuming)
            opr = self.emit_concat_operand(r, consuming)
        } else {
            opl = self.emit_expr(l)
            opr = self.emit_expr(r)
        }
        var s = "{cf}("
        if ctx {
            s = s + "&g_em, "
        }
        s = s + opl + ", " + opr
        if binop_has_nk(bid) {
            s = s + ", 0"                                // num_kind 0 (i64) for the int subset
        }
        return s + ")"
    }


    // emit_concat_operand renders an operand of a CONSUMING op (em_add/eq/neq — they drop both operands),
    // or a returned value. An OWNED binding read is MOVED out (own_into_slot — it transfers ownership);
    // a BORROWED binding read (a non-owned scalar/Value ident) is wrapped in the retain dance so the
    // owner's reference stays balanced; anything else (a literal/call/computed temp) is emitted as-is.
    // retain_dance wraps a BORROWED heap operand in `({ Value vN = <e>; if (IS_OBJ(vN)) OBJ_RETAIN(…); vN; })`
    // so a consuming op (em_add) balances and the owner keeps its reference. The IS_OBJ guard makes it a
    // no-op for scalar operands. vN is taken BEFORE emitting <e>, so it precedes any inner temp (OFI-166).
    fn retain_dance(mut self, e: ps.Expr) -> string {
        let v = self.fresh_var()
        return "(\{ Value v{v} = {self.emit_expr(e)}; if (IS_OBJ(v{v})) OBJ_RETAIN(AS_OBJ(v{v})); v{v}; \})"
    }


    // move_binding renders an OWNED binding being moved OUT (a return / a consumed concat operand). A
    // unique-owner ARRAY is moved by NIL-ing its slot — `({ Value vN = cn; cn = INT_VAL(0); vN; })` — so its
    // scope-exit drop becomes a no-op (a retain would deep-CLONE it; arrays aren't refcounted). A refcounted
    // STRING is owned into the new slot via own_into_slot (a retain), and its scope-exit drop balances it.
    // (cgen_c.c: moves_local==1 for the array, moves_local==2 for the string.)
    fn move_binding(mut self, name: string) -> string {
        let cn = self.lookup_cname(name)
        // A UNIQUE-OWNER binding — an ARRAY or a plain (non-rc) BOXED STRUCT — is moved by NIL-ing its slot
        // (a retain would deep-CLONE it; neither is refcounted). A refcounted STRING / ENUM / rc-struct is
        // owned into the new slot via own_into_slot (a retain balanced by its scope-exit drop).
        // An OWNED erased TYPE-PARAM local (a reduce accumulator `var acc = init`) also MOVES by nil-ing its
        // slot — stage-0's moves_local==1 for a whole-value read of an owned type-param (OFI-176 F2). It reaches
        // move_binding only when owned (lookup_drop), so a BORROWED type-param param still retains elsewhere.
        let sid = self.lookup_struct(name)
        let unique_owner_struct = sid >= 0 && self.st.is_value(sid) == false && self.st.kinds[sid] == 0
        if self.lookup_array(name) || unique_owner_struct || self.lookup_tyvar(name) {
            let m = self.fresh_var()
            return "(\{ Value v{m} = {cn}; {cn} = INT_VAL(0); v{m}; \})"
        }
        return "own_into_slot(&g_em, {cn})"
    }


    fn emit_concat_operand(mut self, e: ps.Expr, consuming: bool) -> string {
        match e {
            case EIdent(name) {
                if self.lookup_cname(name) == "" && self.en.is_variant(name) == false && self.consts.lookup_idx(name) >= 0 {
                    return self.emit_expr(e)   // a folded int constant (INT_VAL literal) — not a heap borrow, no retain-dance
                }
                if self.lookup_drop(name) {
                    if consuming {
                        return self.move_binding(name)   // `+` consumes → move the owned binding out
                    }
                    return self.retain_dance(e)          // `==`/`!=` only compare → retain (still used later)
                }
                if consuming && self.lookup_refc(name) {
                    // a REFCOUNTED BORROW (a string/enum enum-payload binding) owned INTO the consuming op —
                    // own_into_slot retains it (moves_local==2); the enum keeps its own reference.
                    return "own_into_slot(&g_em, {self.lookup_cname(name)})"
                }
                return self.retain_dance(e)
            }
            case EIndex(object, index) {
                // an array-element read `arr[i]` is a BORROW (em_index returns it un-retained) → retain it,
                // so the consuming op balances and the array keeps ownership (cgen_c.c:emit_concat_operand).
                // A refcounted STRING / ENUM element (`p.bindings[i]`) consumed / bound is first owned into a
                // new slot (own_into_slot = the aliased-read moves_local==2 retain), then the balance-retain
                // wraps it. A STRUCT element (`toks[i]` — em_index materialises/borrows the record) is only
                // retained, not owned (its element sid resolves, so struct_sid_any >= 0).
                if consuming && self.is_array_expr(object.value) && self.index_elem_refcounted(object.value) && self.struct_sid_any(e) < 0 {
                    let v = self.fresh_var()
                    return "(\{ Value v{v} = own_into_slot(&g_em, {self.emit_expr(e)}); if (IS_OBJ(v{v})) OBJ_RETAIN(AS_OBJ(v{v})); v{v}; \})"
                }
                return self.retain_dance(e)
            }
            case EGet(object, name) {
                // An OWNING-TEMP field read `arr[i].field` (an inline-packable element — drop_object): emit_expr
                // already materialise-retain-drops it into an OWNED value, so it is NOT a borrow (no retain-dance).
                // Consumed by `+`, it is owned into the concat (own_into_slot, moves_local==2); a `==` read passes
                // the materialised value directly. (cgen_c.c emit_concat_operand's `!drop_object` gate.)
                if self.object_is_owning_temp(object.value) {
                    // the own_into_slot rides the FIELD's refcount (moves_local==2), not the receiver: a
                    // REFCOUNTED field consumed by `+` is owned into the concat; a SCALAR field (or any
                    // non-consuming / returned read) yields the materialised value as-is (it already owns it).
                    if consuming && self.st.field_is_refcounted(self.struct_sid_any(object.value), name) {
                        return "own_into_slot(&g_em, {self.emit_expr(e)})"
                    }
                    return self.emit_expr(e)
                }
                // A field read that is a BORROW yields a value the consuming op would over-release → retain it.
                // (1) `self.field` — self is the borrowed method receiver (a by-value struct param / let field
                // is an owned COPY, NOT retained). (2) a BOXED-struct field read (em_enum_field borrows — the
                // struct owns the field). A value-struct scalar field makes the IS_OBJ retain a no-op.
                let bsid = self.boxed_sid_of(object.value)
                if bsid >= 0 && consuming && self.st.field_is_refcounted(bsid, name) {
                    // a refcounted (string / enum) field CONSUMED by `+` is owned into the concat (own_into_slot,
                    // moves_local==2) and then the consuming op's balance-retain wraps it (cgen_c.c).
                    let v = self.fresh_var()
                    return "(\{ Value v{v} = own_into_slot(&g_em, {self.emit_expr(e)}); if (IS_OBJ(v{v})) OBJ_RETAIN(AS_OBJ(v{v})); v{v}; \})"
                }
                if self.is_self_field(object.value) || bsid >= 0 {
                    return self.retain_dance(e)
                }
            }
            case _ {
            }
        }
        return self.emit_expr(e)
    }


    // is_self_field reports whether `object` is the borrowed method receiver `self` (a value-struct binding),
    // so a field read off it is a borrow. (mut/move self — a consuming receiver — is a later increment.)
    fn is_self_field(self, object: ps.Expr) -> bool {
        match object {
            case EIdent(oname) {
                return oname == "self" && self.lookup_struct(oname) >= 0
            }
            case _ {
                return false
            }
        }
    }


    // emit_call_arg renders a user-call argument: the callee takes OWNERSHIP, so an owned binding is MOVED
    // in via own_into_slot; a non-owned binding / literal / temp is passed AS-IS (no retain — unlike a
    // consuming em_add operand, a plain call does not need the owner's reference balanced separately).
    fn emit_call_arg(mut self, e: ps.Expr) -> string {
        match e {
            case EIdent(name) {
                // An owned STRING / ENUM binding is MOVED in (own_into_slot). An owned ARRAY or BOXED-STRUCT
                // binding is passed as a BORROW (the callee's param is a borrow — the owner keeps it and drops
                // it at its own scope exit).
                let sid = self.lookup_struct(name)
                let is_boxed_struct = sid >= 0 && self.st.is_value(sid) == false
                if self.lookup_drop(name) && self.lookup_array(name) == false && is_boxed_struct == false {
                    return "own_into_slot(&g_em, {self.lookup_cname(name)})"
                }
                if self.lookup_refc(name) && is_boxed_struct == false {
                    // a REFCOUNTED (string / enum) PAYLOAD binding (a borrow the enum owns) moved into a call:
                    // own_into_slot RETAINS it for the callee's consume, leaving the arm's borrow untouched.
                    return "own_into_slot(&g_em, {self.lookup_cname(name)})"
                }
            }
            case EGet(object, name) {
                // A REFCOUNTED (string / enum) struct field read passed to a call is MOVED in (own_into_slot
                // retains the field for the callee's consume; the struct keeps its own reference). A scalar /
                // array / struct field is passed as-is (a borrow).
                let sid = self.struct_sid_any(object.value)
                if sid >= 0 && self.st.field_is_refcounted(sid, name) {
                    return "own_into_slot(&g_em, {self.emit_expr(e)})"
                }
            }
            case EIndex(object, index) {
                // A REFCOUNTED (string / enum) array-element read passed to a call is MOVED in (own_into_slot —
                // em_index returns a fresh owned ref moved into the callee). A boxed STRUCT element (a boxed-
                // pointer array like `[Param]`) is a BORROW (passed as-is, like a boxed-struct binding — the
                // owner keeps it). A scalar element (an int/… array) is passed as-is.
                if self.is_array_expr(object.value) && self.index_elem_refcounted(object.value) {
                    let esid = self.struct_sid_any(e)
                    if esid >= 0 && self.st.is_value(esid) == false && self.st.is_inline_packable(esid) == false {
                        return self.emit_expr(e)   // a boxed (non-inline) struct element → a borrow
                    }
                    return "own_into_slot(&g_em, {self.emit_expr(e)})"
                }
            }
            case _ {
            }
        }
        return self.emit_expr(e)
    }


    // arg_is_owning_temp reports whether a call argument is a FRESH owned heap temporary passed by borrow —
    // the caller must drop it after the call, or it leaks (the checker's drop_mask). M5d: an array literal
    // `[…]` (a binding read is a borrow its owner drops; a moved string is consumed, not a borrowed temp).
    fn arg_is_owning_temp(self, e: ps.Expr) -> bool {
        match e {
            case EArray(elems, lines) {
                return true
            }
            case EStructLit(ty, fields) {
                // a BOXED struct literal passed by borrow is a fresh owned heap temp → caller drops it after
                // the call (a value struct has no heap, so it is NOT an owning temp).
                let sid = ty_struct_sid(ty.value, self.st.names)
                return sid >= 0 && self.st.is_value(sid) == false
            }
            case ECall(callee, args) {
                // a call returning a fresh ARRAY or BOXED STRUCT is a non-refcounted owning temp passed to a
                // BORROW param → the caller drops it after the call (check.c drop_mask). A string/enum-returning
                // call is MOVED into a refcounted param (own_into_slot), not dropped, so it is not masked here.
                return self.is_array_expr(e) || self.boxed_sid_of(e) >= 0
            }
            case _ {
                return false
            }
        }
    }


    // is_fresh_string_temp reports whether `e` is a FRESH string temporary (a literal, a `+` concat, or a
    // string-returning call) — NOT a place-read (a binding/field/element read the owner keeps). Mirrors
    // check.c:2766 is_owning_temp restricted to refcounted string temps (the string case of the drop_mask).
    fn is_fresh_string_temp(self, e: ps.Expr) -> bool {
        match e {
            case EStr(parts) {
                return true
            }
            case EBinary(op, l, r) {
                return self.is_string_expr(e)          // a string `+` concat is a fresh owned temp
            }
            case ECall(callee, args) {
                return self.is_string_expr(e)          // a string-returning call is a fresh owned temp
            }
            case _ {
                return false                           // EIdent/EGet/EIndex string reads are borrows (not temps)
            }
        }
    }


    // param_is_gen_borrow reports whether value-param `pidx` of fn `fi` is an erased generic-T BORROW param.
    fn param_is_gen_borrow(self, fi: int, pidx: int) -> bool {
        if fi < 0 || fi >= self.fn_param_gen_mask.len() {
            return false
        }
        return ((self.fn_param_gen_mask[fi] >> pidx) & 1) != 0
    }


    // emit_call_arg_gen is emit_call_arg with a value-struct BOX for an erased generic-param destination: a
    // value struct passed to a `val: V` generic param (`m.set(k, Rect{…})`) is boxed into the Value slot (a raw
    // em_s would blow the varargs/param ABI), like emit_field_consume does for a generic FIELD. OFI-218.
    fn emit_call_arg_gen(mut self, e: ps.Expr, fi: int, pidx: int) -> string {
        if self.param_is_gen_borrow(fi, pidx) {
            let vsid = self.struct_sid_of(e)
            if vsid >= 0 {
                let bv = self.fresh_var()
                return "(\{ em_s{vsid} v{bv} = {self.emit_expr(e)}; em_box_struct(&g_em, {vsid}, (Value*)&v{bv}, {self.st.field_count(vsid)}); \})"
            }
        }
        return self.emit_call_arg(e)
    }


    // arg_owning_temp_p is the PARAM-AWARE owning-temp test used at a resolved call: a param-independent owning
    // temp (array / boxed-struct literal or call — arg_is_owning_temp), OR a fresh STRING temp passed to an
    // erased generic-T BORROW param (which is not refcounted, so the caller drops it — check.c:3196 drop_mask,
    // OFI-176 F1). A string temp at a CONCRETE string param is moved/adopted (refcounted), NOT dropped.
    fn arg_owning_temp_p(self, fi: int, pidx: int, e: ps.Expr) -> bool {
        if self.arg_is_owning_temp(e) {
            return true
        }
        return self.param_is_gen_borrow(fi, pidx) && self.is_fresh_string_temp(e)
    }


    // emit_call emits a user free-function call `f(args)` → `em_fn_<index>(<args>)`, or a built-in array
    // method (`arr.len()` → em_array_len, `arr.append(x)` → em_array_append) when the callee is `recv.m`.
    // emit_closure_call renders a call THROUGH a closure VALUE (a fn-typed local/param): rt_call_closure(&g_em,
    // <closure>, <argc>, (Value[])\{ args \}, em_invoke). The args are borrows — rt_call_closure retains heap
    // args at runtime (mirrors cgen_c.c's closure_call path + the VM's OP_CALL_CLOSURE).
    fn emit_closure_call(mut self, closure: string, args: [ps.Expr]) -> string {
        var s = "rt_call_closure(&g_em, {closure}, {args.len()}, "
        if args.len() == 0 {
            s = s + "0"
        } else {
            s = s + "(Value[])\{ "
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
            s = s + " \}"
        }
        return s + ", em_invoke)"
    }


    // emit_ffi_call emits a hosted-registry `extern "c"` call as em_ffi(&g_em, idx, rsid, leaves, (Value[]){…}),
    // mirroring src/cgen_c.c emit_ffi_call. COMMON CASE only: scalar/string/Ptr args + a NON-struct return
    // (rsid -1, leaves = argc) — which covers http / proc / net / file / tcp / plain math. Struct args
    // (flattened em_s leaves) and struct returns (cvec2 → em_unbox_struct) are the harder tail, still TODO.
    // The result temp is allocated BEFORE the args (like stage-0) so the fresh-var sequence matches. P6 FFI.
    fn emit_ffi_call(mut self, name: string, args: [ps.Expr]) -> string {
        let idx = cgc_cextern_index(name)
        let rv = self.fresh_var()
        var s = "(\{ Value v{rv} = em_ffi(&g_em, {idx}, -1, {args.len()}, "
        if args.len() == 0 {
            s = s + "0"
        } else {
            s = s + "(Value[])\{ "
            var i = 0
            loop {
                if i >= args.len() {
                    break
                }
                if i > 0 {
                    s = s + ", "
                }
                s = s + self.emit_expr(args[i])   // one borrowed scalar/string/Ptr leaf
                i = i + 1
            }
            s = s + " \}"
        }
        return s + "); v{rv}; \})"
    }


    fn emit_call(mut self, callee: ps.Expr, args: [ps.Expr]) -> string {
        match callee {
            case EIdent(name) {
                let ck = numeric_typename_kind(name)
                if ck >= 0 && args.len() == 1 {
                    return "em_conv({self.emit_expr(args[0])}, {ck})"   // a numeric-width conversion `int(x)`
                }
                // WRAPPING arithmetic intrinsics (OFI-041): wrapping_add/sub/mul(a, b) → em_wrap_<op>(a, b,
                // num_kind) — modulo 2^width, no trap. The args are borrowed scalars; num_kind 0 (i64 subset).
                if args.len() == 2 && (name == "wrapping_add" || name == "wrapping_sub" || name == "wrapping_mul") {
                    let opn = byte_slice(name, 9, name.len())   // drop the "wrapping_" prefix → add / sub / mul
                    return "em_wrap_{opn}({self.emit_expr(args[0])}, {self.emit_expr(args[1])}, 0)"
                }
                if self.lookup_cname(name) != "" {
                    // A call THROUGH a fn-typed local/param (`f(v)` where `f: fn(T)->U`) — a local binding a
                    // callee can only be a closure value, so dispatch via rt_call_closure (cgen_c.c closure_call).
                    return self.emit_closure_call(self.lookup_cname(name), args)
                }
                if self.en.is_case_variant(name) {
                    return self.emit_enum_ctor(name, args)   // an enum-variant construction `Circle(4)` / prelude `Some(5)`
                }
                // panic(msg) in EXPRESSION position (e.g. a `case None { panic(m) }` arm whose value is used):
                // em_panic_val diverges (renders the runtime string + exit 70), so wrap it in a comma expression
                // that yields a placeholder Value — never evaluated, but keeps the emitter a value to hand back.
                if name == "panic" && args.len() == 1 {
                    return "(em_panic_val(&g_em, {self.emit_expr(args[0])}), INT_VAL(0))"
                }
                // Concurrency CHANNEL builtins: channel(n) → a buffered channel; send(ch, v) enqueues (v moved
                // in); recv(ch)/try_recv(ch) → Option<elem> (blocking / non-blocking poll); close(ch). recv wraps
                // the value in Some/None, so it carries the Option enum id + Some(0)/None(1) tags. (cgen_c.c M4.)
                if name == "channel" && args.len() == 1 {
                    return "em_channel_new(&g_em, AS_INT({self.emit_expr(args[0])}))"
                }
                if name == "send" && args.len() == 2 {
                    return "em_channel_send(&g_em, {self.emit_expr(args[0])}, {self.emit_consume_arg(args[1])})"
                }
                if name == "recv" && args.len() == 1 {
                    let eid = self.en.prelude_enum_id("Some")
                    return "em_channel_recv(&g_em, {self.emit_expr(args[0])}, {eid}, 0, 1)"
                }
                if name == "try_recv" && args.len() == 1 {
                    let eid = self.en.prelude_enum_id("Some")
                    return "em_channel_try_recv(&g_em, {self.emit_expr(args[0])}, {eid}, 0, 1)"
                }
                if name == "close" && args.len() == 1 {
                    return "em_channel_close({self.emit_expr(args[0])})"
                }
                // int↔float REINTERPRET intrinsics (the bits, not a numeric cast) + monotonic clock. (cgen_c.c M5.)
                if name == "to_float" && args.len() == 1 {
                    return "em_to_float({self.emit_expr(args[0])})"
                }
                if name == "to_int" && args.len() == 1 {
                    return "em_to_int({self.emit_expr(args[0])})"
                }
                if name == "clock" && args.len() == 0 {
                    return "em_clock()"
                }
                let nid = native_id_for_name(name)
                if is_em_native_id(nid) {
                    // a native runtime builtin (byte_slice, read_file, math, …) → em_native(&g_em, <id>, <argc>,
                    // (Value[]){ args }); its args are read as BORROWS. (print/println keep em_print/em_println.)
                    if args.len() == 0 {
                        return "em_native(&g_em, {nid}, 0, 0)"
                    }
                    var s = "em_native(&g_em, {nid}, {args.len()}, (Value[])\{ "
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
                    return s + " \})"
                }
                // extern "c" REGISTRY FFI call (sin / proc_run / http_post / …) — not a native builtin and not
                // a user fn: dispatch through em_ffi + the in-tree registry (cextern.c), like the VM's CALL_C.
                if self.fn_index(name) < 0 && cgc_cextern_index(name) >= 0 {
                    return self.emit_ffi_call(name, args)
                }
                let fi = self.fn_index(name)
                if fi >= 0 {
                    return self.emit_free_call(fi, args)
                }
            }
            case EGet(object, mname) {
                // A MODULE-QUALIFIED enum-variant CONSTRUCTION `mod.Variant(args)` (`ps.TyName("", "string")`) —
                // the receiver is an import alias (not a binding/struct) and the name is an enum variant. Route
                // it to emit_enum_ctor like the unqualified `Variant(args)` (EIdent) case does — the checker
                // erases the module qualifier, so it lowers to the same em_enum (OFI-202, un-dodged).
                match object.value {
                    case EIdent(recv) {
                        if self.lookup_cname(recv) == "" && self.lookup_struct(recv) < 0 && self.en.is_case_variant(mname) {
                            return self.emit_enum_ctor(mname, args)
                        }
                    }
                    case _ {
                    }
                }
                // A MODULE-QUALIFIED free call `mod.fn(args)` — the receiver is an import alias, not an
                // in-scope binding (no cname, not a struct binding). The self-hosted path has no checker to
                // stamp `resolved_fn`, so we resolve `fn` in the merged declaration-order fn table ourselves
                // (the flattened em_fn_<index> numbering). (cgen_c.c takes the direct-call path off resolved_fn.)
                let mfi = self.qual_free_fi(object.value, mname)
                if mfi >= 0 {
                    return self.emit_free_call(mfi, args)
                }
                // A built-in STRING method (a string receiver — a param / literal / owned local). `.len()`
                // is em_str_len (NO ctx); `.bytes()`/`.chars()` return fresh OWNED arrays (em_str_bytes → [u8],
                // em_str_chars → [string]); `.split(sep)` → [string]. The receiver is a BORROW (read as-is;
                // a temp-receiver drop is a later increment). (cgen_c.c string-method ops.)
                if self.is_string_expr(object.value) {
                    if mname == "len" {
                        return "em_str_len({self.emit_expr(object.value)})"
                    }
                    if mname == "char_count" {
                        return "em_str_char_count({self.emit_expr(object.value)})"   // code-point count (borrow recv)
                    }
                    if mname == "bytes" {
                        return "em_str_bytes(&g_em, {self.emit_expr(object.value)})"
                    }
                    if mname == "chars" {
                        return "em_str_chars(&g_em, {self.emit_expr(object.value)})"
                    }
                    if mname == "split" {
                        let recv = self.emit_expr(object.value)
                        let sep = self.emit_expr(args[0])
                        return "em_str_split(&g_em, {recv}, {sep})"
                    }
                    if mname == "parse_int" {
                        // s.parse_int() → Option<int>; em_str_parse_int carries the Option enum id + Some(0)/
                        // None(1) tags. A fresh string TEMP receiver is measured then dropped; a borrow is read
                        // as-is. (cgen_c.c string_op 4.)
                        let eid = self.en.prelude_enum_id("Some")
                        if self.recv_is_temp(object.value) {
                            let t = self.fresh_var()
                            let rv = self.fresh_var()
                            return "(\{ Value v{t} = {self.emit_expr(object.value)}; Value v{rv} = em_str_parse_int(&g_em, v{t}, {eid}, 0, 1); drop_value(&g_em, v{t}); v{rv}; \})"
                        }
                        return "em_str_parse_int(&g_em, {self.emit_expr(object.value)}, {eid}, 0, 1)"
                    }
                }
                // A built-in array method. `.len()` returns the length scalar; `.append(x)` grows the array.
                if self.is_array_expr(object.value) {
                    if mname == "len" {
                        // A FRESH temporary receiver (an array literal / call result) is measured, then
                        // dropped so it can't leak; a binding/index receiver is a borrow its owner drops.
                        if self.recv_is_temp(object.value) {
                            let t = self.fresh_var()
                            let m = self.fresh_var()
                            let r = self.emit_expr(object.value)
                            return "(\{ Value v{t} = {r}; Value v{m} = em_array_len(v{t}); drop_value(&g_em, v{t}); v{m}; \})"
                        }
                        return "em_array_len({self.emit_expr(object.value)})"
                    }
                    if mname == "append" {
                        let recv = self.emit_expr(object.value)
                        let el = self.emit_consume_arg(args[0])   // the array CONSUMES the element (owned ones moved in); source order (OFI-166)
                        return "em_array_append(&g_em, {recv}, {el})"
                    }
                    if mname == "remove_at" {
                        // arr.remove_at(i) → removes + RETURNS element i (shifting the tail down). Receiver +
                        // index are borrows; the returned element is a fresh owned value.
                        let recv = self.emit_expr(object.value)
                        let ix = self.emit_expr(args[0])
                        return "em_array_remove_at(&g_em, {recv}, {ix})"
                    }
                    if mname == "slice" {
                        // arr.slice(lo, hi) → a fresh OWNED copy of the [lo, hi) range. Receiver + bounds borrows.
                        let recv = self.emit_expr(object.value)
                        let lo = self.emit_expr(args[0])
                        let hi = self.emit_expr(args[1])
                        return "em_array_slice(&g_em, {recv}, {lo}, {hi})"
                    }
                    if mname == "clone" {
                        // arr.clone() → a DEEP copy. An index read of an aggregate element (`m[i]` of a `[[T]]`)
                        // is ALREADY an owned clone (em_index materialises) → emit as-is; a fresh owned temp is
                        // cloned then dropped; a borrow (binding/param/field) is deep-cloned by own_into_slot.
                        // (A value-struct clone is unsupported here, as in stage-0's native backend — OFI-082.)
                        match object.value {
                            case EIndex(a, ix) {
                                return self.emit_expr(object.value)
                            }
                            case _ {
                            }
                        }
                        if self.recv_is_temp(object.value) {
                            let t = self.fresh_var()
                            let rv = self.fresh_var()
                            return "(\{ Value v{t} = {self.emit_expr(object.value)}; Value v{rv} = own_into_slot(&g_em, v{t}); drop_value(&g_em, v{t}); v{rv}; \})"
                        }
                        return "own_into_slot(&g_em, {self.emit_expr(object.value)})"
                    }
                }
                // A struct method call `recv.m(args)` → em_fn_<K>(recv, args…): self is arg 0, the method's
                // fn-index resolves via the `Struct.method` name. A VALUE-struct self is passed by value (an
                // em_s); a BOXED-struct self is passed as its borrowed Value (a heap pointer — mutations via
                // em_set_field reach the caller's object). (cgen_c.c method path.)
                let rsid = self.struct_sid_any(object.value)
                if rsid >= 0 {
                    let fi = self.fn_index("{self.st.names[rsid]}.{mname}")
                    if fi >= 0 {
                        // A NON-IDENT receiver (`self.st.field_index(x)`, `f(x).m()`) is evaluated ONCE into a
                        // C temp, then the call reads it — sequencing the receiver before the args
                        // deterministically (OFI-166) and letting an owning-temp receiver be dropped after. An
                        // IDENT receiver (`self.m()`) is passed inline. (cgen_c.c non-ident-receiver path.)
                        match object.value {
                            case EIdent(rn) {
                            }
                            case _ {
                                let recv_vs = self.struct_sid_of(object.value)   // value-struct receiver → em_s, else Value
                                let ret_vs = self.fn_ret_struct[fi]              // value-struct return → em_s, else Value
                                let tv = self.fresh_var()
                                let rv = self.fresh_var()
                                var h = "(\{ "
                                if recv_vs >= 0 {
                                    h = h + "em_s{recv_vs} v{tv} = "
                                } else {
                                    h = h + "Value v{tv} = "
                                }
                                h = h + self.emit_expr(object.value) + "; "
                                if ret_vs >= 0 {
                                    h = h + "em_s{ret_vs} v{rv} = em_fn_{fi}(v{tv}"
                                } else {
                                    h = h + "Value v{rv} = em_fn_{fi}(v{tv}"
                                }
                                var ai = 0
                                loop {
                                    if ai >= args.len() {
                                        break
                                    }
                                    h = h + ", " + self.emit_call_arg_gen(args[ai], fi, ai)
                                    ai = ai + 1
                                }
                                h = h + "); "
                                if recv_vs < 0 && self.recv_is_temp(object.value) {
                                    h = h + "drop_value(&g_em, v{tv}); "   // an owned boxed temp receiver
                                }
                                return h + "v{rv}; \})"
                            }
                        }
                        // If any argument is a fresh OWNING TEMP passed by borrow (an inline `clone_bools(src)`
                        // array to a borrow param), stage the call: hoist every arg into a `c%d` local, call
                        // with `self` inline, drop the masked temps, yield the result — mirroring emit_free_call
                        // (OFI-165 un-dodged). Otherwise emit the call inline.
                        var mtemp = false
                        var mt = 0
                        loop {
                            if mt >= args.len() {
                                break
                            }
                            if self.arg_is_owning_temp(args[mt]) {
                                mtemp = true
                            }
                            mt = mt + 1
                        }
                        if mtemp {
                            let rid = self.fresh_var()          // result id, taken BEFORE the arg ids (OFI-166)
                            var argids: [int] = []
                            var s = "(\{ "
                            var i = 0
                            loop {
                                if i >= args.len() {
                                    break
                                }
                                let aid = self.fresh_var()
                                argids.append(aid)
                                s = s + "Value c{aid} = {self.emit_call_arg_gen(args[i], fi, i)}; "
                                i = i + 1
                            }
                            s = s + "Value c{rid} = em_fn_{fi}(" + self.emit_expr(object.value)   // self inline
                            var j = 0
                            loop {
                                if j >= argids.len() {
                                    break
                                }
                                s = s + ", c{argids[j]}"
                                j = j + 1
                            }
                            s = s + "); "
                            var k = 0
                            loop {
                                if k >= args.len() {
                                    break
                                }
                                if self.arg_is_owning_temp(args[k]) {
                                    s = s + "drop_value(&g_em, c{argids[k]}); "
                                }
                                k = k + 1
                            }
                            return s + "c{rid}; \})"
                        }
                        var s = "em_fn_{fi}(" + self.emit_expr(object.value)   // self (em_s value / boxed Value)
                        var i = 0
                        loop {
                            if i >= args.len() {
                                break
                            }
                            s = s + ", " + self.emit_call_arg_gen(args[i], fi, i)
                            i = i + 1
                        }
                        return s + ")"
                    }
                }
                // A bounded-method call on a TYPE-PARAM receiver (`key.hash()` — a param typed K; `e.key.eq(k)`
                // — a K-typed field) dispatches through self's witness field (the concrete Hash/Eq impl for this
                // instance's type-arg). Only inside a bounded-struct method (cur_owner has bounded params). OFI-174.
                if self.cur_owner >= 0 {
                    var wtp = ""
                    match object.value {
                        case EIdent(rn) {
                            wtp = self.lookup_tp_tname(rn)
                        }
                        case EGet(wobj, wfname) {
                            let wosid = self.struct_sid_any(wobj.value)
                            if wosid >= 0 {
                                let cand = self.st.field_tpname_of(wosid, wfname)
                                if cand != "" && self.st.struct_bound_of(self.cur_owner, cand) != "" {
                                    wtp = cand
                                }
                            }
                        }
                        case _ {
                        }
                    }
                    if wtp != "" && self.bound_for_method(self.cur_owner, wtp, mname) != "" {
                        return self.emit_witness_call(object.value, wtp, mname, args)
                    }
                }
                // UFCS (Phase 3): a NON-STRUCT value receiver (an enum like Option, …) whose method
                // name is a free function → emit the free call `mname(object, args)` with the receiver
                // prepended as arg 0 (mirrors src/check.c's AST rewrite → byte-identical to stage-0).
                let ufi = self.fn_index(mname)
                if ufi >= 0 {
                    var uargs: [ps.Expr] = []
                    uargs.append(object.value)
                    var ua = 0
                    loop {
                        if ua >= args.len() {
                            break
                        }
                        uargs.append(args[ua])
                        ua = ua + 1
                    }
                    return self.emit_free_call(ufi, uargs)
                }
            }
            case _ {
            }
        }
        var desc = "?"
        match callee {
            case EIdent(n) {
                desc = "{n}(…)"
            }
            case EGet(o, m) {
                desc = ".{m}(…)"
            }
            case _ {
            }
        }
        return cgc_internal_error("unsupported call form — unresolved callee {desc} (OFI-173)")
    }


    // emit_free_call emits a direct FREE-function call `em_fn_<fi>(args…)`. If any argument is an owning
    // temporary (an array literal), hoist EVERY argument into a `c%d` local (left-to-right), call, drop the
    // masked temps, then yield the result — a statement-expression so it stays usable in expression position
    // (cgen_c.c:emit_call). Shared by the bare-name and the module-qualified `mod.fn` call paths.
    fn emit_free_call(mut self, fi: int, args: [ps.Expr]) -> string {
        self.record_hof_lambdas(fi, args)               // capture any lambda arg's param typing before it lifts
        var any_temp = false
        var ti = 0
        loop {
            if ti >= args.len() {
                break
            }
            if self.arg_owning_temp_p(fi, ti, args[ti]) {
                any_temp = true
            }
            ti = ti + 1
        }
        if any_temp {
            let rid = self.fresh_var()                  // result id, taken BEFORE the arg ids
            var argids: [int] = []
            var s = "(\{ "
            var i = 0
            loop {
                if i >= args.len() {
                    break
                }
                let aid = self.fresh_var()
                argids.append(aid)
                s = s + "Value c{aid} = {self.emit_call_arg_gen(args[i], fi, i)}; "
                i = i + 1
            }
            s = s + "Value c{rid} = em_fn_{fi}("
            var j = 0
            loop {
                if j >= argids.len() {
                    break
                }
                if j > 0 {
                    s = s + ", "
                }
                s = s + "c{argids[j]}"
                j = j + 1
            }
            s = s + "); "
            var k = 0
            loop {
                if k >= args.len() {
                    break
                }
                if self.arg_owning_temp_p(fi, k, args[k]) {
                    s = s + "drop_value(&g_em, c{argids[k]}); "
                }
                k = k + 1
            }
            return s + "c{rid}; \})"
        }
        var s = "em_fn_{fi}("
        var i = 0
        loop {
            if i >= args.len() {
                break
            }
            if i > 0 {
                s = s + ", "
            }
            s = s + self.emit_call_arg_gen(args[i], fi, i)
            i = i + 1
        }
        return s + ")"
    }


    // qual_free_fi resolves a MODULE-QUALIFIED free call `mod.fn` to its merged fn-table index, or -1. The
    // receiver `obj` is a module import alias iff it is a bare EIdent that is NOT an in-scope binding (no
    // cname) and NOT a struct binding — the only non-binding EIdent receiver. Used by emit_call and the
    // is_string/array/enum return-type predicates so `lx.kind_name(op)` resolves like a bare free call.
    fn qual_free_fi(self, obj: ps.Expr, mname: string) -> int {
        match obj {
            case EIdent(recv) {
                if self.lookup_cname(recv) == "" && self.lookup_struct(recv) < 0 {
                    return self.fn_index(mname)
                }
            }
            case _ {
            }
        }
        return 0 - 1
    }


    // record_hof_lambdas discovers, at a HOF call site, the param typing of each lambda argument and stashes
    // it in lam_recs keyed by the lambda's lifted em_fn slot (predicted from cur_lambda plus any lambdas in
    // the args emitted before it). The global lifted-body pass has no call context, so THIS is where a lambda
    // param's string/scalar nature is fixed — from the input array's element (map/filter/sort) or the init
    // value (reduce). Fires only for a call whose callee is a HOF (fn_hof_srcs non-empty). OFI-206 follow-on.
    fn record_hof_lambdas(mut self, fi: int, args: [ps.Expr]) {
        let base = fi * 6                            // fn_hof_srcs is a FLAT stride-6 table; scalar-index throughout
        if fi < 0 || base + 5 >= self.fn_hof_srcs.len() {
            return
        }
        let lam_arg = self.fn_hof_srcs[base + 0]
        let np = self.fn_hof_srcs[base + 1]
        if lam_arg < 0 || lam_arg >= args.len() {
            return
        }
        match args[lam_arg] {
            case ELambda(lparams, body) {
                var slot = self.cur_lambda                   // the em_closure counter at this call
                var a = 0
                loop {
                    if a >= lam_arg {
                        break
                    }
                    slot = slot + count_lambdas_expr(args[a])   // earlier lambda-bearing args take slots first
                    a = a + 1
                }
                self.lam_recs.append(slot)
                self.lam_recs.append(lparams.len())
                var pi = 0
                loop {
                    if pi >= lparams.len() {
                        break
                    }
                    var is_str = 0
                    var kind = 0 - 1
                    if pi < np {
                        let src_arg = self.fn_hof_srcs[base + 2 + pi * 2]
                        let is_elem = self.fn_hof_srcs[base + 3 + pi * 2]
                        if src_arg >= 0 && src_arg < args.len() {
                            if is_elem == 1 {
                                if self.arg_elem_aek_boxed(args[src_arg]) == 0 {   // the `[T]` input's element
                                    is_str = 1
                                }
                                kind = self.value_elem_kind(args[src_arg])
                            } else {
                                if self.is_string_expr(args[src_arg]) {            // the whole `U` init value
                                    is_str = 1
                                }
                                kind = self.scalar_kind_of(args[src_arg])
                            }
                        }
                    }
                    self.lam_recs.append(is_str)
                    self.lam_recs.append(kind)
                    pi = pi + 1
                }
            }
            case _ {
            }
        }
    }


    // recv_is_temp reports whether a method receiver is a FRESH owned temporary (an array literal or a call
    // result) — which the caller must drop after a borrowing method — rather than a borrow (a binding /
    // index read the owner drops). Mirrors cgen_c.c:recv_is_borrow (negated).
    fn recv_is_temp(self, e: ps.Expr) -> bool {
        match e {
            case EArray(elems, lines) {
                return true
            }
            case ECall(callee, args) {
                return true
            }
            case _ {
                return false
            }
        }
    }


    // scalar_kind_of statically classifies an expression's numeric width-kind (0 i64 … for the M5a int
    // subset), or -1 if it is not a known scalar (a string/struct/Value). Drives the `let` storage choice.
    // gret_scalar_kind resolves the scalar kind of a generic fn `fi`'s bare-`T` return from its determining
    // value arg (reduce's U from init), or falls back to fn_ret_kind (-1 for a type-param) — OFI-206 follow-on.
    // map_ret_kind returns a map-style call's return-ELEMENT scalar kind (`map(words, |w| w.len())` -> 0,
    // int), or -1 (a boxed/string element, or not a map call). map_ret_is_str is the string companion. Both
    // TYPE the lambda arg's return expr with its param typed from the input array's element — the genuine
    // lambda-body inference (OFI-206 follow-on). The two share map_lam_ret which does the push/type/restore.
    fn map_lam_ret(mut self, value: ps.Expr, want_str: bool) -> int {
        match value {
            case ECall(callee, args) {
                var fi = 0 - 1
                match callee.value {
                    case EIdent(name) {
                        fi = self.fn_index(name)
                    }
                    case EGet(obj, mname) {
                        fi = self.qual_free_fi(obj.value, mname)
                    }
                    case _ {
                    }
                }
                if fi >= 0 && fi < self.fn_ret_lam_arg.len() {
                    let la = self.fn_ret_lam_arg[fi]
                    let inarg = self.fn_ret_lam_in[fi]
                    if la >= 0 && la < args.len() {
                        match args[la] {
                            case ELambda(lparams, body) {
                                var in_is_str = false
                                var in_kind = 0 - 1
                                if inarg >= 0 && inarg < args.len() {
                                    in_is_str = self.arg_elem_aek_boxed(args[inarg]) == 0   // handles an EIdent array (words)
                                    in_kind = self.value_elem_kind(args[inarg])
                                }
                                let mark = self.sc_name.len()
                                var pi = 0
                                loop {
                                    if pi >= lparams.len() {
                                        break
                                    }
                                    if in_is_str {
                                        self.push(lparams[pi].name, "_lp{pi}", 0 - 1, false, true, false, 0 - 1)   // an owned STRING param
                                    } else {
                                        self.push(lparams[pi].name, "_lp{pi}", in_kind, false, false, false, 0 - 1) // a scalar param
                                    }
                                    pi = pi + 1
                                }
                                var res = 0 - 1
                                var i = 0
                                loop {
                                    if i >= body.len() {
                                        break
                                    }
                                    match body[i] {
                                        case SReturn(rv, line) {
                                            if rv.len() > 0 {
                                                if want_str {
                                                    if self.is_string_expr(rv[0].value) {
                                                        res = 1
                                                    } else {
                                                        res = 0
                                                    }
                                                } else {
                                                    res = self.scalar_kind_of(rv[0].value)
                                                }
                                            }
                                        }
                                        case _ {
                                        }
                                    }
                                    i = i + 1
                                }
                                self.truncate_scope(mark)
                                return res
                            }
                            case _ {
                            }
                        }
                    }
                }
            }
            case _ {
            }
        }
        return 0 - 1
    }


    // gret_is_string resolves whether a generic fn `fi`'s bare-`T` return is a STRING at this call site,
    // from its determining arg (gtwice's T from x="hi") — OFI-206 follow-on.
    fn gret_is_string(self, fi: int, args: [ps.Expr]) -> bool {
        if fi >= self.fn_ret_det_arg.len() || self.fn_ret_array[fi] {
            return false
        }
        let da = self.fn_ret_det_arg[fi]
        if da < 0 || da >= args.len() {
            return false
        }
        if self.fn_ret_det_elem[fi] {
            return self.arg_elem_aek_boxed(args[da]) == 0   // the `[T]` arg's element is a string
        }
        return self.is_string_expr(args[da])                // the whole arg is a string
    }


    fn gret_scalar_kind(self, fi: int, args: [ps.Expr]) -> int {
        let base = self.fn_ret_kind[fi]
        if base >= 0 {
            return base
        }
        if fi >= self.fn_ret_det_arg.len() || self.fn_ret_array[fi] {
            return base                                 // not a bare-T return (an array/concrete return)
        }
        let da = self.fn_ret_det_arg[fi]
        if da < 0 || da >= args.len() {
            return base
        }
        if self.fn_ret_det_elem[fi] {
            return self.value_elem_kind(args[da])       // T = the `[T]` arg's element scalar kind
        }
        return self.scalar_kind_of(args[da])            // T = the whole arg's scalar kind
    }


    fn scalar_kind_of(self, e: ps.Expr) -> int {
        match e {
            case EInt(v, kind) {
                return kind
            }
            case EBinary(op, l, r) {
                let bid = ps.binop_id(op)
                // `+` is STRING concat (not a scalar) when either operand is a string, else int addition.
                if bid == 1 {
                    if self.is_string_expr(l.value) || self.is_string_expr(r.value) {
                        return 0 - 1
                    }
                    return 0
                }
                // other arithmetic / bitwise / shift produce a numeric value; compares/logic produce a bool
                if bid >= 2 && bid <= 5 {
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
                        let ck = numeric_typename_kind(name)
                        if ck >= 0 {
                            return ck                     // a numeric conversion `let a = i32(n)` → a sized scalar
                        }
                        let fi = self.fn_index(name)
                        if fi >= 0 {
                            return self.gret_scalar_kind(fi, args)
                        }
                        let ei = self.extern_index(name)
                        if ei >= 0 {
                            return self.extern_ret_kind[ei]   // `let s = sin(x)` → the extern's declared scalar kind
                        }
                    }
                    case EGet(object, mname) {
                        // `arr.len()` / `s.len()` returns an int scalar (kind 0 = i64).
                        if mname == "len" {
                            if self.is_array_expr(object.value) || self.is_string_expr(object.value) {
                                return 0
                            }
                        }
                        // a struct method call `p.method()` returning a scalar (`let n = p.norm1()` / a boxed
                        // `let a = lx.advance()`).
                        let rsid = self.struct_sid_any(object.value)
                        if rsid >= 0 {
                            let fi = self.fn_index("{self.st.names[rsid]}.{mname}")
                            if fi >= 0 {
                                return self.fn_ret_kind[fi]
                            }
                        }
                        let qfi = self.qual_free_fi(object.value, mname)   // a module-qualified scalar-returning call `ps.binop_class(op)`
                        if qfi >= 0 {
                            return self.gret_scalar_kind(qfi, args)
                        }
                    }
                    case _ {
                    }
                }
                return 0 - 1
            }
            case EIndex(object, index) {
                // `arr[i]` of a scalar-element array is that element's scalar kind (a boxed element → -1).
                return self.index_elem_kind(object.value)
            }
            case EGet(object, name) {
                // `let x = s.field` of a SCALAR struct field types as that field's C scalar (a boxed / array /
                // struct field → -1, a Value binding); a struct-array field's `.len()` is handled via ECall.
                let sid = self.struct_sid_any(object.value)
                if sid >= 0 {
                    return self.st.field_scalar_kind(sid, name)
                }
                return 0 - 1
            }
            case EIdent(name) {
                if self.lookup_cname(name) == "" && self.consts.lookup_idx(name) >= 0 {
                    return 0                     // a folded module-level int constant (TY_UNIT = 6) → i64
                }
                return self.lookup_kind(name)
            }
            case _ {
                return 0 - 1
            }
        }
    }


    // value_elem_kind infers the ELEMENT scalar kind of an UN-annotated array initialiser: a literal from
    // its first element (a float → f64=9, a string/array element → boxed -1, otherwise i64=0), an
    // array-returning call from its return element kind, an array binding alias from the source's kind.
    // value_elem_struct resolves the ELEMENT struct sid of an array-valued initialiser that is a CALL
    // returning `[Struct]` (a free fn / struct method / module-qualified call), or -1. Lets `let xs = f()`
    // track `xs[i]` as a boxed struct (a borrow), matching the `[T]`-annotated path.
    // array_elem_struct_of returns the ELEMENT struct sid of an array EXPRESSION: a binding/param array
    // (lookup_elem_struct), a struct field array (field_elem_struct), or an array-returning call
    // (value_elem_struct). -1 for a scalar/string-element or non-array. So `xs.clone()[i]` / `for x in xs`
    // resolve x's fields.
    fn array_elem_struct_of(self, e: ps.Expr) -> int {
        match e {
            case EIdent(aname) {
                return self.lookup_elem_struct(aname)
            }
            case EGet(gobj, gname) {
                let osid = self.struct_sid_any(gobj.value)
                if osid >= 0 {
                    return self.st.field_elem_struct(osid, gname)
                }
                return 0 - 1
            }
            case ECall(callee, args) {
                return self.value_elem_struct(e)
            }
            case _ {
            }
        }
        return 0 - 1
    }


    fn value_elem_struct(self, value: ps.Expr) -> int {
        match value {
            case ECall(callee, args) {
                match callee.value {
                    case EIdent(name) {
                        let fi = self.fn_index(name)
                        if fi >= 0 {
                            return self.fn_ret_elem_struct[fi]
                        }
                    }
                    case EGet(object, mname) {
                        // arr.clone() / arr.slice() → the SAME element struct as the receiver array.
                        if (mname == "clone" || mname == "slice") && self.is_array_expr(object.value) {
                            return self.array_elem_struct_of(object.value)
                        }
                        let sid = self.struct_sid_any(object.value)
                        if sid >= 0 {
                            let fi = self.fn_index("{self.st.names[sid]}.{mname}")
                            if fi >= 0 {
                                return self.fn_ret_elem_struct[fi]
                            }
                        }
                        let qfi = self.qual_free_fi(object.value, mname)
                        if qfi >= 0 {
                            return self.fn_ret_elem_struct[qfi]
                        }
                    }
                    case _ {
                    }
                }
            }
            case _ {
            }
        }
        return 0 - 1
    }


    // value_elem_is_array reports whether an inferred array VALUE's element is itself an ARRAY (`[[T]]` — its
    // first element is an array), so `grid[i].len()` is em_array_len not em_str_len (OFI-219).
    fn value_elem_is_array(self, value: ps.Expr) -> bool {
        match value {
            case EArray(elems, lines) {
                if elems.len() > 0 {
                    return self.is_array_expr(elems[0])
                }
            }
            case _ {
            }
        }
        return false
    }


    // value_elem_aek_boxed returns 0 when an array VALUE's element is BOXED refcounted (a string/enum/struct/
    // nested-array element — so `xs[i]` is a heap value, e.g. a string `.len()` receiver), else -1. Used to set
    // an inferred array binding's element AEK (annotated arrays get it from the `[T]` type). OFI-206 follow-on.
    fn value_elem_aek_boxed(self, value: ps.Expr) -> int {
        match value {
            case EArray(elems, lines) {
                if elems.len() > 0 {
                    if self.is_string_expr(elems[0]) || self.is_array_expr(elems[0]) || self.struct_sid_of(elems[0]) >= 0 || self.is_enum_expr(elems[0]) {
                        return 0
                    }
                }
            }
            case ECall(callee, args) {
                // a `[T]`-returning generic call (`sort(words)`): its element AEK = the determining `[T]` arg's
                // element AEK (words's), resolved through the gret return table (OFI-206 follow-on).
                var fi = 0 - 1
                match callee.value {
                    case EIdent(name) {
                        fi = self.fn_index(name)
                    }
                    case EGet(obj, mname) {
                        // a built-in string method returning a `[string]` array (`s.split(sep)` / `s.chars()`)
                        // → STRING elements (aek 0), so a `parts[i].len()` resolves as a string method.
                        if self.is_string_expr(obj.value) && (mname == "split" || mname == "chars") {
                            return 0
                        }
                        fi = self.qual_free_fi(obj.value, mname)
                    }
                    case _ {
                    }
                }
                if fi >= 0 && fi < self.fn_ret_det_arg.len() && self.fn_ret_array[fi] {
                    let da = self.fn_ret_det_arg[fi]
                    if da >= 0 && da < args.len() && self.fn_ret_det_elem[fi] {
                        return self.arg_elem_aek_boxed(args[da])
                    }
                }
            }
            case _ {
            }
        }
        return 0 - 1
    }


    // arg_elem_aek_boxed returns 0 when an array-typed arg's element is boxed refcounted (a [string] local /
    // literal), else -1 — used to propagate a `[T]`-returning call's element AEK from its determining arg.
    fn arg_elem_aek_boxed(self, e: ps.Expr) -> int {
        match e {
            case EIdent(name) {
                if self.lookup_array(name) && self.lookup_elem_aek(name) == 0 {
                    return 0
                }
            }
            case EArray(elems, lines) {
                return self.value_elem_aek_boxed(e)
            }
            case _ {
            }
        }
        return 0 - 1
    }


    fn value_elem_kind(self, value: ps.Expr) -> int {
        match value {
            case EArray(elems, lines) {
                if elems.len() == 0 {
                    return 0 - 1
                }
                if self.is_string_expr(elems[0]) || self.is_array_expr(elems[0]) {
                    return 0 - 1
                }
                match elems[0] {
                    case EFloat(v) {
                        return 9
                    }
                    case _ {
                        return 0
                    }
                }
            }
            case ECall(callee, args) {
                var fi = 0 - 1
                match callee.value {
                    case EIdent(name) {
                        fi = self.fn_index(name)
                    }
                    case EGet(object, mname) {
                        if self.is_string_expr(object.value) && mname == "bytes" {
                            return 4                      // `s.bytes()` → [u8]; u8 is element scalar kind 4
                        }
                        let sid = self.struct_sid_any(object.value)   // an array-returning struct METHOD `self.ty_arg_types()`
                        if sid >= 0 {
                            fi = self.fn_index("{self.st.names[sid]}.{mname}")
                        } else {
                            fi = self.qual_free_fi(object.value, mname)   // a module-qualified array-returning call
                        }
                    }
                    case _ {
                    }
                }
                if fi >= 0 {
                    let k = self.fn_ret_elem_kind[fi]
                    if k >= 0 {
                        return k
                    }
                    // a `[T]`-returning generic call (`sort(xs)`): its element scalar kind = the determining
                    // `[T]` arg's element kind (xs's), resolved through the gret return table — so `asc[i]`
                    // types as a scalar and is NOT own_into_slot'd in a consuming op (OFI-176, F3).
                    if fi < self.fn_ret_det_arg.len() && self.fn_ret_array[fi] {
                        let da = self.fn_ret_det_arg[fi]
                        if da >= 0 && da < args.len() && self.fn_ret_det_elem[fi] {
                            return self.value_elem_kind(args[da])
                        }
                    }
                }
                return 0 - 1
            }
            case EIdent(name) {
                return self.lookup_elem_kind(name)
            }
            case _ {
                return 0 - 1
            }
        }
    }


    // index_elem_kind returns the scalar width-kind of an indexed array's ELEMENT (or -1 for a non-scalar /
    // unknown element): an array BINDING carries its element kind, an array-returning CALL its return kind.
    fn index_elem_kind(self, object: ps.Expr) -> int {
        match object {
            case EIdent(name) {
                return self.lookup_elem_kind(name)
            }
            case ECall(callee, args) {
                match callee.value {
                    case EIdent(name) {
                        let fi = self.fn_index(name)
                        if fi >= 0 {
                            return self.fn_ret_elem_kind[fi]
                        }
                    }
                    case _ {
                    }
                }
                return 0 - 1
            }
            case EGet(gobj, gname) {
                // a struct FIELD array `s.nums[i]` → the field's element scalar kind (so a scalar element is
                // not mistaken for a refcounted one that would be own_into_slot'd).
                let sid = self.struct_sid_any(gobj.value)
                if sid >= 0 {
                    return self.st.field_elem(sid, gname)
                }
                return 0 - 1
            }
            case EIndex(iobj, iidx) {
                // `grid[i]` of a `[[T]]` binding → the INNER element scalar kind (T's), so `grid[i][j]` reads
                // plain (a scalar) and isn't own_into_slot'd as a refcounted element (OFI-219).
                match iobj.value {
                    case EIdent(aname) {
                        return self.lookup_elem_elem_kind(aname)
                    }
                    case _ {
                    }
                }
                return 0 - 1
            }
            case _ {
                return 0 - 1
            }
        }
    }


    // index_elem_refcounted reports whether an indexed array's ELEMENT is a REFCOUNTED single Value (a string
    // or enum — a boxed AEK-0 element, NOT a struct). Drives the own_into_slot decision when the element is
    // consumed/returned. Unlike index_elem_kind, a BOOL element (AEK 11, scalar) is correctly NOT refcounted —
    // ty_scalar_kind maps bool to -1, which index_elem_kind can't distinguish from a boxed element. For a
    // struct-FIELD array the element AEK is known exactly (field_elem_aek); for a binding/call array we fall
    // back to "non-scalar element that is not a struct" (the corpus has no consumed [bool] binding array).
    fn index_elem_refcounted(self, object: ps.Expr) -> bool {
        match object {
            case EGet(gobj, gname) {
                let sid = self.struct_sid_any(gobj.value)
                if sid >= 0 {
                    return self.st.field_elem_aek(sid, gname) == 0 && self.st.field_elem_struct(sid, gname) < 0
                }
            }
            case EIdent(name) {
                let aek = self.lookup_elem_aek(name)   // a binding/param array with a KNOWN element AEK (a [bool] = 11 is scalar)
                if aek >= 0 {
                    // ...but a `[[T]]` element (a nested array, boxed AEK-0) is a unique-owner ARRAY the outer
                    // array owns — a BORROW, not a refcounted single Value, so it is NOT own_into_slot'd (OFI-219).
                    return aek == 0 && self.lookup_elem_is_array(name) == false
                }
            }
            case _ {
            }
        }
        return self.index_elem_kind(object) < 0
    }


    // emit_stmt prints the C for one statement (4-space indented inside a function body).
    fn lookup_drop(self, name: string) -> bool {
        var i = self.sc_name.len() - 1
        loop {
            if i < 0 {
                break
            }
            if self.sc_name[i] == name {
                return self.sc_drop[i]
            }
            i = i - 1
        }
        return false
    }


    // is_string_expr reports whether an expression produces a STRING (an owned heap value, dropped at
    // scope exit). M5b: a string literal, an owned string binding, and a string concatenation.
    fn is_string_expr(self, e: ps.Expr) -> bool {
        match e {
            case EStr(parts) {
                return true
            }
            case EIdent(name) {
                // an owned string LOCAL, or a refcounted (string/enum) PAYLOAD binding (`case EIdent(name)` —
                // treated as a string for a receiver method like `.len()`; an enum payload never calls one). A
                // boxed STRUCT binding is owned/drop too but is NOT a string (lookup_struct >= 0) — excluding it
                // lets `b.get().len()` (a method-array-return receiver) resolve as an array, not a string.
                return (self.lookup_drop(name) || self.lookup_refc(name)) && self.lookup_array(name) == false && self.lookup_struct(name) < 0
            }
            case EGet(object, name) {
                // a refcounted (string / enum) struct FIELD read `self.src` — treated as a string for a
                // receiver method (`self.src.len()` → em_str_len). An enum field would over-match, but the
                // corpus only calls string methods on string fields (a benign over-approximation).
                let sid = self.struct_sid_any(object.value)
                return sid >= 0 && self.st.field_is_refcounted(sid, name)
            }
            case EIndex(object, index) {
                // `xs[i]` of a [string]-like array (element AEK 0 = boxed refcounted, not a struct element) —
                // treated as a string receiver so `xs[0].len()` → em_str_len. The same benign over-
                // approximation as the EGet/EIdent arms (the corpus only calls string methods on strings).
                match object.value {
                    case EIdent(aname) {
                        // ...but NOT a `[[T]]` element (a nested array is boxed AEK-0 too) — that is an ARRAY
                        // receiver (`grid[i].len()` → em_array_len), handled by is_array_expr instead (OFI-219).
                        return self.lookup_array(aname) && self.lookup_elem_aek(aname) == 0 && self.lookup_elem_struct(aname) < 0 && self.lookup_elem_is_array(aname) == false
                    }
                    case EGet(gobj, gname) {
                        // `self.parts[0]` — an element of a struct's string-array FIELD (a boxed AEK-0, non-struct
                        // element) is a string receiver, so `self.parts[0].len()`/`.split()` resolve directly —
                        // no bind-to-local needed (OFI-173 indexed-field-element method call, un-dodged).
                        let sid = self.struct_sid_any(gobj.value)
                        return sid >= 0 && self.st.field_elem_aek(sid, gname) == 0 && self.st.field_elem_struct(sid, gname) < 0
                    }
                    case _ {
                    }
                }
                return false
            }
            case EBinary(op, l, r) {
                if ps.binop_id(op) == 1 {
                    return self.is_string_expr(l.value) || self.is_string_expr(r.value)
                }
                return false
            }
            case ECall(callee, args) {
                match callee.value {
                    case EIdent(name) {
                        let fi = self.fn_index(name)
                        if fi >= 0 {
                            return self.fn_ret_str[fi] || self.gret_is_string(fi, args)
                        }
                        if native_ret_kind(name) == 0 - 3 {
                            return true                  // a string-returning native builtin (byte_slice, read_file, …)
                        }
                        let ei = self.extern_index(name)
                        if ei >= 0 {
                            return self.extern_ret_str[ei]   // a string-returning extern (proc_stdout / http_get / …)
                        }
                    }
                    case EGet(object, mname) {
                        // a string-returning METHOD call `let v = recv.method(…)`.
                        let sid = self.struct_sid_any(object.value)
                        if sid >= 0 {
                            let fi = self.fn_index("{self.st.names[sid]}.{mname}")
                            if fi >= 0 {
                                return self.fn_ret_str[fi]
                            }
                        }
                        let qfi = self.qual_free_fi(object.value, mname)   // a module-qualified free call `lx.kind_name(op)`
                        if qfi >= 0 {
                            return self.fn_ret_str[qfi] || self.gret_is_string(qfi, args)
                        }
                    }
                    case _ {
                    }
                }
                return false
            }
            case _ {
                return false
            }
        }
    }


    // is_array_expr reports whether an expression produces an ARRAY value: a literal, an array binding, or
    // a call to an array-returning function (`let xs = make()` — an owned array local, dropped at exit).
    fn is_array_expr(self, e: ps.Expr) -> bool {
        match e {
            case EArray(elems, lines) {
                return true
            }
            case EIdent(name) {
                return self.lookup_array(name)
            }
            case EGet(object, name) {
                // a struct's ARRAY field `s.toks` (so `s.toks.len()` / `s.toks[i]` resolve)
                let sid = self.struct_sid_any(object.value)
                return sid >= 0 && self.st.field_is_array(sid, name)
            }
            case EIndex(object, index) {
                // `grid[i]` of a `[[T]]` binding is itself an ARRAY (so `grid[i].len()` → em_array_len,
                // `grid[i][j]` resolves) — OFI-219.
                match object.value {
                    case EIdent(aname) {
                        return self.lookup_array(aname) && self.lookup_elem_is_array(aname)
                    }
                    case EGet(gobj, gname) {
                        // `self.dk_tabs[i]` of a `[[T]]` FIELD is itself an array — the field's element type is
                        // an array (`[[string]]`'s element is `[string]`).
                        let sid = self.struct_sid_any(gobj.value)
                        if sid >= 0 {
                            return is_array_ty(elem_ty_of(self.st.field_ty(sid, gname)))
                        }
                    }
                    case _ {
                    }
                }
                return false
            }
            case ECall(callee, args) {
                match callee.value {
                    case EIdent(name) {
                        let fi = self.fn_index(name)
                        if fi >= 0 {
                            return self.fn_ret_array[fi]
                        }
                        if native_ret_kind(name) == 0 - 2 {
                            return true                  // an array-returning native builtin (args)
                        }
                    }
                    case EGet(object, mname) {
                        // a string→array method `s.bytes()` / `s.chars()` / `s.split(sep)` (an owned array).
                        if self.is_string_expr(object.value) {
                            return mname == "bytes" || mname == "chars" || mname == "split"
                        }
                        // an array→array method: `arr.slice(lo, hi)` / `arr.clone()` return arrays.
                        if self.is_array_expr(object.value) {
                            return mname == "slice" || mname == "clone"
                        }
                        let sid = self.struct_sid_any(object.value)   // an array-returning struct METHOD `self.parse_params()`
                        if sid >= 0 {
                            let fi = self.fn_index("{self.st.names[sid]}.{mname}")
                            if fi >= 0 {
                                return self.fn_ret_array[fi]
                            }
                        }
                        let qfi = self.qual_free_fi(object.value, mname)   // a module-qualified array-returning call `lx.lex(src)`
                        if qfi >= 0 {
                            return self.fn_ret_array[qfi]
                        }
                    }
                    case _ {
                    }
                }
                return false
            }
            case _ {
                return false
            }
        }
    }


    // elem_kind_of_expr infers a non-empty array literal's ArrayElemKind (value.h AEK_*) from its first
    // element's form — mirroring codegen.ig's elem_kind_of so both backends agree with stage-0's checker:
    // a string/array (boxed) element → 0, a float → f64=10, a bool → 11, otherwise i64=4 (int / arithmetic).
    fn elem_kind_of_expr(self, e: ps.Expr) -> int {
        if self.is_string_expr(e) || self.is_array_expr(e) || self.is_enum_expr(e) || self.boxed_sid_of(e) >= 0 {
            return 0                          // string / array / enum / boxed-struct element → boxed
        }
        match e {
            case EStr(parts) {
                return 0
            }
            case EStructLit(ty, fields) {
                return 0                      // a struct element is boxed (a Value pointer / packed record)
            }
            case EIdent(name) {
                if self.lookup_refc(name) {
                    return 0                  // a refcounted (string / enum) PAYLOAD binding element → boxed
                }
                return 4
            }
            case EFloat(v) {
                return 10
            }
            case EBool(b) {
                return 11
            }
            case _ {
                return 4
            }
        }
    }


    // emit_block_raw emits a statement list WITHOUT managing scope (the caller — e.g. a for-loop that
    // pushed its loop variable before the body — handles the drops/truncate itself).
    fn emit_block_raw(mut self, body: [ps.Stmt]) {
        var i = 0
        loop {
            if i >= body.len() {
                break
            }
            self.emit_stmt(body[i])
            i = i + 1
        }
    }


    // emit_block_stmts emits a scoped block (an if/loop/bare-block body): its owned locals are dropped at
    // the block's normal exit and leave scope (cgen_c.c:emit_block_scoped).
    fn emit_block_stmts(mut self, body: [ps.Stmt]) {
        let mark = self.sc_name.len()
        var i = 0
        loop {
            if i >= body.len() {
                break
            }
            self.emit_stmt(body[i])
            i = i + 1
        }
        self.emit_drops(mark)
        self.truncate_scope(mark)
    }


    // emit_if renders `if (em_truthy(<cond>)) { … }` with an optional `else { … }` / `else if …` chain.
    // `leading` is the prefix before `if` — the indent for a top-level if, "" when chained after `} else `.
    fn emit_if(mut self, cond: ps.Expr, then_blk: [ps.Stmt], els: [ps.Stmt], leading: string) {
        let c = self.emit_expr(cond)
        println("{leading}if (em_truthy({c})) \{")
        self.indent = self.indent + 1
        self.emit_block_stmts(then_blk)
        self.indent = self.indent - 1
        if els.len() > 0 {
            match els[0] {
                case SBlock(body) {
                    println("{self.ind()}\} else \{")
                    self.indent = self.indent + 1
                    self.emit_block_stmts(body)
                    self.indent = self.indent - 1
                    println("{self.ind()}\}")
                }
                case SIf(econd, ethen, eels) {
                    print("{self.ind()}\} else ")
                    self.emit_if(econd.value, ethen, eels, "")
                }
                case _ {
                    println("{self.ind()}\}")
                }
            }
        } else {
            println("{self.ind()}\}")
        }
    }


    // emit_return_value renders a NON-drop-scope return value (no owned locals to survive). It mirrors
    // emit_expr_raw's moves_local==2: a REFCOUNTED value READ from an existing owner (a boxed field, an array
    // element, an owning-temp field read) is owned INTO the return slot via own_into_slot; a fresh temp
    // (a call/ctor/concat), a scalar, or a literal is returned as-is. (The drop-scope path retains instead,
    // via emit_concat_operand, so the value survives the local drops — cgen_c.c STMT_RETURN.)
    fn emit_return_value(mut self, e: ps.Expr) -> string {
        if self.ret_owns(e) {
            return "own_into_slot(&g_em, {self.emit_expr(e)})"
        }
        return self.emit_expr(e)
    }


    // emit_assign_value renders the RHS stored into an OWNED `var` (`s = other`). It mirrors emit_expr with
    // moves_local==2: an owned BINDING or a refcounted FIELD / ELEMENT / owning-temp read is owned INTO the
    // slot (own_into_slot — retain a string/enum, clone an array); a fresh temp (call/ctor/concat) or a
    // scalar is stored as-is. (We conservatively own_into_slot an owned binding rather than nil-slot-move it,
    // since without liveness we cannot prove a last use — safe: never leaks, never double-frees.)
    fn emit_assign_value(mut self, e: ps.Expr) -> string {
        match e {
            case EIdent(name) {
                if self.lookup_drop(name) {
                    return "own_into_slot(&g_em, {self.lookup_cname(name)})"
                }
                if self.lookup_array(name) {
                    // a BORROWED array read (an enum-payload array `case Branch(kids,..)`, or a borrow-array
                    // param) stored into a new owner is own_into_slot'd — it clones (arrays are unique-owner),
                    // the borrow's owner keeps its reference (stage-0's moves_local==2, OFI-220 un-dodged).
                    return "own_into_slot(&g_em, {self.lookup_cname(name)})"
                }
            }
            case _ {
            }
        }
        if self.ret_owns(e) {
            return "own_into_slot(&g_em, {self.emit_expr(e)})"
        }
        return self.emit_expr(e)
    }


    // ret_owns reports whether a value READ must be owned into a NEW slot (own_into_slot — the moves_local==2
    // retain): a REFCOUNTED struct FIELD read (`self.name`, `f(x).text`, `arr[i].text` — regardless of whether
    // the receiver is a borrow or an owning temp, since the own_into_slot rides the FIELD's refcount, not the
    // receiver), or a refcounted (string/enum) array ELEMENT (`xs[i]`). A scalar / non-refcounted field, a
    // struct element (em_index materialises/borrows the record), a literal, or a fresh owned temp go as-is.
    fn ret_owns(self, e: ps.Expr) -> bool {
        match e {
            case EIdent(name) {
                // A refcounted BORROW binding — an enum payload, or an erased generic-`T` param/payload (OFI-205) —
                // is own_into_slot'd on return (a retain balanced by the owner's drop), matching stage-0.
                return self.lookup_refc(name)
            }
            case EGet(object, name) {
                let osid = self.struct_sid_any(object.value)
                if osid >= 0 {
                    return self.st.field_is_refcounted(osid, name)
                }
                return false
            }
            case EIndex(object, index) {
                if self.object_is_owning_temp(e) {
                    return false   // an inline-packable element — em_index already materialised an owned COPY
                }
                // a refcounted STRING / ENUM element is owned in; a STRUCT element (em_index materialises /
                // borrows the record) and a scalar (incl. bool) element are passed as-is.
                return self.is_array_expr(object.value) && self.index_elem_refcounted(object.value) && self.struct_sid_any(e) < 0
            }
            case _ {
                return false
            }
        }
    }


    // emit_or_cond returns the parenthesised C disjunction for an or-pattern `case a | b | c`: each
    // alternative is a variant-tag test (`tag == vi`) or a literal equality (`em_eq_op`), OR'd with
    // `||`. The `||` short-circuits exactly like the VM's OR-of-tests, so both backends agree. Mirrors
    // src/cgen_c.c emit_or_cond (same fresh-var order → byte-identical output).
    fn emit_or_cond(mut self, alts: [ps.Pattern], sv: int, tv: int) -> string {
        var s = "("
        var a = 0
        loop {
            if a >= alts.len() {
                break
            }
            if a > 0 {
                s = s + " || "
            }
            if alts[a].kind == 2 {
                let rv = self.fresh_var()
                s = s + "em_truthy(em_eq_op(&g_em, (\{ Value v{rv} = v{sv}; if (IS_OBJ(v{rv})) OBJ_RETAIN(AS_OBJ(v{rv})); v{rv}; \}), {self.emit_expr(alts[a].lit[0])}))"
            } else {
                let tag = self.en.v_tag[self.en.variant_flat(alts[a].variant)]
                s = s + "v{tv} == {tag}"
            }
            a = a + 1
        }
        s = s + ")"
        return s
    }


    // emit_enum_inner_and returns ` && em_tag(payload_b) == <inner tag>` for each REFUTABLE enum-inner
    // slot of a variant pattern (`case Some(Ok(v))` — Phase 2d-ii), mirroring the VM's AND-of-tests
    // (outer tag AND each inner tag). An enum-inner is a nested slot whose variant name resolves to a
    // known variant; a struct-inner does not, and contributes no test. Mirrors src/cgen_c.c.
    fn emit_enum_inner_and(self, pat: ps.Pattern, sv: int) -> string {
        var s = ""
        var b = 0
        loop {
            if b >= pat.binding_pats.len() {
                break
            }
            if pat.binding_pats[b].kind != 5 {
                let ivf = self.en.variant_flat(pat.binding_pats[b].variant)
                if ivf >= 0 {
                    s = s + " && em_tag(em_enum_field(&g_em, v{sv}, {b})) == {self.en.v_tag[ivf]}"
                }
            }
            b = b + 1
        }
        return s
    }


    fn emit_stmt(mut self, s: ps.Stmt) {
        match s {
            case SReturn(value, line) {
                if self.scope_has_drops() {
                    // Evaluate the value into a temp, drop the function's owned locals/params, then return it.
                    // The value goes through emit_concat_operand (own a moved binding / retain a borrow).
                    let r = self.fresh_var()
                    var rv = "INT_VAL(0)"
                    if value.len() > 0 {
                        rv = self.emit_concat_operand(value[0].value, true)
                    }
                    println("{self.ind()}\{ Value v{r} = {rv};")
                    self.indent = self.indent + 1
                    self.emit_drops(0)
                    println("{self.ind()}return v{r};")
                    self.indent = self.indent - 1
                    println("{self.ind()}\}")
                } else {
                    if value.len() > 0 {
                        println("{self.ind()}return {self.emit_return_value(value[0].value)};")
                    } else {
                        println("{self.ind()}return INT_VAL(0);")    // a bare return yields unit (0), like the VM
                    }
                }
            }
            case SLet(is_var, name, ty, value) {
                // The binding's C variable number is taken BEFORE the initialiser (so a `let` is vN and the
                // initialiser's retain temps follow as v(N+1)…). A scalar binding lowers to a typed C scalar
                // unboxed from the Value (`int64_t vN = (int64_t)AS_INT(<rhs>)`); a string binding is an
                // owned Value (dropped at scope exit). (cgen_c.c:STMT_LET.)
                let id = self.fresh_var()
                let ssid = self.struct_sid_of(value.value)
                let kind = self.scalar_kind_of(value.value)
                if ssid >= 0 {
                    // A VALUE-struct binding: stored as the C `em_s<sid>` aggregate (value semantics, no drop).
                    println("{self.ind()}em_s{ssid} v{id} = {self.emit_expr(value.value)};")
                    self.push(name, "v{id}", 0 - 1, false, false, false, 0 - 1)
                    self.set_last_struct(ssid)
                } else if kind >= 0 {
                    let ct = scalar_ctype(kind)
                    println("{self.ind()}{ct} v{id} = ({ct})AS_INT({self.emit_expr(value.value)});")
                    self.push(name, "v{id}", kind, true, false, false, 0 - 1)        // unboxed C scalar storage
                } else {
                    let arr = self.is_array_expr(value.value)
                    let bsid = self.boxed_sid_of(value.value)                            // a BOXED struct local (owned, like an array)
                    // string / array / enum / boxed-struct local is owned/dropped; ret_owns also catches a
                    // refcounted FIELD / ELEMENT / owning-temp read (`let w = self.peek().text`) whose owned
                    // string/enum the plain predicates miss (is_string_expr has no field/element case).
                    let owned = self.is_string_expr(value.value) || arr || self.is_enum_expr(value.value) || bsid >= 0 || self.ret_owns(value.value)
                    // An owned array local carries its ELEMENT scalar kind so a later `xs[i]` types as a scalar —
                    // from the `[T]` annotation if present, else inferred from the initialiser.
                    var elem_sk = 0 - 1
                    if arr {
                        if ty.len() > 0 {
                            elem_sk = ty_scalar_kind(elem_ty_of(ty[0]))
                        } else {
                            elem_sk = self.value_elem_kind(value.value)
                            if elem_sk < 0 {
                                // a map-style call (`map(words, |w| w.len())`): the return element is the
                                // lambda's return type — type its body to recover a scalar element (OFI-206).
                                let mk = self.map_lam_ret(value.value, false)
                                if mk >= 0 {
                                    elem_sk = mk
                                }
                            }
                        }
                    }
                    // An empty array literal `[]` carries no element kind in the literal — take it from the
                    // `[T]` annotation (em_array(&g_em, 0, <elem_kind>)), mirroring the checker's context typing.
                    var done = false
                    match value.value {
                        case EArray(elems, lines) {
                            if elems.len() == 0 && ty.len() > 0 {
                                // An empty array of INLINE-PACKABLE structs is em_struct_array(&g_em, <sid>, 0)
                                // (packed layout); a non-inline struct element (boxed pointers) or any other
                                // empty array is em_array(&g_em, 0, <kind>) — matching the checker's elem_struct_id.
                                let esid = ty_struct_sid(elem_ty_of(ty[0]), self.st.names)
                                if esid >= 0 && self.st.is_inline_packable(esid) {
                                    println("{self.ind()}Value v{id} = em_struct_array(&g_em, 0, {esid});")   // em_struct_array(&g_em, count, sid)
                                } else {
                                    let ek = array_elem_kind_ty(elem_ty_of(ty[0]))
                                    println("{self.ind()}Value v{id} = em_array(&g_em, 0, {ek});")
                                }
                                done = true
                            }
                        }
                        case _ {
                        }
                    }
                    if done == false {
                        println("{self.ind()}Value v{id} = {self.emit_concat_operand(value.value, true)};")
                    }
                    self.push(name, "v{id}", 0 - 1, false, owned, arr, elem_sk)
                    if bsid >= 0 {
                        self.set_last_struct(bsid)          // track the boxed-struct sid so `c.field` resolves
                    }
                    if owned {
                        // `var acc = init` / `let a = d` where the RHS reads an erased TYPE-PARAM binding: the
                        // new owner is an owned type-param local — a whole-value consume MOVES it (nil-slot),
                        // not own_into_slot (stage-0's moves_local==1, OFI-176 F2). A concrete string/array RHS
                        // is NOT a type-param read, so this leaves it on the retain path.
                        match value.value {
                            case EIdent(vn) {
                                if self.lookup_tyvar(vn) {
                                    self.set_last_tyvar(true)
                                }
                            }
                            case _ {
                            }
                        }
                    }
                    if arr {
                        // a `[Struct]` array binding tracks its element struct sid (so `xs[i]` is a boxed-struct
                        // borrow) — from the `[T]` annotation, else from an array-returning CALL's element struct.
                        var esid = 0 - 1
                        if ty.len() > 0 {
                            esid = ty_struct_sid(elem_ty_of(ty[0]), self.st.names)
                            self.set_last_elem_aek(array_elem_kind_ty(elem_ty_of(ty[0])))   // element AEK (a [bool] element isn't refcounted)
                            if is_array_ty(elem_ty_of(ty[0])) {                            // a `[[T]]` binding (OFI-219)
                                self.set_last_elem_is_array(true)
                                self.set_last_elem_elem_kind(ty_scalar_kind(elem_ty_of(elem_ty_of(ty[0]))))   // T's scalar kind, so `grid[i][j]` reads plain
                            }
                        } else {
                            if self.value_elem_is_array(value.value) {
                                self.set_last_elem_is_array(true)                          // an inferred `[[T]]` literal
                            }
                            esid = self.value_elem_struct(value.value)
                            var bea = self.value_elem_aek_boxed(value.value)   // an inferred [string]-like array: mark its boxed element (OFI-206 follow-on)
                            if bea != 0 && self.map_lam_ret(value.value, true) == 1 {
                                bea = 0                                    // a map(…, |…| <string>) → boxed string element (OFI-206)
                            }
                            if bea == 0 {
                                self.set_last_elem_aek(0)
                            } else {
                                // a map(…, |…| <scalar>) → a SCALAR element AEK, so `lens[i]` reads plain (not own_into_slot).
                                let msk = self.map_lam_ret(value.value, false)
                                if msk >= 0 {
                                    self.set_last_elem_aek(scalar_kind_to_aek(msk))
                                }
                            }
                        }
                        if esid >= 0 {
                            self.set_last_elem_struct(esid)
                        }
                    }
                }
            }
            case SIf(cond, then_blk, els) {
                self.emit_if(cond.value, then_blk, els, self.ind())
            }
            case SLoop(body) {
                println("{self.ind()}for (;;) \{")
                self.indent = self.indent + 1
                self.emit_block_stmts(body)
                self.indent = self.indent - 1
                println("{self.ind()}\}")
            }
            case SFor(vname, index_var, iter, body) {
                // Both forms wrap in a `{ }` block. Range `for i in lo..hi`: declare lo/hi as int64_t `t`
                // temps, loop the index `t`, bind the loop var as a fresh Value each pass. Array `for x in
                // xs`: evaluate the array once into a `v`, loop over `em_array_len`, bind each element via
                // `em_index`. Per-pass owned body locals are dropped (cgen_c.c:STMT_FOR). The `t` and `v`
                // names SHARE the one counter; only the loop variable(s) are pushed into the binding scope.
                match iter.value {
                    case ERange(lo, hi) {
                        let lo_t = self.fresh_var()
                        let hi_t = self.fresh_var()
                        let ix = self.fresh_var()
                        println("{self.ind()}\{")
                        self.indent = self.indent + 1
                        println("{self.ind()}int64_t t{lo_t} = AS_INT({self.emit_expr(lo.value)});")
                        println("{self.ind()}int64_t t{hi_t} = AS_INT({self.emit_expr(hi.value)});")
                        println("{self.ind()}for (int64_t t{ix} = t{lo_t}; t{ix} < t{hi_t}; t{ix}++) \{")
                        self.indent = self.indent + 1
                        let vid = self.fresh_var()
                        println("{self.ind()}Value v{vid} = INT_VAL(t{ix});")
                        let mark = self.sc_name.len()
                        self.push(vname, "v{vid}", 0 - 1, false, false, false, 0 - 1)
                        self.emit_block_raw(body)
                        self.emit_drops(mark)
                        self.truncate_scope(mark)
                        self.indent = self.indent - 1
                        println("{self.ind()}\}")
                        self.indent = self.indent - 1
                        println("{self.ind()}\}")
                    }
                    case _ {
                        let av = self.fresh_var()
                        let nv = self.fresh_var()
                        let ix = self.fresh_var()
                        println("{self.ind()}\{")
                        self.indent = self.indent + 1
                        println("{self.ind()}Value v{av} = {self.emit_expr(iter.value)};")
                        println("{self.ind()}int64_t t{nv} = AS_INT(em_array_len(v{av}));")
                        println("{self.ind()}for (int64_t t{ix} = 0; t{ix} < t{nv}; t{ix}++) \{")
                        self.indent = self.indent + 1
                        let xv = self.fresh_var()
                        println("{self.ind()}Value v{xv} = em_index(&g_em, v{av}, INT_VAL(t{ix}));")
                        let mark = self.sc_name.len()
                        if index_var != "" {
                            let iv = self.fresh_var()
                            println("{self.ind()}Value v{iv} = INT_VAL(t{ix});")
                            self.push(index_var, "v{iv}", 0 - 1, false, false, false, 0 - 1)
                        }
                        self.push(vname, "v{xv}", 0 - 1, false, false, false, 0 - 1)
                        // Type the loop variable by the iterable's ELEMENT struct so `t.field` resolves — a
                        // `for t in turns` over a `[Turn]` binds each `t` as a Turn.
                        let lv_esid = self.array_elem_struct_of(iter.value)
                        if lv_esid >= 0 {
                            self.set_last_struct(lv_esid)
                        }
                        self.emit_block_raw(body)
                        self.emit_drops(mark)
                        self.truncate_scope(mark)
                        self.indent = self.indent - 1
                        println("{self.ind()}\}")
                        // A FRESH temporary iterable (an array literal or a call result) is dropped after the
                        // loop; a named binding / field is a borrow the owner drops (cgen_c.c:STMT_FOR).
                        match iter.value {
                            case EArray(elems, lines) {
                                println("{self.ind()}drop_value(&g_em, v{av});")
                            }
                            case ECall(callee, cargs) {
                                println("{self.ind()}drop_value(&g_em, v{av});")
                            }
                            case _ {
                            }
                        }
                        self.indent = self.indent - 1
                        println("{self.ind()}\}")
                    }
                }
            }
            case SBreak(line) {
                println("{self.ind()}break;")
            }
            case SContinue(line) {
                println("{self.ind()}continue;")
            }
            case SBlock(body) {
                println("{self.ind()}\{")
                self.indent = self.indent + 1
                self.emit_block_stmts(body)
                self.indent = self.indent - 1
                println("{self.ind()}\}")
            }
            case SMatch(value, cases) {
                // `match scrut { case V(binds) { … } … }` → evaluate the scrutinee once (a borrow of the owner),
                // read its tag, then an if / else-if chain on the variant tag. A case's payload fields are bound
                // POSITIONALLY via em_enum_field (a borrow — the enum owns them); a `case _` is the `else`.
                // (cgen_c.c match lowering. Scrutinee-is-an-owning-temp drop is a later increment.)
                let sv = self.fresh_var()
                println("{self.ind()}\{")
                self.indent = self.indent + 1
                println("{self.ind()}Value v{sv} = {self.emit_expr(value.value)};")
                // The tag header is only needed for variant arms; a scalar/string subject (all-literal
                // arms) has no tag, so emitting em_tag on it would be dead and ill-typed (mirrors cgen_c.c).
                var has_variant = false
                var hvi = 0
                loop {
                    if hvi >= cases.len() {
                        break
                    }
                    // A REAL variant arm (a bare/qualified name the enum table resolves). A bare name it
                    // does NOT resolve is a scalar value binding (`case n` — Phase 2b), which needs no tag.
                    let hv_real = cases[hvi].pattern.wildcard == false && cases[hvi].pattern.kind == 0 && self.en.is_case_variant(cases[hvi].pattern.variant)
                    if hv_real {
                        has_variant = true
                    }
                    if cases[hvi].pattern.kind == 4 {
                        // An or-pattern needs the tag header iff any alternative is a variant (not a literal).
                        var ova = 0
                        loop {
                            if ova >= cases[hvi].pattern.alts.len() {
                                break
                            }
                            if cases[hvi].pattern.alts[ova].kind != 2 {
                                has_variant = true
                            }
                            ova = ova + 1
                        }
                    }
                    hvi = hvi + 1
                }
                var tv = 0
                if has_variant {
                    tv = self.fresh_var()
                    println("{self.ind()}int v{tv} = em_tag(v{sv});")
                }
                // If the scrutinee is a fresh OWNED enum temp (a call/ctor result — not a borrow binding/field),
                // it must be dropped on every exit (each arm's return/break/… via emit_drops(0)) AND at the
                // match's fall-through. Push it as a synthetic owned binding BELOW the arm payload marks so the
                // per-arm emit_drops(mark) leaves it alive, then drop it after the if/else chain. (cgen_c.c.)
                let owns_subj = self.is_enum_expr(value.value)
                let subj_mark = self.sc_name.len()
                if owns_subj {
                    self.push("", "v{sv}", 0 - 1, false, true, false, 0 - 1)
                }
                // Guards break the if/else-if chain — a failed guard must fall through, which `else if`
                // can't do — so a match with any guard uses a `matched` flag + independent `if` blocks.
                var has_guard = false
                var hgi = 0
                loop {
                    if hgi >= cases.len() {
                        break
                    }
                    if cases[hgi].guard.len() > 0 {
                        has_guard = true
                    }
                    hgi = hgi + 1
                }
                var mv = 0
                if has_guard {
                    mv = self.fresh_var()
                    println("{self.ind()}int v{mv} = 0;")
                }
                var ci = 0
                var first = true
                loop {
                    if ci >= cases.len() {
                        break
                    }
                    // A bare name the enum table does NOT resolve is a scalar VALUE binding (`case n`, 2b).
                    let vb = cases[ci].pattern.wildcard == false && cases[ci].pattern.kind == 0 && self.en.is_case_variant(cases[ci].pattern.variant) == false
                    // --- condition ---
                    if has_guard {
                        if cases[ci].pattern.wildcard || vb {
                            println("{self.ind()}if (v{mv} == 0) \{")
                        } else if cases[ci].pattern.kind == 2 {
                            let rv = self.fresh_var()
                            let cond = "em_truthy(em_eq_op(&g_em, (\{ Value v{rv} = v{sv}; if (IS_OBJ(v{rv})) OBJ_RETAIN(AS_OBJ(v{rv})); v{rv}; \}), {self.emit_expr(cases[ci].pattern.lit[0])}))"
                            println("{self.ind()}if (v{mv} == 0 && {cond}) \{")
                        } else if cases[ci].pattern.kind == 4 {
                            let cond = self.emit_or_cond(cases[ci].pattern.alts, sv, tv)
                            println("{self.ind()}if (v{mv} == 0 && {cond}) \{")
                        } else {
                            let tag = self.en.case_tag(cases[ci].pattern.variant)
                            let inner = self.emit_enum_inner_and(cases[ci].pattern, sv)
                            println("{self.ind()}if (v{mv} == 0 && v{tv} == {tag}{inner}) \{")
                        }
                    } else {
                        if cases[ci].pattern.wildcard || vb {
                            if first {
                                println("{self.ind()}if (1) \{")
                            } else {
                                println("{self.ind()}\} else \{")
                            }
                        } else if cases[ci].pattern.kind == 2 {
                            let rv = self.fresh_var()
                            let cond = "em_truthy(em_eq_op(&g_em, (\{ Value v{rv} = v{sv}; if (IS_OBJ(v{rv})) OBJ_RETAIN(AS_OBJ(v{rv})); v{rv}; \}), {self.emit_expr(cases[ci].pattern.lit[0])}))"
                            if first {
                                println("{self.ind()}if ({cond}) \{")
                            } else {
                                println("{self.ind()}\} else if ({cond}) \{")
                            }
                        } else if cases[ci].pattern.kind == 4 {
                            let cond = self.emit_or_cond(cases[ci].pattern.alts, sv, tv)
                            if first {
                                println("{self.ind()}if ({cond}) \{")
                            } else {
                                println("{self.ind()}\} else if ({cond}) \{")
                            }
                        } else {
                            let tag = self.en.case_tag(cases[ci].pattern.variant)
                            let inner = self.emit_enum_inner_and(cases[ci].pattern, sv)
                            if first {
                                println("{self.ind()}if (v{tv} == {tag}{inner}) \{")
                            } else {
                                println("{self.ind()}\} else if (v{tv} == {tag}{inner}) \{")
                            }
                        }
                    }
                    self.indent = self.indent + 1
                    let mark = self.sc_name.len()
                    // --- bindings (shared between chain + flag) ---
                    if vb {
                        let bv = self.fresh_var()
                        println("{self.ind()}Value v{bv} = v{sv};")   // scalar value binding — a borrow of the subject
                        self.push(cases[ci].pattern.variant, "v{bv}", 0 - 1, false, false, false, 0 - 1)
                    } else {
                        var bi = 0
                        loop {
                            if bi >= cases[ci].pattern.bindings.len() {
                                break
                            }
                            // A ONE-LEVEL REFUTABLE enum-inner (`case Some(Ok(v))` — Phase 2d-ii): the
                            // outer/inner tag tests already gated the condition, so bind each inner
                            // (scalar/string) field via em_enum_field on the payload. Mirrors src/cgen_c.c.
                            if cases[ci].pattern.binding_pats.len() > 0 && cases[ci].pattern.binding_pats[bi].kind != 5 && self.en.variant_flat(cases[ci].pattern.binding_pats[bi].variant) >= 0 {
                                var ij = 0
                                loop {
                                    if ij >= cases[ci].pattern.binding_pats[bi].bindings.len() {
                                        break
                                    }
                                    let bv = self.fresh_var()
                                    println("{self.ind()}Value v{bv} = em_enum_field(&g_em, em_enum_field(&g_em, v{sv}, {bi}), {ij});")
                                    self.push(cases[ci].pattern.binding_pats[bi].bindings[ij], "v{bv}", 0 - 1, false, false, false, 0 - 1)   // a borrow of the inner enum's field
                                    if self.en.payload_refc(cases[ci].pattern.binding_pats[bi].variant, ij) {
                                        self.set_last_refc(true)      // a refcounted (string/enum) inner payload → own_into_slot on consume
                                    }
                                    ij = ij + 1
                                }
                                bi = bi + 1
                                continue
                            }
                            // A ONE-LEVEL nested struct destructure (`case Some(Point(x, y))`): unbox the
                            // boxed value-struct payload into an em_s ONCE, then bind each inner name to
                            // its em_s field (em_s fields ARE Values — no re-boxing). Mirrors src/cgen_c.c.
                            if cases[ci].pattern.binding_pats.len() > 0 && cases[ci].pattern.binding_pats[bi].kind != 5 {
                                let psid = self.st.sid_of_ty(self.en.payload_ty(cases[ci].pattern.variant, bi))
                                let fc = self.st.field_count(psid)
                                let bv = self.fresh_var()
                                println("{self.ind()}em_s{psid} v{bv}; em_unbox_struct(&g_em, {psid}, em_enum_field(&g_em, v{sv}, {bi}), (Value*)&v{bv}, {fc});")
                                var ij = 0
                                loop {
                                    if ij >= cases[ci].pattern.binding_pats[bi].bindings.len() {
                                        break
                                    }
                                    self.push(cases[ci].pattern.binding_pats[bi].bindings[ij], "v{bv}.f{ij}", 0 - 1, false, false, false, 0 - 1)   // a Value field of the unboxed struct
                                    ij = ij + 1
                                }
                                bi = bi + 1
                                continue
                            }
                            // A simple `case Some(r)`/`case Ok(r)` whose payload the ENUM TABLE types as the
                            // erased T (a prelude generic), but whose SCRUTINEE is a concrete generic container
                            // (`self.rects.get(id)` : Option<Rect>): recover the concrete payload struct from the
                            // scrutinee (the self-hosted stand-in for stage-0's checker-stamped binding_struct).
                            // A VALUE struct is unboxed into an em_s so `r.w` is a value-struct field read; a
                            // boxed struct falls through as a Value binding with its sid tracked. OFI-218 keystone.
                            var resolved_boxed = 0 - 1
                            var declared_payload_sid = 0 - 1
                            if self.en.has_payload_field(cases[ci].pattern.variant, bi) {
                                declared_payload_sid = self.st.sid_of_ty(self.en.payload_ty(cases[ci].pattern.variant, bi))
                            }
                            if declared_payload_sid < 0 {
                                let csid = self.match_payload_sid(value.value)
                                if csid >= 0 {
                                    if self.st.is_value(csid) {
                                        let fc = self.st.field_count(csid)
                                        let bv = self.fresh_var()
                                        println("{self.ind()}em_s{csid} v{bv}; em_unbox_struct(&g_em, {csid}, em_enum_field(&g_em, v{sv}, {bi}), (Value*)&v{bv}, {fc});")
                                        self.push(cases[ci].pattern.bindings[bi], "v{bv}", 0 - 1, false, false, false, 0 - 1)
                                        self.set_last_struct(csid)
                                        bi = bi + 1
                                        continue
                                    }
                                    resolved_boxed = csid
                                }
                            }
                            let bv = self.fresh_var()
                            println("{self.ind()}Value v{bv} = em_enum_field(&g_em, v{sv}, {bi});")
                            let pa = self.en.payload_array(cases[ci].pattern.variant, bi)
                            var pek = 0 - 1
                            if pa {
                                pek = self.en.payload_elem(cases[ci].pattern.variant, bi)
                            }
                            self.push(cases[ci].pattern.bindings[bi], "v{bv}", 0 - 1, false, false, pa, pek)   // a borrowed payload field (array-aware)
                            if resolved_boxed >= 0 {
                                self.set_last_struct(resolved_boxed)   // a BOXED-struct container payload (rc struct) → `r.field` resolves
                            }
                            if self.en.payload_refc(cases[ci].pattern.variant, bi) || self.subject_is_gopt(value.value) {
                                self.set_last_refc(true)      // a refcounted (string/enum) payload, OR an erased generic-Option<T> payload (OFI-205) → own_into_slot on consume
                            }
                            if pa {
                                // a `[Struct]` / `[Box<T>]` payload: resolve the element struct sid via sid_of_ty
                                // (handles generic instances ty_struct_sid can't), so `xs[i]` / `xs[i].f` resolve.
                                let ety = elem_ty_of(self.en.payload_ty(cases[ci].pattern.variant, bi))
                                let pes = self.st.sid_of_ty(ety)
                                if pes >= 0 {
                                    self.set_last_elem_struct(pes)
                                }
                            } else if self.en.has_payload_field(cases[ci].pattern.variant, bi) {
                                let pty = self.en.payload_ty(cases[ci].pattern.variant, bi)
                                let psid = self.st.sid_of_ty(pty)
                                if psid >= 0 {
                                    self.set_last_struct(psid)       // a struct / `Box<T>` payload: `elem.value` / `s.field` resolves
                                }
                                let rk = render_kind_of_ty(pty)
                                if rk != 0 {
                                    self.set_last_render(rk)         // a scalar float/bool/sized payload: `{v}` renders at its kind
                                }
                            }
                            // else: a generic prelude payload (Some/Ok/Err's T/E) — a plain Value binding,
                            // no struct sid / render kind (the return retain-dance emits the IS_OBJ wrapper).
                            bi = bi + 1
                        }
                    }
                    // --- body (guard-wrapped in the flag path) ---
                    if has_guard && cases[ci].guard.len() > 0 {
                        println("{self.ind()}if (em_truthy({self.emit_expr(cases[ci].guard[0])})) \{")
                        self.indent = self.indent + 1
                        println("{self.ind()}v{mv} = 1;")
                        self.emit_block_raw(cases[ci].body)
                        self.emit_drops(mark)
                        self.indent = self.indent - 1
                        println("{self.ind()}\}")
                    } else {
                        if has_guard {
                            println("{self.ind()}v{mv} = 1;")
                        }
                        self.emit_block_raw(cases[ci].body)
                        self.emit_drops(mark)
                    }
                    self.truncate_scope(mark)
                    self.indent = self.indent - 1
                    if has_guard {
                        println("{self.ind()}\}")        // close this arm's independent `if`
                    }
                    first = false
                    ci = ci + 1
                }
                if has_guard == false {
                    if first == false {
                        println("{self.ind()}\}")
                    }
                }
                if owns_subj {
                    self.emit_drops(subj_mark)        // fall-through: drop the owning-temp scrutinee
                    self.truncate_scope(subj_mark)
                }
                self.indent = self.indent - 1
                println("{self.ind()}\}")
            }
            case SAssign(target, value) {
                // Assignment to a `var`. A scalar → `vN = (ctype)AS_INT(<rhs>);` (re-stored at width). An
                // OWNED binding (array/string) → evaluate the new value, DROP the old, then store (so the
                // replaced value can't leak — cgen_c.c:STMT_ASSIGN). A plain Value var → a direct store.
                match target.value {
                    case EIdent(name) {
                        let k = self.lookup_kind(name)
                        let cn = self.lookup_cname(name)
                        if self.lookup_unboxed(name) {
                            let ct = scalar_ctype(k)
                            println("{self.ind()}{cn} = ({ct})AS_INT({self.emit_expr(value.value)});")
                        } else if self.lookup_drop(name) {
                            let t = self.fresh_var()
                            println("{self.ind()}\{ Value v{t} = {self.emit_assign_value(value.value)};")
                            self.indent = self.indent + 1
                            println("{self.ind()}drop_value(&g_em, {cn});")
                            println("{self.ind()}{cn} = v{t};")
                            self.indent = self.indent - 1
                            println("{self.ind()}\}")
                        } else {
                            println("{self.ind()}{cn} = {self.emit_expr(value.value)};")
                        }
                    }
                    case EIndex(object, index) {
                        // Element mutation `arr[i] = v` → em_set_index (bounds-checked; drops the old element,
                        // moves the new value in). Object/index/value emitted in source order (OFI-166). The
                        // array CONSUMES the value (a refcounted string/enum/array/struct is own_into_slot'd in,
                        // exactly like `.append(v)`) — emit_consume_arg, not a raw read (closes OFI-166/173).
                        let o = self.emit_expr(object.value)
                        let ix = self.emit_expr(index.value)
                        let val = self.emit_consume_arg(value.value)
                        println("{self.ind()}em_set_index(&g_em, {o}, {ix}, {val});")
                    }
                    case EGet(object, name) {
                        // Field mutation `recv.f = v` on a BOXED struct → em_set_field (drops the overwritten
                        // field, moves the new value in). A VALUE-struct field write (a C member assign) is a
                        // later increment. Receiver then value in source order (OFI-166).
                        let bsid = self.boxed_sid_of(object.value)
                        if bsid >= 0 {
                            let fidx = self.st.field_index(bsid, name)
                            let o = self.emit_expr(object.value)
                            let val = self.emit_field_consume(bsid, name, value.value)   // the field CONSUMES the value (`[]` at the field's kind)
                            println("{self.ind()}em_set_field(&g_em, {o}, {fidx}, {val});")
                        }
                    }
                    case _ {
                    }
                }
            }
            case SExpr(expr) {
                // A bare expression statement. A builtin `println(x)` → `(void)(em_println(&g_em, <args>));`
                // (borrowed args, read as-is). Any OTHER call (a user free fn, a struct method, a
                // module-qualified call, an em_native builtin, an enum ctor) goes through emit_call_stmt,
                // which mirrors stage-0's STMT_EXPR: `(void)(E)` for a unit result, or (for a discarded
                // fresh OWNING temp — string/array/enum/boxed-struct) `{ Value _dis = (E); drop_value(…); }`.
                match expr.value {
                    case ECall(callee, args) {
                        match callee.value {
                            case EIdent(name) {
                                let nat = native_cfn(name)
                                if nat != "" {
                                    var s = "{self.ind()}(void)({nat}(&g_em"
                                    var i = 0
                                    loop {
                                        if i >= args.len() {
                                            break
                                        }
                                        s = s + ", " + self.emit_expr(args[i])
                                        i = i + 1
                                    }
                                    println(s + "));")
                                } else {
                                    // panic(msg) as a statement flows here too: emit_call_stmt wraps the
                                    // expression form `(em_panic_val(…), INT_VAL(0))` in `(void)(…);`, matching
                                    // stage-0's generic STMT_EXPR path byte-for-byte.
                                    self.emit_call_stmt(expr.value)
                                }
                            }
                            case EGet(object, mname) {
                                self.emit_call_stmt(expr.value)
                            }
                            case _ {
                            }
                        }
                    }
                    case _ {
                    }
                }
            }
            case _ {
            }
        }
    }


    // emit_call_stmt renders a call expression STATEMENT whose result is discarded (a user free fn / struct
    // method / module-qualified call / em_native builtin / enum ctor). Mirrors stage-0's STMT_EXPR: if the
    // result is a FRESH OWNING temp (a string / array / enum / boxed struct — like the checker's release_temp
    // flag), drop it (`{ Value _dis = (E); drop_value(&g_em, _dis); }`), else `(void)(E);`. A unit-returning
    // call (p_expr) and a borrow-returning array method (`arr.append`) take the plain `(void)` form.
    fn emit_call_stmt(mut self, e: ps.Expr) {
        let owns = self.is_string_expr(e) || self.is_array_expr(e) || self.is_enum_expr(e) || self.boxed_sid_of(e) >= 0
        match e {
            case ECall(callee, args) {
                let c = self.emit_call(callee.value, args)
                if owns {
                    println("{self.ind()}\{ Value _dis = ({c}); drop_value(&g_em, _dis); \}")
                } else {
                    println("{self.ind()}(void)({c});")
                }
            }
            case _ {
            }
        }
    }
}


// native_cfn maps a builtin name to its em_* runtime C function (M5b: the print family), or "" if not one.
fn native_cfn(name: string) -> string {
    if name == "println" {
        return "em_println"
    }
    if name == "print" {
        return "em_print"
    }
    return ""
}


// binop_cfn maps a binop id (ps.binop_id: 1 + / 2 - / 3 * / 4 / / 5 % / 6 < / 7 <= / 8 > / 9 >= / 10 == /
// 11 != / 14 & / 15 | / 16 ^ / 17 << / 18 >>) to its em_* runtime C function.
fn binop_cfn(bid: int) -> string {
    if bid == 1 { return "em_add" }
    if bid == 2 { return "em_sub" }
    if bid == 3 { return "em_mul" }
    if bid == 4 { return "em_div" }
    if bid == 5 { return "em_mod" }
    if bid == 6 { return "em_lt" }
    if bid == 7 { return "em_le" }
    if bid == 8 { return "em_gt" }
    if bid == 9 { return "em_ge" }
    if bid == 10 { return "em_eq_op" }
    if bid == 11 { return "em_neq_op" }
    if bid == 14 { return "em_bitand" }
    if bid == 15 { return "em_bitor" }
    if bid == 16 { return "em_bitxor" }
    if bid == 17 { return "em_shl" }
    if bid == 18 { return "em_shr" }
    return "em_add"
}


// binop_wants_ctx: em_add (1) / em_eq_op (10) / em_neq_op (11) take `&g_em` and retain their consumed operands.
fn binop_wants_ctx(bid: int) -> bool {
    return bid == 1 || bid == 10 || bid == 11
}


// binop_has_nk: arithmetic (1–5), ordered compares (6–9), and shifts (17–18) carry a trailing num_kind;
// equality (10–11) and bitwise (14–16) do not.
fn binop_has_nk(bid: int) -> bool {
    return (bid >= 1 && bid <= 9) || bid == 17 || bid == 18
}


// emit_fn_body prints a single function's C definition: `static Value em_fn_N(params) { … }` with the
// implicit trailing `return INT_VAL(0);` stage-0 always emits. The params are pushed into scope as the
// Value bindings a0, a1, … (a method's `self` is the leading a0). (C braces escaped `\{`/`\}`.)
fn is_string_ty(ty: ps.Ty) -> bool {
    match ty {
        case TyName(qual, name) {
            return qual == "" && name == "string"
        }
        case _ {
            return false
        }
    }
}


// cextern_names_ordered is the hosted FFI registry in g_sigs order (src/cextern.c) — the POSITION of each name
// IS its em_ffi index. The self-hosted compiler is one binary for every profile (a program native-links
// against whichever runtime it needs), so this superset includes the profile bands: the DEFAULT band (0-41,
// present in every build) and the NET band http_* (42-47, matching the net-gfx build Inglenook uses; the web
// build's GFX_HEADLESS band would shift these — a target-profile concern for later). OFI-218 P6 FFI.
fn cextern_names_ordered() -> [string] {
    return ["sin", "cos", "tan", "asin", "acos", "atan", "atan2", "exp", "log", "log2", "log10", "sinh",
        "cosh", "tanh", "cbrt", "trunc", "hypot", "fmod", "cvec2_len", "cvec2_dot", "cvec2_add", "cvec2_scale",
        "strlen", "strncmp", "fopen", "fread", "fwrite", "fclose", "proc_run", "proc_exit", "proc_stdout",
        "proc_stderr", "proc_free", "em_now_unix", "em_mkdir", "em_remove", "em_tcp_listen", "em_tcp_accept",
        "em_tcp_connect", "em_recv", "em_send", "em_close",
        "http_post", "http_get", "http_open", "http_next", "http_status", "http_close"]
}


// cgc_cextern_index returns the em_ffi registry index of a hosted extern name, or -1.
fn cgc_cextern_index(name: string) -> int {
    let names = cextern_names_ordered()
    var i = 0
    loop {
        if i >= names.len() {
            break
        }
        if names[i] == name {
            return i
        }
        i = i + 1
    }
    return 0 - 1
}


// native_id_for_name maps a built-in free-function name to its NATIVE_* id (the em_native dispatcher operand),
// mirroring codegen.ig / src/builtin.c. Returns -1 for a non-builtin. Core (default-build) builtins only.
fn native_id_for_name(name: string) -> int {
    if name == "print" {
        return 0
    }
    if name == "println" {
        return 1
    }
    if name == "read_line" {
        return 2
    }
    if name == "read_file" {
        return 3
    }
    if name == "write_file" {
        return 4
    }
    if name == "char_code" {
        return 5
    }
    if name == "from_char_code" {
        return 6
    }
    if name == "parse_float" {
        return 7
    }
    if name == "sqrt" {
        return 8
    }
    if name == "pow" {
        return 9
    }
    if name == "abs" {
        return 10
    }
    if name == "floor" {
        return 11
    }
    if name == "ceil" {
        return 12
    }
    if name == "round" {
        return 13
    }
    if name == "random" {
        return 14
    }
    if name == "hash" {
        return 15
    }
    if name == "concat" {
        return 16
    }
    if name == "args" {
        return 17
    }
    if name == "env" {
        return 18
    }
    if name == "exit" {
        return 19
    }
    if name == "byte_slice" {
        return 22
    }
    if name == "from_bytes" {
        return 23
    }
    // Graphics builtins (ids 100-142) drive raylib through em_native → ember_gfx_native (the same
    // dispatcher the VM uses); only reachable when linked against the graphics runtime. Mirrors
    // codegen.ig / src/cgen_c.c (the graphics arm of the native band). Needed so the self-hosted
    // C-emit can build graphics apps (Flare / Inglenook) — OFI-218 Phase 6 (Inglenook-on-selfhost).
    if name == "window_open" {
        return 100
    }
    if name == "window_close" {
        return 101
    }
    if name == "window_should_close" {
        return 102
    }
    if name == "frame_begin" {
        return 103
    }
    if name == "frame_end" {
        return 104
    }
    if name == "draw_rect" {
        return 105
    }
    if name == "draw_text" {
        return 106
    }
    if name == "key_down" {
        return 107
    }
    if name == "mouse_x" {
        return 108
    }
    if name == "mouse_y" {
        return 109
    }
    if name == "mouse_down" {
        return 110
    }
    if name == "measure_text" {
        return 111
    }
    if name == "char_pressed" {
        return 112
    }
    if name == "key_pressed" {
        return 113
    }
    if name == "set_layer" {
        return 114
    }
    if name == "clip_push" {
        return 115
    }
    if name == "clip_pop" {
        return 116
    }
    if name == "tape_open" {
        return 117
    }
    if name == "tape_close" {
        return 118
    }
    if name == "tape_mark" {
        return 119
    }
    if name == "fill_round" {
        return 120
    }
    if name == "stroke_round" {
        return 121
    }
    if name == "fill_grad" {
        return 122
    }
    if name == "shadow" {
        return 123
    }
    if name == "fill_circle" {
        return 124
    }
    if name == "mouse_wheel" {
        return 125
    }
    if name == "key_repeat" {
        return 126
    }
    if name == "load_font" {
        return 127
    }
    if name == "set_font" {
        return 128
    }
    if name == "clipboard_set" {
        return 129
    }
    if name == "clipboard_get" {
        return 130
    }
    if name == "screen_width" {
        return 131
    }
    if name == "screen_height" {
        return 132
    }
    if name == "text_line_height" {
        return 133
    }
    if name == "set_cursor" {
        return 134
    }
    if name == "frame_capture" {
        return 135
    }
    if name == "set_event_waiting" {
        return 136
    }
    if name == "had_input" {
        return 137
    }
    if name == "measure_misses" {
        return 138
    }
    if name == "frame_steps" {
        return 139
    }
    if name == "set_alpha" {
        return 140
    }
    if name == "mouse_right_down" {
        return 141
    }
    if name == "dropped_files" {
        return 142
    }
    return 0 - 1
}


// is_em_native_id reports whether a native id goes through the em_native dispatcher (the READ_LINE..EXIT band
// plus byte_slice and from_bytes; print/println keep their own em_print/em_println path, and 20/21 are witness-only).
fn is_em_native_id(nid: int) -> bool {
    return (nid >= 2 && nid <= 19) || nid == 22 || nid == 23 || (nid >= 100 && nid <= 142)
}


// native_ret_kind classifies a native builtin's OWNED return: -3 a string, -2 an array, -1 scalar/unit
// (not droppable), -4 = not a builtin. Drives owned-binding tracking for `let x = byte_slice(…)`.
fn native_ret_kind(name: string) -> int {
    if name == "read_line" || name == "read_file" || name == "env" || name == "from_char_code" || name == "byte_slice" || name == "concat" || name == "from_bytes" {
        return 0 - 3
    }
    if name == "args" {
        return 0 - 2
    }
    if native_id_for_name(name) >= 0 {
        return 0 - 1
    }
    return 0 - 4
}


// numeric_typename_kind returns the em_conv target-kind for a numeric type-name used as a CONVERSION call
// (`int(x)`, `i32(x)`, `u8(x)`, `f64(x)`), or -1 if `name` is not a numeric typename (mirrors codegen.ig).
fn numeric_typename_kind(name: string) -> int {
    if name == "int" || name == "i64" {
        return 0
    }
    if name == "i8" {
        return 1
    }
    if name == "i16" {
        return 2
    }
    if name == "i32" {
        return 3
    }
    if name == "u8" {
        return 4
    }
    if name == "u16" {
        return 5
    }
    if name == "u32" {
        return 6
    }
    if name == "u64" {
        return 7
    }
    if name == "f32" {
        return 8
    }
    if name == "f64" {
        return 9
    }
    return 0 - 1
}


// is_enum_ty reports whether a type annotation names a declared enum (an OWNED refcounted value — an enum
// param / local / return is dropped at scope exit and moved into a call, exactly like a string).
fn enum_name_known(name: string, en: EnumTab) -> bool {
    // The prelude Option/Result are enums but aren't in the C-emit enum table (construction has its own
    // path), so recognise them by name (OFI-204) — an `o: Option<int>` param/return is an owned enum.
    if name == "Option" {
        return true
    }
    if name == "Result" {
        return true
    }
    var i = 0
    loop {
        if i >= en.names.len() {
            break
        }
        if en.names[i] == name {
            return true
        }
        i = i + 1
    }
    return false
}


// is_fn_ty reports whether a type is a function type `fn(...) -> ...` — a first-class CLOSURE value, which is
// an OWNED refcounted heap object (dropped at scope exit, like a string/enum). Mirrors codegen.ig's ty_is_fn.
fn is_fn_ty(ty: ps.Ty) -> bool {
    match ty {
        case TyFn(params, ret) {
            return true
        }
        case _ {
            return false
        }
    }
}


fn is_enum_ty(ty: ps.Ty, en: EnumTab) -> bool {
    match ty {
        case TyName(qual, name) {
            // The qualifier is the module alias (`lx.Tk`); the merged enum table registers each enum by its
            // BARE name (like ast_print drops the qualifier), so match on `name` regardless of `qual`.
            return enum_name_known(name, en)
        }
        case TyGeneric(qual, name, args) {
            // A generic-enum instance (`Option<int>`, `Result<T, E>`, a user generic enum) is also an enum.
            return enum_name_known(name, en)
        }
        case _ {
            return false
        }
    }
}


// ty_is_generic_param reports whether type `ty` is a bare reference to one of the enclosing function's type
// parameters (`T` in `fn f<T>(x: T)`). Such an ERASED value is refcount-of-unknown-type: stage-0 own_into_slots
// it on return / consume (a retain balanced by the owner's drop), so the self-host must mark it a refcounted
// borrow to match byte-for-byte (OFI-205).
fn ty_is_generic_param(ty: ps.Ty, generics: [ps.GenericParam]) -> bool {
    match ty {
        case TyName(qual, name) {
            var i = 0
            loop {
                if i >= generics.len() {
                    break
                }
                if generics[i].name == name {
                    return true
                }
                i = i + 1
            }
            return false
        }
        case _ {
            return false
        }
    }
}


// enum_payload_generic reports whether `ty` is a GENERIC Option/Result whose payload is a bare type parameter
// (`Option<T>` / `Result<T, E>`) — so a `case Some(v)`/`case Ok(v)` on a subject of this type binds an erased T
// (own_into_slot on return), UNLIKE a concrete `Option<int>` (a scalar payload, plain retain-dance).
fn enum_payload_generic(ty: ps.Ty, generics: [ps.GenericParam]) -> bool {
    match ty {
        case TyGeneric(qual, name, args) {
            if name == "Option" && args.len() > 0 {
                return ty_is_generic_param(args[0], generics)
            }
            if name == "Result" && args.len() > 0 {
                return ty_is_generic_param(args[0], generics)
            }
            return false
        }
        case _ {
            return false
        }
    }
}


fn emit_fn_body(f: ps.FnDecl, idx: int, has_self: bool, owner_sid: int, st: StructTab, en: EnumTab, fn_names: [string], fn_ret_kind: [int], fn_ret_render: [int], fn_ret_opt_param: [int], fn_ret_str: [bool], fn_ret_array: [bool], fn_ret_elem_kind: [int], fn_ret_elem_struct: [int], fn_ret_struct: [int], fn_ret_enum: [bool], consts: ConstTab, lambda_start: int, fn_ret_det_arg: [int], fn_ret_det_elem: [bool], fn_ret_lam_arg: [int], fn_ret_lam_in: [int], fn_hof_srcs: [int], fn_param_gen_mask: [int], lam_pstr: [bool], lam_pkind: [int], extern_names: [string], extern_ret_kind: [int], extern_ret_str: [bool]) -> [int] {
    var g = CgcGen{ next_var: 0, sc_name: [], sc_cname: [], sc_kind: [], sc_unboxed: [], sc_drop: [], sc_array: [], sc_elem_kind: [], sc_elem_aek: [], sc_elem_is_array: [], sc_elem_elem_kind: [], sc_elem_struct: [], sc_refc: [], sc_tyvar: [], sc_struct: [], sc_render: [], indent: 1, st: st, en: en, fn_names: fn_names, fn_ret_kind: fn_ret_kind, fn_ret_render: fn_ret_render, fn_ret_opt_param: fn_ret_opt_param, fn_ret_str: fn_ret_str, fn_ret_array: fn_ret_array, fn_ret_elem_kind: fn_ret_elem_kind, fn_ret_elem_struct: fn_ret_elem_struct, fn_ret_struct: fn_ret_struct, fn_ret_enum: fn_ret_enum, consts: consts, cur_gopt: [], cur_owner: owner_sid, cur_tp_pname: [], cur_tp_tname: [], cur_lambda: lambda_start, fn_ret_det_arg: fn_ret_det_arg, fn_ret_det_elem: fn_ret_det_elem, fn_ret_lam_arg: fn_ret_lam_arg, fn_ret_lam_in: fn_ret_lam_in, fn_hof_srcs: fn_hof_srcs, fn_param_gen_mask: fn_param_gen_mask, lam_recs: [], extern_names: extern_names, extern_ret_kind: extern_ret_kind, extern_ret_str: extern_ret_str }
    // For a lifted lambda, lam_pstr/lam_pkind type its OWN params (the trailing params after the captures) so
    // the body dispatches `.len()`/concat/arithmetic like stage-0 (the C signature stays all-`Value`). Captures
    // lead and stay untyped. caps = (non-self param count) − (own params typed) — OFI-206 follow-on.
    var nv = 0
    var pv = 0
    loop {
        if pv >= f.params.len() {
            break
        }
        if f.params[pv].is_self == false {
            nv = nv + 1
        }
        pv = pv + 1
    }
    let lam_caps = nv - lam_pstr.len()
    var ai = 0
    if has_self {
        g.push("self", "a0", 0 - 1, false, false, false, 0 - 1)
        if owner_sid >= 0 {
            g.set_last_struct(owner_sid)          // `self` is the owning struct (value → a0.fN, boxed → em_enum_field)
        }
        ai = 1
    }
    var p = 0
    loop {
        if p >= f.params.len() {
            break
        }
        if f.params[p].is_self == false {
            // a param's TYPE scalar-kind (so `let x = a` infers a scalar) — but its STORAGE is the Value aN.
            // A string param is an OWNED value, dropped at every exit; a value-struct param is an em_s.
            var pk = 0 - 1
            var owned = false
            var is_arr = false
            var ek = 0 - 1
            var eaek = 0 - 1
            var psid = 0 - 1
            var pesid = 0 - 1
            var peia = false
            var peek = 0 - 1
            if f.params[p].ty.len() > 0 {
                pk = ty_scalar_kind(f.params[p].ty[0])
                owned = is_string_ty(f.params[p].ty[0]) || is_enum_ty(f.params[p].ty[0], en) || is_fn_ty(f.params[p].ty[0])   // string / enum / closure param is OWNED
                is_arr = is_array_ty(f.params[p].ty[0])   // an array param is a BORROW (not dropped at exit)
                if is_arr {
                    ek = ty_scalar_kind(elem_ty_of(f.params[p].ty[0]))   // its element scalar kind, so `a[i]` is a scalar
                    eaek = array_elem_kind_ty(elem_ty_of(f.params[p].ty[0]))   // its element AEK, so a `[bool]` element isn't owned
                    pesid = ty_struct_sid(elem_ty_of(f.params[p].ty[0]), st.names)   // a `[Struct]` param: `a[i]` is a boxed struct
                    peia = is_array_ty(elem_ty_of(f.params[p].ty[0]))   // a `[[T]]` param: its element is an array (OFI-219)
                    if peia {
                        peek = ty_scalar_kind(elem_ty_of(elem_ty_of(f.params[p].ty[0])))   // its INNER element scalar kind
                    }
                }
                psid = st.sid_of_ty(f.params[p].ty[0])   // value OR boxed struct sid this param carries (incl. a generic instance)
            }
            // A lifted lambda's own param (typeless in the AST) takes its type from the recorded call context:
            // a string param is OWNED (dropped at exit); a scalar carries its width-kind. (ai == the non-self
            // index here, as a lifted lambda has no `self`.)
            if lam_pstr.len() > 0 && ai >= lam_caps {
                let own_idx = ai - lam_caps
                if own_idx < lam_pstr.len() {
                    if lam_pstr[own_idx] {
                        owned = true
                        pk = 0 - 1
                    } else if lam_pkind[own_idx] >= 0 {
                        pk = lam_pkind[own_idx]
                        owned = false
                    }
                }
            }
            g.push(f.params[p].name, "a{ai}", pk, false, owned, is_arr, ek)
            if is_arr {
                g.set_last_elem_aek(eaek)
                g.set_last_elem_is_array(peia)
                g.set_last_elem_elem_kind(peek)
            }
            if psid >= 0 {
                g.set_last_struct(psid)           // value param → read via aN.fM; boxed param → a borrowed Value
            }
            if pesid >= 0 {
                g.set_last_elem_struct(pesid)     // struct-array param → `a[i]` types as a boxed struct
            }
            if f.params[p].ty.len() > 0 {
                // An erased generic-`T` param (`d: T`) is a refcounted borrow — own_into_slot on return (OFI-205).
                if ty_is_generic_param(f.params[p].ty[0], f.generics) {
                    g.set_last_refc(true)
                    g.set_last_tyvar(true)        // mark it a type-param read source, so `var acc = <this>` inherits (F2)
                }
                // A generic Option/Result param (`o: Option<T>`) — record it so `case Some(v)`/`case Ok(v)` on it
                // binds its erased payload as a refcounted borrow too.
                if enum_payload_generic(f.params[p].ty[0], f.generics) {
                    g.cur_gopt.append(f.params[p].name)
                }
                // A param typed as one of the OWNER struct's BOUNDED type-params (`key: K` in a Map<K,V> method)
                // — record it so a bounded-method call `key.hash()`/`key.eq(..)` dispatches through self's witness.
                let otp = owner_tparam_name(f.params[p].ty[0], st, owner_sid)
                if otp != "" {
                    g.cur_tp_pname.append(f.params[p].name)
                    g.cur_tp_tname.append(otp)
                }
            }
            ai = ai + 1
        }
        p = p + 1
    }
    println("static {fn_ret_ctype(f, st)} em_fn_{idx}({fn_param_list(f, has_self, st, owner_sid)}) \{")
    var i = 0
    loop {
        if i >= f.body.len() {
            break
        }
        g.emit_stmt(f.body[i])
        i = i + 1
    }
    // the implicit trailing return — preceded by the owned-binding drops on the fall-through path. A value-
    // struct-returning fn yields a zero-initialised `(em_s<sid>){0}` (the C return type must match).
    if g.scope_has_drops() {
        g.emit_drops(0)
    }
    let rsid = fn_ret_value_struct(f, st)
    if rsid >= 0 {
        println("    return (em_s{rsid})\{0\};")
    } else {
        println("    return INT_VAL(0);")
    }
    println("\}")
    // copy the recorded rec blocks out into a fresh local (a field can't be moved out; scalars copy) — OFI-206
    var out: [int] = []
    var ci = 0
    loop {
        if ci >= g.lam_recs.len() {
            break
        }
        out.append(g.lam_recs[ci])
        ci = ci + 1
    }
    return out
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


// emit_invoke_case prints the em_invoke dispatcher case for fn `idx` (the indirect-call trampoline). Each
// value-struct PARAMETER slot is unboxed into an em_s temp (em_unbox_struct); em_fn_idx is called; a value-
// struct RESULT is boxed back to a Value (em_box_struct). A purely Value-signature fn is unchanged
// (`Value _r = em_fn_idx(slots…); return _r;`). Mirrors cgen_c.c's em_invoke.
fn emit_invoke_case(f: ps.FnDecl, idx: int, has_self: bool, stab: StructTab, owner_sid: int) {
    println("        case {idx}: \{")
    let n = value_arity(f, has_self)
    var i = 0
    loop {
        if i >= n {
            break
        }
        let psid = param_value_sid(f, has_self, stab, owner_sid, i)
        if psid >= 0 {
            println("            em_s{psid} p{i}; em_unbox_struct(ctx, {psid}, slots[{i}], (Value*)&p{i}, {stab.field_count(psid)});")
        }
        i = i + 1
    }
    var args = ""
    var j = 0
    loop {
        if j >= n {
            break
        }
        if j > 0 {
            args = args + ", "
        }
        let psid = param_value_sid(f, has_self, stab, owner_sid, j)
        if psid >= 0 {
            args = args + "p{j}"
        } else {
            args = args + "slots[{j}]"
        }
        j = j + 1
    }
    let rsid = fn_ret_value_struct(f, stab)
    if rsid >= 0 {
        println("            em_s{rsid} r = em_fn_{idx}({args});")
        println("            return em_box_struct(ctx, {rsid}, (Value*)&r, {stab.field_count(rsid)});")
    } else {
        println("            Value _r = em_fn_{idx}({args});")
        println("            return _r;")
    }
    println("        \}")
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
    return 0                            // no `main` (a standalone module compile): stage-0's plan defaults to em_fn_0
}


// emit_struct_preamble emits the C struct block, byte-identical to stage-0: (1) a `typedef struct {…} em_sN;`
// for every VALUE-type struct (a nested value-struct field is `em_s<m> f<i>`, a scalar is `Value f<i>`);
// (2) per-struct packed-layout metadata arrays `em_sN_off/knd/fst[]` for EVERY struct (offsets are a running
// sum of size_of_aek — no alignment padding); (3) the `em_structs[]` StructType table the runtime reads for
// boxing/field-access/drop. Nothing is emitted when there are no declared structs.
fn emit_struct_preamble(tab: StructTab, fn_names: [string]) {
    let n = tab.names.len()
    if n == 0 {
        return
    }
    let total_structs = tab.struct_count()             // declared + generic instances
    // (1) typedefs — a DECLARED struct gets a full `typedef struct {…} em_s<sid>;`; a generic INSTANCE aliases
    // its base (`typedef em_s<base> em_s<sid>;` — T is erased, so it shares the base layout). Instances follow
    // the declared structs in sid order. A nested value-struct field is `em_s<m> f<i>`, else `Value f<i>`.
    var sid = 0
    loop {
        if sid >= total_structs {
            break
        }
        if sid >= n {
            println("typedef em_s{tab.base_of(sid)} em_s{sid};")
            println("")
        } else {
            println("typedef struct \{")
            let fc = tab.field_count(sid)
            var f = 0
            loop {
                if f >= fc {
                    break
                }
                let flat = tab.flat_index(sid, f)
                if tab.f_struct[flat] >= 0 && tab.is_value(tab.f_struct[flat]) {
                    println("    em_s{tab.f_struct[flat]} f{f};")
                } else {
                    println("    Value f{f};")
                }
                f = f + 1
            }
            if fc == 0 {
                println("    Value _unit;")           // C forbids an empty struct
            }
            println("\} em_s{sid};")
            println("")
        }
        sid = sid + 1
    }
    // (2) packed-layout metadata arrays (offset / kind / field_struct), for EVERY struct (an instance's
    // fields resolve through base_of to the generic base's layout).
    var s2 = 0
    loop {
        if s2 >= total_structs {
            break
        }
        let fc = tab.field_count(s2)
        var offs = ""
        var knds = ""
        var fsts = ""
        var off = 0
        var f = 0
        loop {
            if f >= fc {
                break
            }
            let flat = tab.flat_index(s2, f)
            if f > 0 {
                offs = offs + ", "
                knds = knds + ", "
                fsts = fsts + ", "
            }
            offs = offs + "{off}"
            knds = knds + "{tab.field_aek(flat)}"
            fsts = fsts + "{tab.fst_of(flat)}"
            off = off + tab.field_size(flat)
            f = f + 1
        }
        println("static int em_s{s2}_off[] = \{{offs}\};")
        println("static int em_s{s2}_knd[] = \{{knds}\};")
        println("static int em_s{s2}_fst[] = \{{fsts}\};")
        s2 = s2 + 1
    }
    // (3) the StructType table (one row per struct, sid order). drop_fn is -1 until a generated drop is wired;
    // is_rc / is_resource follow the declared `kind` (an instance inherits its base's kind).
    println("static const StructType em_structs[{total_structs}] = \{")
    var s3 = 0
    loop {
        if s3 >= total_structs {
            break
        }
        let fc = tab.field_count(s3)
        let total = tab.total_size(s3)
        let kind = tab.kinds[tab.base_of(s3)]
        var is_rc = 0
        if kind == 1 {
            is_rc = 1
        }
        var is_res = 0
        if kind == 2 {
            is_res = 1
        }
        // drop_fn = the em_fn index of this struct's `drop` method (a resource/rc struct's RAII hook), or -1.
        // A method is named "Struct.drop" in fn_names, whose position IS its em_fn index — so a Run/Db handle
        // runs proc_free/sqlite_close on scope exit (was hardcoded -1 → the drop never ran). Uses the BASE name
        // (a generic instance inherits its base's drop). Mirrors check.c's si->drop_fn.
        var drop_fn = 0 - 1
        let dname = "{tab.names[tab.base_of(s3)]}.drop"
        var di = 0
        loop {
            if di >= fn_names.len() {
                break
            }
            if fn_names[di] == dname {
                drop_fn = di
                break
            }
            di = di + 1
        }
        println("    \{ .field_count = {fc}, .total_size = {total}, .is_rc = {is_rc}, .is_resource = {is_res}, .drop_fn = {drop_fn}, .offset = em_s{s3}_off, .kind = em_s{s3}_knd, .field_struct = em_s{s3}_fst \},")
        s3 = s3 + 1
    }
    println("\};")
}


// ---- lambda lifting (OFI-206 / OFI-218 P3) — mirrors codegen.ig's FvCtx + LambdaSpec machinery ------
// The C-emit lifts each lambda to a top-level `em_fn_N` numbered AFTER all declared fns+methods, in
// body-traversal discovery order (matching stage-0's checker-appended lambda DECL_FNs). A lambda VALUE
// becomes `em_closure(&g_em, N, ncap, cap0…)`; the lifted body's params are [captures…, own params…], all
// boxed Value. Capture analysis (free variables) is duplicated here — the two backends duplicate by design.

// CgcFv is the free-variable walker (copy of codegen.ig's FvCtx): free = referenced non-bound locals, in
// traversal order = a lambda's captures.
struct CgcFv {
    bound: [string]
    free: [string]


    fn note(mut self, name: string) {
        if index_of_str(self.bound, name) >= 0 {
            return
        }
        if index_of_str(self.free, name) >= 0 {
            return
        }
        self.free.append(name)
    }


    fn walk_expr(mut self, e: ps.Expr) {
        match e {
            case EIdent(name) {
                self.note(name)
            }
            case EUnary(op, operand) {
                self.walk_expr(operand.value)
            }
            case EBinary(op, l, r) {
                self.walk_expr(l.value)
                self.walk_expr(r.value)
            }
            case ECall(callee, args) {
                self.walk_expr(callee.value)
                self.walk_args(args)
            }
            case EGet(object, name) {
                self.walk_expr(object.value)
            }
            case EIndex(object, index) {
                self.walk_expr(object.value)
                self.walk_expr(index.value)
            }
            case EArray(elems, lines) {
                self.walk_args(elems)
            }
            case EStructLit(ty, fields) {
                var i = 0
                loop {
                    if i >= fields.len() {
                        break
                    }
                    self.walk_expr(fields[i].value)
                    i = i + 1
                }
            }
            case ETry(operand) {
                self.walk_expr(operand.value)
            }
            case ERange(lo, hi) {
                self.walk_expr(lo.value)
                self.walk_expr(hi.value)
            }
            case EStr(parts) {
                var i = 0
                loop {
                    if i >= parts.len() {
                        break
                    }
                    if parts[i].hole.len() > 0 {
                        self.walk_expr(parts[i].hole[0])
                    }
                    i = i + 1
                }
            }
            case ELambda(params, body) {
                let saved = clone_strs(self.bound)
                var p = 0
                loop {
                    if p >= params.len() {
                        break
                    }
                    self.bound.append(params[p].name)
                    p = p + 1
                }
                self.walk_block(body)
                self.bound = saved
            }
            case _ {
            }
        }
    }


    fn walk_args(mut self, args: [ps.Expr]) {
        var i = 0
        loop {
            if i >= args.len() {
                break
            }
            self.walk_expr(args[i])
            i = i + 1
        }
    }


    fn walk_stmt(mut self, s: ps.Stmt) {
        match s {
            case SLet(is_var, name, ty, value) {
                self.walk_expr(value.value)
                self.bound.append(name)
            }
            case SReturn(value, line) {
                if value.len() > 0 {
                    self.walk_expr(value[0].value)
                }
            }
            case SExpr(expr) {
                self.walk_expr(expr.value)
            }
            case SAssign(target, value) {
                self.walk_expr(target.value)
                self.walk_expr(value.value)
            }
            case SIf(cond, then_blk, els) {
                self.walk_expr(cond.value)
                self.walk_block(then_blk)
                self.walk_block(els)
            }
            case SFor(vname, index_var, iter, body) {
                self.walk_expr(iter.value)
                let saved = clone_strs(self.bound)
                self.bound.append(vname)
                if index_var != "" {
                    self.bound.append(index_var)
                }
                self.walk_block(body)
                self.bound = saved
            }
            case SLoop(body) {
                self.walk_block(body)
            }
            case SMatch(value, cases) {
                self.walk_expr(value.value)
                var ci = 0
                loop {
                    if ci >= cases.len() {
                        break
                    }
                    let saved = clone_strs(self.bound)
                    var bi = 0
                    loop {
                        if bi >= cases[ci].pattern.bindings.len() {
                            break
                        }
                        self.bound.append(cases[ci].pattern.bindings[bi])
                        bi = bi + 1
                    }
                    self.walk_block(cases[ci].body)
                    self.bound = saved
                    ci = ci + 1
                }
            }
            case SBlock(body) {
                self.walk_block(body)
            }
            case SSpawn(call) {
                self.walk_expr(call.value)
            }
            case SNursery(body, line) {
                self.walk_block(body)
            }
            case _ {
            }
        }
    }


    fn walk_block(mut self, body: [ps.Stmt]) {
        let saved = clone_strs(self.bound)
        var i = 0
        loop {
            if i >= body.len() {
                break
            }
            self.walk_stmt(body[i])
            i = i + 1
        }
        self.bound = saved
    }
}


// cgc_lambda_captures returns a lambda's free-variable (capture) NAMES in traversal order.
fn cgc_lambda_captures(params: [ps.Param], body: [ps.Stmt]) -> [string] {
    var seed: [string] = []
    var p = 0
    loop {
        if p >= params.len() {
            break
        }
        seed.append(params[p].name)
        p = p + 1
    }
    var ctx = CgcFv { bound: seed, free: [] }
    ctx.walk_block(body)
    return clone_strs(ctx.free)
}


// cgc_lifted_params builds a lifted lambda's C parameter list: [capture params…, own params…], every one
// UNTYPED so it emits as a boxed `Value aN` (stage-0 forces inline_struct_id=-1 on a lifted param).
fn cgc_lifted_params(caps: [string], own: [ps.Param]) -> [ps.Param] {
    var out: [ps.Param] = []
    var i = 0
    loop {
        if i >= caps.len() {
            break
        }
        out.append(ps.Param { qual: 0, is_self: false, name: caps[i], ty: [] })
        i = i + 1
    }
    var p = 0
    loop {
        if p >= own.len() {
            break
        }
        out.append(ps.Param { qual: own[p].qual, is_self: false, name: own[p].name, ty: [] })
        p = p + 1
    }
    return out
}


// LamColl collects each lambda as a synthetic lifted FnDecl into `lams`, in the SAME traversal order the
// emit pass hits them (statement order, then expression left-to-right) — so the em_fn_N numbering the
// collection assigns matches the `cur_lambda` counter the em_closure site increments. Flat lambdas only (a
// lambda body is NOT re-walked; nested lambdas are a documented gap, as in the VM path).
struct LamColl {
    lams: [ps.FnDecl]


    fn cl_expr(mut self, e: ps.Expr) {
        match e {
            case EUnary(op, operand) {
                self.cl_expr(operand.value)
            }
            case EBinary(op, l, r) {
                self.cl_expr(l.value)
                self.cl_expr(r.value)
            }
            case ECall(callee, args) {
                self.cl_expr(callee.value)
                var i = 0
                loop {
                    if i >= args.len() {
                        break
                    }
                    self.cl_expr(args[i])
                    i = i + 1
                }
            }
            case EGet(object, name) {
                self.cl_expr(object.value)
            }
            case EIndex(object, index) {
                self.cl_expr(object.value)
                self.cl_expr(index.value)
            }
            case EArray(elems, lines) {
                var i = 0
                loop {
                    if i >= elems.len() {
                        break
                    }
                    self.cl_expr(elems[i])
                    i = i + 1
                }
            }
            case EStructLit(ty, fields) {
                var i = 0
                loop {
                    if i >= fields.len() {
                        break
                    }
                    self.cl_expr(fields[i].value)
                    i = i + 1
                }
            }
            case ETry(operand) {
                self.cl_expr(operand.value)
            }
            case ERange(lo, hi) {
                self.cl_expr(lo.value)
                self.cl_expr(hi.value)
            }
            case EStr(parts) {
                var i = 0
                loop {
                    if i >= parts.len() {
                        break
                    }
                    if parts[i].hole.len() > 0 {
                        self.cl_expr(parts[i].hole[0])
                    }
                    i = i + 1
                }
            }
            case ELambda(params, body) {
                let caps = cgc_lambda_captures(params, body)
                let lp = cgc_lifted_params(caps, params)
                self.lams.append(ps.FnDecl { name: "<lambda>", generics: [], params: lp, ret: [], has_body: true, body: body, reqs: [], req_lines: [], enss: [], ens_lines: [] })
            }
            case _ {
            }
        }
    }


    fn cl_stmt(mut self, s: ps.Stmt) {
        match s {
            case SLet(is_var, name, ty, value) {
                self.cl_expr(value.value)
            }
            case SReturn(value, line) {
                if value.len() > 0 {
                    self.cl_expr(value[0].value)
                }
            }
            case SExpr(expr) {
                self.cl_expr(expr.value)
            }
            case SAssign(target, value) {
                self.cl_expr(target.value)
                self.cl_expr(value.value)
            }
            case SIf(cond, then_blk, els) {
                self.cl_expr(cond.value)
                self.cl_block(then_blk)
                self.cl_block(els)
            }
            case SFor(vname, index_var, iter, body) {
                self.cl_expr(iter.value)
                self.cl_block(body)
            }
            case SLoop(body) {
                self.cl_block(body)
            }
            case SMatch(value, cases) {
                self.cl_expr(value.value)
                var ci = 0
                loop {
                    if ci >= cases.len() {
                        break
                    }
                    self.cl_block(cases[ci].body)
                    ci = ci + 1
                }
            }
            case SBlock(body) {
                self.cl_block(body)
            }
            case SSpawn(call) {
                self.cl_expr(call.value)
            }
            case SNursery(body, line) {
                self.cl_block(body)
            }
            case _ {
            }
        }
    }


    fn cl_block(mut self, body: [ps.Stmt]) {
        var i = 0
        loop {
            if i >= body.len() {
                break
            }
            self.cl_stmt(body[i])
            i = i + 1
        }
    }
}


// build_lam_coll walks every declared fn/method body in declaration order, returning a LamColl whose `lams`
// holds each lambda as a synthetic lifted FnDecl. Slot for entry k is `fn_count(decls) + k`. Returned WHOLE
// (not the field — a partial move is unsupported), read in place by emit_program.
fn build_lam_coll(decls: [ps.Decl]) -> LamColl {
    var c = LamColl { lams: [] }
    var i = 0
    loop {
        if i >= decls.len() {
            break
        }
        match decls[i] {
            case DFn(f) {
                if f.has_body {
                    c.cl_block(f.body)
                }
            }
            case DStruct(name, generics, impls, fields, methods, kind) {
                var mi = 0
                loop {
                    if mi >= methods.len() {
                        break
                    }
                    if methods[mi].has_body {
                        c.cl_block(methods[mi].body)
                    }
                    mi = mi + 1
                }
            }
            case _ {
            }
        }
        i = i + 1
    }
    return c
}


// count_lambdas_body returns how many top-level lambdas a fn body contains (its em_closure counter span).
fn count_lambdas_body(body: [ps.Stmt]) -> int {
    var c = LamColl { lams: [] }
    c.cl_block(body)
    return c.lams.len()
}


// count_lambdas_expr returns how many lambdas an expression subtree lifts — for predicting the em_fn slot of
// a lambda that follows earlier lambda-bearing args in the same call.
fn count_lambdas_expr(e: ps.Expr) -> int {
    var c = LamColl { lams: [] }
    c.cl_expr(e)
    return c.lams.len()
}


// emit_program writes the whole C translation unit for the merged module declarations, byte-identical to
// stage-0 `inglec --emit=c`. It iterates `decls` once per section, keeping a shared em_fn_N counter.
fn emit_program(decls: [ps.Decl], filename: string) {
    let total = fn_count(decls)
    let fn_names = build_fn_names(decls)
    let fn_ret_kind = build_fn_ret_kinds(decls)
    let fn_ret_render = build_fn_ret_render(decls)
    let fn_ret_opt_param = build_ret_opt_param(decls)   // per-method Option/Result generic-payload param index
    let fn_ret_str = build_fn_ret_str(decls)
    let fn_ret_array = build_fn_ret_array(decls)
    let fn_ret_elem_kind = build_fn_ret_elem_kinds(decls)
    let stab = build_struct_tab(decls)
    let etab = build_enum_tab(decls, stab.names)
    let ctab = build_const_tab(decls)
    let fn_ret_elem_struct = build_fn_ret_elem_structs(decls, stab.names)
    let fn_ret_struct = build_fn_ret_structs(decls, stab)
    let fn_ret_enum = build_fn_ret_enum(decls, etab)
    let fn_ret_det_arg = build_ret_det_arg(decls)
    let fn_ret_det_elem = build_ret_det_elem(decls)
    let fn_ret_lam_arg = build_ret_lam_arg(decls)
    let fn_ret_lam_in = build_ret_lam_in(decls)
    let fn_hof_srcs = build_hof_srcs(decls)    // per-HOF lifted-lambda param sources (OFI-206)
    let fn_param_gen_mask = build_fn_param_gen_mask(decls)   // per-fn generic-borrow-param bitmask (OFI-176, F1)
    let extern_names = build_extern_names(decls)             // declared `extern "c"` fns (side table — P6 FFI)
    let extern_ret_kind = build_extern_ret_kinds(decls)      // ...and their declared return width-kinds
    let extern_ret_str = build_extern_ret_str(decls)         // ...and which return an owned string
    let lc = build_lam_coll(decls)             // lifted lambdas, numbered `total + k` (OFI-206)
    let grand = total + lc.lams.len()                // total em_fn slots (declared + lambdas)
    println("// Generated by `inglec --emit=c` from {filename}. Do not edit.")
    println("// The bytecode VM is the reference semantics; tests/native diffs the two.")
    println("#include \"ember_rt.h\"")
    println("")
    emit_struct_preamble(stab, fn_names)       // struct typedefs + runtime metadata (nothing if no structs)
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
                    println("static {fn_ret_ctype(f, stab)} em_fn_{fwd}({fn_param_list(f, false, stab, 0 - 1)});")
                    fwd = fwd + 1
                }
            }
            case DStruct(name, generics, impls, fields, methods, kind) {
                let owner = stab.sid_of(name)
                var mi = 0
                loop {
                    if mi >= methods.len() {
                        break
                    }
                    if methods[mi].has_body {
                        println("static {fn_ret_ctype(methods[mi], stab)} em_fn_{fwd}({fn_param_list(methods[mi], true, stab, owner)});")
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
    // lifted-lambda forward declarations (em_fn_{total+k}), in collection order
    var lf = 0
    loop {
        if lf >= lc.lams.len() {
            break
        }
        println("static {fn_ret_ctype(lc.lams[lf], stab)} em_fn_{total + lf}({fn_param_list(lc.lams[lf], false, stab, 0 - 1)});")
        lf = lf + 1
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
                    emit_invoke_case(f, inv, false, stab, 0 - 1)
                    inv = inv + 1
                }
            }
            case DStruct(name, generics, impls, fields, methods, kind) {
                let owner = stab.sid_of(name)
                var mi = 0
                loop {
                    if mi >= methods.len() {
                        break
                    }
                    if methods[mi].has_body {
                        emit_invoke_case(methods[mi], inv, true, stab, owner)
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
    // lifted-lambda em_invoke cases (fn_index total+k)
    var li = 0
    loop {
        if li >= lc.lams.len() {
            break
        }
        emit_invoke_case(lc.lams[li], total + li, false, stab, 0 - 1)
        li = li + 1
    }
    println("        default: break;")
    println("    \}")
    println("    em_panic(\"em_invoke: not a callable function\");")
    println("    return INT_VAL(0);")
    println("\}")
    println("")
    // the function bodies. Each declared body returns the param typings of any lambda it lifts (discovered at
    // its HOF call sites); we accumulate them, then route each into the matching lifted body below (OFI-206).
    var b = 0
    var lam_next = total                          // the em_fn slot the NEXT lifted lambda takes
    var all_recs: [int] = []                      // flat self-describing rec blocks accumulated across bodies
    let eb: [bool] = []                           // typed-empty rows for a declared (non-lambda) body — passed as
    let ei: [int] = []                            // bindings so their AEK matches stage-0 (a bare `[]` arg isn't
                                                  // context-typed by the self-hosted C-emit — see OFI-221)
    var k = 0
    loop {
        if k >= decls.len() {
            break
        }
        match decls[k] {
            case DFn(f) {
                if f.has_body {
                    let recs = emit_fn_body(f, b, false, 0 - 1, stab, etab, fn_names, fn_ret_kind, fn_ret_render, fn_ret_opt_param, fn_ret_str, fn_ret_array, fn_ret_elem_kind, fn_ret_elem_struct, fn_ret_struct, fn_ret_enum, ctab, lam_next, fn_ret_det_arg, fn_ret_det_elem, fn_ret_lam_arg, fn_ret_lam_in, fn_hof_srcs, fn_param_gen_mask, eb, ei, extern_names, extern_ret_kind, extern_ret_str)
                    var ri = 0
                    loop {
                        if ri >= recs.len() {
                            break
                        }
                        all_recs.append(recs[ri])
                        ri = ri + 1
                    }
                    lam_next = lam_next + count_lambdas_body(f.body)
                    b = b + 1
                    if b < grand {
                        println("")
                    }
                }
            }
            case DStruct(name, generics, impls, fields, methods, kind) {
                let owner = stab.sid_of(name)
                var mi = 0
                loop {
                    if mi >= methods.len() {
                        break
                    }
                    if methods[mi].has_body {
                        let recs = emit_fn_body(methods[mi], b, true, owner, stab, etab, fn_names, fn_ret_kind, fn_ret_render, fn_ret_opt_param, fn_ret_str, fn_ret_array, fn_ret_elem_kind, fn_ret_elem_struct, fn_ret_struct, fn_ret_enum, ctab, lam_next, fn_ret_det_arg, fn_ret_det_elem, fn_ret_lam_arg, fn_ret_lam_in, fn_hof_srcs, fn_param_gen_mask, eb, ei, extern_names, extern_ret_kind, extern_ret_str)
                        var ri = 0
                        loop {
                            if ri >= recs.len() {
                                break
                            }
                            all_recs.append(recs[ri])
                            ri = ri + 1
                        }
                        lam_next = lam_next + count_lambdas_body(methods[mi].body)
                        b = b + 1
                        if b < grand {
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
    // lifted-lambda bodies (em_fn_{total+k}); a flat lambda body has no nested lambda, so lambda_start=0. Each
    // gets its own recorded param typing, decoded fresh from all_recs into LOCAL rows (empty rows if the lambda
    // wasn't a HOF arg). (Flat/local rows are a simplicity choice — nested arrays now compile, OFI-219 closed.)
    var lb = 0
    loop {
        if lb >= lc.lams.len() {
            break
        }
        let want = total + lb
        var ps: [bool] = []
        var pk: [int] = []
        var pos = 0
        loop {
            if pos >= all_recs.len() {
                break
            }
            let slot = all_recs[pos]              // block = [slot, nparams, s0, k0, s1, k1, …]
            let np = all_recs[pos + 1]
            if slot == want {
                var pp = 0
                loop {
                    if pp >= np {
                        break
                    }
                    ps.append(all_recs[pos + 2 + pp * 2] == 1)
                    pk.append(all_recs[pos + 3 + pp * 2])
                    pp = pp + 1
                }
            }
            pos = pos + 2 + np * 2
        }
        let _drop = emit_fn_body(lc.lams[lb], total + lb, false, 0 - 1, stab, etab, fn_names, fn_ret_kind, fn_ret_render, fn_ret_opt_param, fn_ret_str, fn_ret_array, fn_ret_elem_kind, fn_ret_elem_struct, fn_ret_struct, fn_ret_enum, ctab, 0, fn_ret_det_arg, fn_ret_det_elem, fn_ret_lam_arg, fn_ret_lam_in, fn_hof_srcs, fn_param_gen_mask, ps, pk, extern_names, extern_ret_kind, extern_ret_str)
        b = b + 1
        if b < grand {
            println("")
        }
        lb = lb + 1
    }
    println("")
    // the C main wrapper, invoking the Ingle `main`
    let mi = main_index(decls)
    println("int main(int argc, char **argv) \{")
    println("    em_argc = argc - 1; em_argv = argv + 1;")
    if stab.names.len() > 0 {
        println("    g_em.structs = em_structs;")
        println("    g_em.struct_count = {stab.struct_count()};")
    } else {
        println("    g_em.structs = 0;")
        println("    g_em.struct_count = 0;")
    }
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
