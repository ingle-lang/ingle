// selfhost/codegen.em — the Ember bytecode backend (Stage 4 / M4 of the self-hosting bootstrap,
// docs/design/self-hosting.md). It consumes the self-hosted parser's AST and emits bytecode whose
// disassembly is BYTE-IDENTICAL to stage-0 `emberc --emit=bytecode` over the corpus (the M4 differential,
// the same shape as the lexer's --emit=tokens and the parser's --emit=ast).
//
// This is built in stages. The FOUNDATION here is design-free: the opcode table (include/opcode.h), the
// Chunk (a bytecode buffer + constant/string pools + per-byte line numbers), the operand codec (LEB128 +
// fixed-width big-endian, mirroring opcode.h), and the disassembler (src/chunk.c chunk_disassemble — the
// exact text the differential compares). The codegen proper (AST -> Chunk) grows on top of this.

import "parser" as ps


// ---- operand kinds (opcode.h OperandKind) ---------------------------------------------------------
let OPK_U8: int = 0
let OPK_U16: int = 1
let OPK_U24: int = 2
let OPK_OFF16: int = 3
let OPK_IDX: int = 4


// ---- named opcodes the disassembler / codegen reference directly (byte = position in op_names) -----
let OP_CONST: int = 0
let OP_STRING: int = 1
let OP_TRUE: int = 2
let OP_FALSE: int = 3
let OP_POP: int = 4
let OP_GET_LOCAL: int = 6
let OP_SET_LOCAL: int = 7
let OP_SUB: int = 9
let OP_WRAP_ADD: int = 21
let OP_WRAP_SUB: int = 22
let OP_WRAP_MUL: int = 23
let OP_NEG: int = 13
let OP_NOT: int = 14
let OP_BITNOT: int = 18
let OP_JUMP: int = 30
let OP_JUMP_IF_FALSE: int = 31
let OP_LOOP: int = 32
let OP_FOR_RANGE: int = 33
let OP_FOR_ARRAY: int = 34
let OP_CALL: int = 35
let OP_CALL_NATIVE: int = 36
let OP_CALL_C: int = 37
let OP_CALL_INDIRECT: int = 38
let OP_MAKE_DYN: int = 39
let OP_CALL_DYN: int = 40
let OP_MAKE_CLOSURE: int = 41
let OP_CALL_CLOSURE: int = 42
let OP_INT_TO_FLOAT: int = 70
let OP_FLOAT_TO_INT: int = 71
let OP_CONV: int = 72
let OP_EQ: int = 24
let OP_NEW_STRUCT: int = 43
let OP_NEW_ENUM: int = 44
let OP_GET_FIELD: int = 45
let OP_GET_TAG: int = 54
let OP_GET_FIELD_OWNED: int = 46
let OP_DROP_UNDER: int = 47
let OP_PICK: int = 48
let OP_NEW_STRUCT_ARRAY: int = 49
let OP_UNBOX_STRUCT: int = 50
let OP_BOX_STRUCT: int = 52
let OP_SET_FIELD: int = 53
let OP_NEW_ARRAY: int = 55
let OP_INDEX: int = 56
let OP_SET_INDEX: int = 57
let OP_ARRAY_LEN: int = 58
let OP_ARRAY_APPEND: int = 59
let OP_STR_LEN: int = 64
let OP_STR_CHARS: int = 65
let OP_STR_CHAR_COUNT: int = 66
let OP_STR_BYTES: int = 67
let OP_TO_STRING: int = 74
let OP_NURSERY_BEGIN: int = 75
let OP_CONTRACT_CHECK: int = 76
let OP_SPAWN: int = 77
let OP_NURSERY_END: int = 78
let OP_CHANNEL_NEW: int = 79
let OP_SEND: int = 80
let OP_RECV: int = 81
let OP_TRY_RECV: int = 82
let OP_CLOSE: int = 83
let OP_DROP: int = 84
let OP_INCREF: int = 85
let OP_RETURN_STRUCT: int = 87
let OP_RETURN: int = 88
let OP_CONCAT: int = 89
let OP_DUP: int = 5
let OP_ROUTE_HOP: int = 90


// ty_is_scalar reports whether a type is a scalar (so a struct of only scalars is multi-slot, not boxed).
fn ty_is_scalar(ty: ps.Ty) -> bool {
    match ty {
        case TyName(qual, name) {
            if qual != "" {
                return false
            }
            return name == "int" || name == "i64" || name == "i8" || name == "i16" || name == "i32" || name == "u8" || name == "u16" || name == "u32" || name == "u64" || name == "bool" || name == "float" || name == "f64" || name == "f32"
        }
        case _ {
            return false
        }
    }
}


// ty_is_array reports whether a type annotation is an array `[T]` (a move type, owned-droppable).
fn ty_is_array(ty: ps.Ty) -> bool {
    match ty {
        case TyArray(elem) {
            return true
        }
        case _ {
            return false
        }
    }
}


// ty_is_channel reports whether a type is `Channel<T>` — a refcounted HANDLE, so a channel `let`/param is
// owned/droppable (like an enum) and INCREFs when passed to a spawned task or another function.
fn ty_is_channel(ty: ps.Ty) -> bool {
    match ty {
        case TyGeneric(qual, name, args) {
            return name == "Channel"
        }
        case _ {
            return false
        }
    }
}


// param_is_erased_tparam reports whether param `p`'s type is a bare generic TYPE PARAMETER (`x: T` where T is
// one of the enclosing fn's `<...>` names). Such a value is ERASED — refcounted at run time if the concrete
// type is (string/enum/...), a no-op INCREF if scalar — so it INCREFs on consume but is NEVER dropped
// (over-retain, sound per OFI-009). Realized as local_str=true (INCREF via is_str_local_read) + droppable=false.
fn param_is_erased_tparam(p: ps.Param, generics: [ps.GenericParam]) -> bool {
    if p.ty.len() == 0 {
        return false
    }
    match p.ty[0] {
        case TyName(qual, name) {
            if qual != "" {
                return false
            }
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


// erased_tparam_name returns the type-parameter name a param is typed as (`x: T` -> "T"), or "" if the param
// is not a bare type parameter. Companion to param_is_erased_tparam. Implemented via param_is_erased_tparam +
// ty_key_name (both byte-identical on both backends) rather than returning a match-pattern-bound string from
// inside a loop — the latter is a construct the self-hosted C-emit backend doesn't clone (own_into_slot), an
// OFI-173 sibling that would break the C-emit reproduction fixed point.
fn erased_tparam_name(p: ps.Param, generics: [ps.GenericParam]) -> string {
    if param_is_erased_tparam(p, generics) {
        return ty_key_name(p.ty[0])
    }
    return ""
}


// str_starts_with reports whether `s` begins with `prefix`.
fn str_starts_with(s: string, prefix: string) -> bool {
    if s.len() < prefix.len() {
        return false
    }
    return byte_slice(s, 0, prefix.len()) == prefix
}


// parse_inst_types extracts the concrete type-argument names from a monomorphized instance key: "new_bag<int>"
// with fn "new_bag" -> ["int"]; "pair_age<Person_Person>" -> ["Person", "Person"] (reversing the "_" join that
// bounded_call_key/bounded_key produce). Used to bind a bounded generic fn's type params to concrete types.
fn parse_inst_types(key: string, fnname: string) -> [string] {
    var out: [string] = []
    let pre = fnname.len() + 1                      // skip "fnname<"
    if key.len() <= pre + 1 {
        return out
    }
    let inner = byte_slice(key, pre, key.len() - 1)  // strip trailing ">"
    let bs = inner.bytes()
    var cur = ""
    var i = 0
    loop {
        if i >= bs.len() {
            break
        }
        if int(bs[i]) == 95 {                        // '_'
            out.append(cur)
            cur = ""
        } else {
            cur = cur + byte_slice(inner, i, i + 1)
        }
        i = i + 1
    }
    out.append(cur)
    return out
}


// split_plus splits a "Hash+Eq" bound string into ["Hash", "Eq"] (the sg_bound encoding).
fn split_plus(s: string) -> [string] {
    var out: [string] = []
    if s == "" {
        return out
    }
    let bs = s.bytes()
    var cur = ""
    var i = 0
    loop {
        if i >= bs.len() {
            break
        }
        if int(bs[i]) == 43 {                    // '+'
            out.append(cur)
            cur = ""
        } else {
            cur = cur + byte_slice(s, i, i + 1)
        }
        i = i + 1
    }
    out.append(cur)
    return out
}


// ty_tparam_name_in returns the type name if `ty` is a bare (unqualified) type parameter listed in `names`,
// else "". Used with the erased-type-param name list a function body carries (its own generics plus, for a
// generic-struct method, the struct's type params — so `Bag.add(x: K)` sees K as erased).
fn ty_tparam_name_in(ty: ps.Ty, names: [string]) -> string {
    match ty {
        case TyName(qual, name) {
            if qual == "" && cg_index_of(names, name) >= 0 {
                return name
            }
            return ""
        }
        case _ {
            return ""
        }
    }
}


// ty_is_fn reports whether a type is a function type `fn(...) -> ...` — a first-class CLOSURE value, which is
// a refcounted heap object, so a fn-typed `let`/param is owned/droppable (dropped at every exit).
fn ty_is_fn(ty: ps.Ty) -> bool {
    match ty {
        case TyFn(params, ret) {
            return true
        }
        case _ {
            return false
        }
    }
}


// is_channel_call reports whether an expression is `channel(cap)` — the channel constructor, whose result is
// an owned refcounted handle (so its `let` binding is droppable).
fn is_channel_call(e: ps.Expr) -> bool {
    match e {
        case ECall(callee, args) {
            match callee.value {
                case EIdent(name) {
                    return name == "channel" && args.len() == 1
                }
                case _ {
                    return false
                }
            }
        }
        case _ {
            return false
        }
    }
}


// ty_is_string reports whether a type is `string` (a refcounted field that must INCREF when consumed).
fn ty_is_string(ty: ps.Ty) -> bool {
    match ty {
        case TyName(qual, name) {
            return qual == "" && name == "string"
        }
        case _ {
            return false
        }
    }
}


// StructTable holds every struct's layout (id = declaration order) so codegen can decide representation
// (all-scalar = multi-slot, else boxed), order construction fields, and resolve field indices.
struct StructTable {
    names: [string]            // struct id -> name
    f_owner: [int]             // flat field table: owning struct id
    f_name: [string]           // ...field name (in declaration order)
    f_scalar: [bool]           // ...is the field a scalar type?
    f_string: [bool]           // ...is the field a string (refcounted)?
    f_array: [bool]            // ...is the field an array `[T]`?
    f_struct: [int]            // ...struct id of the field's type if it is a struct, else -1
    f_elem: [int]              // ...for an array field: its element type code (struct sid / -3 str / -4 enum / -1)
    f_arrkind: [int]           // ...for an array field: its NEW_ARRAY element kind byte (AEK_*), else -1
    f_enum: [bool]             // ...is the field a known enum (a refcounted single Value — inline-packable)?
    f_kind: [int]              // ...for a scalar field: its num/render kind (int=0, sized 1..7, f32=8, f64=9, bool=10)
    f_tpname: [string]         // ...if the field's type is a bare type-param of the struct (`key: K`), its name; else ""
    f_elem_payload: [int]      // ...for a `[Option<Struct>]`/`[Result<Struct>]` array field: the payload struct
                               //   sid (so `case Some(e)` over `arr[i]` binds e as that struct), else -1
}


fn build_structs(decls: [ps.Decl]) -> StructTable {
    // Pass 1: collect every struct name so a field whose type is a struct declared LATER still resolves, and
    // every enum name so an array field `[SomeEnum]` classifies its element as refcounted (-4).
    var names: [string] = []
    var enames: [string] = []
    var n = 0
    loop {
        if n >= decls.len() {
            break
        }
        match decls[n] {
            case DStruct(name, generics, impls, fields, methods, kind) {
                names.append(name)
            }
            case DEnum(name, generics, impls, variants) {
                enames.append(name)
            }
            case _ {
            }
        }
        n = n + 1
    }
    enames.append("Option")
    enames.append("Result")
    // Pass 2: build the flat field table (classification needs all names known).
    var fo: [int] = []
    var fn_: [string] = []
    var fsc: [bool] = []
    var fst: [bool] = []
    var far: [bool] = []
    var fsd: [int] = []
    var fel: [int] = []
    var fak: [int] = []
    var fen: [bool] = []
    var fkind: [int] = []
    var ftp: [string] = []
    var fep: [int] = []
    var id = 0
    var i = 0
    loop {
        if i >= decls.len() {
            break
        }
        match decls[i] {
            case DStruct(name, generics, impls, fields, methods, kind) {
                var fi = 0
                loop {
                    if fi >= fields.len() {
                        break
                    }
                    let fty = fields[fi].ty
                    fo.append(id)
                    fn_.append(fields[fi].name)
                    fsc.append(ty_is_scalar(fty))
                    fst.append(ty_is_string(fty))
                    far.append(ty_is_array(fty))
                    fsd.append(ty_struct_id(fty, names))
                    fen.append(ty_enum_id(fty, enames) >= 0)
                    fkind.append(ty_scalar_kind(fty))
                    ftp.append(field_tpname(fty, generics))
                    fep.append(array_elem_enum_payload_sid(fty, names))
                    if ty_is_array(fty) {
                        fel.append(elem_type_code(elem_ty_of(fty), names, enames))
                        fak.append(array_elem_kind_from_ty(elem_ty_of(fty)))
                    } else {
                        fel.append(0 - 1)
                        fak.append(0 - 1)
                    }
                    fi = fi + 1
                }
                // A BOUNDED generic struct carries one HIDDEN WITNESS FIELD per (type-param, bound) — the
                // dictionary of that bound's methods for the concrete type argument (OFI-174). They follow the
                // declared fields (so declared field indices are unchanged) and are `Some(ref)` enums.
                var gwi = 0
                loop {
                    if gwi >= generics.len() {
                        break
                    }
                    var bwi = 0
                    loop {
                        if bwi >= generics[gwi].bounds.len() {
                            break
                        }
                        fo.append(id)
                        fn_.append("$wit")
                        fsc.append(false)
                        fst.append(false)
                        far.append(false)
                        fsd.append(0 - 1)
                        fen.append(true)           // a witness is a Some(method-ref) enum (refcounted single Value)
                        fkind.append(0)
                        fel.append(0 - 1)
                        fak.append(0 - 1)
                        ftp.append("")
                        fep.append(0 - 1)
                        bwi = bwi + 1
                    }
                    gwi = gwi + 1
                }
                id = id + 1
            }
            case _ {
            }
        }
        i = i + 1
    }
    return StructTable { names: names, f_owner: fo, f_name: fn_, f_scalar: fsc, f_string: fst, f_array: far, f_struct: fsd, f_elem: fel, f_arrkind: fak, f_enum: fen, f_kind: fkind, f_tpname: ftp, f_elem_payload: fep }
}


// field_tpname returns the name of a struct type-parameter if the field's type is exactly that bare type
// parameter (`key: K` in a struct declared `<K, V>` -> "K"), else "". Lets a bound-method call on a type-param
// field receiver (`e.key.eq(..)`) dispatch through the enclosing method's witness.
fn field_tpname(ty: ps.Ty, generics: [ps.GenericParam]) -> string {
    match ty {
        case TyName(qual, name) {
            if qual == "" {
                var i = 0
                loop {
                    if i >= generics.len() {
                        break
                    }
                    if generics[i].name == name {
                        return name
                    }
                    i = i + 1
                }
            }
            return ""
        }
        case _ {
            return ""
        }
    }
}


// ty_struct_id returns the struct id of a `[Ty]`-less type that names a known struct (a non-scalar,
// non-string `TyName`), or -1. Used to classify a struct field whose type is itself a struct.
fn ty_struct_id(ty: ps.Ty, names: [string]) -> int {
    if ty_is_scalar(ty) || ty_is_string(ty) {
        return -1
    }
    match ty {
        case TyName(qual, name) {
            return cg_index_of(names, name)
        }
        case _ {
            return -1
        }
    }
}


// ty_struct_id_g is the generic-aware struct-id lookup for a BINDING/value type: like ty_struct_id but a
// generic struct (`Box<Ty>`) resolves to its BASE struct id (field layout is the base; the instance id only
// rides a NEW_STRUCT operand). Used to classify a `case V(x: Box<Ty>)` binding so `x.value` resolves AND its
// refcounted field read INCREFs. NOT used for struct-FIELD classification, where a generic field must stay
// "refcounted single Value" (st_fstruct = -1) so reads of it INCREF.
fn ty_struct_id_g(ty: ps.Ty, names: [string]) -> int {
    match ty {
        case TyGeneric(qual, name, args) {
            return cg_index_of(names, name)
        }
        case _ {
            return ty_struct_id(ty, names)
        }
    }
}


// ty_enum_id returns the enum id a type names (a `TyName` or generic `Option<…>`/`Result<…>` whose base is a
// known enum), else -1. The qualifier is ignored (merged module enums share one table by name).
fn ty_enum_id(ty: ps.Ty, enum_names: [string]) -> int {
    match ty {
        case TyName(qual, name) {
            return cg_index_of(enum_names, name)
        }
        case TyGeneric(qual, name, args) {
            return cg_index_of(enum_names, name)
        }
        case _ {
            return -1
        }
    }
}


// elem_type_code classifies an array's ELEMENT type `[T]` -> `T` for per-slot tracking, the single source of
// truth shared by array params, array `let`s, and `case V(arr)` bindings: a struct element -> its sid (>=0),
// a string -> -3, an enum/refcounted single-Value element -> -4, anything else (scalar) -> -1. The -4 code
// makes `arr[i]` of an enum array INCREF when read into a new owner, like a string element.
// array_elem_enum_payload_sid returns the payload struct id of a `[Option<Struct>]` / `[Result<Struct>]` array
// type (the element is a generic enum whose first type-argument is a struct), or -1. Lets a `case Some(e)` over
// such an array element bind `e` as the concrete payload struct — nested-generic enum-payload typing (OFI-174).
fn array_elem_enum_payload_sid(fty: ps.Ty, struct_names: [string]) -> int {
    match fty {
        case TyArray(elem) {
            match elem.value {
                case TyGeneric(qual, name, args) {
                    if name == "Option" || name == "Result" {
                        if args.len() > 0 {
                            return ty_struct_id_g(args[0], struct_names)
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
    return 0 - 1
}


// ty_is_concrete_arg reports whether a generic type ARGUMENT is concrete (a scalar/string, an array, a known
// struct OR enum, or a nested generic) rather than an erased bare type-parameter (`K` / `V`). An enum arg
// (`Box<Expr>`, `Box<Ty>`) is concrete — a genuine monomorphized instance — so enum_names must be consulted.
fn ty_is_concrete_arg(ty: ps.Ty, struct_names: [string], enum_names: [string]) -> bool {
    match ty {
        case TyName(qual, name) {
            return ty_is_scalar(ty) || ty_is_string(ty) || cg_index_of(struct_names, name) >= 0 || cg_index_of(enum_names, name) >= 0
        }
        case _ {
            return true
        }
    }
}


// ty_args_all_concrete reports whether every type argument is concrete — so a generic-struct construction is a
// real monomorphized instance (`Map<string,[int]>`, `Box<Expr>`), not an erased one (`Bag<K>`, `MapEntry<K,V>`).
fn ty_args_all_concrete(args: [ps.Ty], struct_names: [string], enum_names: [string]) -> bool {
    var i = 0
    loop {
        if i >= args.len() {
            break
        }
        if ty_is_concrete_arg(args[i], struct_names, enum_names) == false {
            return false
        }
        i = i + 1
    }
    return true
}


fn elem_type_code(elem_ty: ps.Ty, struct_names: [string], enum_names: [string]) -> int {
    let sid = ty_struct_id_g(elem_ty, struct_names)   // generic-aware: a `[Box<Expr>]` element resolves to base Box
    if sid >= 0 {
        return sid
    }
    if ty_is_string(elem_ty) {
        return 0 - 3
    }
    if ty_enum_id(elem_ty, enum_names) >= 0 {
        return 0 - 4
    }
    return 0 - 1
}


// EnumTable holds every enum's variants so codegen can resolve a variant name to (enum_id, tag, arity) for
// NEW_ENUM construction and match dispatch. User enums are numbered in declaration order (0..U-1, matching
// the checker), then the prelude Option (id U) and Result (id U+1) are appended — the self-hosted parser
// never sees the implicit prelude enum decls, so codegen injects them to keep enum ids byte-identical.
struct EnumTable {
    e_names: [string]          // enum id -> name
    v_owner: [int]             // flat variant table: owning enum id
    v_name: [string]           // ...variant name
    v_tag: [int]               // ...tag (index within its enum)
    v_arity: [int]             // ...payload field count
    vf_var: [int]              // flat payload-field table: owning flat-variant index
    vf_string: [bool]          // ...is the field a string (refcounted)?
    vf_struct: [int]           // ...struct id of the field's type if a struct, else -1
    vf_array: [bool]           // ...is the field an array `[T]`?
    vf_elem: [int]             // ...for an array field: its element type code (struct sid / -3 str / -4 enum / -1)
    vf_enum: [bool]            // ...is the field an enum (a refcounted single Value — INCREF on consume)?
    vf_kind: [int]             // ...for a scalar field: its numeric/render kind (int=0, f32=8, f64=9, bool=10, …)
}


// build_enums numbers user enums in declaration order then appends the prelude Option/Result, and classifies
// every variant's payload FIELD types (so a `case V(x)` binding gets the right INCREF/field-access discipline:
// a string binding INCREFs on consume, a struct binding resolves `.field`, an array binding resolves `[i]`).
// Generic payloads (`Option<T>`/`Result<T>`'s erased `T`) are left unclassified — their concrete refcounting
// needs scrutinee type inference (a known gap; see OFI-163).
fn build_enums(decls: [ps.Decl], structs: StructTable) -> EnumTable {
    // Pre-pass: collect every user enum name (plus the prelude Option/Result) so an array field `[SomeEnum]`
    // whose element enum is declared LATER still classifies as a refcounted element (-4).
    var enames: [string] = []
    var pn = 0
    loop {
        if pn >= decls.len() {
            break
        }
        match decls[pn] {
            case DEnum(name, generics, impls, variants) {
                enames.append(name)
            }
            case _ {
            }
        }
        pn = pn + 1
    }
    enames.append("Option")
    enames.append("Result")
    var en: [string] = []
    var vo: [int] = []
    var vn: [string] = []
    var vt: [int] = []
    var va: [int] = []
    var fv: [int] = []
    var fs: [bool] = []
    var fd: [int] = []
    var fa: [bool] = []
    var fe: [int] = []
    var fn2: [bool] = []
    var fk: [int] = []
    var i = 0
    loop {
        if i >= decls.len() {
            break
        }
        match decls[i] {
            case DEnum(name, generics, impls, variants) {
                let id = en.len()
                en.append(name)
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
                        fv.append(vflat)
                        fs.append(ty_is_string(fty))
                        fd.append(ty_struct_id_g(fty, structs.names))   // generic-aware: a Box<T> binding resolves to base Box
                        fa.append(ty_is_array(fty))
                        fn2.append(ty_enum_id(fty, enames) >= 0)
                        fk.append(ty_scalar_kind(fty))                  // scalar render/num kind (float=9, bool=10, …)
                        if ty_is_array(fty) {
                            fe.append(elem_type_code(elem_ty_of(fty), structs.names, enames))
                        } else {
                            fe.append(0 - 1)
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
    // Append the prelude enums the parser never sees, at the ids that continue after the user enums
    // (Option before Result; Some/Ok = tag 0, None/Err = tag 1 — confirmed against stage-0). A program MAY
    // redeclare `enum Option`/`Result` (a self-contained test often does); stage-0 then uses ITS OWN as the
    // prelude enum rather than adding a duplicate, so skip a prelude enum the user already declared.
    if cg_index_of(en, "Option") < 0 {
        let opt = en.len()
        en.append("Option")
        vo.append(opt)
        vn.append("Some")
        vt.append(0)
        va.append(1)
        vo.append(opt)
        vn.append("None")
        vt.append(1)
        va.append(0)
    }
    if cg_index_of(en, "Result") < 0 {
        let res = en.len()
        en.append("Result")
        vo.append(res)
        vn.append("Ok")
        vt.append(0)
        va.append(1)
        vo.append(res)
        vn.append("Err")
        vt.append(1)
        va.append(1)
    }
    // The prelude payloads (Some/Ok/Err's `T`/`E`) are generic — left out of the field table (OFI-163).
    return EnumTable { e_names: en, v_owner: vo, v_name: vn, v_tag: vt, v_arity: va, vf_var: fv, vf_string: fs, vf_struct: fd, vf_array: fa, vf_elem: fe, vf_enum: fn2, vf_kind: fk }
}


// variant_index_of returns the flat variant-table index for a variant name, or -1 if `name` is not a known
// variant. (Same-named variants across enums would need scrutinee-directed resolution — OFI-073; a
// program-wide unique-name lookup is sufficient for the corpus.)
fn variant_index_of(et: EnumTable, name: string) -> int {
    var i = 0
    loop {
        if i >= et.v_name.len() {
            break
        }
        if et.v_name[i] == name {
            return i
        }
        i = i + 1
    }
    return -1
}


// numeric_typename_kind returns the CONV target-kind for a numeric type-name used as a conversion call
// (`int(x)`, `i32(x)`, `u8(x)`, `f64(x)`), or -1 if `name` is not a numeric typename. Mirrors
// is_numeric_typename + the checker's target num_kind (NB: `float`/`bool` are NOT conversion typenames).
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


// wrapping_opcode maps a built-in wrapping-arithmetic name to its dedicated opcode (OFI-041), else -1. These
// are lowered inline as `<a> <b> WRAP_* <num_kind>` (NOT a CALL) — the two-operand wrapping ops src/codegen.c
// special-cases before the generic call.
fn wrapping_opcode(name: string) -> int {
    if name == "wrapping_add" {
        return 21
    }
    if name == "wrapping_sub" {
        return 22
    }
    if name == "wrapping_mul" {
        return 23
    }
    return 0 - 1
}


// cextern_index maps a hosted `extern "c"` symbol to its registry index (the CALL_C operand) — the position
// in src/cextern.c's g_sigs for the DEFAULT build (no NET/SQLITE, which are #ifdef-gated and append AFTER
// these). A name not in the hosted registry returns -1 (a direct-extern, OFI-167 — native-only, never a
// CALL_C). This table MUST stay in lockstep with g_sigs' order or the FFI dispatch mis-indexes.
fn cextern_index(name: string) -> int {
    if name == "sin" {
        return 0
    }
    if name == "cos" {
        return 1
    }
    if name == "tan" {
        return 2
    }
    if name == "asin" {
        return 3
    }
    if name == "acos" {
        return 4
    }
    if name == "atan" {
        return 5
    }
    if name == "atan2" {
        return 6
    }
    if name == "exp" {
        return 7
    }
    if name == "log" {
        return 8
    }
    if name == "log2" {
        return 9
    }
    if name == "log10" {
        return 10
    }
    if name == "sinh" {
        return 11
    }
    if name == "cosh" {
        return 12
    }
    if name == "tanh" {
        return 13
    }
    if name == "cbrt" {
        return 14
    }
    if name == "trunc" {
        return 15
    }
    if name == "hypot" {
        return 16
    }
    if name == "fmod" {
        return 17
    }
    if name == "cvec2_len" {
        return 18
    }
    if name == "cvec2_dot" {
        return 19
    }
    if name == "cvec2_add" {
        return 20
    }
    if name == "cvec2_scale" {
        return 21
    }
    if name == "strlen" {
        return 22
    }
    if name == "strncmp" {
        return 23
    }
    if name == "fopen" {
        return 24
    }
    if name == "fread" {
        return 25
    }
    if name == "fwrite" {
        return 26
    }
    if name == "fclose" {
        return 27
    }
    return 0 - 1
}




// native_id_for_name maps a built-in free-function name to its NATIVE_* id (a CALL_NATIVE operand), mirroring
// src/builtin.c. Returns -1 for a non-builtin (a user/variant call). Core (default-build) builtins only;
// graphics/network natives are added when those build flavours are differenced.
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
    return -1
}


// native_ret_kind classifies a builtin's OWNED return type the way expr_ret_kind does for user calls: -3 a
// string, -2 an array, -1 a scalar/float/unit (not droppable), or -4 = `name` is not a builtin at all.
fn native_ret_kind(name: string) -> int {
    if name == "read_line" || name == "read_file" || name == "env" || name == "from_char_code" || name == "byte_slice" || name == "concat" {
        return -3
    }
    if name == "args" {
        return -2
    }
    if native_id_for_name(name) >= 0 {
        return -1
    }
    return 0 - 4
}


// GlobalConsts holds every top-level `let` as a folded literal — stage-0 inlines a module-level constant at
// each reference (`return TY_INT` -> `CONST (= 2)`), so codegen must too. Top-level lets are literal-valued
// (the checker requires it), so the value is captured as kind + int/string/bool/float.
struct GlobalConsts {
    names: [string]
    kind: [int]                // 0 int, 1 string, 2 bool, 3 float, -1 unknown
    ival: [int]
    sval: [string]
    bval: [bool]
    fval: [float]
}


fn build_globals(decls: [ps.Decl]) -> GlobalConsts {
    var names: [string] = []
    var kind: [int] = []
    var iv: [int] = []
    var sv: [string] = []
    var bv: [bool] = []
    var fv: [float] = []
    var i = 0
    loop {
        if i >= decls.len() {
            break
        }
        match decls[i] {
            case DLet(is_var, name, ty, value) {
                names.append(name)
                match value.value {
                    case EInt(v, _) {
                        kind.append(0)
                        iv.append(v)
                        sv.append("")
                        bv.append(false)
                        fv.append(0.0)
                    }
                    case EStr(parts) {
                        kind.append(1)
                        iv.append(0)
                        sv.append(const_str_of(parts))
                        bv.append(false)
                        fv.append(0.0)
                    }
                    case EBool(v) {
                        kind.append(2)
                        iv.append(0)
                        sv.append("")
                        bv.append(v)
                        fv.append(0.0)
                    }
                    case EFloat(v) {
                        kind.append(3)
                        iv.append(0)
                        sv.append("")
                        bv.append(false)
                        fv.append(v)
                    }
                    case _ {
                        kind.append(0 - 1)
                        iv.append(0)
                        sv.append("")
                        bv.append(false)
                        fv.append(0.0)
                    }
                }
            }
            case _ {
            }
        }
        i = i + 1
    }
    return GlobalConsts { names: names, kind: kind, ival: iv, sval: sv, bval: bv, fval: fv }
}


// const_str_of joins a constant string literal's text parts (a const string carries no interpolation holes).
fn const_str_of(parts: [ps.StrPart]) -> string {
    var s = ""
    var i = 0
    loop {
        if i >= parts.len() {
            break
        }
        s = s + parts[i].text
        i = i + 1
    }
    return s
}


// ty_key renders a type to a canonical (qualifier-agnostic) string — the identity of a generic-struct
// INSTANCE: `Box<Ty>` and `Box<Expr>` are distinct keys; `Box<int>` used twice is one key.
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
        case TyArray(elem) {
            return "[" + ty_key(elem.value) + "]"
        }
        case TyFn(params, ret) {
            return "fn"
        }
    }
}


// InstColl collects generic-struct INSTANTIATIONS in stage-0's monomorphization order: a PRE-ORDER walk of
// every function body in declaration order, registering each `Box<X>{…}` construction the FIRST time it is
// seen (mirrors struct_instance_id / check.c — the struct literal registers BEFORE its field values are
// visited). `snames` are the declared struct names, so a generic ENUM (`Option<int>`) is skipped.
struct InstColl {
    keys: [string]
    snames: [string]
    enames: [string]            // declared enum names — an enum type-arg (`Box<Expr>`) is a concrete instance
    bounded: [string]           // names of BOUNDED generic structs (Bag, Map) — erased of these use the base id


    fn register(mut self, ty: ps.Ty) {
        match ty {
            case TyGeneric(qual, name, args) {
                // Register a generic-struct construction as a monomorphized instance ONLY when every type
                // argument is CONCRETE (`Box<Expr>`, `Map<string,[int]>`). An ERASED construction — a bounded
                // struct's `Bag<K>` or a bounded-struct method's `MapEntry<K,V>` (a bare type-param argument) —
                // reuses the BASE layout and has no per-instantiation instance, so it is NOT registered here
                // (lit_struct_id resolves it to the base id) (OFI-174).
                if cg_index_of(self.snames, name) >= 0 {
                    if ty_args_all_concrete(args, self.snames, self.enames) {
                        let k = ty_key(ty)
                        if cg_index_of(self.keys, k) < 0 {
                            self.keys.append(k)
                        }
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


// bounded_struct_names returns the names of every struct with a BOUNDED type parameter — those carry hidden
// witness fields in the base and are not monomorphized to per-instantiation struct instances.
fn bounded_struct_names(decls: [ps.Decl]) -> [string] {
    var out: [string] = []
    var i = 0
    loop {
        if i >= decls.len() {
            break
        }
        match decls[i] {
            case DStruct(name, generics, impls, fields, methods, kind) {
                var gi = 0
                loop {
                    if gi >= generics.len() {
                        break
                    }
                    if generics[gi].bounds.len() > 0 {
                        out.append(name)
                    }
                    gi = gi + 1
                }
            }
            case _ {
            }
        }
        i = i + 1
    }
    return out
}


// build_struct_instances returns the generic-struct INSTANCE keys in stage-0's monomorphization order — each
// instance's runtime struct id is `declared_struct_count + its index here` (appended after the declared
// structs, which include the generic base `Box<T>` itself).
fn enum_decl_names(decls: [ps.Decl]) -> [string] {
    var out: [string] = []
    var i = 0
    loop {
        if i >= decls.len() {
            break
        }
        match decls[i] {
            case DEnum(name, generics, impls, variants) {
                out.append(name)
            }
            case _ {
            }
        }
        i = i + 1
    }
    out.append("Option")
    out.append("Result")
    return out
}


fn build_struct_instances(decls: [ps.Decl], snames: [string]) -> [string] {
    var c = InstColl { keys: [], snames: snames, enames: enum_decl_names(decls), bounded: bounded_struct_names(decls) }
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
    return clone_strs(c.keys)
}


// mono_arg_key returns the monomorphization key of a generic call's FIRST argument — the type it instantiates
// the bare type-param T to. The string need not equal stage-0's SemType int, only induce the SAME partition
// (the key is never printed). Tier-1: LITERAL args (int/sized/float/bool/string); a non-literal falls to a
// shared "k0" (variables/exprs — the Tier-1 corpus has none; general inference is Tier-2).
fn mono_arg_key(e: ps.Expr) -> string {
    match e {
        case EInt(v, kind) {
            return "k{kind}"
        }
        case EStr(parts) {
            return "str"
        }
        case EFloat(v) {
            return "k9"
        }
        case EBool(v) {
            return "k10"
        }
        case _ {
            return "k0"
        }
    }
}


// mono_ty_key derives a monomorphization key from an EXPECTED type — the annotation on a `let x: Option<int> =
// none_of()`. A return-type-inferred generic call (arity 0, or one whose type param appears only in the result)
// has no value argument to key off, so the binding of its sole type param comes from the expected type's first
// type-argument (Option<int> -> "int", Box<str> -> "str"). Falls back to the type's own name / "k0".
fn mono_ty_key(t: ps.Ty) -> string {
    match t {
        case TyGeneric(qual, name, args) {
            if args.len() > 0 {
                return ty_key_name(args[0])
            }
            return name
        }
        case TyName(qual, name) {
            return name
        }
        case _ {
            return "k0"
        }
    }
}


// ty_key_name renders a type as a stable one-token mono key (its head name; an array becomes "[elem]").
fn ty_key_name(t: ps.Ty) -> string {
    match t {
        case TyName(qual, name) {
            return name
        }
        case TyGeneric(qual, name, args) {
            return name
        }
        case TyArray(elem) {
            return "[{ty_key_name(elem.value)}]"
        }
        case _ {
            return "k0"
        }
    }
}


// ty_args_key renders a generic type's type-ARGUMENTS as a "_"-joined key (Bag<int> -> "int", Map<string,
// [int]> -> "string_[int]"), or "" for a non-generic type. Keys a generic-struct METHOD instance by its
// receiver's concrete type arguments (Bag.add on a Bag<int> -> "Bag.add<int>").
fn ty_args_key(ty: ps.Ty) -> string {
    match ty {
        case TyGeneric(qual, name, args) {
            var parts = ""
            var i = 0
            loop {
                if i >= args.len() {
                    break
                }
                let k = ty_key_name(args[i])
                if i == 0 {
                    parts = k
                } else {
                    parts = "{parts}_{k}"
                }
                i = i + 1
            }
            return parts
        }
        case _ {
            return ""
        }
    }
}


// GenFns lists every GENERIC free function: `names` (a call to one lowers to a monomorphized instance) and
// the parallel `pquals` (per-param qual string '0'/'1'/'2'). A '2' (move) param takes OWNERSHIP of an
// owning-temp arg (not masked); a '0'/'1' (Copy/borrow) erased-T param borrows it (kept + PICK + DROP_UNDER).
struct GenFns {
    names: [string]
    pquals: [string]
}


fn build_generic_fns(decls: [ps.Decl]) -> GenFns {
    var names: [string] = []
    var pquals: [string] = []
    var i = 0
    loop {
        if i >= decls.len() {
            break
        }
        match decls[i] {
            case DFn(f) {
                if f.generics.len() > 0 {
                    names.append(f.name)
                    var q = ""
                    var pi = 0
                    loop {
                        if pi >= f.params.len() {
                            break
                        }
                        q = q + "{f.params[pi].qual}"
                        pi = pi + 1
                    }
                    pquals.append(q)
                }
            }
            case _ {
            }
        }
        i = i + 1
    }
    return GenFns { names: names, pquals: pquals }
}


// WitInfo carries the interface + bounded-generic tables the witness codegen needs (OFI-174). All GLOBAL,
// built once from the decls and cloned into every Chunk. A bounded generic call builds one witness per
// (type-param, bound): a `Some(method-ref)` enum passed as a hidden LEADING arg; inside the body a bound-
// method call reads `GET_FIELD <method-index>` off that witness and dispatches with CALL_INDIRECT.
struct WitInfo {
    if_names: [string]      // interface id -> name
    ifm_iface: [int]        // interface-method table: owning interface index (parallel to ifm_name)
    ifm_name: [string]      // ...required method name, in declaration order within the interface
    ifm_owning: [bool]      // ...does the method return an OWNING value (string/array) — so a call to it via a
                            //   witness is an owning temp that a native-call arg must keep + PICK + DROP_UNDER
    gb_fn: [string]         // generic-fn bound table: fn name (one row per (type-param, bound))
    gb_tpname: [string]     // ...the type-parameter name
    gb_bound: [string]      // ...the bound interface name
    gb_argidx: [int]        // ...index of the first value param typed as this type-param (-1 = return-inferred)
    impl_struct: [string]   // struct-implements table: struct name (one row per implemented interface)
    impl_iface: [string]    // ...an interface it declares it implements
    sg_struct: [string]     // struct-generics table: struct name (one row per type parameter)
    sg_tparam: [string]     // ...the type-parameter name (so a method of a generic struct erases `K`/`V`)
    sg_bound: [string]      // ...that type-param's bound interfaces, joined by "+" ("" if none, "Copy" excluded)
    gret_fn: [string]       // generic-return table: a generic fn whose RETURN is a bare type-param T or [T]
    gret_arr: [bool]        // ...is the return `[T]` (true) or bare `T` (false)?
    gret_argidx: [int]      // ...the value-param index (typed T or [T]) whose concrete type the result takes
}


// param_tparam_index returns the index of the first value parameter whose type is exactly the bare type
// parameter `tpname` (so a call's concrete type argument for `tpname` is read off that argument), or -1.
fn param_tparam_index(params: [ps.Param], tpname: string) -> int {
    var i = 0
    loop {
        if i >= params.len() {
            break
        }
        if params[i].is_self == false && params[i].ty.len() > 0 {
            match params[i].ty[0] {
                case TyName(qual, name) {
                    if qual == "" && name == tpname {
                        return i
                    }
                }
                case _ {
                }
            }
        }
        i = i + 1
    }
    return 0 - 1
}


// ty_ret_is_owning reports whether a return type is an OWNING value (string / array) — a call yielding one is
// a fresh owned temporary a native-call argument must keep + PICK + DROP_UNDER.
fn ty_ret_is_owning(ret: [ps.Ty]) -> bool {
    if ret.len() == 0 {
        return false
    }
    return ty_is_string(ret[0]) || ty_is_array(ret[0])
}


// generic_has reports whether `name` is one of the type parameters in `generics`.
fn generic_has(generics: [ps.GenericParam], name: string) -> bool {
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


// ret_tparam_name returns the type-parameter name a return type IS — a bare `T` or an array `[T]` of a type
// parameter — else "" (a concrete or non-type-param return, handled by the ordinary fn_rets kind).
fn ret_tparam_name(ty: ps.Ty, generics: [ps.GenericParam]) -> string {
    match ty {
        case TyName(qual, name) {
            if qual == "" && generic_has(generics, name) {
                return name
            }
            return ""
        }
        case TyArray(elem) {
            match elem.value {
                case TyName(qual, name) {
                    if qual == "" && generic_has(generics, name) {
                        return name
                    }
                }
                case _ {
                }
            }
            return ""
        }
        case _ {
            return ""
        }
    }
}


// ret_is_array_tparam reports whether a return type is an ARRAY (`[T]`) rather than a bare type parameter.
fn ret_is_array_tparam(ty: ps.Ty) -> bool {
    match ty {
        case TyArray(elem) {
            return true
        }
        case _ {
            return false
        }
    }
}


// param_of_shape_index returns the index of the first value param typed as `tpname` (is_array=false) or as
// `[tpname]` (is_array=true) — the argument whose concrete type a generic result of that shape takes.
fn param_of_shape_index(params: [ps.Param], tpname: string, is_array: bool) -> int {
    var i = 0
    loop {
        if i >= params.len() {
            break
        }
        if params[i].is_self == false && params[i].ty.len() > 0 {
            if is_array {
                match params[i].ty[0] {
                    case TyArray(elem) {
                        match elem.value {
                            case TyName(qual, name) {
                                if qual == "" && name == tpname {
                                    return i
                                }
                            }
                            case _ {
                            }
                        }
                    }
                    case _ {
                    }
                }
            } else {
                match params[i].ty[0] {
                    case TyName(qual, name) {
                        if qual == "" && name == tpname {
                            return i
                        }
                    }
                    case _ {
                    }
                }
            }
        }
        i = i + 1
    }
    return 0 - 1
}


// build_wit_info collects every interface's method list and every generic free function's per-type-param
// bounds. The bound rows are ordered (type-param, then bound) exactly as stage-0 prepends witness params.
fn build_wit_info(decls: [ps.Decl]) -> WitInfo {
    var if_names: [string] = []
    var ifm_iface: [int] = []
    var ifm_name: [string] = []
    var ifm_owning: [bool] = []
    var gb_fn: [string] = []
    var gb_tpname: [string] = []
    var gb_bound: [string] = []
    var gb_argidx: [int] = []
    var impl_struct: [string] = []
    var impl_iface: [string] = []
    var sg_struct: [string] = []
    var sg_tparam: [string] = []
    var sg_bound: [string] = []
    var gret_fn: [string] = []
    var gret_arr: [bool] = []
    var gret_argidx: [int] = []
    var i = 0
    loop {
        if i >= decls.len() {
            break
        }
        match decls[i] {
            case DInterface(name, generics, methods) {
                let iid = if_names.len()
                if_names.append(name)
                var mi = 0
                loop {
                    if mi >= methods.len() {
                        break
                    }
                    ifm_iface.append(iid)
                    ifm_name.append(methods[mi].name)
                    ifm_owning.append(ty_ret_is_owning(methods[mi].ret))
                    mi = mi + 1
                }
            }
            case DStruct(name, generics, impls, fields, methods, kind) {
                var ii = 0
                loop {
                    if ii >= impls.len() {
                        break
                    }
                    impl_struct.append(name)
                    impl_iface.append(impls[ii])
                    ii = ii + 1
                }
                var gi = 0
                loop {
                    if gi >= generics.len() {
                        break
                    }
                    sg_struct.append(name)
                    sg_tparam.append(generics[gi].name)
                    var bs = ""
                    var bi = 0
                    loop {
                        if bi >= generics[gi].bounds.len() {
                            break
                        }
                        if bs == "" {
                            bs = generics[gi].bounds[bi]
                        } else {
                            bs = "{bs}+{generics[gi].bounds[bi]}"
                        }
                        bi = bi + 1
                    }
                    sg_bound.append(bs)
                    gi = gi + 1
                }
            }
            case DFn(f) {
                if f.generics.len() > 0 {
                    var gi = 0
                    loop {
                        if gi >= f.generics.len() {
                            break
                        }
                        let ai = param_tparam_index(f.params, f.generics[gi].name)
                        var bi = 0
                        loop {
                            if bi >= f.generics[gi].bounds.len() {
                                break
                            }
                            gb_fn.append(f.name)
                            gb_tpname.append(f.generics[gi].name)
                            gb_bound.append(f.generics[gi].bounds[bi])
                            gb_argidx.append(ai)
                            bi = bi + 1
                        }
                        gi = gi + 1
                    }
                    // Generic-RETURN shape (OFI-174): if the return is a bare type-param `T` or `[T]`, record the
                    // value-param of the same shape whose concrete type the result takes — so `let x = sort(words)`
                    // infers x:[string] and `let s = gtwice(f,"hi")` infers s:string (for STR_LEN on x[i]/.len()).
                    if f.ret.len() > 0 {
                        let rtp = ret_tparam_name(f.ret[0], f.generics)
                        if rtp != "" {
                            let ra = ret_is_array_tparam(f.ret[0])
                            let ai = param_of_shape_index(f.params, rtp, ra)
                            if ai >= 0 {
                                gret_fn.append(f.name)
                                gret_arr.append(ra)
                                gret_argidx.append(ai)
                            }
                        }
                    }
                }
            }
            case _ {
            }
        }
        i = i + 1
    }
    // Seed the PRELUDE interfaces (Hash/Eq/Ord) — they are built-in, not declared in the source, so the decl
    // walk never sees their method lists; a bounded generic over a prelude bound still needs them (OFI-174). A
    // user program that redeclares one (e.g. bounded_generic.em declares `Ord`) already has it, so skip.
    if cg_index_of(if_names, "Hash") < 0 {
        ifm_iface.append(if_names.len())
        ifm_name.append("hash")
        ifm_owning.append(false)
        if_names.append("Hash")
    }
    if cg_index_of(if_names, "Eq") < 0 {
        ifm_iface.append(if_names.len())
        ifm_name.append("eq")
        ifm_owning.append(false)
        if_names.append("Eq")
    }
    if cg_index_of(if_names, "Ord") < 0 {
        ifm_iface.append(if_names.len())
        ifm_name.append("compare")
        ifm_owning.append(false)
        if_names.append("Ord")
    }
    return WitInfo { if_names: if_names, ifm_iface: ifm_iface, ifm_name: ifm_name, ifm_owning: ifm_owning, gb_fn: gb_fn, gb_tpname: gb_tpname, gb_bound: gb_bound, gb_argidx: gb_argidx, impl_struct: impl_struct, impl_iface: impl_iface, sg_struct: sg_struct, sg_tparam: sg_tparam, sg_bound: sg_bound, gret_fn: gret_fn, gret_arr: gret_arr, gret_argidx: gret_argidx }
}


// FnInsts holds the collected generic-function instances: `keys` are full instance keys ("id<str>") in
// first-use pre-order (the dedup identity + numbering order), `bases` the parallel base fn names ("id").
struct FnInsts {
    keys: [string]
    bases: [string]
}


// FnInstColl walks call sites collecting generic-function instances (pre-order, first-use), mirroring InstColl.
// scope_type looks up a name's tracked concrete type (last binding wins, for shadowing), or "".
fn scope_type(snames: [string], stypes: [string], name: string) -> string {
    var i = snames.len() - 1
    loop {
        if i < 0 {
            break
        }
        if snames[i] == name {
            return stypes[i]
        }
        i = i - 1
    }
    return ""
}


// arg_type_name_scope is the pre-pass (no-Chunk) analogue of Chunk.arg_type_name: the concrete type NAME of an
// argument expression, using the let-binding scope tracker for identifiers. Must agree with arg_type_name so a
// bounded generic's instance key registered here matches the one resolved at the call site.
fn arg_type_name_scope(e: ps.Expr, snames: [string], stypes: [string]) -> string {
    match e {
        case EStructLit(ty, fields) {
            return ty_key_name(ty.value)
        }
        case EInt(v, kind) {
            return "int"
        }
        case EStr(parts) {
            return "string"
        }
        case EBool(v) {
            return "bool"
        }
        case EFloat(v) {
            return "float"
        }
        case EIdent(name) {
            return scope_type(snames, stypes, name)
        }
        case _ {
            return ""
        }
    }
}


struct FnInstColl {
    keys: [string]
    bases: [string]
    generic_fns: [string]
    gb_fn: [string]             // bounded-generic tables (parallel), so a bounded call keys by concrete type
    gb_tpname: [string]
    gb_bound: [string]
    gb_argidx: [int]
    snames: [string]            // let-binding scope: name -> concrete type (for keying identifier args)
    stypes: [string]
    styargs: [string]           // ...parallel: the binding's type-ARGUMENTS key (`b: Bag<int>` -> "int"), for
                                //   keying a generic-struct METHOD instance (`b.add(..)` -> "Bag.add<int>")


    fn register(mut self, name: string, argkey: string) {
        let k = "{name}<{argkey}>"
        if cg_index_of(self.keys, k) < 0 {
            self.keys.append(k)
            self.bases.append(name)
        }
    }


    // bounded_key builds a bounded generic call's instance key from its (type-param, bound) rows' determining
    // arguments — the pre-pass mirror of Chunk.bounded_call_key.
    fn bounded_key(self, name: string, args: [ps.Expr]) -> string {
        var parts = ""
        var first = true
        var gwi = 0
        loop {
            if gwi >= self.gb_fn.len() {
                break
            }
            if self.gb_fn[gwi] == name {
                var tn = ""
                let ai = self.gb_argidx[gwi]
                if ai >= 0 && ai < args.len() {
                    tn = arg_type_name_scope(args[ai], self.snames, self.stypes)
                }
                if first {
                    parts = tn
                    first = false
                } else {
                    parts = "{parts}_{tn}"
                }
            }
            gwi = gwi + 1
        }
        return parts
    }


    // bounded_ret_key builds a RETURN-type-inferred bounded generic call's key: the single concrete type
    // `tyname` (from the `let`'s annotation) repeated per (type-param, bound) row — matching bounded_call_key
    // when its rows read expected_key.
    fn bounded_ret_key(self, name: string, tyname: string) -> string {
        var parts = ""
        var first = true
        var gwi = 0
        loop {
            if gwi >= self.gb_fn.len() {
                break
            }
            if self.gb_fn[gwi] == name {
                if first {
                    parts = tyname
                    first = false
                } else {
                    parts = "{parts}_{tyname}"
                }
            }
            gwi = gwi + 1
        }
        return parts
    }


    fn walk_expr(mut self, e: ps.Expr) {
        match e {
            case ECall(callee, args) {
                match callee.value {
                    case EIdent(name) {
                        if cg_index_of(self.gb_fn, name) >= 0 && args.len() > 0 {
                            // a BOUNDED generic call keys by concrete type(s); a 0-arg (return-inferred) one is
                            // registered in walk_stmt from the `let` annotation instead.
                            self.register(name, self.bounded_key(name, args))
                        } else if cg_index_of(self.generic_fns, name) >= 0 && args.len() > 0 {
                            self.register(name, mono_arg_key(args[0]))   // register BEFORE args (pre-order)
                        }
                    }
                    case EGet(obj, mname) {
                        // A METHOD call on a generic-struct instance (`b.add(..)` with b: Bag<int>) monomorphizes
                        // to `Struct.mname<typeargs>` — registered in first-use order, interleaved with the free
                        // instances, matching stage-0's numbering (OFI-174).
                        match obj.value {
                            case EIdent(rname) {
                                let rty = scope_type(self.snames, self.stypes, rname)
                                let rargs = scope_type(self.snames, self.styargs, rname)
                                if rty != "" && rargs != "" {
                                    self.register("{rty}.{mname}", rargs)
                                }
                            }
                            case _ {
                            }
                        }
                    }
                    case _ {
                    }
                }
                self.walk_expr(callee.value)
                self.walk_args(args)
            }
            case EUnary(op, operand) {
                self.walk_expr(operand.value)
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
                self.walk_body(body)
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
            case SLet(v, n, ty, value) {
                // A RETURN-type-inferred generic call — `let x: Option<int> = none_of()` — has no value arg
                // to key off, so its instance is registered from the annotation's type-arg (pre-order, before
                // the value's own nested calls), exactly where stage-0's inference monomorphizes it.
                if ty.len() > 0 {
                    match value.value {
                        case ECall(callee, cargs) {
                            match callee.value {
                                case EIdent(name) {
                                    if cargs.len() == 0 && cg_index_of(self.generic_fns, name) >= 0 {
                                        if cg_index_of(self.gb_fn, name) >= 0 {
                                            // a BOUNDED return-inferred generic (`var b: Bag<int> = new_bag()`):
                                            // key by the annotation's type-arg, repeated per (type-param, bound).
                                            self.register(name, self.bounded_ret_key(name, mono_ty_key(ty[0])))
                                        } else {
                                            self.register(name, mono_ty_key(ty[0]))
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
                self.walk_expr(value.value)
                // Track this binding's concrete type (annotation first, else inferred from the initialiser) so a
                // later bounded generic call can key an identifier argument by its type; and its type-ARGUMENTS
                // (`b: Bag<int>` -> "int") so a method call on it keys a generic-struct method instance.
                var bt = ""
                var bta = ""
                if ty.len() > 0 {
                    bt = ty_key_name(ty[0])
                    bta = ty_args_key(ty[0])
                } else {
                    bt = arg_type_name_scope(value.value, self.snames, self.stypes)
                }
                self.snames.append(n)
                self.stypes.append(bt)
                self.styargs.append(bta)
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
            case SSpawn(call) {
                self.walk_expr(call.value)
            }
            case SNursery(body, line) {
                self.walk_body(body)
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
}


// build_fn_instances collects every generic-function instantiation in the program, in first-use pre-order
// (walking declared fns + methods in decl order) — the fn analogue of build_struct_instances. Instance i is
// numbered fn_names.len() + total_lambdas + i (appended after declared fns AND lifted lambdas).
fn build_fn_instances(decls: [ps.Decl], generic_fns: [string], wit: WitInfo) -> FnInsts {
    var c = FnInstColl { keys: [], bases: [], generic_fns: generic_fns, gb_fn: clone_strs(wit.gb_fn), gb_tpname: clone_strs(wit.gb_tpname), gb_bound: clone_strs(wit.gb_bound), gb_argidx: clone_ints(wit.gb_argidx), snames: [], stypes: [], styargs: [] }
    var i = 0
    loop {
        if i >= decls.len() {
            break
        }
        match decls[i] {
            case DFn(f) {
                if f.has_body {
                    c.snames = []       // per-function let-binding scope (for keying identifier args by type)
                    c.stypes = []
                    c.styargs = []
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
                        c.snames = []
                        c.stypes = []
                        c.styargs = []
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
    return FnInsts { keys: clone_strs(c.keys), bases: clone_strs(c.bases) }
}


// string_method_op maps a built-in string method to its single opcode (`.len()` -> STR_LEN,
// `.bytes()` -> STR_BYTES), or -1 if not a built-in single-opcode string method.
fn string_method_op(mname: string) -> int {
    if mname == "len" {
        return OP_STR_LEN
    }
    if mname == "bytes" {
        return OP_STR_BYTES
    }
    if mname == "chars" {
        return OP_STR_CHARS
    }
    if mname == "char_count" {
        return OP_STR_CHAR_COUNT
    }
    return 0 - 1
}


fn is_array_lit(e: ps.Expr) -> bool {
    match e {
        case EArray(elems, lines) {
            return true
        }
        case _ {
            return false
        }
    }
}


// is_owning_temp reports whether an expression produces an OWNING TEMPORARY (a fresh owned value the caller
// must release) rather than a borrowed place — a call result or a struct construction, or a field extracted
// from one. A field READ of an owning temp uses GET_FIELD_OWNED (extract + drop the receiver box), where a
// borrowed place (a local) uses plain GET_FIELD.
fn is_owning_temp(e: ps.Expr) -> bool {
    match e {
        case ECall(callee, args) {
            return true
        }
        case EStructLit(ty, fields) {
            return true
        }
        case EIndex(object, index) {
            return true                          // `arr[i]` materialises a fresh owned element copy
        }
        case EGet(object, name) {
            return is_owning_temp(object.value)
        }
        case _ {
            return false
        }
    }
}


// is_call_expr reports whether an expression is a call. A call that returns an all-scalar struct leaves it
// MULTI-SLOT (RETURN_STRUCT spread), so a consumer needing one boxed value (a method receiver, a struct
// field value) must BOX_STRUCT the raw return slots first.
fn is_call_expr(e: ps.Expr) -> bool {
    match e {
        case ECall(callee, args) {
            return true
        }
        case _ {
            return false
        }
    }
}


// array_lit_is_empty reports whether an expression is the EMPTY array literal `[]` (which carries no element
// to infer the ArrayElemKind from, so the kind must come from the declared `[T]` type instead).
fn array_lit_is_empty(e: ps.Expr) -> bool {
    match e {
        case EArray(elems, lines) {
            return elems.len() == 0
        }
        case _ {
            return false
        }
    }
}


// elem_ty_of unwraps an array type `[T]` to its element `T`; a non-array type is returned unchanged.
fn elem_ty_of(ty: ps.Ty) -> ps.Ty {
    match ty {
        case TyArray(elem) {
            return elem.value
        }
        case _ {
            return ty
        }
    }
}


// ty_scalar_kind maps a SCALAR type name to its numeric/render kind (the checker's int_kind + bool=10):
// int/i64 -> 0, i8..u64 -> 1..7, f32 -> 8, float/f64 -> 9, bool -> 10. Non-scalar (or unknown) -> 0 (the
// default the codegen falls back to). Feeds the TO_STRING interpolation render kind (and, later, binary
// num_kind for sized/float arithmetic).
fn ty_scalar_kind(ty: ps.Ty) -> int {
    match ty {
        case TyName(qual, name) {
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
            if name == "float" || name == "f64" {
                return 9
            }
            if name == "bool" {
                return 10
            }
            return 0
        }
        case _ {
            return 0
        }
    }
}


// aek_to_render_kind maps an ArrayElemKind byte (value.h AEK_*) to the int_kind/render kind: an i64 array
// element renders as int (0), sized ints keep their kind, f32->8, f64->9, bool->10. Lets an interpolation
// hole `{arr[i]}` of a scalar array render with the element's width.
fn aek_to_render_kind(aek: int) -> int {
    if aek == 9 {
        return 8                             // AEK_F32 -> render f32
    }
    if aek == 10 {
        return 9                             // AEK_F64 -> render f64
    }
    if aek == 11 {
        return 10                            // AEK_BOOL -> render bool
    }
    if aek == 4 {
        return 0                             // AEK_I64 -> render int
    }
    if aek >= 1 && aek <= 3 {
        return aek                           // AEK_I8/I16/I32 -> render 1/2/3
    }
    if aek >= 5 && aek <= 8 {
        return aek - 1                       // AEK_U8..U64 -> render 4..7
    }
    return 0
}


// array_elem_kind_from_ty maps an element type `T` (of an array annotation `[T]`) to its runtime
// ArrayElemKind byte — the table the VM/native packed-array representation uses (see value.h AEK_*).
fn array_elem_kind_from_ty(ty: ps.Ty) -> int {
    match ty {
        case TyName(qual, name) {
            if qual != "" {
                return 0                         // a module-qualified (struct) element -> boxed
            }
            if name == "string" {
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
            if name == "int" || name == "i64" {
                return 4
            }
            if name == "u8" {
                return 5
            }
            if name == "u16" {
                return 6
            }
            if name == "u32" {
                return 7
            }
            if name == "u64" {
                return 8
            }
            if name == "f32" {
                return 9
            }
            if name == "float" || name == "f64" {
                return 10
            }
            if name == "bool" {
                return 11
            }
            return 0                             // a named (struct) element -> boxed
        }
        case _ {
            return 0                             // a nested array `[[T]]` element -> boxed
        }
    }
}


fn clone_ints(xs: [int]) -> [int] {
    var out: [int] = []
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


fn clone_floats(xs: [float]) -> [float] {
    var out: [float] = []
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


fn clone_bools(xs: [bool]) -> [bool] {
    var out: [bool] = []
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


// binop_to_opcode maps a parser binop_id (1..18) to its arithmetic/comparison/bitwise opcode.
// (Logical &&/|| — ids 12/13 — short-circuit via jumps and are handled separately, not here.)
fn binop_to_opcode(id: int) -> int {
    if id == 1 { return 8 }          // +  ADD
    if id == 2 { return 9 }          // -  SUB
    if id == 3 { return 10 }         // *  MUL
    if id == 4 { return 11 }         // /  DIV
    if id == 5 { return 12 }         // %  MOD
    if id == 6 { return 26 }         // <  LT
    if id == 7 { return 27 }         // <= LE
    if id == 8 { return 28 }         // >  GT
    if id == 9 { return 29 }         // >= GE
    if id == 10 { return 24 }        // == EQ
    if id == 11 { return 25 }        // != NEQ
    if id == 14 { return 15 }        // &  BITAND
    if id == 15 { return 16 }        // |  BITOR
    if id == 16 { return 17 }        // ^  BITXOR
    if id == 17 { return 19 }        // << SHL
    if id == 18 { return 20 }        // >> SHR
    return -1
}


fn cg_index_of(xs: [string], v: string) -> int {
    var i = 0
    loop {
        if i >= xs.len() {
            break
        }
        if xs[i] == v {
            return i
        }
        i = i + 1
    }
    return -1
}


// op_names: the mnemonic of each opcode, in enum order (opcode.h EMBER_OPCODES). Index = the opcode byte.
fn op_names() -> [string] {
    return ["CONST", "STRING", "TRUE", "FALSE", "POP", "DUP", "GET_LOCAL", "SET_LOCAL", "ADD", "SUB",
        "MUL", "DIV", "MOD", "NEG", "NOT", "BITAND", "BITOR", "BITXOR", "BITNOT", "SHL", "SHR",
        "WRAP_ADD", "WRAP_SUB", "WRAP_MUL", "EQ", "NEQ", "LT", "LE", "GT", "GE", "JUMP", "JUMP_IF_FALSE",
        "LOOP", "FOR_RANGE", "FOR_ARRAY", "CALL", "CALL_NATIVE", "CALL_C", "CALL_INDIRECT", "MAKE_DYN",
        "CALL_DYN", "MAKE_CLOSURE", "CALL_CLOSURE", "NEW_STRUCT", "NEW_ENUM", "GET_FIELD",
        "GET_FIELD_OWNED", "DROP_UNDER", "PICK", "NEW_STRUCT_ARRAY", "UNBOX_STRUCT", "UNBOX_STRUCT_BORROW",
        "BOX_STRUCT", "SET_FIELD", "GET_TAG", "NEW_ARRAY", "INDEX", "SET_INDEX", "ARRAY_LEN",
        "ARRAY_APPEND", "ARRAY_POP", "ARRAY_REMOVE_AT", "SLICE", "SLICE_COPY", "STR_LEN", "STR_CHARS",
        "STR_CHAR_COUNT", "STR_BYTES", "STR_SPLIT", "STR_PARSE_INT", "INT_TO_FLOAT", "FLOAT_TO_INT",
        "CONV", "CLOCK", "TO_STRING", "NURSERY_BEGIN", "CONTRACT_CHECK", "SPAWN", "NURSERY_END",
        "CHANNEL_NEW", "SEND", "RECV", "TRY_RECV", "CLOSE", "DROP", "INCREF", "RELEASE", "RETURN_STRUCT",
        "RETURN", "CONCAT", "ROUTE_HOP"]
}


// The operand-kind spec per opcode, flat-encoded (generated from opcode.h's OPS rows): op_kstart[op] is
// the start index into op_kflat, op_kcount[op] the number of operands. Each op_kflat entry is an OPK_*.
fn op_kstart() -> [int] {
    return [0, 1, 2, 2, 2, 2, 2, 3, 4, 5, 6, 7, 8, 9, 10, 10, 10, 10, 10, 11, 12, 13, 14, 15, 16, 16, 16,
        17, 18, 19, 20, 21, 22, 23, 26, 31, 33, 35, 37, 38, 38, 40, 42, 43, 45, 48, 49, 50, 50, 51, 53,
        54, 55, 56, 57, 57, 59, 59, 59, 59, 59, 59, 59, 59, 59, 59, 59, 59, 59, 59, 62, 62, 62, 63, 63,
        64, 64, 65, 67, 67, 67, 67, 70, 73, 73, 74, 74, 74, 75, 75, 75]
}


fn op_kcount() -> [int] {
    return [1, 1, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 0, 0, 1, 1, 1, 1, 1,
        1, 1, 3, 5, 2, 2, 2, 1, 0, 2, 2, 1, 2, 3, 1, 1, 0, 1, 2, 1, 1, 1, 1, 0, 2, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 3, 0, 0, 1, 0, 1, 0, 1, 2, 0, 0, 0, 3, 3, 0, 1, 0, 0, 1, 0, 0, 0]
}


fn op_kflat() -> [int] {
    return [4, 4, 4, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3, 3, 3, 4, 4, 3, 4, 4, 4, 4, 3,
        4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 0, 4, 4, 4, 0,
        0, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4]
}


// A Chunk is one function's compiled body: the bytecode bytes, a parallel per-byte source line, and the
// constant + string pools that CONST / STRING index. (A constant is an int or a float — parallel arrays
// keyed by const_is_float, since Ember has no heterogeneous list.)
struct Chunk {
    code: [int]                 // bytecode bytes (0..255)
    lines: [int]                // source line of the instruction starting at each byte (parallel to code)
    const_is_float: [bool]
    const_int: [int]
    const_float: [float]
    strings: [string]
    locals: [string]            // codegen scratch: slot -> binding name (the stack-slot table)
    local_str: [bool]           // ...is slot a string (CONCAT detection + INCREF on a consumed read)?
    local_drop: [bool]          // ...is slot a droppable owned value (string, or an owned boxed-struct let)?
    cur_line: int               // codegen scratch: line of the node currently being lowered
    fn_names: [string]          // codegen scratch: top-level fn names in definition order (CALL index)
    fn_ret_str: [bool]          // ...parallel: does fn #i return a string?
    fn_ret_arr: [bool]          // ...parallel: does fn #i return an array?
    fn_ret_elem: [int]          // ...parallel: for an array-returning fn #i, its element type code, else -1
    fn_ret_sid: [int]           // ...parallel: struct id fn #i returns (else -1)
    fn_ret_enum: [bool]         // ...parallel: does fn #i return an enum?
    fn_ret_kind: [int]          // ...parallel: fn #i's return scalar kind (int=0, sized 1..7, f32/f64=8/9, bool=10)
    ext_names: [string]         // every `extern "c"` fn name (parallel to ext_kinds/ext_pquals)
    ext_kinds: [int]            // ...its DECLARED return scalar kind, for an extern call's render/num width
    ext_pquals: [string]        // ...per-param qual string ('0'/'1'/'2'): a '2' (move) Ptr arg is move-consumed
    lambda_base: int            // fn-table index of THIS function's first lifted lambda (declared fns come first)
    lifted: [LambdaSpec]        // lambdas encountered in THIS function, in source order (compiled after decls)
    generic_fns: [string]       // names of generic free fns — a call to one lowers to a monomorphized instance
    generic_pquals: [string]    // ...parallel: each generic fn's per-param qual string ('2' move = arg not masked)
    fn_inst_keys: [string]      // every generic instance key ("id<str>") in order; slot = inst_base + index
    inst_base: int              // fn-table index of the FIRST instance (= fn_names.len() + total lifted lambdas)
    cont_targets: [int]         // loop-context stack: each enclosing loop's continue target (its start)
    loop_bases: [int]           // ...and each loop's local count at body entry (break/continue unwind to it)
    break_jumps: [int]          // flat list of pending break-JUMP operand positions (per-loop slice)
    break_bases: [int]          // loop-context stack: each loop's start index into break_jumps
    slot_struct: [int]          // per slot: struct id if this is a struct binding's BASE slot, else -1
    slot_boxed: [bool]          // ...and is that struct binding BOXED (else multi-slot)?
    slot_array: [bool]          // ...is this slot an array binding (so `.len()`/`.append()` are array ops)?
    slot_elem: [int]            // ...for an array binding: its ELEMENT type code (struct sid, -3 string, else -1)
    slot_kind: [int]            // ...for a SCALAR binding: its numeric/render kind (int=0, sized 1..7, f32=8, f64=9, bool=10)
    cur_return_span: int        // >0 if this function returns an all-scalar struct (RETURN_STRUCT span)
    cur_fn_name: string         // this function's own name (for synthesizing contract-violation messages)
    fn_ens_e: [ps.Expr]         // this function's `ensures` predicate exprs (checked at every return)
    fn_ens_l: [int]             // ...parallel: each clause's source line (for codegen attribution)
    ret_kind: int               // the return type's scalar kind (for the temporary `result` binding's slot_kind)
    st_names: [string]          // the struct table (cloned): struct id -> name
    st_fowner: [int]            // ...flat field table: owning struct id
    st_fname: [string]          // ...field name
    st_fscalar: [bool]          // ...field scalar?
    st_fstring: [bool]          // ...field string (refcounted)?
    st_farray: [bool]           // ...field array `[T]`?
    st_fstruct: [int]           // ...field's struct id (else -1)
    st_felem: [int]             // ...for an array field: its element type code (struct sid / -3 / -4 / -1)
    st_farrkind: [int]          // ...for an array field: its NEW_ARRAY element kind byte (AEK_*), else -1
    st_fenum: [bool]            // ...is the field a known enum (a refcounted single Value)?
    st_fkind: [int]             // ...for a scalar field: its num/render kind (int=0, sized 1..7, f32=8, f64=9, bool=10)
    st_ftpname: [string]        // ...if the field's type is a bare struct type-param (`key: K`), its name; else ""
    st_felem_payload: [int]      // ...for a [Option<Struct>] array field: the payload struct sid (for case Some(e))
    inst_keys: [string]         // generic-struct INSTANCE keys (cloned): id = st_names.len() + index here
    et_names: [string]          // the enum table (cloned): enum id -> name
    ev_owner: [int]             // ...flat variant table: owning enum id
    ev_name: [string]           // ...variant name
    ev_tag: [int]               // ...variant tag
    ev_arity: [int]             // ...variant payload field count
    ev_fvar: [int]              // ...flat payload-field table: owning flat-variant index
    ev_fstring: [bool]          // ...is the payload field a string (refcounted)?
    ev_fstruct: [int]           // ...struct id of the payload field's type, else -1
    ev_farray: [bool]           // ...is the payload field an array?
    ev_felem: [int]             // ...for an array payload field: its element type code (sid / -3 / -4 / -1)
    ev_fenum: [bool]            // ...is the payload field an enum (refcounted single Value)?
    ev_fkind: [int]             // ...for a scalar payload field: its numeric/render kind (f32=8, f64=9, bool=10, …)
    gc_names: [string]          // the global-constant table (cloned): name -> folded literal
    gc_kind: [int]              // ...0 int, 1 string, 2 bool, 3 float
    gc_ival: [int]
    gc_sval: [string]
    gc_bval: [bool]
    gc_fval: [float]
    expected_key: string        // consume-once: the annotation-derived mono key ("int") for a RETURN-type-inferred
                                //   generic call in `let x: Option<int> = none_of()` — no value arg gives the key
    // ---- Witness / bounded-generic tables (OFI-174) ----
    if_names: [string]          // interface id -> name (GLOBAL, cloned)
    ifm_iface: [int]            // interface-method table: owning interface index (parallel to ifm_name)
    ifm_name: [string]          // ...required method name, in interface declaration order
    ifm_owning: [bool]          // ...does the method return an owning value (string/array)?
    gb_fn: [string]             // generic-fn bound table: fn name (one row per (type-param, bound), GLOBAL)
    gb_tpname: [string]         // ...type-parameter name
    gb_bound: [string]          // ...bound interface name
    gb_argidx: [int]            // ...value-arg index determining this type-param's concrete type (-1 = from return)
    impl_struct: [string]       // struct-implements table (GLOBAL): struct name -> interface it implements
    impl_iface: [string]        // ...parallel: the interface name
    sg_struct: [string]         // struct-generics table (GLOBAL): struct name -> a type-param name
    sg_tparam: [string]         // ...parallel: the type-param name (so a generic-struct METHOD erases it)
    sg_bound: [string]          // ...parallel: that type-param's bounds joined by "+" ("" if none)
    gret_fn: [string]           // generic-return table (GLOBAL): a generic fn returning a bare `T` / `[T]`
    gret_arr: [bool]            // ...is the return `[T]` (true) or bare `T`?
    gret_argidx: [int]          // ...the value-param whose concrete type the result takes
    wit_tpname: [string]        // THIS fn's witness slots, in order: slot k's type-param name (k = 0..n_wit-1)
    wit_bound: [string]         // ...and slot k's bound interface name (the leading hidden params)
    wit_slot: [int]             // ...and the actual local slot each witness occupies (leading, before value params)
    tp_pslot: [int]             // THIS fn's value-param slots that are typed as a bare type-param
    tp_pname: [string]          // ...parallel: the type-param name that slot is typed as
    mwit_tpname: [string]       // THIS method's struct-witness fields (a method of a bounded generic struct):
    mwit_bound: [string]        // ...(type-param, bound) whose witness lives in self's FIELD mwit_field
    mwit_field: [int]           // ...the self field index of that witness (declared fields, then witness fields)
    mrecv_name: [string]        // generic-struct binding -> its type-ARGUMENTS key (`b: Bag<int>` -> "int"), so a
    mrecv_args: [string]        // ...method call `b.add(..)` retargets to the monomorphized `Bag.add<int>` instance
    cur_tp_names: [string]      // THIS fn's own type-param names (`K` for new_bag<K>) — for baking witnesses in
    cur_tp_types: [string]      // ...parallel: the concrete type each binds to in this compilation (`int`)


    // variant_field_index returns the flat payload-field-table index of field position `b` of flat-variant
    // `vfi` (the b-th entry whose owner is `vfi`), or -1 if unclassified (a generic prelude payload, or an
    // imported variant not in this module's table). Lets a `case V(x0, x1)` binding read its field type.
    fn variant_field_index(self, vfi: int, b: int) -> int {
        var count = 0
        var i = 0
        loop {
            if i >= self.ev_fvar.len() {
                break
            }
            if self.ev_fvar[i] == vfi {
                if count == b {
                    return i
                }
                count = count + 1
            }
            i = i + 1
        }
        return 0 - 1
    }


    // field_elem_code returns the element type code of array field `fname` of struct `id` (struct sid / -3
    // string / -4 enum / -1 scalar), or -1 if not found. Lets `obj.arr[i]` resolve its element kind.
    fn field_elem_code(self, id: int, fname: string) -> int {
        var i = 0
        loop {
            if i >= self.st_fowner.len() {
                break
            }
            if self.st_fowner[i] == id && self.st_fname[i] == fname {
                return self.st_felem[i]
            }
            i = i + 1
        }
        return 0 - 1
    }


    // field_elem_payload returns the payload struct sid of a `[Option<Struct>]` array field `fname` of struct
    // `id` (its element enum's struct type argument), or -1 (OFI-174).
    fn field_elem_payload(self, id: int, fname: string) -> int {
        var i = 0
        loop {
            if i >= self.st_fowner.len() {
                break
            }
            if self.st_fowner[i] == id && self.st_fname[i] == fname {
                return self.st_felem_payload[i]
            }
            i = i + 1
        }
        return 0 - 1
    }


    // scrutinee_payload_sid returns the concrete struct a `case Some(e)` binding should take when the matched
    // scrutinee is an element of a `[Option<Struct>]` field array (`match self.buckets[i]`) — nested-generic
    // enum-payload typing so `e.key.eq(..)` / `e.val` dispatch (OFI-174), else -1.
    fn scrutinee_payload_sid(self, e: ps.Expr) -> int {
        match e {
            case EIndex(object, index) {
                match object.value {
                    case EGet(inner, fname) {
                        let osid = self.expr_type_kind(inner.value)
                        if osid >= 0 {
                            return self.field_elem_payload(osid, fname)
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


    // field_arr_kind returns the NEW_ARRAY element-kind byte (AEK_*) of array field `fname` of struct `id`,
    // or -1 if not found. Lets an EMPTY array `[]` written as a field value take the field's element kind
    // (otherwise the context-free `[]` defaults to int — wrong for `[Stmt]`/`[Expr]` boxed-element fields).
    fn field_arr_kind(self, id: int, fname: string) -> int {
        var i = 0
        loop {
            if i >= self.st_fowner.len() {
                break
            }
            if self.st_fowner[i] == id && self.st_fname[i] == fname {
                return self.st_farrkind[i]
            }
            i = i + 1
        }
        return 0 - 1
    }


    // field_kind returns the num/render kind of a scalar field `fname` of struct `id` (int=0, sized 1..7,
    // f32=8, f64=9, bool=10), so `self.x - other.x` on float/sized fields emits the right operand width.
    fn field_kind(self, id: int, fname: string) -> int {
        var i = 0
        loop {
            if i >= self.st_fowner.len() {
                break
            }
            if self.st_fowner[i] == id && self.st_fname[i] == fname {
                return self.st_fkind[i]
            }
            i = i + 1
        }
        return 0
    }


    // field_is_string reports whether field `fname` of struct `id` is a string (refcounted) field.
    fn field_is_string(self, id: int, fname: string) -> bool {
        var i = 0
        loop {
            if i >= self.st_fowner.len() {
                break
            }
            if self.st_fowner[i] == id && self.st_fname[i] == fname {
                return self.st_fstring[i]
            }
            i = i + 1
        }
        return false
    }


    // field_is_refcounted reports whether field `fname` of struct `id` is a single REFCOUNTED Value (string,
    // enum, closure, type-param) — i.e. not a packed scalar, not an array, not a nested struct. Reading such a
    // field into a new owner INCREFs it (the same discipline as a string field).
    fn field_is_refcounted(self, id: int, fname: string) -> bool {
        var i = 0
        loop {
            if i >= self.st_fowner.len() {
                break
            }
            if self.st_fowner[i] == id && self.st_fname[i] == fname {
                return self.st_fscalar[i] == false && self.st_farray[i] == false && self.st_fstruct[i] < 0
            }
            i = i + 1
        }
        return false
    }


    // struct_id_of returns the struct id for `name`, or -1 if not a struct.
    fn struct_id_of(self, name: string) -> int {
        return cg_index_of(self.st_names, name)
    }


    // struct_all_scalar reports whether every field of struct `id` is a scalar (so it is multi-slot).
    fn struct_all_scalar(self, id: int) -> bool {
        var i = 0
        var seen = false
        loop {
            if i >= self.st_fowner.len() {
                break
            }
            if self.st_fowner[i] == id {
                seen = true
                if self.st_fscalar[i] == false {
                    return false
                }
            }
            i = i + 1
        }
        return seen
    }


    // struct_field_count returns the number of fields of struct `id`.
    fn struct_field_count(self, id: int) -> int {
        var n = 0
        var i = 0
        loop {
            if i >= self.st_fowner.len() {
                break
            }
            if self.st_fowner[i] == id {
                n = n + 1
            }
            i = i + 1
        }
        return n
    }


    // struct_field_index returns the declaration-order index of field `fname` in struct `id`, or -1.
    fn struct_field_index(self, id: int, fname: string) -> int {
        var idx = 0
        var i = 0
        loop {
            if i >= self.st_fowner.len() {
                break
            }
            if self.st_fowner[i] == id {
                if self.st_fname[i] == fname {
                    return idx
                }
                idx = idx + 1
            }
            i = i + 1
        }
        return -1
    }


    // struct_field_name_at returns the name of field `idx` (declaration order) of struct `id`.
    fn struct_field_name_at(self, id: int, idx: int) -> string {
        var seen = 0
        var i = 0
        loop {
            if i >= self.st_fowner.len() {
                break
            }
            if self.st_fowner[i] == id {
                if seen == idx {
                    return self.st_fname[i]
                }
                seen = seen + 1
            }
            i = i + 1
        }
        return ""
    }


    fn emit(mut self, b: int) {
        self.code.append(b)
        self.lines.append(self.cur_line)
    }


    // emit_idx writes one unsigned LEB128 operand (opcode.h operand_write OPK_IDX).
    fn emit_idx(mut self, v: int) {
        var x = v
        loop {
            if x < 128 {
                break
            }
            self.emit((x & 127) | 128)
            x = x / 128
        }
        self.emit(x)
    }


    // add_const_int appends an int constant to the pool and returns its index (NO dedup — stage-0 keeps
    // one pool entry per emit_const, so e.g. `return 0` produces two value-0 entries).
    fn add_const_int(mut self, v: int) -> int {
        let idx = self.const_is_float.len()
        self.const_is_float.append(false)
        self.const_int.append(v)
        self.const_float.append(0.0)
        return idx
    }


    // add_const_float appends a float constant to the pool and returns its index (same no-dedup rule).
    fn add_const_float(mut self, v: float) -> int {
        let idx = self.const_is_float.len()
        self.const_is_float.append(true)
        self.const_int.append(0)
        self.const_float.append(v)
        return idx
    }


    fn add_string(mut self, s: string) -> int {
        let idx = self.strings.len()
        self.strings.append(s)
        return idx
    }


    // is_erased_read reports whether `e` reads an ERASED type-param local (`x: T`) — a slot marked local_str
    // (INCREF-on-consume) but NOT droppable (over-retain). `let a = x` of such a value stays erased (no drop).
    fn is_erased_read(self, e: ps.Expr) -> bool {
        match e {
            case EIdent(name) {
                let slot = self.resolve_slot(name)
                return slot >= 0 && self.local_str[slot] && self.local_drop[slot] == false
            }
            case _ {
                return false
            }
        }
    }


    // is_str_local_read reports whether `e` reads a string from a PLACE (a local, or a struct field) — the
    // borrowed-refcounted case that must INCREF when consumed (the place keeps its reference).
    fn is_str_local_read(self, e: ps.Expr) -> bool {
        let ec = self.index_elem_code(e)
        if ec == 0 - 3 || ec == 0 - 4 {
            return true                          // `arr[i]` of a [string]/[enum] array is a refcounted place read
        }
        match e {
            case EIdent(name) {
                let slot = self.resolve_slot(name)
                if slot < 0 {
                    return false
                }
                // a string OR enum/closure local: an owned single-refcounted-Value local (droppable, not an
                // array, not a struct, not BOXED — a boxed move-T is MOVED, not INCREF'd) read into a new owner
                return self.local_str[slot] || (self.local_drop[slot] && self.slot_array[slot] == false && self.slot_struct[slot] < 0 && self.slot_boxed[slot] == false)
            }
            case EGet(object, name) {
                // a REFCOUNTED field (string OR enum/closure) read off any struct-typed object (a local, OR
                // an owning temp like `arr[i]`) — reading it into a new owner INCREFs it
                let osid = self.expr_type_kind(object.value)
                if osid < 0 {
                    return false
                }
                return self.field_is_refcounted(osid, name)
            }
            case _ {
                return false
            }
        }
    }


    // move_local_slot returns the slot of an OWNED move-type local (an array or boxed struct `let`/`var`)
    // read by `e`, or -1. Consuming such a local MOVES it: the value goes to the consumer and the slot is
    // zeroed, so the function-exit DROP of that slot is a harmless no-op (it never double-frees).
    fn move_local_slot(self, e: ps.Expr) -> int {
        match e {
            case EIdent(name) {
                let slot = self.resolve_slot(name)
                if slot < 0 {
                    return -1
                }
                if self.local_str[slot] {
                    return -1                        // a string is refcounted -> INCREF, not moved
                }
                if self.local_drop[slot] && (self.slot_array[slot] || self.slot_boxed[slot]) {
                    return slot
                }
                return -1
            }
            case _ {
                return -1
            }
        }
    }


    // gen_consume lowers a value being CONSUMED (a return value, a CONCAT operand, a let/field/element
    // initialiser): a borrowed-string place-read is INCREF'd; an owned move-type local is MOVED (zero its
    // slot); an owned temporary (literal/concat/construction) needs neither.
    fn gen_consume(mut self, e: ps.Expr, line: int) {
        let inc = self.is_str_local_read(e)
        let mvslot = self.move_local_slot(e)
        let barr = self.is_borrowed_array_read(e)
        self.gen_expr(e, line)
        if inc {
            self.emit(OP_INCREF)
        } else if mvslot >= 0 {
            let zidx = self.add_const_int(0)
            self.emit(OP_CONST)                      // zero the moved slot: CONST 0; SET_LOCAL; POP
            self.emit_idx(zidx)
            self.emit(OP_SET_LOCAL)
            self.emit_idx(mvslot)
            self.emit(OP_POP)
        } else if barr {
            self.emit(OP_INCREF)                     // a BORROWED array (a borrow param) aliased into an OWNER
        }
    }


    // is_borrowed_array_read reports whether `e` reads a BORROWED array local (an array param — slot_array set,
    // not droppable). Consuming one into a new OWNER (a struct field, a return) keeps the borrow's reference,
    // so it INCREFs (an OWNED array `let` is MOVED instead — handled by move_local_slot).
    fn is_borrowed_array_read(self, e: ps.Expr) -> bool {
        match e {
            case EIdent(name) {
                let slot = self.resolve_slot(name)
                return slot >= 0 && self.slot_array[slot] && self.local_drop[slot] == false
            }
            case _ {
                return false
            }
        }
    }


    // gen_global_const inlines the folded literal of top-level constant `gi` (the same value stage-0 inlines
    // at each reference): an int/float -> CONST, a string -> STRING, a bool -> TRUE/FALSE.
    fn gen_global_const(mut self, gi: int) {
        let k = self.gc_kind[gi]
        if k == 1 {
            let idx = self.add_string(self.gc_sval[gi])
            self.emit(OP_STRING)
            self.emit_idx(idx)
        } else if k == 2 {
            if self.gc_bval[gi] {
                self.emit(OP_TRUE)
            } else {
                self.emit(OP_FALSE)
            }
        } else if k == 3 {
            let idx = self.add_const_float(self.gc_fval[gi])
            self.emit(OP_CONST)
            self.emit_idx(idx)
        } else {
            let idx = self.add_const_int(self.gc_ival[gi])
            self.emit(OP_CONST)
            self.emit_idx(idx)
        }
    }


    // is_enum_ctor reports whether an expression constructs an enum value — a bare (zero-field) variant
    // referenced by name (and not shadowed by a local), or a payload variant `V(args)`.
    fn is_enum_ctor(self, e: ps.Expr) -> bool {
        match e {
            case EIdent(name) {
                return self.resolve_slot(name) < 0 && cg_index_of(self.ev_name, name) >= 0
            }
            case ECall(callee, args) {
                match callee.value {
                    case EIdent(name) {
                        return cg_index_of(self.ev_name, name) >= 0
                    }
                    case _ {
                        return false
                    }
                }
            }
            case _ {
                return false
            }
        }
    }


    // struct_value_info returns the struct id of a struct-literal value, or -1 if not a struct construction.
    fn struct_value_info(self, e: ps.Expr) -> int {
        match e {
            case EStructLit(ty, fields) {
                return self.type_struct_id(ty.value)
            }
            case _ {
                return -1
            }
        }
    }


    // expr_ret_kind classifies the OWNED type a `let`/`var` initialiser produces when it is a same-file
    // free-function call — the checker would carry this; codegen re-derives it from the fn-return tables so
    // that `let xs = make()` tracks `xs` as an owned-droppable array/struct/string (not a leaked scalar).
    // Encoded as a single int (NOT a value-struct return — that mis-compiles on the native backend from a
    // method, OFI-162): -1 = none/scalar, -2 = array, -3 = string, >= 0 = a struct id.
    // Cross-module / method-call returns aren't resolved here (idx == -1 -> -1/scalar, the safe default).
    fn expr_ret_kind(self, e: ps.Expr) -> int {
        match e {
            case ECall(callee, args) {
                match callee.value {
                    case EIdent(name) {
                        let nk = native_ret_kind(name)
                        if nk != 0 - 4 {
                            return nk                         // a builtin returning an owned object
                        }
                    }
                    case EGet(object, mname) {
                        if mname == "bytes" {
                            return -2                     // `s.bytes()` -> an owned byte array
                        }
                        if mname == "chars" {
                            return -2                     // `s.chars()` -> an owned [string] of characters
                        }
                    }
                    case _ {
                    }
                }
                let idx = self.resolve_call_fn_index(callee.value)
                if idx >= 0 {
                    if self.fn_ret_arr[idx] {
                        return -2
                    }
                    if self.fn_ret_str[idx] {
                        return -3
                    }
                    return self.fn_ret_sid[idx]          // struct id, or -1 (scalar)
                }
            }
            case _ {
            }
        }
        return -1
    }


    // expr_ret_elem returns the ELEMENT type code of an array-returning call (`let xs = f()` then `xs[i]`):
    // a user fn from `fn_ret_elem`, `args()` -> [string] (-3), `s.bytes()` -> a scalar byte array (-1). -1
    // when not an array-returning call (or the element kind is unknown).
    fn expr_ret_elem(self, e: ps.Expr) -> int {
        match e {
            case ECall(callee, args) {
                match callee.value {
                    case EIdent(name) {
                        if name == "args" {
                            return 0 - 3                  // args() -> [string]
                        }
                    }
                    case EGet(object, mname) {
                        if mname == "bytes" {
                            return 0 - 1                  // s.bytes() -> a scalar (u8) byte array
                        }
                        if mname == "chars" {
                            return 0 - 3                  // s.chars() -> a [string]: string elements
                        }
                    }
                    case _ {
                    }
                }
                let idx = self.resolve_call_fn_index(callee.value)
                if idx >= 0 {
                    return self.fn_ret_elem[idx]
                }
            }
            case _ {
            }
        }
        return 0 - 1
    }


    // resolve_call_fn_index returns the merged-fn-table index a call's callee names: a free function
    // (`f`), a struct method (`recv.m` where recv is a struct VALUE -> `Struct.m`), or a MODULE-QUALIFIED
    // free function (`mod.f` where `mod` is an import alias, not a value -> `f`). -1 if unresolved.
    fn resolve_call_fn_index(self, callee: ps.Expr) -> int {
        match callee {
            case EIdent(name) {
                return cg_index_of(self.fn_names, name)
            }
            case EGet(recv, mname) {
                let rsid = self.expr_type_kind(recv.value)
                if rsid >= 0 {
                    return cg_index_of(self.fn_names, self.st_names[rsid] + "." + mname)
                }
                return cg_index_of(self.fn_names, mname)   // a module-qualified free function
            }
            case _ {
                return -1
            }
        }
    }


    // call_returns_enum reports whether `e` is a call (free function, `self.method`, or a module-qualified
    // `mod.f`) that returns an enum, so a `let k = self.scan_token(...)` binding is an owned, droppable enum.
    fn call_returns_enum(self, e: ps.Expr) -> bool {
        match e {
            case ECall(callee, args) {
                let idx = self.resolve_call_fn_index(callee.value)
                return idx >= 0 && self.fn_ret_enum[idx]
            }
            case _ {
                return false
            }
        }
    }


    // field_type_kind classifies field `fname` of struct `id` as a type code (same encoding as
    // expr_type_kind: -2 array, -3 string, >= 0 struct id, -1 scalar).
    fn field_type_kind(self, id: int, fname: string) -> int {
        var i = 0
        loop {
            if i >= self.st_fowner.len() {
                break
            }
            if self.st_fowner[i] == id && self.st_fname[i] == fname {
                if self.st_farray[i] {
                    return -2
                }
                if self.st_fstring[i] {
                    return -3
                }
                return self.st_fstruct[i]        // struct id, or -1 (scalar)
            }
            i = i + 1
        }
        return -1
    }


    // expr_type_kind re-derives the static type of a method-call RECEIVER so a built-in `.len()`/`.append()`
    // on a non-identifier receiver (`acc.vals.len()`, `t.text.len()`, `make().len()`) dispatches like the
    // checker's array_op/string_op flags would. Encoding: -2 array, -3 string, >= 0 struct id, -1 scalar.
    fn expr_type_kind(self, e: ps.Expr) -> int {
        match e {
            case EIdent(name) {
                let slot = self.resolve_slot(name)
                if slot < 0 {
                    return -1
                }
                if self.local_str[slot] {
                    return -3
                }
                if self.slot_array[slot] {
                    return -2
                }
                return self.slot_struct[slot]    // struct id, or -1
            }
            case EGet(object, fname) {
                let osid = self.expr_type_kind(object.value)
                if osid >= 0 {
                    return self.field_type_kind(osid, fname)
                }
                return -1
            }
            case ECall(callee, args) {
                return self.expr_ret_kind(e)     // a call's return type (free-fn returns only)
            }
            case EIndex(object, index) {
                let ek = self.index_elem_code(e) // `arr[i]` has the array's element type
                if ek == 0 - 99 {
                    return -1
                }
                return ek
            }
            case _ {
                return -1
            }
        }
    }


    // gen_struct_fields pushes a struct literal's field values in DECLARATION order (reordering the
    // literal), each via gen_consume so a refcounted (string) field value that reads a local is INCREF'd.
    fn gen_struct_fields(mut self, sid: int, fields: [ps.SLitField], line: int) {
        let n = self.struct_field_count(sid)
        var fi = 0
        loop {
            if fi >= n {
                break
            }
            let fname = self.struct_field_name_at(sid, fi)
            var li = 0
            loop {
                if li >= fields.len() {
                    break
                }
                if fields[li].name == fname {
                    // A field holds a single value, never a multi-slot spread, so a struct field value is
                    // stored BOXED: a nested struct LITERAL is built via NEW_STRUCT (even when all-scalar),
                    // and a struct-returning CALL that lands its result MULTI-SLOT (an all-scalar return) is
                    // BOX_STRUCT'd. Any other value consumes normally (a string field INCREFs).
                    let fv = fields[li].value
                    if self.struct_value_info(fv) >= 0 {
                        self.gen_struct_construct(fv, line, true)
                    } else if array_lit_is_empty(fv) {
                        // an empty `[]` field value carries no element kind — take it from the FIELD's declared
                        // `[T]` (a boxed `[Stmt]`/`[Expr]` element is AEK 0, not the context-free int default).
                        self.cur_line = line
                        let esid = self.field_elem_code(sid, fname)
                        if esid >= 0 && self.struct_array_inline(esid) {
                            self.emit(OP_NEW_STRUCT_ARRAY)
                            self.emit_idx(0)
                            self.emit_idx(esid)
                        } else {
                            self.emit(OP_NEW_ARRAY)
                            self.emit_idx(0)
                            self.emit(self.field_arr_kind(sid, fname))
                        }
                    } else {
                        let rk = self.expr_ret_kind(fv)
                        if rk >= 0 {
                            self.gen_expr(fv, line)
                            if self.struct_all_scalar(rk) {
                                self.emit(OP_BOX_STRUCT)
                                self.emit_idx(rk)
                            }
                        } else {
                            self.gen_consume(fv, line)
                        }
                    }
                    break
                }
                li = li + 1
            }
            fi = fi + 1
        }
    }


    // gen_method_call emits `recv.method(args)`. A method takes a BOXED `self`, so a boxed receiver (self,
    // a boxed-struct local) is just pushed and CALL'd; a MULTI-SLOT receiver is first boxed (push its slots,
    // BOX_STRUCT), PICK'd (a copy for the call vs the owned temp to drop), then CALL'd and DROP_UNDER'd.
    // iface_method_index returns the position of method `mname` within interface `iface`'s declared method
    // list — the GET_FIELD index into the witness `Some(method-ref)` — or -1 if unknown (OFI-174).
    fn iface_method_index(self, iface: string, mname: string) -> int {
        let iid = cg_index_of(self.if_names, iface)
        if iid < 0 {
            return 0 - 1
        }
        var pos = 0
        var i = 0
        loop {
            if i >= self.ifm_iface.len() {
                break
            }
            if self.ifm_iface[i] == iid {
                if self.ifm_name[i] == mname {
                    return pos
                }
                pos = pos + 1
            }
            i = i + 1
        }
        return 0 - 1
    }


    // iface_method_flat_index returns the FLAT row index (into ifm_owning) of method `mname` in interface
    // `iface`, or -1. Distinct from iface_method_index, which returns the position WITHIN the interface.
    fn iface_method_flat_index(self, iface: string, mname: string) -> int {
        let iid = cg_index_of(self.if_names, iface)
        if iid < 0 {
            return 0 - 1
        }
        var i = 0
        loop {
            if i >= self.ifm_iface.len() {
                break
            }
            if self.ifm_iface[i] == iid && self.ifm_name[i] == mname {
                return i
            }
            i = i + 1
        }
        return 0 - 1
    }


    // witness_method_owning reports whether a bound-method call on a `tpn` receiver returns an OWNING value —
    // i.e. the interface method the witness (a param OR self's field) resolves to returns a string/array.
    fn witness_method_owning(self, tpn: string, mname: string) -> bool {
        var k = 0
        loop {
            if k >= self.wit_tpname.len() {
                break
            }
            if self.wit_tpname[k] == tpn {
                let oi = self.iface_method_flat_index(self.wit_bound[k], mname)
                if oi >= 0 {
                    return self.ifm_owning[oi]
                }
            }
            k = k + 1
        }
        var m = 0
        loop {
            if m >= self.mwit_tpname.len() {
                break
            }
            if self.mwit_tpname[m] == tpn {
                let oi = self.iface_method_flat_index(self.mwit_bound[m], mname)
                if oi >= 0 {
                    return self.ifm_owning[oi]
                }
            }
            m = m + 1
        }
        return false
    }


    // method_is_iface_impl reports whether method `mname` of struct `sname` implements an interface method (the
    // struct declares `implements <I>` and `I` requires `mname`). Such a method is reachable via a witness's
    // CALL_INDIRECT, which passes its receiver + Self-typed args BOXED, so those params compile as boxed. (OFI-174)
    fn method_is_iface_impl(self, sname: string, mname: string) -> bool {
        var i = 0
        loop {
            if i >= self.impl_struct.len() {
                break
            }
            if self.impl_struct[i] == sname {
                if self.iface_method_index(self.impl_iface[i], mname) >= 0 {
                    return true
                }
            }
            i = i + 1
        }
        return false
    }


    // param_is_self_typed reports whether a parameter's declared type is the struct itself (`other: Version`
    // in `Version.compare`, the `Self` of the interface method) — the params a witness call boxes.
    fn param_is_self_typed(self, p: ps.Param, sid: int) -> bool {
        if p.is_self || p.ty.len() == 0 {
            return false
        }
        match p.ty[0] {
            case TyName(qual, name) {
                return qual == "" && name == self.st_names[sid]
            }
            case _ {
                return false
            }
        }
    }


    // tp_slot_name returns the type-parameter name a receiver slot is typed as (a bound type-param param),
    // or "" if the slot is an ordinary value.
    fn tp_slot_name(self, slot: int) -> string {
        var i = 0
        loop {
            if i >= self.tp_pslot.len() {
                break
            }
            if self.tp_pslot[i] == slot {
                return self.tp_pname[i]
            }
            i = i + 1
        }
        return ""
    }


    // gen_witness_method_call lowers a bound-method call on a type-param receiver (`a.compare(b)`, `x.name()`)
    // to a witness dispatch: push the receiver + args (borrowed), then GET_FIELD the method-ref off the
    // matching witness and CALL_INDIRECT. Returns true if it handled the call (OFI-174).
    fn gen_witness_method_call(mut self, recv: ps.Expr, tpn: string, mname: string, args: [ps.Expr], line: int) -> bool {
        // A free-fn / method's own witness PARAM (max<T: Ord>): the witness is a leading local slot.
        var k = 0
        loop {
            if k >= self.wit_tpname.len() {
                break
            }
            if self.wit_tpname[k] == tpn {
                let midx = self.iface_method_index(self.wit_bound[k], mname)
                if midx >= 0 {
                    self.gen_witness_dispatch_head(recv, args, line)
                    self.emit(OP_GET_LOCAL)             // push the witness dict (a leading param)
                    self.emit_idx(self.wit_slot[k])
                    self.gen_witness_dispatch_tail(midx, args.len())
                    return true
                }
            }
            k = k + 1
        }
        // A method of a bounded generic struct (Map<K:Hash+Eq,V>.set): the witness lives in SELF's field.
        var m = 0
        loop {
            if m >= self.mwit_tpname.len() {
                break
            }
            if self.mwit_tpname[m] == tpn {
                let midx = self.iface_method_index(self.mwit_bound[m], mname)
                if midx >= 0 {
                    self.gen_witness_dispatch_head(recv, args, line)
                    self.emit(OP_GET_LOCAL)             // push self...
                    self.emit_idx(0)
                    self.emit(OP_GET_FIELD)             // ...and read its witness field (the Some dict)
                    self.emit_idx(self.mwit_field[m])
                    self.gen_witness_dispatch_tail(midx, args.len())
                    return true
                }
            }
            m = m + 1
        }
        return false
    }


    // gen_witness_dispatch_head pushes the receiver + call arguments (borrowed), before the witness dict.
    fn gen_witness_dispatch_head(mut self, recv: ps.Expr, args: [ps.Expr], line: int) {
        self.gen_expr(recv, line)                      // push the receiver (borrow: a local or a field read)
        var a = 0
        loop {
            if a >= args.len() {
                break
            }
            self.gen_expr(args[a], line)               // push each arg (borrow)
            a = a + 1
        }
    }


    // receiver_tparam returns the type-param name a method-call receiver has (so the call dispatches through a
    // witness): a type-param local/param (`key.hash()`), or a type-param FIELD (`e.key.eq(..)`), else "".
    fn receiver_tparam(self, e: ps.Expr) -> string {
        match e {
            case EIdent(name) {
                let slot = self.resolve_slot(name)
                if slot >= 0 {
                    return self.tp_slot_name(slot)
                }
                return ""
            }
            case EGet(obj, fname) {
                let osid = self.expr_type_kind(obj.value)
                if osid >= 0 {
                    return self.field_tpname_of(osid, fname)
                }
                return ""
            }
            case _ {
                return ""
            }
        }
    }


    // field_tpname_of returns field `fname` of struct `sid`'s bare type-param name (`e.key` -> "K"), or "".
    fn field_tpname_of(self, sid: int, fname: string) -> string {
        var i = 0
        loop {
            if i >= self.st_fowner.len() {
                break
            }
            if self.st_fowner[i] == sid && self.st_fname[i] == fname {
                return self.st_ftpname[i]
            }
            i = i + 1
        }
        return ""
    }


    // gen_witness_dispatch_tail extracts the concrete method-ref from the witness dict (already on top) and
    // dispatches through it: GET_FIELD <method-index>; CALL_INDIRECT <argc incl receiver>.
    fn gen_witness_dispatch_tail(mut self, midx: int, nargs: int) {
        self.emit(OP_GET_FIELD)
        self.emit_idx(midx)
        self.emit(OP_CALL_INDIRECT)
        self.emit_idx(1 + nargs)
    }


    // witness_method_ref resolves the concrete method-ref stored in a witness for `typename`'s implementation
    // of interface method `mname`: a USER struct method -> its fn-table index; a built-in (int/string) Hash/Eq
    // method -> the native sentinel (WITNESS_NATIVE_BASE + native id: hash=20, eq=21). (OFI-174)
    fn witness_method_ref(self, typename: string, mname: string) -> int {
        let fi = cg_index_of(self.fn_names, "{typename}.{mname}")
        if fi >= 0 {
            return fi
        }
        if mname == "hash" {
            return 1000000 + 20
        }
        if mname == "eq" {
            return 1000000 + 21
        }
        return 0
    }


    // arg_type_name returns the concrete type NAME of a call argument (struct name / "int" / "string" / "bool"
    // / "float", or "" if unknown) — the per-type-param key component for monomorphizing a bounded generic.
    fn arg_type_name(self, e: ps.Expr) -> string {
        match e {
            case EStructLit(ty, fields) {
                return ty_key_name(ty.value)
            }
            case EInt(v, kind) {
                return "int"
            }
            case EStr(parts) {
                return "string"
            }
            case EBool(v) {
                return "bool"
            }
            case EFloat(v) {
                return "float"
            }
            case EIdent(name) {
                let slot = self.resolve_slot(name)
                if slot >= 0 {
                    if self.slot_struct[slot] >= 0 {
                        return self.st_names[self.slot_struct[slot]]
                    }
                    if self.local_str[slot] {
                        return "string"
                    }
                    return "int"
                }
                return ""
            }
            case _ {
                return ""
            }
        }
    }


    // emit_witness builds one witness dictionary for `typename`'s implementation of interface `bound` and
    // leaves it on the stack: push each interface method's concrete ref (in declaration order), then wrap them
    // in a `Some(...)` enum (NEW_ENUM Option/Some <method-count>) — the hidden leading arg of a bounded call.
    fn emit_witness(mut self, bound: string, typename: string, line: int) {
        let iid = cg_index_of(self.if_names, bound)
        var count = 0
        var i = 0
        loop {
            if i >= self.ifm_iface.len() {
                break
            }
            if self.ifm_iface[i] == iid {
                let ref = self.witness_method_ref(typename, self.ifm_name[i])
                let ci = self.add_const_int(ref)
                self.cur_line = line
                self.emit(OP_CONST)
                self.emit_idx(ci)
                count = count + 1
            }
            i = i + 1
        }
        let vsome = cg_index_of(self.ev_name, "Some")
        self.emit(OP_NEW_ENUM)
        self.emit_idx(self.ev_owner[vsome])
        self.emit_idx(self.ev_tag[vsome])
        self.emit_idx(count)
    }


    // gen_bounded_arg pushes one value argument of a bounded generic call as a single erased Value: a struct
    // literal is built boxed (NEW_STRUCT); an all-scalar struct local is BOX_STRUCT'd from its slots; an
    // already-boxed struct local / scalar is pushed as-is.
    fn gen_bounded_arg(mut self, e: ps.Expr, line: int) {
        match e {
            case EIdent(name) {
                let slot = self.resolve_slot(name)
                if slot >= 0 && self.slot_struct[slot] >= 0 {
                    let sid = self.slot_struct[slot]
                    if self.slot_boxed[slot] {
                        self.cur_line = line
                        self.emit(OP_GET_LOCAL)          // already a boxed struct value
                        self.emit_idx(slot)
                    } else {
                        let span = self.struct_field_count(sid)
                        var s = 0
                        loop {
                            if s >= span {
                                break
                            }
                            self.cur_line = line
                            self.emit(OP_GET_LOCAL)      // push each multi-slot field, then box
                            self.emit_idx(slot + s)
                            s = s + 1
                        }
                        self.emit(OP_BOX_STRUCT)
                        self.emit_idx(sid)
                    }
                    return
                }
                self.gen_expr(e, line)
            }
            case EStructLit(ty, fields) {
                self.gen_struct_construct(e, line, true)   // build boxed (NEW_STRUCT)
            }
            case _ {
                self.gen_expr(e, line)
            }
        }
    }


    // bounded_call_key builds the monomorphization key for a bounded generic call: the concrete type of each
    // (type-param, bound) row's determining argument, joined by "_" — matching build_fn_instances' registration
    // so the call resolves to the right instance slot. A return-inferred row (argidx -1) uses expected_key.
    fn bounded_call_key(self, name: string, args: [ps.Expr]) -> string {
        var parts = ""
        var first = true
        var gwi = 0
        loop {
            if gwi >= self.gb_fn.len() {
                break
            }
            if self.gb_fn[gwi] == name {
                var tn = self.expected_key
                let ai = self.gb_argidx[gwi]
                if ai >= 0 && ai < args.len() {
                    tn = self.arg_type_name(args[ai])
                }
                if first {
                    parts = tn
                    first = false
                } else {
                    parts = "{parts}_{tn}"
                }
            }
            gwi = gwi + 1
        }
        return parts
    }


    // let_value_is_bounded_call reports whether a `let`'s initialiser is a 0-arg (return-inferred) bounded
    // generic call (`new_bag()`), so the SLet threads the annotation type in as expected_key.
    fn let_value_is_bounded_call(self, e: ps.Expr) -> bool {
        match e {
            case ECall(callee, args) {
                match callee.value {
                    case EIdent(name) {
                        return args.len() == 0 && cg_index_of(self.gb_fn, name) >= 0
                    }
                    case _ {
                        return false
                    }
                }
            }
            case _ {
                return false
            }
        }
    }


    // emit_bounded_witnesses pushes one witness per (type-param, bound) of a bounded generic call, in order,
    // returning the count. The concrete type for each row is its determining arg's type, or expected_key for a
    // return-inferred row. Shared by a direct CALL and a SPAWN of a bounded generic (OFI-174).
    fn emit_bounded_witnesses(mut self, name: string, args: [ps.Expr], line: int) -> int {
        var n_wit = 0
        var gwi = 0
        loop {
            if gwi >= self.gb_fn.len() {
                break
            }
            if self.gb_fn[gwi] == name {
                var tn = self.expected_key
                let ai = self.gb_argidx[gwi]
                if ai >= 0 && ai < args.len() {
                    tn = self.arg_type_name(args[ai])
                }
                self.emit_witness(self.gb_bound[gwi], tn, line)
                n_wit = n_wit + 1
            }
            gwi = gwi + 1
        }
        return n_wit
    }


    // bounded_inst_index returns the monomorphized instance fn-table index for a bounded generic call, or the
    // base fn-index if no instance is registered.
    fn bounded_inst_index(self, name: string, args: [ps.Expr]) -> int {
        let ix = cg_index_of(self.fn_inst_keys, "{name}<{self.bounded_call_key(name, args)}>")
        if ix >= 0 {
            return self.inst_base + ix
        }
        return cg_index_of(self.fn_names, name)
    }


    // gen_bounded_call lowers a call to a BOUNDED generic function (OFI-174): build one witness per
    // (type-param, bound) as a hidden leading arg, then the value args (erased/boxed), then CALL the
    // monomorphized instance with (witness-count + value-arg-count) arguments.
    fn gen_bounded_call(mut self, name: string, args: [ps.Expr], line: int) {
        let fi = self.bounded_inst_index(name, args)
        let n_wit = self.emit_bounded_witnesses(name, args, line)
        var a = 0
        loop {
            if a >= args.len() {
                break
            }
            self.gen_bounded_arg(args[a], line)
            a = a + 1
        }
        self.cur_line = line
        self.emit(OP_CALL)
        self.emit_idx(fi)
        self.emit_idx(n_wit + args.len())
    }


    // resolve_method_index returns the fn-table index of `struct_name.mname`, retargeting to a monomorphized
    // METHOD instance (`Bag.add<int>`) when the receiver binding `recv_name` carries concrete type-args (OFI-174).
    fn resolve_method_index(self, recv_name: string, struct_name: string, mname: string) -> int {
        var i = self.mrecv_name.len() - 1
        loop {
            if i < 0 {
                break
            }
            if self.mrecv_name[i] == recv_name {
                if self.mrecv_args[i] != "" {
                    let ix = cg_index_of(self.fn_inst_keys, "{struct_name}.{mname}<{self.mrecv_args[i]}>")
                    if ix >= 0 {
                        return self.inst_base + ix
                    }
                }
                break
            }
            i = i - 1
        }
        return cg_index_of(self.fn_names, "{struct_name}.{mname}")
    }


    fn gen_method_call(mut self, object: ps.Expr, mname: string, args: [ps.Expr], line: int) {
        // A bound-method call on a type-param receiver (`key.hash()`, `e.key.eq(..)`) dispatches through a
        // witness (OFI-174) — handled uniformly for a type-param local/param OR a type-param field receiver.
        let rtpn = self.receiver_tparam(object)
        if rtpn != "" {
            if self.gen_witness_method_call(object, rtpn, mname, args, line) {
                return
            }
        }
        match object {
            case EIdent(recv) {
                let slot = self.resolve_slot(recv)
                if slot < 0 {
                    // the receiver is not a value: a MODULE-QUALIFIED free-function call (`ps.parse(x)`) — the
                    // alias is inert and `mname` names a (merged) function, so emit a plain CALL by name.
                    let fi = cg_index_of(self.fn_names, mname)
                    if fi >= 0 {
                        let n = self.gen_call_args(args, line)
                        self.cur_line = line
                        self.emit(OP_CALL)
                        self.emit_idx(fi)
                        self.emit_idx(n)
                    }
                    return
                }
                if self.local_str[slot] {
                    // a built-in string method (`.len()` -> STR_LEN, `.bytes()` -> STR_BYTES) is one opcode.
                    let sop = string_method_op(mname)
                    if sop >= 0 {
                        self.cur_line = line
                        self.emit(OP_GET_LOCAL)
                        self.emit_idx(slot)
                        self.emit(sop)
                    }
                    return
                }
                if self.slot_array[slot] {
                    // built-in array methods compile to dedicated opcodes, not a CALL.
                    self.cur_line = line
                    self.emit(OP_GET_LOCAL)
                    self.emit_idx(slot)
                    if mname == "len" {
                        self.emit(OP_ARRAY_LEN)
                    } else if mname == "append" {
                        self.gen_append_value(args[0], line)
                        self.emit(OP_ARRAY_APPEND)
                    }
                    return
                }
                let sid = self.slot_struct[slot]
                if sid < 0 {
                    return
                }
                let midx = self.resolve_method_index(recv, self.st_names[sid], mname)
                self.cur_line = line
                if self.slot_boxed[slot] {
                    self.emit(OP_GET_LOCAL)
                    self.emit_idx(slot)
                    let n = self.gen_call_args(args, line)
                    self.emit(OP_CALL)
                    self.emit_idx(midx)
                    self.emit_idx(1 + n)
                } else {
                    let span = self.struct_field_count(sid)
                    var s = 0
                    loop {
                        if s >= span {
                            break
                        }
                        self.emit(OP_GET_LOCAL)          // push each multi-slot field
                        self.emit_idx(slot + s)
                        s = s + 1
                    }
                    self.emit(OP_BOX_STRUCT)
                    self.emit_idx(sid)
                    self.emit(OP_PICK)
                    self.emit_idx(0)
                    let n = self.gen_call_args(args, line)
                    self.emit(OP_CALL)
                    self.emit_idx(midx)
                    self.emit_idx(1 + n)
                    self.emit(OP_DROP_UNDER)
                }
            }
            case _ {
                // A NON-identifier receiver (`acc.vals.len()`, `t.text.len()`, `make().method()`): evaluate
                // the receiver expression, then dispatch by its static type. Built-in string/array methods
                // compile to dedicated opcodes; a boxed-struct receiver is pushed and CALL'd as `self`.
                let tk = self.expr_type_kind(object)
                if tk == -3 {
                    let sop = string_method_op(mname)
                    if sop >= 0 {
                        self.cur_line = line
                        self.gen_expr(object, line)
                        self.emit(sop)
                    }
                } else if tk == -2 {
                    self.cur_line = line
                    self.gen_expr(object, line)
                    if mname == "len" {
                        self.emit(OP_ARRAY_LEN)
                    } else if mname == "append" {
                        self.gen_append_value(args[0], line)
                        self.emit(OP_ARRAY_APPEND)
                    }
                } else if tk >= 0 {
                    // A boxed-struct receiver that is an OWNING TEMP (a field read / call result increfs):
                    // PICK a copy for the call and DROP_UNDER the temp after — exactly the multi-slot path,
                    // minus the BOX_STRUCT (the value is already boxed).
                    let midx = cg_index_of(self.fn_names, self.st_names[tk] + "." + mname)
                    self.cur_line = line
                    self.gen_expr(object, line)
                    if is_call_expr(object) && self.struct_all_scalar(tk) {
                        self.emit(OP_BOX_STRUCT)         // a multi-slot struct returned by a call -> one box
                        self.emit_idx(tk)
                    }
                    self.emit(OP_PICK)
                    self.emit_idx(0)
                    let n = self.gen_call_args(args, line)
                    self.emit(OP_CALL)
                    self.emit_idx(midx)
                    self.emit_idx(1 + n)
                    self.emit(OP_DROP_UNDER)
                }
            }
        }
    }


    // gen_call_args pushes each argument and returns the TOTAL number of stack slots pushed — a multi-slot
    // (all-scalar) value-struct argument occupies one slot per field, so call arity counts slots not args.
    fn gen_call_args(mut self, args: [ps.Expr], line: int) -> int {
        var total = 0
        var a = 0
        loop {
            if a >= args.len() {
                break
            }
            total = total + self.gen_one_arg(args[a], line)
            a = a + 1
        }
        return total
    }


    fn gen_one_arg(mut self, e: ps.Expr, line: int) -> int {
        match e {
            case EIdent(name) {
                let slot = self.resolve_slot(name)
                if slot >= 0 {
                    let sid = self.slot_struct[slot]
                    if sid >= 0 && self.slot_boxed[slot] == false {
                        let span = self.struct_field_count(sid)   // multi-slot struct: spread its field slots
                        var s = 0
                        loop {
                            if s >= span {
                                break
                            }
                            self.emit(OP_GET_LOCAL)
                            self.emit_idx(slot + s)
                            s = s + 1
                        }
                        return span
                    }
                }
            }
            case _ {
            }
        }
        if self.arg_needs_incref(e) {
            // a refcounted value passed to an owned param keeps the caller's reference -> INCREF (the callee
            // drops its copy). Covers a string/enum local AND a string PLACE read (field / `arr[i]` element).
            self.gen_expr(e, line)
            self.emit(OP_INCREF)
            return 1
        }
        self.gen_expr(e, line)
        return 1
    }


    // is_erased_tparam_arg reports whether `e` reads a bare local slot typed as an ERASED type-parameter
    // (`key: K`) — distinct from a string/enum borrow, which tp_slot_name leaves as "". Used to suppress the
    // borrow-passthrough INCREF that a type-param arg does not need (OFI-165).
    fn is_erased_tparam_arg(self, e: ps.Expr) -> bool {
        match e {
            case EIdent(name) {
                let slot = self.resolve_slot(name)
                if slot < 0 {
                    return false
                }
                return self.tp_slot_name(slot) != ""
            }
            case _ {
                return false
            }
        }
    }


    // arg_needs_incref reports whether a call argument is a refcounted value whose owner the caller retains.
    fn arg_needs_incref(self, e: ps.Expr) -> bool {
        if self.is_erased_tparam_arg(e) {
            // A bare ERASED type-param read (`key: K`) passed into a callee that also borrows it
            // (`self._index(key, cap)`) is a borrow-passthrough: the reference is not retained across the call,
            // so no INCREF — matching stage-0's borrow convention for erased type-param args (OFI-165). A string
            // borrow (`s: string`) is NOT excluded here: stage-0 DOES INCREF a string passed to an owned param.
            return false
        }
        if self.is_str_local_read(e) {
            return true
        }
        match e {
            case EIdent(name) {
                let slot = self.resolve_slot(name)
                return slot >= 0 && self.local_drop[slot] && self.slot_array[slot] == false && self.slot_struct[slot] < 0
            }
            case _ {
                return false
            }
        }
    }


    // arg_is_owning_object reports whether a builtin call's argument is a FRESH owning-temp heap object (a
    // string literal/interpolation, a string concat, an array/struct literal, or a call returning an object).
    // A native adopts nothing, so such an arg must be kept + PICK'd + DROP_UNDER'd by the caller (the checker
    // records this as drop_mask; codegen re-derives it). A variable/scalar arg is a borrow — never masked.
    fn arg_is_owning_object(self, e: ps.Expr) -> bool {
        match e {
            case EStr(parts) {
                return true
            }
            case EArray(elems, lines) {
                return true
            }
            case EStructLit(ty, fields) {
                return true
            }
            case EBinary(op, l, r) {
                return ps.binop_id(op) == 1 && (self.expr_is_string(l.value) || self.expr_is_string(r.value))
            }
            case ECall(callee, args) {
                if self.is_enum_ctor(e) {
                    return true
                }
                // a GENERIC call returning bare-T yields its arg-0's type: `id("copy")` (id<T>(x:T)->T) is a
                // fresh owning-temp STRING, so `println(id("copy"))` masks + drops it.
                match callee.value {
                    case EIdent(name) {
                        if cg_index_of(self.generic_fns, name) >= 0 && args.len() > 0 {
                            return self.arg_is_owning_object(args[0])
                        }
                    }
                    case EGet(recv, mname) {
                        // a WITNESS method call (`x.name()`) returning a string/array is a fresh owning temp.
                        let tpn = self.receiver_tparam(recv.value)
                        if tpn != "" {
                            return self.witness_method_owning(tpn, mname)
                        }
                    }
                    case _ {
                    }
                }
                return self.expr_ret_kind(e) != 0 - 1   // a user call returning string/array/struct
            }
            case _ {
                return false
            }
        }
    }


    // gen_builtin_call emits a native free-function call (CALL_NATIVE <nid> <argc>). Owning-temp object args
    // are kept below the arg region and passed as a borrow alias via PICK, then DROP_UNDER'd from under the
    // single result — the builtin analogue of the OFI-027 call drop discipline (mirrors src/codegen.c:1017).
    fn gen_builtin_call(mut self, nid: int, args: [ps.Expr], line: int) {
        // Only print/println/read_file/write_file (nids 0/1/3/4) require the caller to drop owning-temp
        // object args; every other native releases its args internally (check.c:4361), so no PICK dance.
        let does_mask = nid == 0 || nid == 1 || nid == 3 || nid == 4
        var masked: [bool] = []
        var keep = 0
        var i = 0
        loop {
            if i >= args.len() {
                break
            }
            let m = does_mask && self.arg_is_owning_object(args[i])
            masked.append(m)
            if m {
                keep = keep + 1
            }
            i = i + 1
        }
        if keep == 0 {
            var a = 0
            loop {
                if a >= args.len() {
                    break
                }
                self.gen_expr(args[a], line)
                a = a + 1
            }
            self.cur_line = line
            self.emit(OP_CALL_NATIVE)
            self.emit_idx(nid)
            self.emit_idx(args.len())
            return
        }
        var k = 0                                    // push every kept temp first (they sit below the args)
        loop {
            if k >= args.len() {
                break
            }
            if masked[k] {
                self.gen_expr(args[k], line)
            }
            k = k + 1
        }
        var built = 0
        var t_seen = 0
        var b = 0
        loop {
            if b >= args.len() {
                break
            }
            if masked[b] {
                self.emit(OP_PICK)                   // a borrow alias of the kept temp
                self.emit_idx(keep + built - 1 - t_seen)
                t_seen = t_seen + 1
            } else {
                self.gen_expr(args[b], line)
            }
            built = built + 1
            b = b + 1
        }
        self.cur_line = line
        self.emit(OP_CALL_NATIVE)
        self.emit_idx(nid)
        self.emit_idx(args.len())
        var dk = 0
        loop {
            if dk >= keep {
                break
            }
            self.emit(OP_DROP_UNDER)
            dk = dk + 1
        }
    }


    // extern_param_is_move reports whether param `i` of extern `name` is declared `move` (qual '2') — a
    // linear Ptr the callee CONSUMES (e.g. fclose(move f: Ptr)), so the arg is move-consumed at the call site.
    fn extern_param_is_move(self, name: string, i: int) -> bool {
        var j = 0
        loop {
            if j >= self.ext_names.len() {
                break
            }
            if self.ext_names[j] == name {
                let qs = self.ext_pquals[j]              // bind first: `.bytes()` on an indexed field element
                let q = qs.bytes()                       // isn't lowered by the C-emit backend (INT_VAL(0))
                if i < q.len() {
                    return int(q[i]) == 50               // '2' = move
                }
                return false
            }
            j = j + 1
        }
        return false
    }


    // gen_extern_arg pushes one extern argument. A `move` param whose arg is a LOCAL is move-consumed: load the
    // value, then ZERO the slot (CONST 0; SET_LOCAL; POP) so the linear Ptr isn't reachable — and thus not
    // double-consumed — after the call (mirrors the array/struct move discipline). Every other arg is a plain
    // BORROW pushed raw (no INCREF — the foreign callee adopts nothing).
    fn gen_extern_arg(mut self, name: string, i: int, e: ps.Expr, line: int) {
        if self.extern_param_is_move(name, i) {
            match e {
                case EIdent(vn) {
                    let slot = self.resolve_slot(vn)
                    if slot >= 0 {
                        self.cur_line = line
                        self.emit(OP_GET_LOCAL)
                        self.emit_idx(slot)
                        let z = self.add_const_int(0)
                        self.emit(OP_CONST)
                        self.emit_idx(z)
                        self.emit(OP_SET_LOCAL)
                        self.emit_idx(slot)
                        self.emit(OP_POP)
                        return
                    }
                }
                case _ {
                }
            }
        }
        self.gen_expr(e, line)
    }


    // gen_call_c emits a hosted `extern "c"` call: CALL_C <registry index> <op>, where op = 0xFFFF (65535) for
    // a non-struct return (every hosted scalar/Ptr/string extern). An extern BORROWS its heap args (§5h — Ember
    // keeps ownership across the borrow), so a fresh owning-temp OBJECT arg (a string/array literal, e.g. the
    // "r" in fopen(path, "r")) is kept below the args, PICK'd as a borrow alias, and DROP_UNDER'd from under the
    // single result — the same discipline as gen_builtin_call, but the mask applies to EVERY extern (not just
    // nids 0/1/3/4). A `move Ptr` arg is move-consumed (gen_extern_arg). Struct-by-value returns (op = rsid)
    // are deferred.
    fn gen_call_c(mut self, name: string, args: [ps.Expr], line: int) {
        var masked: [bool] = []
        var keep = 0
        var i = 0
        loop {
            if i >= args.len() {
                break
            }
            let m = self.arg_is_owning_object(args[i])
            masked.append(m)
            if m {
                keep = keep + 1
            }
            i = i + 1
        }
        if keep == 0 {
            // Extern args are BORROWED — the foreign callee adopts nothing (stage-0 gates consume on
            // !is_extern), so push each arg RAW (NOT gen_one_arg, which would INCREF a string place-read and
            // over-retain a borrowed local); a `move Ptr` arg is move-consumed by gen_extern_arg.
            var a = 0
            loop {
                if a >= args.len() {
                    break
                }
                self.gen_extern_arg(name, a, args[a], line)
                a = a + 1
            }
            self.cur_line = line
            self.emit(OP_CALL_C)
            self.emit_idx(cextern_index(name))
            self.emit_idx(65535)
            return
        }
        var k = 0                                    // push every kept owning temp first (below the args)
        loop {
            if k >= args.len() {
                break
            }
            if masked[k] {
                self.gen_expr(args[k], line)
            }
            k = k + 1
        }
        var built = 0
        var t_seen = 0
        var b = 0
        loop {
            if b >= args.len() {
                break
            }
            if masked[b] {
                self.emit(OP_PICK)                   // a borrow alias of the kept temp
                self.emit_idx(keep + built - 1 - t_seen)
                t_seen = t_seen + 1
            } else {
                self.gen_extern_arg(name, b, args[b], line)   // borrowed (or move-consumed) extern arg
            }
            built = built + 1
            b = b + 1
        }
        self.cur_line = line
        self.emit(OP_CALL_C)
        self.emit_idx(cextern_index(name))
        self.emit_idx(65535)
        var dk = 0
        loop {
            if dk >= keep {
                break
            }
            self.emit(OP_DROP_UNDER)
            dk = dk + 1
        }
    }


    // user_arg_masked reports whether a user-function call argument is an OWNING-TEMP ARRAY (an array literal,
    // or a call returning an array) passed to a BORROW param — the caller retains the temp and must drop it
    // after the call. Strings/enums go to OWNED params (adopted, no drop); structs aren't masked here (the
    // corpus has no struct-temp user-call arg — they'd extend this when one appears).
    fn user_arg_masked(self, e: ps.Expr) -> bool {
        match e {
            case EArray(elems, lines) {
                return true
            }
            case ECall(callee, args) {
                if self.is_enum_ctor(e) {
                    return false
                }
                return self.expr_ret_kind(e) == 0 - 2   // a call returning an array
            }
            case _ {
                return false
            }
        }
    }


    // gen_user_call emits a free-function CALL, applying the owning-temp keep+drop discipline (PICK + DROP_UNDER,
    // like gen_builtin_call) to array-object args: each kept temp is pushed BELOW the args, PICK'd as a borrow
    // alias for the call, then DROP_UNDER'd from under the single result. Non-masked args go through gen_one_arg
    // (so a string/enum place-read still INCREFs and a multi-slot struct still spreads).
    fn gen_user_call(mut self, fn_idx: int, args: [ps.Expr], line: int, mask_obj: bool, pquals: string) {
        let pq = pquals.bytes()
        var masked: [bool] = []
        var keep = 0
        var i = 0
        loop {
            if i >= args.len() {
                break
            }
            // A GENERIC call's Copy/borrow erased-T params BORROW an owning-temp OBJECT arg -> kept + PICK'd +
            // DROP_UNDER'd (like an extern). A `move` param (qual '2') TAKES OWNERSHIP -> not masked. A normal
            // user call masks only owning-temp ARRAYS.
            var m = self.user_arg_masked(args[i])
            if mask_obj {
                m = self.arg_is_owning_object(args[i])
                if m && i < pq.len() && int(pq[i]) == 50 {
                    m = false                            // '2' (50) = move: the callee adopts the temp
                }
            }
            masked.append(m)
            if m {
                keep = keep + 1
            }
            i = i + 1
        }
        if keep == 0 {
            let n = self.gen_call_args(args, line)
            self.cur_line = line
            self.emit(OP_CALL)
            self.emit_idx(fn_idx)
            self.emit_idx(n)
            return
        }
        var k = 0                                    // push every kept temp first (they sit below the args)
        loop {
            if k >= args.len() {
                break
            }
            if masked[k] {
                self.gen_expr(args[k], line)
            }
            k = k + 1
        }
        var argc = 0
        var built = 0
        var t_seen = 0
        var b = 0
        loop {
            if b >= args.len() {
                break
            }
            if masked[b] {
                self.emit(OP_PICK)                   // a borrow alias of the kept temp
                self.emit_idx(keep + built - 1 - t_seen)
                t_seen = t_seen + 1
                built = built + 1
                argc = argc + 1
            } else {
                let span = self.gen_one_arg(args[b], line)
                built = built + span
                argc = argc + span
            }
            b = b + 1
        }
        self.cur_line = line
        self.emit(OP_CALL)
        self.emit_idx(fn_idx)
        self.emit_idx(argc)
        var dk = 0
        loop {
            if dk >= keep {
                break
            }
            self.emit(OP_DROP_UNDER)
            dk = dk + 1
        }
    }


    // elem_is_boxed reports whether an array element expression is a BOXED value (AEK_BOXED=0): a string, an
    // array, a struct, or an enum (owned single-refcounted local / enum constructor / enum-returning call).
    // A scalar (int/sized/float/bool) is NOT boxed.
    fn elem_is_boxed(self, e: ps.Expr) -> bool {
        if self.expr_is_string(e) {
            return true
        }
        if self.struct_value_info(e) >= 0 {
            return true                          // a struct CONSTRUCTION (`Box<Expr>{…}`) -> a boxed element
        }
        let tk = self.expr_type_kind(e)
        if tk == 0 - 2 || tk == 0 - 3 || tk >= 0 {
            return true                          // array / string / struct
        }
        if self.is_enum_ctor(e) || self.call_returns_enum(e) {
            return true                          // a fresh enum value
        }
        match e {
            case EIdent(name) {
                let slot = self.resolve_slot(name)
                // an owned enum/closure local: droppable single refcounted Value (not str/array/struct)
                return slot >= 0 && self.local_drop[slot] && self.slot_array[slot] == false && self.slot_struct[slot] < 0 && self.local_str[slot] == false
            }
            case _ {
                return false
            }
        }
    }


    // elem_kind_of infers an array element's ArrayElemKind (value.h): a string/array/struct/enum element is
    // AEK_BOXED=0, a float is AEK_F64=10, a bool is AEK_BOOL=11, otherwise AEK_I64=4 (int / int arithmetic).
    // (Sized-int element arrays are not yet distinguished — they default into AEK_I64.)
    fn elem_kind_of(self, e: ps.Expr) -> int {
        if self.elem_is_boxed(e) {
            return 0
        }
        match e {
            case EFloat(v) {
                return 10
            }
            case EBool(v) {
                return 11
            }
            case _ {
                return 4
            }
        }
    }


    // gen_struct_construct lowers a struct literal as either multi-slot (push fields) or boxed (push fields
    // + NEW_STRUCT) — the caller chooses, since a `var`/mutated all-scalar struct is boxed though its TYPE
    // is all-scalar (so a field assignment can mutate it via SET_FIELD).
    // resolve_concrete_tyname maps a construction type-argument to its concrete type name, resolving a bare
    // type parameter of the enclosing fn through its cur_tp binding (`Bag<K>{}` in new_bag<int> -> K = "int").
    fn resolve_concrete_tyname(self, ty: ps.Ty) -> string {
        match ty {
            case TyName(qual, name) {
                let i = cg_index_of(self.cur_tp_names, name)
                if i >= 0 {
                    return self.cur_tp_types[i]
                }
                return name
            }
            case _ {
                return ty_key_name(ty)
            }
        }
    }


    // emit_struct_witnesses pushes a BOUNDED generic struct's hidden witness fields (one Some(method-ref) per
    // (struct type-param, bound)) for the concrete type arguments, right after the declared fields and before
    // NEW_STRUCT — so `Bag<K>{items,count}` in new_bag<int> appends int's Hash + Eq witnesses (OFI-174).
    fn emit_struct_witnesses(mut self, sty: ps.Ty, line: int) {
        match sty {
            case TyGeneric(qual, sname, args) {
                var pi = 0
                var sgx = 0
                loop {
                    if sgx >= self.sg_struct.len() {
                        break
                    }
                    if self.sg_struct[sgx] == sname {
                        var tn = ""
                        if pi < args.len() {
                            tn = self.resolve_concrete_tyname(args[pi])
                        }
                        let bounds = split_plus(self.sg_bound[sgx])
                        var bi = 0
                        loop {
                            if bi >= bounds.len() {
                                break
                            }
                            if bounds[bi] != "" {
                                self.emit_witness(bounds[bi], tn, line)
                            }
                            bi = bi + 1
                        }
                        pi = pi + 1
                    }
                    sgx = sgx + 1
                }
            }
            case _ {
            }
        }
    }


    fn gen_struct_construct(mut self, value: ps.Expr, line: int, boxed: bool) {
        match value {
            case EStructLit(ty, fields) {
                let sid = self.type_struct_id(ty.value)
                self.gen_struct_fields(sid, fields, line)
                self.emit_struct_witnesses(ty.value, line)   // bake hidden witness fields (bounded generic struct)
                if boxed {
                    self.emit(OP_NEW_STRUCT)
                    self.emit_idx(self.lit_struct_id(ty.value))
                    self.emit_idx(self.struct_field_count(sid))
                }
            }
            case _ {
                self.gen_expr(value, line)
            }
        }
    }


    // array_elem_type_code classifies an array's ELEMENT type `[T]` -> `T` for per-slot tracking: a struct
    // element returns its sid (>= 0), a string element -3, an enum/refcounted element -4, anything else -1.
    // Lets `let x = arr[i]` / `f(arr[i])` know x's type (boxed struct / string / enum / scalar) without a
    // separate type pass. Delegates to the shared free classifier so params + bindings agree.
    fn array_elem_type_code(self, elem_ty: ps.Ty) -> int {
        // An erased type-parameter element (`[T]` in a generic fn) is REFCOUNTED at runtime — a read INCREFs
        // (a runtime-conditional retain, a no-op for a scalar element). Classify it like an enum element (-4)
        // so an erased element store `out[j] = out[j-1]` retains the value (OFI-174 / OFI-015).
        match elem_ty {
            case TyName(qual, name) {
                if qual == "" && cg_index_of(self.cur_tp_names, name) >= 0 {
                    return 0 - 4
                }
            }
            case _ {
            }
        }
        return elem_type_code(elem_ty, self.st_names, self.et_names)
    }


    // index_elem_code returns the ELEMENT type code of `arr[i]` when arr is an array local (slot_elem:
    // struct sid / -3 string / -1 scalar), or -99 if the expression is not an index of a known array.
    fn index_elem_code(self, e: ps.Expr) -> int {
        match e {
            case EIndex(object, index) {
                match object.value {
                    case EIdent(name) {
                        let slot = self.resolve_slot(name)
                        if slot >= 0 && self.slot_array[slot] {
                            return self.slot_elem[slot]
                        }
                    }
                    case EGet(inner, fname) {
                        // `obj.field[i]` — the element kind of the indexed struct FIELD array (e.g. self.toks[i]).
                        let osid = self.expr_type_kind(inner.value)
                        if osid >= 0 {
                            return self.field_elem_code(osid, fname)
                        }
                    }
                    case _ {
                    }
                }
            }
            case _ {
            }
        }
        return 0 - 99
    }


    // gen_append_value lowers an `arr.append(x)` element: a struct LITERAL is built BOXED (NEW_STRUCT) so
    // ARRAY_APPEND can pack its bytes into an inline struct array; any other value consumes normally.
    fn gen_append_value(mut self, arg: ps.Expr, line: int) {
        if self.struct_value_info(arg) >= 0 {
            self.gen_struct_construct(arg, line, true)
        } else {
            self.gen_consume(arg, line)
        }
    }


    // emit_empty_array lowers an empty array literal `[]` of element type `elem_ty`: an all-scalar struct
    // element packs INLINE (NEW_STRUCT_ARRAY <count> <sid>), every other element kind is boxed/scalar
    // (NEW_ARRAY <count> <kind>).
    // struct_array_inline reports whether an array may store struct `id` INLINE (NEW_STRUCT_ARRAY): every
    // field must be a packed scalar OR a 16-byte REFCOUNTED box (string/enum) — both shallow-copyable per
    // element. A field that is an array, a nested struct, OR a 16-byte NON-refcounted unique owner (a generic
    // type-param field like `Box<T>.value`) is NOT inline-packable (a shallow copy would alias/double-free) —
    // mirrors src/check.c:array_inline_struct_id (`sz==16 && !is_refcounted -> not inline`).
    fn struct_array_inline(self, id: int) -> bool {
        var i = 0
        var seen = false
        loop {
            if i >= self.st_fowner.len() {
                break
            }
            if self.st_fowner[i] == id {
                seen = true
                if self.st_farray[i] || self.st_fstruct[i] >= 0 {
                    return false
                }
                // a non-scalar, non-string, non-enum field is a generic type-param (`T`): 16-byte but not
                // refcounted -> a unique owner that can't be shallow-packed.
                if self.st_fscalar[i] == false && self.st_fstring[i] == false && self.st_fenum[i] == false {
                    return false
                }
            }
            i = i + 1
        }
        return seen
    }


    fn emit_empty_array(mut self, elem_ty: ps.Ty, line: int) {
        self.cur_line = line
        let esid = self.type_struct_id(elem_ty)
        if esid >= 0 && self.struct_array_inline(esid) {
            self.emit(OP_NEW_STRUCT_ARRAY)
            self.emit_idx(0)
            self.emit_idx(esid)
        } else {
            self.emit(OP_NEW_ARRAY)
            self.emit_idx(0)
            self.emit(array_elem_kind_from_ty(elem_ty))
        }
    }


    // gen_field_access emits a struct field read `obj.name`: an all-scalar (multi-slot) struct is
    // GET_LOCAL(base + index); a boxed struct is GET_LOCAL(base) then GET_FIELD(index). Returns true if
    // handled. (A `var`/mutated all-scalar struct is boxed too, but that case is deferred.)
    // generic_call_ret_sid returns the concrete struct id a bounded generic call yields when its result is a
    // boxed erased value of a type argument (`max<T>()->T` with T=Version returns a boxed Version), or -1.
    // Used so `f(...).field` on such a result reads GET_FIELD_OWNED off the boxed struct even when that struct
    // is all-scalar (erased returns are always boxed).
    // gret_call_index returns the generic-return-table row for a call to a generic fn whose return is a bare
    // type-param `T` or `[T]` (so the result's concrete type is inferred from an argument), or -1 (OFI-174).
    fn gret_call_index(self, e: ps.Expr) -> int {
        match e {
            case ECall(callee, args) {
                match callee.value {
                    case EIdent(name) {
                        return cg_index_of(self.gret_fn, name)
                    }
                    case EGet(obj, mname) {
                        // a module-qualified free-fn call (`list.sort(...)`): the alias is inert, mname is the fn.
                        match obj.value {
                            case EIdent(mod) {
                                if self.resolve_slot(mod) < 0 {
                                    return cg_index_of(self.gret_fn, mname)
                                }
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
            case _ {
                return 0 - 1
            }
        }
    }


    // gret_arg_elem returns the array-element type code of a `[T]`-returning generic call's determining argument
    // (`sort(words)` -> words's element, -3 for [string]), or -1.
    fn gret_arg_elem(self, e: ps.Expr, gi: int) -> int {
        match e {
            case ECall(callee, args) {
                let ai = self.gret_argidx[gi]
                if ai >= 0 && ai < args.len() {
                    match args[ai] {
                        case EIdent(nm) {
                            let s = self.resolve_slot(nm)
                            if s >= 0 && self.slot_array[s] {
                                return self.slot_elem[s]
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


    // array_lit_elem_code returns the element type code of an array LITERAL from its first element (a string
    // element -> -3, a struct element -> its sid), or -1 (scalar / empty / unknown).
    fn array_lit_elem_code(self, e: ps.Expr) -> int {
        match e {
            case EArray(elems, lines) {
                if elems.len() > 0 {
                    if self.expr_is_string(elems[0]) {
                        return 0 - 3
                    }
                    let sid = self.struct_value_info(elems[0])
                    if sid >= 0 {
                        return sid
                    }
                }
            }
            case _ {
            }
        }
        return 0 - 1
    }


    // gret_arg_is_string reports whether a bare-`T`-returning generic call's determining argument is a string
    // (`gtwice(f, "hi")` -> the result is an owned string).
    fn gret_arg_is_string(self, e: ps.Expr, gi: int) -> bool {
        match e {
            case ECall(callee, args) {
                let ai = self.gret_argidx[gi]
                if ai >= 0 && ai < args.len() {
                    return self.expr_is_string(args[ai])
                }
            }
            case _ {
            }
        }
        return false
    }


    fn generic_call_ret_sid(self, e: ps.Expr) -> int {
        match e {
            case ECall(callee, args) {
                match callee.value {
                    case EIdent(name) {
                        if cg_index_of(self.gb_fn, name) >= 0 {
                            var gwi = 0
                            loop {
                                if gwi >= self.gb_fn.len() {
                                    break
                                }
                                if self.gb_fn[gwi] == name {
                                    let ai = self.gb_argidx[gwi]
                                    if ai >= 0 && ai < args.len() {
                                        return cg_index_of(self.st_names, self.arg_type_name(args[ai]))
                                    }
                                    return 0 - 1
                                }
                                gwi = gwi + 1
                            }
                        }
                        return 0 - 1
                    }
                    case _ {
                        return 0 - 1
                    }
                }
            }
            case _ {
                return 0 - 1
            }
        }
    }


    fn gen_field_access(mut self, object: ps.Expr, name: string) -> bool {
        // A bounded/erased generic call returns a BOXED value of its concrete type argument (even an all-scalar
        // struct is boxed when erased), so `f(...).field` evaluates the call and GET_FIELD_OWNEDs it (OFI-174).
        let gsid = self.generic_call_ret_sid(object)
        if gsid >= 0 {
            let ln = self.cur_line
            self.gen_expr(object, ln)
            self.cur_line = ln
            self.emit(OP_GET_FIELD_OWNED)
            self.emit_idx(self.struct_field_index(gsid, name))
            return true
        }
        match object {
            case EIdent(oname) {
                let slot = self.resolve_slot(oname)
                if slot < 0 {
                    return false
                }
                let sid = self.slot_struct[slot]
                if sid < 0 {
                    return false
                }
                if self.slot_boxed[slot] {
                    self.emit(OP_GET_LOCAL)
                    self.emit_idx(slot)
                    self.emit(OP_GET_FIELD)
                    self.emit_idx(self.struct_field_index(sid, name))
                } else {
                    self.emit(OP_GET_LOCAL)
                    self.emit_idx(slot + self.struct_field_index(sid, name))
                }
                return true
            }
            case _ {
                // A field read off a NON-identifier object (a call result, a construction): evaluate the
                // object, then extract the field. A boxed-struct owning temp uses GET_FIELD_OWNED (drops the
                // receiver box after extracting); a borrowed place uses GET_FIELD. (Multi-slot temps —
                // a flat-struct call result — are deferred to the nested-flattening work.)
                let tk = self.expr_type_kind(object)
                if tk >= 0 && self.struct_all_scalar(tk) == false {
                    let ln = self.cur_line
                    self.gen_expr(object, ln)
                    self.cur_line = ln
                    if self.is_owning_temp_obj(object) {
                        self.emit(OP_GET_FIELD_OWNED)
                    } else {
                        self.emit(OP_GET_FIELD)
                    }
                    self.emit_idx(self.struct_field_index(tk, name))
                    return true
                }
                return false
            }
        }
    }


    // is_owning_temp_obj reports whether a field-read OBJECT is a fresh owned struct TEMPORARY (so `.field`
    // uses GET_FIELD_OWNED, dropping the receiver box) vs a borrowed PLACE (plain GET_FIELD). Mirrors the
    // checker's is_owning_temp for the field-read object (src/check.c:2752): a call/construction is owning;
    // `arr[i]` is owning ONLY when the array stores INLINE structs (a boxed-element array like `[Param]`
    // yields a borrowed place — a fresh copy is NOT materialised); a nested `obj.field` is owning iff the
    // OBJECT it reads from is itself an owning temp (the deferred inline-nested case is rare).
    fn is_owning_temp_obj(self, e: ps.Expr) -> bool {
        match e {
            case ECall(callee, args) {
                return true
            }
            case EStructLit(ty, fields) {
                return true
            }
            case EIndex(object, index) {
                let ec = self.index_elem_code(e)
                return ec >= 0 && self.struct_array_inline(ec)
            }
            case EGet(object, name) {
                return self.is_owning_temp_obj(object.value)
            }
            case _ {
                return false
            }
        }
    }


    // emit_drops releases every owned refcounted local on a function-exit path (DROP <slot>, highest first).
    fn emit_drops(mut self) {
        var i = self.local_drop.len() - 1
        loop {
            if i < 0 {
                break
            }
            if self.local_drop[i] {
                self.emit(OP_DROP)
                self.emit_idx(i)
            }
            i = i - 1
        }
    }


    // emit_ensures checks this function's `ensures` clauses at a return point. The return value is already
    // on the stack, occupying the slot just past the declared locals; bind `result` there so the predicate
    // can read it (GET_LOCAL), evaluate each clause, and CONTRACT_CHECK <running index>. The binding is a
    // borrow (the real value stays on the stack for RETURN) and is removed afterwards. Emitted BEFORE the
    // exit drops and RETURN. (A struct/RETURN_STRUCT result's ensures is a later increment.)
    fn emit_ensures(mut self) {
        if self.fn_ens_e.len() == 0 {
            return
        }
        let rs = self.locals.len()
        self.declare_binding("result", 1, -1, false, false, false, false)
        self.slot_kind[self.slot_kind.len() - 1] = self.ret_kind
        var ei = 0
        loop {
            if ei >= self.fn_ens_e.len() {
                break
            }
            self.gen_expr(self.fn_ens_e[ei], self.fn_ens_l[ei])
            let msg = "postcondition failed in '{self.cur_fn_name}' (ensures, line {self.fn_ens_l[ei]})"
            self.emit(OP_CONTRACT_CHECK)
            self.emit_idx(self.add_string(msg))
            ei = ei + 1
        }
        self.truncate_to(rs)
    }


    // expr_is_string reports whether an expression has string type (so `+` lowers to CONCAT not ADD).
    // Step 1 sees string literals/interpolation and `+`-chains of them; locals/calls come with type tracking.
    fn expr_is_string(self, e: ps.Expr) -> bool {
        match e {
            case EStr(parts) {
                return true
            }
            case EBinary(op, l, r) {
                if ps.binop_id(op) == 1 {
                    return self.expr_is_string(l.value) || self.expr_is_string(r.value)
                }
                return false
            }
            case EIdent(name) {
                let slot = self.resolve_slot(name)
                if slot < 0 {
                    let gi = cg_index_of(self.gc_names, name)   // a global string constant inlines to a string
                    return gi >= 0 && self.gc_kind[gi] == 1
                }
                return self.local_str[slot]
            }
            case EGet(object, name) {
                // a string field read off any struct-typed object (a local, OR an owning temp like `arr[i]`)
                let osid = self.expr_type_kind(object.value)
                if osid < 0 {
                    return false
                }
                return self.field_is_string(osid, name)
            }
            case _ {
                return false
            }
        }
    }


    // hole_is_str_temp reports whether an interpolation hole is a FRESH OWNED STRING (stage-0 `string_temp`):
    // a string-typed value that is an OWNING TEMP — a call returning a string, a string concat `a + b`, or a
    // nested interpolation. Such a hole already leaves an owned reference the fold's CONCAT consumes, so its
    // TO_STRING is SKIPPED (else the reference leaks). A borrowed string (local/field/element) is NOT a temp.
    fn hole_is_str_temp(self, e: ps.Expr) -> bool {
        match e {
            case EStr(parts) {
                return true
            }
            case ECall(callee, args) {
                return self.expr_type_kind(e) == 0 - 3   // a string-returning call (owning temp)
            }
            case EBinary(op, l, r) {
                return self.expr_is_string(e)            // a string concat -> a fresh owned string
            }
            case _ {
                return false
            }
        }
    }


    // extern_ret_kind returns the DECLARED return scalar kind of an `extern "c"` fn (i32=3, i64=0, f64=9, …),
    // so `let r = strncmp(...)`/`{sin(x)}` renders/widths at the declared type (the ABI registry can't tell
    // i32 from i64 — both are 'i'). 0 if not found (a valid extern call always resolves).
    fn extern_ret_kind(self, name: string) -> int {
        var i = 0
        loop {
            if i >= self.ext_names.len() {
                break
            }
            if self.ext_names[i] == name {
                return self.ext_kinds[i]
            }
            i = i + 1
        }
        return 0
    }


    // scalar_kind_of returns the NUM_KIND of a numeric expression (the checker's int_kind: int=0, sized 1..7,
    // f32=8, f64=9 — bool is int_kind 0 here, NOT the render-kind 10). Drives a binary op's width operand. A
    // value whose kind the codegen can't infer (a field/call/index — pending st_fkind/fn-ret-kind) is 0 (int).
    fn scalar_kind_of(self, e: ps.Expr) -> int {
        match e {
            case EFloat(v) {
                return 9
            }
            case EInt(v, kind) {
                return kind
            }
            case EIdent(name) {
                let slot = self.resolve_slot(name)
                if slot >= 0 {
                    let k = self.slot_kind[slot]
                    if k == 10 {
                        return 0                     // bool: render-kind 10 but int_kind 0 for num_kind
                    }
                    return k
                }
                return 0
            }
            case EBinary(op, l, r) {
                return self.scalar_kind_of(l.value)  // arithmetic preserves its operand kind
            }
            case ECall(callee, args) {
                // a wrapping intrinsic preserves its first operand's width; any other call carries its
                // declared return width (bool return -> 0 for a num_kind operand).
                match callee.value {
                    case EIdent(name) {
                        if wrapping_opcode(name) >= 0 && args.len() > 0 {
                            return self.scalar_kind_of(args[0])
                        }
                        if cextern_index(name) >= 0 && cg_index_of(self.fn_names, name) < 0 {
                            let ck = self.extern_ret_kind(name)
                            if ck == 10 {
                                return 0
                            }
                            return ck
                        }
                    }
                    case _ {
                    }
                }
                let idx = self.resolve_call_fn_index(callee.value)
                if idx >= 0 {
                    let k = self.fn_ret_kind[idx]
                    if k == 10 {
                        return 0
                    }
                    return k
                }
                return 0
            }
            case EGet(object, name) {
                // a scalar field read `self.x` carries the field's width (a float field -> f64=9)
                let osid = self.expr_type_kind(object.value)
                if osid >= 0 {
                    let k = self.field_kind(osid, name)
                    if k == 10 {
                        return 0
                    }
                    return k
                }
                return 0
            }
            case _ {
                return 0
            }
        }
    }


    // render_kind_of returns the TO_STRING render kind of an interpolation hole expression — the checker's
    // `render_kind` (int_kind + bool=10): a float literal/binding renders as f64=9, a bool as 10, an int (and
    // any value whose scalar kind the codegen can't infer) as 0. Mirrors check.c:5284.
    fn render_kind_of(self, e: ps.Expr) -> int {
        match e {
            case EFloat(v) {
                return 9
            }
            case EInt(v, kind) {
                return kind
            }
            case EBool(v) {
                return 10
            }
            case EIdent(name) {
                let slot = self.resolve_slot(name)
                if slot >= 0 {
                    return self.slot_kind[slot]
                }
                return 0
            }
            case EGet(object, name) {
                // a scalar field hole `{p.x}` renders at the field's width (a float field -> f64=9).
                let osid = self.expr_type_kind(object.value)
                if osid >= 0 {
                    return self.field_kind(osid, name)
                }
                return 0
            }
            case EIndex(object, index) {
                // an element hole `{obj.farr[i]}` of a scalar FIELD array (e.g. `chunk.const_float[i]`):
                // render with the field's element kind (the array's AEK byte mapped to the render kind).
                match object.value {
                    case EGet(inner, fname) {
                        let osid = self.expr_type_kind(inner.value)
                        if osid >= 0 {
                            return aek_to_render_kind(self.field_arr_kind(osid, fname))
                        }
                    }
                    case _ {
                    }
                }
                return 0
            }
            case EBinary(op, l, r) {
                // an arithmetic hole `{sum / 3}` renders with its operand's width; a comparison/logical hole
                // renders as a bool.
                let bid = ps.binop_id(op)
                if bid >= 6 && bid <= 13 {
                    return 10
                }
                return self.render_kind_of(l.value)
            }
            case EUnary(op, operand) {
                return self.render_kind_of(operand.value)
            }
            case ECall(callee, args) {
                // a wrapping intrinsic hole `{wrapping_add(a, b)}` renders at its operand width; any other
                // call renders at its declared return width (`{fnv1a(s)}` where fnv1a -> u32 renders as 6).
                match callee.value {
                    case EIdent(name) {
                        if wrapping_opcode(name) >= 0 && args.len() > 0 {
                            return self.render_kind_of(args[0])
                        }
                        if cextern_index(name) >= 0 && cg_index_of(self.fn_names, name) < 0 {
                            return self.extern_ret_kind(name)
                        }
                    }
                    case _ {
                    }
                }
                let idx = self.resolve_call_fn_index(callee.value)
                if idx >= 0 {
                    return self.fn_ret_kind[idx]
                }
                return 0
            }
            case _ {
                return 0
            }
        }
    }


    // infer_render_kind derives the scalar (render/num) kind an initialiser produces, so a `let x = …`
    // binding without an annotation still carries its width: a float is 9, a bool 10, a comparison/logical
    // result is a bool (10), and arithmetic/bitwise preserves its (left) operand's kind — so `let s = u64a +
    // u64b` is u64 (7). Mirrors the checker's type of the initialiser closely enough for num_kind parity.
    fn infer_render_kind(self, e: ps.Expr) -> int {
        match e {
            case EFloat(v) {
                return 9
            }
            case EBool(v) {
                return 10
            }
            case EIdent(name) {
                let slot = self.resolve_slot(name)
                if slot >= 0 {
                    return self.slot_kind[slot]
                }
                return 0
            }
            case EBinary(op, l, r) {
                let bid = ps.binop_id(op)
                if bid >= 6 && bid <= 13 {
                    return 10                        // comparison/logical -> a bool result
                }
                return self.infer_render_kind(l.value)   // arithmetic/bitwise preserve the operand's kind
            }
            case EUnary(op, operand) {
                return self.infer_render_kind(operand.value)
            }
            case EGet(object, name) {
                // `let dx = self.x - other.x` needs the field's width so `dx * dx` is float, not int.
                let osid = self.expr_type_kind(object.value)
                if osid >= 0 {
                    return self.field_kind(osid, name)
                }
                return 0
            }
            case EIndex(object, index) {
                return self.render_kind_of(e)   // reuse the field-array element-kind inference
            }
            case ECall(callee, args) {
                return self.render_kind_of(e)   // a call binding's width (extern f64, wrapping, or fn_ret_kind)
            }
            case _ {
                return 0
            }
        }
    }


    fn resolve_slot(self, name: string) -> int {
        var i = self.locals.len() - 1
        loop {
            if i < 0 {
                break
            }
            if self.locals[i] == name {
                return i
            }
            i = i - 1
        }
        return -1
    }


    // type_struct_id returns the struct id named by a type annotation, or -1 if it is not a struct. The
    // qualifier is IGNORED (an imported `c.RGB` resolves to `RGB` — the merged module universe holds every
    // struct by name, exactly as type_enum_id resolves an imported enum).
    fn type_struct_id(self, ty: ps.Ty) -> int {
        match ty {
            case TyName(qual, name) {
                return self.struct_id_of(name)
            }
            case TyGeneric(qual, name, args) {
                return self.struct_id_of(name)   // a generic struct literal `Box<Ty>{…}` resolves to `Box`
            }
            case _ {
                return -1
            }
        }
    }


    // lit_struct_id returns the runtime struct id used as a NEW_STRUCT operand for a struct LITERAL of type
    // `ty`. A monomorphized generic instance (`Box<Expr>{…}`) gets its own id appended after the declared
    // structs (`struct_count + instance_index`, mirroring stage-0's struct_instance_id); a plain struct keeps
    // its declared id. The FIELD LAYOUT (count/order) is unchanged — only the box's type id differs.
    // struct_is_bounded reports whether struct `sname` has a bounded type parameter (so it carries hidden
    // witness fields and an erased construction of it uses the base struct id).
    fn struct_is_bounded(self, sname: string) -> bool {
        var i = 0
        loop {
            if i >= self.sg_struct.len() {
                break
            }
            if self.sg_struct[i] == sname && self.sg_bound[i] != "" {
                return true
            }
            i = i + 1
        }
        return false
    }


    // struct_declared_field_count returns a struct's DECLARED field count (excluding the hidden witness fields
    // a bounded generic struct carries) — the index where its witness fields begin.
    fn struct_declared_field_count(self, sid: int) -> int {
        var n = 0
        var i = 0
        loop {
            if i >= self.st_fowner.len() {
                break
            }
            if self.st_fowner[i] == sid && self.st_fname[i] != "$wit" {
                n = n + 1
            }
            i = i + 1
        }
        return n
    }


    // ty_args_have_tparam reports whether any type argument is a bare type parameter of the enclosing fn (an
    // ERASED construction like `Bag<K>` inside new_bag<int>).
    fn ty_args_have_tparam(self, args: [ps.Ty]) -> bool {
        var i = 0
        loop {
            if i >= args.len() {
                break
            }
            match args[i] {
                case TyName(qual, name) {
                    if qual == "" && cg_index_of(self.cur_tp_names, name) >= 0 {
                        return true
                    }
                }
                case _ {
                }
            }
            i = i + 1
        }
        return false
    }


    // ty_args_have_erased_struct_tparam reports whether any type argument is an ERASED type-parameter that is
    // NOT the current fn's (monomorphized) type-param — i.e. a bare name that is not a known struct, enum, or
    // scalar and is not in cur_tp_names. This is the STRUCT type-param `K`/`V` of a bounded-struct method
    // (`MapEntry<K,V>` in `Map._put`, compiled once with K/V erased): its construction uses the BASE id, unlike
    // a monomorphized fn's `Box<T>` (T bound to a concrete type, in cur_tp_names) which takes an instance.
    fn ty_args_have_erased_struct_tparam(self, args: [ps.Ty]) -> bool {
        var i = 0
        loop {
            if i >= args.len() {
                break
            }
            match args[i] {
                case TyName(qual, name) {
                    if qual == "" && ty_is_scalar(args[i]) == false && ty_is_string(args[i]) == false {
                        if cg_index_of(self.st_names, name) < 0 && cg_index_of(self.et_names, name) < 0 && cg_index_of(self.cur_tp_names, name) < 0 {
                            return true
                        }
                    }
                }
                case _ {
                }
            }
            i = i + 1
        }
        return false
    }


    fn lit_struct_id(self, ty: ps.Ty) -> int {
        match ty {
            case TyGeneric(qual, name, args) {
                let base = self.struct_id_of(name)
                if base < 0 {
                    return base
                }
                // An ERASED construction of a BOUNDED generic struct (`Bag<K>` in new_bag<int>) uses the BASE
                // struct id (its witness-augmented layout), not a monomorphized instance. An unbounded struct
                // (`Box<T>`) still monomorphizes per instantiation (OFI-174).
                if self.struct_is_bounded(name) && self.ty_args_have_tparam(args) {
                    return base
                }
                // An unbounded struct built from an ERASED STRUCT type-param (`MapEntry<K,V>` in `Map._put`,
                // where K/V are the receiver struct's type-params, compiled once) also uses the BASE id — there
                // is no per-K/V monomorphized instance for a method compiled once over erased type-params.
                if self.ty_args_have_erased_struct_tparam(args) {
                    return base
                }
                let ii = cg_index_of(self.inst_keys, ty_key(ty))
                if ii < 0 {
                    return base
                }
                return self.st_names.len() + ii
            }
            case _ {
                return self.type_struct_id(ty)
            }
        }
    }


    // type_enum_id returns the enum id a type names (a user enum `Dir`, a generic `Option<…>`/`Result<…>`, or
    // an imported `ml.Lib` — the qualifier is ignored since merged module enums share one table by name),
    // else -1. An enum is a heap/move value, so an enum binding/param is owned and dropped at scope exit.
    fn type_enum_id(self, ty: ps.Ty) -> int {
        match ty {
            case TyName(qual, name) {
                return cg_index_of(self.et_names, name)
            }
            case TyGeneric(qual, name, args) {
                return cg_index_of(self.et_names, name)
            }
            case _ {
                return -1
            }
        }
    }


    // declare_binding adds a binding occupying `span` consecutive slots (a multi-slot all-scalar struct
    // uses filler slots after the base so slot == array index still holds). `droppable` marks an owned
    // refcounted value (a string, or an owned boxed-struct `let`) to DROP at function exit.
    fn declare_binding(mut self, name: string, span: int, struct_id: int, is_str: bool, droppable: bool, boxed: bool, is_array: bool) {
        self.locals.append(name)
        self.local_str.append(is_str)
        self.local_drop.append(droppable)
        self.slot_struct.append(struct_id)
        self.slot_boxed.append(boxed)
        self.slot_array.append(is_array)
        self.slot_elem.append(0 - 1)            // element type is set post-hoc for array bindings
        self.slot_kind.append(0)                // scalar kind set post-hoc; 0 (int) for non-float scalars
        var k = 1
        loop {
            if k >= span {
                break
            }
            self.locals.append("")
            self.local_str.append(false)
            self.local_drop.append(false)
            self.slot_struct.append(-1)
            self.slot_boxed.append(false)
            self.slot_array.append(false)
            self.slot_elem.append(0 - 1)
            self.slot_kind.append(0)
            k = k + 1
        }
    }


    // declare_param declares a parameter: an all-scalar struct is multi-slot; a boxed struct is one slot
    // (but still records its struct id for field access); a string is a droppable refcounted slot.
    fn declare_param(mut self, p: ps.Param) {
        if p.ty.len() == 0 {
            self.declare_binding(p.name, 1, -1, false, false, false, false)
            return
        }
        if ty_is_array(p.ty[0]) {
            self.declare_binding(p.name, 1, -1, false, false, false, true)   // array param: borrow, an array
            self.slot_elem[self.slot_elem.len() - 1] = self.array_elem_type_code(elem_ty_of(p.ty[0]))
            return
        }
        if ty_is_channel(p.ty[0]) {
            self.declare_binding(p.name, 1, -1, false, true, false, false)   // channel param: owned, droppable handle
            return
        }
        if ty_is_fn(p.ty[0]) {
            self.declare_binding(p.name, 1, -1, false, true, false, false)   // fn-value param: owned closure, droppable
            return
        }
        if self.type_enum_id(p.ty[0]) >= 0 {
            self.declare_binding(p.name, 1, -1, false, true, false, false)   // enum param: owned, droppable
            return
        }
        let sid = self.type_struct_id(p.ty[0])
        if sid >= 0 {
            // a plain (borrow) all-scalar struct param is multi-slot; a `mut`/`move` or refcounted-field one
            // is boxed. Either way a struct param is a BORROW — not dropped (unlike a string param).
            if p.qual == 0 && self.struct_all_scalar(sid) {
                self.declare_binding(p.name, self.struct_field_count(sid), sid, false, false, false, false)
            } else {
                self.declare_binding(p.name, 1, sid, false, false, true, false)
            }
        } else {
            let s = param_is_string(p)
            self.declare_binding(p.name, 1, -1, s, s, false, false)    // a string param IS owned/droppable
            if s == false {
                self.slot_kind[self.slot_kind.len() - 1] = ty_scalar_kind(p.ty[0])   // a float/bool param renders right
            }
        }
    }


    // return_struct_span is the slot count of an all-scalar-struct return type (so the trailing return and
    // a `return P{...}` use RETURN_STRUCT), or 0 for scalar/string/boxed returns (plain RETURN).
    fn return_struct_span(self, ret: [ps.Ty]) -> int {
        if ret.len() == 0 {
            return 0
        }
        let sid = self.type_struct_id(ret[0])
        if sid >= 0 && self.struct_all_scalar(sid) {
            return self.struct_field_count(sid)
        }
        return 0
    }


    // emit_jump writes a jump opcode + a 2-byte 0xffff placeholder, returning the operand position to patch.
    fn emit_jump(mut self, op: int) -> int {
        self.emit(op)
        self.emit(255)
        self.emit(255)
        return self.code.len() - 2
    }


    // patch_jump fills a forward jump's placeholder with the distance from just after it to here.
    fn patch_jump(mut self, pos: int) {
        let dist = self.code.len() - pos - 2
        self.code[pos] = dist / 256
        self.code[pos + 1] = dist % 256
    }


    // emit_loop writes an OP_LOOP whose operand is the backward distance to `loop_start`.
    fn emit_loop(mut self, loop_start: int) {
        self.emit(OP_LOOP)
        let dist = self.code.len() - loop_start + 2
        self.emit(dist / 256)
        self.emit(dist % 256)
    }


    // gen_block lowers a nested block: its statements, then the unwind of the block-scoped locals it
    // declared (one POP each for scalars — stage-0 cg_unwind), then truncates the slot table back.
    fn gen_block(mut self, body: [ps.Stmt]) {
        let saved = self.locals.len()
        var i = 0
        loop {
            if i >= body.len() {
                break
            }
            self.gen_stmt(body[i])
            i = i + 1
        }
        self.unwind_to(saved)
    }


    // unwind_to releases (DROP owned / POP borrowed) every local above `saved`, top-down, then truncates the
    // per-slot tables back to `saved` — the scope-exit discipline shared by blocks and match cases.
    fn unwind_to(mut self, saved: int) {
        self.emit_unwind(saved)
        self.truncate_to(saved)
    }


    // emit_unwind releases every local above `saved` (DROP owned + POP the slot, top-down) WITHOUT truncating
    // the tables — used by `break`/`continue`, which jump out of a still-live scope (the body's fall-through
    // unwinds the tables itself).
    fn emit_unwind(mut self, saved: int) {
        var n = self.locals.len() - 1
        loop {
            if n < saved {
                break
            }
            if self.local_drop[n] {
                self.emit(OP_DROP)               // an owned refcounted local: decref it, THEN pop the slot
                self.emit_idx(n)
            }
            self.emit(OP_POP)                    // clear the stack slot too
            n = n - 1
        }
    }


    // truncate_to drops the per-slot tables back to `saved` WITHOUT emitting any release (the caller already
    // emitted the stack cleanup) — the logical unwind stage-0 calls cg_unwind, used for the match subject.
    fn truncate_to(mut self, saved: int) {
        var kept: [string] = []
        var ksr: [bool] = []
        var kdr: [bool] = []
        var kss: [int] = []
        var ksb: [bool] = []
        var ksa: [bool] = []
        var kse: [int] = []
        var ksk: [int] = []
        var k = 0
        loop {
            if k >= saved {
                break
            }
            kept.append(self.locals[k])
            ksr.append(self.local_str[k])
            kdr.append(self.local_drop[k])
            kss.append(self.slot_struct[k])
            ksb.append(self.slot_boxed[k])
            ksa.append(self.slot_array[k])
            kse.append(self.slot_elem[k])
            ksk.append(self.slot_kind[k])
            k = k + 1
        }
        self.locals = kept
        self.local_str = ksr
        self.local_drop = kdr
        self.slot_struct = kss
        self.slot_boxed = ksb
        self.slot_array = ksa
        self.slot_elem = kse
        self.slot_kind = ksk
    }


    // pop_loop_ctx ends a loop's context: truncate break_jumps to `base`, drop the top cont/base entries.
    // patch_breaks resolves every pending break-JUMP at or above `base` to the current position (the loop
    // exit) — shared by `loop` and `for`.
    fn patch_breaks(mut self, base: int) {
        var bi = base
        loop {
            if bi >= self.break_jumps.len() {
                break
            }
            self.patch_jump(self.break_jumps[bi])
            bi = bi + 1
        }
    }


    fn pop_loop_ctx(mut self, base: int) {
        var kb: [int] = []
        var i = 0
        loop {
            if i >= base {
                break
            }
            kb.append(self.break_jumps[i])
            i = i + 1
        }
        self.break_jumps = kb
        var kc: [int] = []
        var j = 0
        loop {
            if j >= self.cont_targets.len() - 1 {
                break
            }
            kc.append(self.cont_targets[j])
            j = j + 1
        }
        self.cont_targets = kc
        var klb: [int] = []
        var p = 0
        loop {
            if p >= self.loop_bases.len() - 1 {
                break
            }
            klb.append(self.loop_bases[p])
            p = p + 1
        }
        self.loop_bases = klb
        var kbase: [int] = []
        var m = 0
        loop {
            if m >= self.break_bases.len() - 1 {
                break
            }
            kbase.append(self.break_bases[m])
            m = m + 1
        }
        self.break_bases = kbase
    }


    // gen_expr lowers an expression. `line` is its source line (from the Box that held it); cur_line is set
    // here so every byte the expression emits is attributed to it (stage-0 gen_expr sets current_line=e->line).
    fn gen_expr(mut self, e: ps.Expr, line: int) {
        self.cur_line = line
        match e {
            case EInt(v, _) {
                let idx = self.add_const_int(v)
                self.emit(OP_CONST)
                self.emit_idx(idx)
            }
            case EFloat(v) {
                let idx = self.add_const_float(v)
                self.emit(OP_CONST)
                self.emit_idx(idx)
            }
            case EBool(v) {
                if v {
                    self.emit(OP_TRUE)
                } else {
                    self.emit(OP_FALSE)
                }
            }
            case EIdent(name) {
                let slot = self.resolve_slot(name)
                if slot >= 0 {
                    self.emit(OP_GET_LOCAL)
                    self.emit_idx(slot)
                } else {
                    // not a local: a bare (zero-field) enum variant -> NEW_ENUM, or a top-level constant
                    // referenced by name -> inline its folded literal value.
                    let vi = cg_index_of(self.ev_name, name)
                    if vi >= 0 {
                        self.emit(OP_NEW_ENUM)
                        self.emit_idx(self.ev_owner[vi])
                        self.emit_idx(self.ev_tag[vi])
                        self.emit_idx(0)
                    } else {
                        let gi = cg_index_of(self.gc_names, name)
                        if gi >= 0 {
                            self.gen_global_const(gi)
                        } else {
                            let fi = cg_index_of(self.fn_names, name)
                            if fi >= 0 {
                                // a named function used as a VALUE (not called) -> a zero-capture closure
                                self.emit(OP_MAKE_CLOSURE)
                                self.emit_idx(fi)
                                self.emit_idx(0)
                            }
                        }
                    }
                }
            }
            case EStr(parts) {
                var i = 0
                loop {
                    if i >= parts.len() {
                        break
                    }
                    if parts[i].hole.len() == 1 {
                        let h = parts[i].hole[0]
                        self.gen_expr(h, line)
                        // An owning-temp STRING hole (a call/concat/interpolation result) already leaves an
                        // owned reference the fold's CONCAT consumes; the retaining TO_STRING would leak it
                        // (stage-0 `string_temp`, OFI-146). A borrowed string (local/field/element) or a
                        // non-string hole still renders/retains via TO_STRING.
                        if self.hole_is_str_temp(h) == false {
                            self.emit(OP_TO_STRING)
                            self.emit(self.render_kind_of(h))   // render kind: float=9, bool=10, else int=0
                        }
                    } else {
                        let idx = self.add_string(parts[i].text)
                        self.emit(OP_STRING)
                        self.emit_idx(idx)
                    }
                    if i > 0 {
                        self.emit(OP_CONCAT)         // left-fold the parts
                    }
                    i = i + 1
                }
            }
            case EUnary(op, operand) {
                // a prefix unary op: gen the operand, then NEG (minus) / NOT (!) / BITNOT (~). NEG and BITNOT
                // carry the operand's width kind (num_kind); NOT does not.
                self.gen_expr(operand.value, operand.line)
                let uid = ps.unop_id(op)
                if uid == 1 {
                    self.emit(OP_NEG)
                    self.emit(self.scalar_kind_of(operand.value))
                } else if uid == 2 {
                    self.emit(OP_NOT)
                } else if uid == 3 {
                    self.emit(OP_BITNOT)
                    self.emit(self.scalar_kind_of(operand.value))
                }
            }
            case EBinary(op, l, r) {
                let bid = ps.binop_id(op)
                if bid == 1 && (self.expr_is_string(l.value) || self.expr_is_string(r.value)) {
                    self.gen_consume(l.value, l.line)  // string concatenation -> the consuming OP_CONCAT
                    self.gen_consume(r.value, r.line)  // (a borrowed string-local operand is INCREF'd)
                    self.emit(OP_CONCAT)
                } else if bid == 12 {
                    // a && b: short-circuit. If a is false it stays on the stack AS the result; else pop it
                    // and the result is b.
                    self.gen_expr(l.value, l.line)
                    let jif = self.emit_jump(OP_JUMP_IF_FALSE)
                    self.emit(OP_POP)
                    self.gen_expr(r.value, r.line)
                    self.patch_jump(jif)
                } else if bid == 13 {
                    // a || b: short-circuit. If a is true it stays AS the result (jump past b); else pop it
                    // and the result is b.
                    self.gen_expr(l.value, l.line)
                    let jif = self.emit_jump(OP_JUMP_IF_FALSE)
                    let jend = self.emit_jump(OP_JUMP)
                    self.patch_jump(jif)
                    self.emit(OP_POP)
                    self.gen_expr(r.value, r.line)
                    self.patch_jump(jend)
                } else {
                    self.gen_expr(l.value, l.line)
                    self.gen_expr(r.value, r.line)   // the op emits at the right operand's line
                    let opc = binop_to_opcode(bid)
                    self.emit(opc)
                    if op_kcount()[opc] == 1 {
                        // num_kind = the operands' width (int=0, sized, f32=8, f64=9). Stage-0 uses the LEFT
                        // operand's int_kind; fall back to the right when the left is an untracked 0 (a literal
                        // typed on the other side), so `obj.f > 0.0` still gets the float kind.
                        var nk = self.scalar_kind_of(l.value)
                        if nk == 0 {
                            nk = self.scalar_kind_of(r.value)
                        }
                        self.emit(nk)
                    }
                }
            }
            case ECall(callee, args) {
                match callee.value {
                    case EGet(object, mname) {
                        self.gen_method_call(object.value, mname, args, line)
                    }
                    case EIdent(name) {
                        if self.resolve_slot(name) >= 0 {
                            // the callee is a fn-typed LOCAL/param value -> a closure call, not a direct CALL
                            self.gen_closure_call(callee.value, args, line)
                            return
                        }
                        let ck = numeric_typename_kind(name)
                        if ck >= 0 && args.len() == 1 {
                            self.gen_expr(args[0], line)             // a numeric-width conversion: CONV <kind>
                            self.cur_line = line
                            self.emit(OP_CONV)
                            self.emit(ck)
                            return
                        }
                        // int<->float conversions are distinct opcodes (a reinterpret of the numeric domain),
                        // NOT a width CONV: to_float(i) -> INT_TO_FLOAT, to_int(f) -> FLOAT_TO_INT.
                        if name == "to_float" && args.len() == 1 {
                            self.gen_expr(args[0], line)
                            self.cur_line = line
                            self.emit(OP_INT_TO_FLOAT)
                            return
                        }
                        if name == "to_int" && args.len() == 1 {
                            self.gen_expr(args[0], line)
                            self.cur_line = line
                            self.emit(OP_FLOAT_TO_INT)
                            return
                        }
                        let wop = wrapping_opcode(name)
                        if wop >= 0 && args.len() == 2 {
                            // built-in wrapping arithmetic `wrapping_add/sub/mul(a, b)` -> push both operands,
                            // then the WRAP_* opcode carrying the operand's width kind (int=0, u32=6, …).
                            self.gen_expr(args[0], line)
                            self.gen_expr(args[1], line)
                            self.cur_line = line
                            self.emit(wop)
                            self.emit(self.scalar_kind_of(args[0]))
                            return
                        }
                        // Channel intrinsics lower to dedicated opcodes, NOT a CALL: channel(cap) -> CHANNEL_NEW,
                        // send(ch, v) -> SEND, recv(ch)/try_recv(ch) -> RECV/TRY_RECV (which build an Option at
                        // runtime, so they carry the Some enum-id + Some/None variant tags), close(ch) -> CLOSE.
                        if name == "channel" && args.len() == 1 {
                            self.gen_expr(args[0], line)
                            self.cur_line = line
                            self.emit(OP_CHANNEL_NEW)
                            return
                        }
                        if name == "send" && args.len() == 2 {
                            self.gen_expr(args[0], line)
                            self.gen_expr(args[1], line)
                            self.cur_line = line
                            self.emit(OP_SEND)
                            return
                        }
                        if name == "recv" && args.len() == 1 {
                            self.gen_expr(args[0], line)
                            self.cur_line = line
                            self.emit(OP_RECV)
                            self.emit_recv_option_operands()
                            return
                        }
                        if name == "try_recv" && args.len() == 1 {
                            self.gen_expr(args[0], line)
                            self.cur_line = line
                            self.emit(OP_TRY_RECV)
                            self.emit_recv_option_operands()
                            return
                        }
                        if name == "close" && args.len() == 1 {
                            self.gen_expr(args[0], line)
                            self.cur_line = line
                            self.emit(OP_CLOSE)
                            return
                        }
                        // An `extern "c"` registry call lowers to CALL_C <registry index> <op>, NOT a normal
                        // CALL. A declared extern is never in fn_names (build_fn_names skips DExtern), so an
                        // in-registry name absent from fn_names is unambiguously an extern call (a user fn of
                        // the same name would be in fn_names -> a plain CALL). op = 0xFFFF for a non-struct
                        // return (every hosted scalar/Ptr/string extern; struct-by-value returns are deferred).
                        if cextern_index(name) >= 0 && cg_index_of(self.fn_names, name) < 0 {
                            self.gen_call_c(name, args, line)
                            return
                        }
                        let nid = native_id_for_name(name)
                        if nid >= 0 {
                            self.gen_builtin_call(nid, args, line)   // a built-in: CALL_NATIVE, not CALL
                            return
                        }
                        let vi = cg_index_of(self.ev_name, name)
                        if vi >= 0 {
                            // a payload enum variant: push the payload args, then NEW_ENUM <eid> <tag> <arity>
                            var a = 0
                            loop {
                                if a >= args.len() {
                                    break
                                }
                                self.gen_consume(args[a], line)
                                a = a + 1
                            }
                            self.cur_line = line
                            self.emit(OP_NEW_ENUM)
                            self.emit_idx(self.ev_owner[vi])
                            self.emit_idx(self.ev_tag[vi])
                            self.emit_idx(self.ev_arity[vi])
                        } else if cg_index_of(self.gb_fn, name) >= 0 {
                            // a BOUNDED generic call: build witnesses + boxed args + CALL the instance (OFI-174).
                            self.gen_bounded_call(name, args, line)
                            self.expected_key = ""
                        } else {
                            // a free-function call: index by name, no self. A GENERIC call retargets to its
                            // monomorphized INSTANCE slot (inst_base + the first-use index of its arg-0 key).
                            var fi = cg_index_of(self.fn_names, name)
                            let gi = cg_index_of(self.generic_fns, name)
                            let is_gen = gi >= 0
                            var pq = ""
                            if is_gen {
                                pq = self.generic_pquals[gi]
                                if args.len() > 0 {
                                    let ix = cg_index_of(self.fn_inst_keys, "{name}<{mono_arg_key(args[0])}>")
                                    if ix >= 0 {
                                        fi = self.inst_base + ix
                                    }
                                } else if self.expected_key.len() > 0 {
                                    // a RETURN-type-inferred generic call (`none_of()`): its type param binds
                                    // from the enclosing `let`'s annotation, threaded in as expected_key.
                                    let ix = cg_index_of(self.fn_inst_keys, "{name}<{self.expected_key}>")
                                    if ix >= 0 {
                                        fi = self.inst_base + ix
                                    }
                                }
                            }
                            self.expected_key = ""   // consume-once: the annotation applies only to this call
                            self.gen_user_call(fi, args, line, is_gen, pq)
                        }
                    }
                    case _ {
                        // the callee is a VALUE expression (e.g. `pick(true)(9)` — a call returning a fn) ->
                        // evaluate it and dispatch through CALL_CLOSURE.
                        self.gen_closure_call(callee.value, args, line)
                    }
                }
            }
            case EStructLit(ty, fields) {
                let sid = self.type_struct_id(ty.value)
                if sid >= 0 {
                    self.gen_struct_fields(sid, fields, line)
                    self.emit_struct_witnesses(ty.value, line)   // bake hidden witness fields (bounded generic struct)
                    if self.struct_all_scalar(sid) == false {
                        self.emit(OP_NEW_STRUCT)     // boxed: a refcounted-field struct boxes its fields
                        self.emit_idx(self.lit_struct_id(ty.value))
                        self.emit_idx(self.struct_field_count(sid))
                    }
                }
            }
            case EGet(object, name) {
                self.gen_field_access(object.value, name)
            }
            case EArray(elems, lines) {
                var ai = 0
                loop {
                    if ai >= elems.len() {
                        break
                    }
                    self.gen_consume(elems[ai], lines[ai])   // each element at its own source line (a string INCREFs)
                    ai = ai + 1
                }
                self.emit(OP_NEW_ARRAY)
                self.emit_idx(elems.len())
                var ek = 4
                if elems.len() > 0 {
                    ek = self.elem_kind_of(elems[0])
                }
                self.emit(ek)                           // the ArrayElemKind byte
            }
            case EIndex(object, index) {
                self.gen_expr(object.value, line)       // the array (a borrow)
                self.gen_expr(index.value, line)        // the index
                self.emit(OP_INDEX)
            }
            case ETry(operand) {
                // the `?` operator: evaluate a Result/Option; if Ok/Some (tag 0), unwrap its payload
                // (GET_FIELD 0); if Err/None, record a propagation hop (ROUTE_HOP), drop the owned locals,
                // and RETURN the value. DUP keeps the value on the stack across the tag test so both the
                // payload path and the Err/None early-return can reach it (mirrors src/codegen.c).
                self.gen_expr(operand.value, line)
                self.emit(OP_DUP)
                self.emit(OP_GET_TAG)
                let z = self.add_const_int(0)
                self.emit(OP_CONST)
                self.emit_idx(z)
                self.emit(OP_EQ)
                let jf = self.emit_jump(OP_JUMP_IF_FALSE)
                self.emit(OP_POP)                       // Ok/Some: drop the tag-compare result
                self.emit(OP_GET_FIELD)
                self.emit_idx(0)                        // unwrap the payload
                let jend = self.emit_jump(OP_JUMP)
                self.patch_jump(jf)
                self.emit(OP_POP)                       // Err/None: drop the tag-compare result
                self.emit(OP_ROUTE_HOP)
                self.emit_drops()                       // release owned locals before propagating out
                self.emit(OP_RETURN)
                self.patch_jump(jend)
            }
            case ELambda(params, body) {
                // Capture the free enclosing locals (push each GET_LOCAL), then MAKE_CLOSURE <lifted index>
                // <capture count>. The lifted fn (captures as leading params, then the lambda's own params) is
                // recorded as a LambdaSpec (a pre-built FnDecl + capture flags) and compiled after all decls.
                let caps = lambda_captures(params, body)
                var cflags: [CaptureFlag] = []
                var ci = 0
                loop {
                    if ci >= caps.len() {
                        break
                    }
                    let s = self.resolve_slot(caps[ci])
                    if s >= 0 {                          // a real capture (an enclosing local, not a global/fn)
                        self.emit(OP_GET_LOCAL)
                        self.emit_idx(s)
                        cflags.append(CaptureFlag { name: caps[ci], is_str: self.local_str[s], droppable: self.local_drop[s], struct_id: self.slot_struct[s], boxed: self.slot_boxed[s], is_array: self.slot_array[s], elem: self.slot_elem[s], kind: self.slot_kind[s] })
                    }
                    ci = ci + 1
                }
                let lidx = self.lambda_base + self.lifted.len()
                self.cur_line = line
                self.emit(OP_MAKE_CLOSURE)
                self.emit_idx(lidx)
                self.emit_idx(cflags.len())
                let synth = ps.FnDecl { name: "<lambda>", generics: [], params: params, ret: [], has_body: true, body: body, reqs: [], req_lines: [], enss: [], ens_lines: [] }
                self.lifted.append(LambdaSpec { decl: synth, caps: cflags })
            }
            case _ {
            }
        }
    }


    // emit_recv_option_operands writes RECV/TRY_RECV's operands: the Some variant's enum id, then the Some and
    // None tags (so the VM builds Option<T> — Some(v) on receive, None on a closed+drained channel).
    fn emit_recv_option_operands(mut self) {
        let si = cg_index_of(self.ev_name, "Some")
        let ni = cg_index_of(self.ev_name, "None")
        self.emit_idx(self.ev_owner[si])
        self.emit_idx(self.ev_tag[si])
        self.emit_idx(self.ev_tag[ni])
    }


    // is_fn_value reports whether an expression evaluates to a CLOSURE value (a droppable refcounted heap
    // object): a lambda, or a bare named function used as a value (an ident resolving to fn_names, not a local).
    fn is_fn_value(self, e: ps.Expr) -> bool {
        match e {
            case ELambda(params, body) {
                return true
            }
            case EIdent(name) {
                return self.resolve_slot(name) < 0 && cg_index_of(self.fn_names, name) >= 0
            }
            case _ {
                return false
            }
        }
    }


    // gen_closure_call lowers a call THROUGH A VALUE (a fn-typed local/param, or a call/expr that yields a
    // closure): push the args left-to-right (raw — the closure body owns its params), then the closure value
    // ON TOP, then CALL_CLOSURE <argc>. Distinct from a direct CALL (callee is a named fn resolved by index).
    fn gen_closure_call(mut self, callee: ps.Expr, args: [ps.Expr], line: int) {
        var i = 0
        loop {
            if i >= args.len() {
                break
            }
            self.gen_expr(args[i], line)
            i = i + 1
        }
        self.gen_expr(callee, line)                  // the closure value: GET_LOCAL for a local, or a call result
        self.cur_line = line
        self.emit(OP_CALL_CLOSURE)
        self.emit_idx(args.len())
    }


    // gen_spawn lowers `spawn f(args)`: push each argument (the fiber TAKES OWNERSHIP, so args INCREF/move like
    // a call's but with NO drop-mask — the spawner never drops them), then SPAWN <fn index> <total arg slots>.
    fn gen_spawn(mut self, call: ps.Expr, line: int) {
        match call {
            case ECall(callee, args) {
                self.cur_line = line
                var fi = self.resolve_call_fn_index(callee.value)
                // A SPAWN of a bounded generic (`spawn tally(ch, 5, 5)`) shares the direct-call convention:
                // push the bound witnesses as hidden leading args + retarget to the monomorphized instance,
                // so the fiber can dispatch a.eq / a.hash (OFI-174).
                var n_wit = 0
                match callee.value {
                    case EIdent(name) {
                        if cg_index_of(self.gb_fn, name) >= 0 {
                            fi = self.bounded_inst_index(name, args)
                            n_wit = self.emit_bounded_witnesses(name, args, line)
                        }
                    }
                    case _ {
                    }
                }
                var built = 0
                var i = 0
                loop {
                    if i >= args.len() {
                        break
                    }
                    built = built + self.gen_one_arg(args[i], line)
                    i = i + 1
                }
                self.cur_line = line
                self.emit(OP_SPAWN)
                self.emit_idx(fi)
                self.emit_idx(n_wit + built)
            }
            case _ {
            }
        }
    }


    fn gen_stmt(mut self, s: ps.Stmt) {
        match s {
            case SLet(is_var, name, ty, value) {
                // A RETURN-type-inferred BOUNDED generic call (`var b: Bag<int> = new_bag()`) binds its type
                // param from the annotation; thread it in as expected_key so gen_bounded_call builds the right
                // witnesses + resolves the right instance (consumed once, in the ECall dispatch). (OFI-174)
                if ty.len() > 0 && self.let_value_is_bounded_call(value.value) {
                    self.expected_key = mono_ty_key(ty[0])
                }
                if is_channel_call(value.value) {
                    // `let ch = channel(N)` lands a fresh owned channel HANDLE (refcounted) -> a single droppable
                    // slot, dropped at every exit and INCREF'd when passed to a spawn/call.
                    self.gen_expr(value.value, value.line)
                    self.declare_binding(name, 1, -1, false, true, false, false)
                    return
                }
                if self.is_fn_value(value.value) || (ty.len() > 0 && ty_is_fn(ty[0])) {
                    // `let g = double` / `let h: fn(int)->int = |x| …` lands an owned CLOSURE (refcounted) ->
                    // a single droppable slot.
                    self.gen_expr(value.value, value.line)
                    self.declare_binding(name, 1, -1, false, true, false, false)
                    return
                }
                let gci = self.gret_call_index(value.value)
                if gci >= 0 {
                    // A generic call whose return is a bare `T` / `[T]` (`let bylen = sort(words)` -> [string],
                    // `let s = gtwice(f,"hi")` -> string): infer the concrete result type from the determining
                    // argument so `bylen[i].len()` / `s.len()` know their element/value is a string (OFI-174).
                    if self.gret_arr[gci] {
                        self.gen_expr(value.value, value.line)                     // CALL -> one owned array slot
                        self.declare_binding(name, 1, 0 - 1, false, true, false, true)
                        self.slot_elem[self.slot_elem.len() - 1] = self.gret_arg_elem(value.value, gci)
                        return
                    } else if self.gret_arg_is_string(value.value, gci) {
                        self.gen_expr(value.value, value.line)                     // CALL -> one owned string slot
                        self.declare_binding(name, 1, 0 - 1, true, true, false, false)
                        return
                    }
                }
                if self.is_enum_ctor(value.value) || self.call_returns_enum(value.value) {
                    // an enum is a heap/move value -> the owned binding is dropped at every exit (a variant
                    // construction or an enum-returning call both land a fresh owned enum). If it's a RETURN-
                    // type-inferred generic call (`let n: Option<int> = none_of()`), the annotation supplies the
                    // mono key its call site otherwise lacks (consumed once, inside the ECall dispatch).
                    if ty.len() > 0 {
                        self.expected_key = mono_ty_key(ty[0])
                    }
                    self.gen_expr(value.value, value.line)
                    self.expected_key = ""
                    self.declare_binding(name, 1, -1, false, true, false, false)
                    return
                }
                let eek = self.index_elem_code(value.value)
                if eek != 0 - 99 {
                    // `let t = arr[i]` — OP_INDEX materialises the element; the binding's type/drop follows the
                    // element kind (mirrors stage-0 STMT_LET): a string element INCREFs + drops; an all-scalar
                    // struct UNBOX_STRUCTs into multi-slot (no drop); a string-bearing struct is one boxed
                    // droppable slot; a scalar is a plain slot.
                    if eek == 0 - 3 {
                        self.gen_consume(value.value, value.line)   // INDEX; INCREF
                        self.declare_binding(name, 1, -1, true, true, false, false)
                    } else if eek == 0 - 4 {
                        self.gen_consume(value.value, value.line)   // INDEX; INCREF (enum element, refcounted)
                        self.declare_binding(name, 1, -1, false, true, false, false)   // owned enum: droppable, not a string
                    } else if eek >= 0 {
                        self.gen_expr(value.value, value.line)      // INDEX
                        if self.struct_all_scalar(eek) {
                            self.emit(OP_UNBOX_STRUCT)
                            self.emit_idx(eek)
                            self.declare_binding(name, self.struct_field_count(eek), eek, false, false, false, false)
                        } else {
                            self.declare_binding(name, 1, eek, false, true, true, false)
                        }
                    } else {
                        self.gen_expr(value.value, value.line)      // INDEX (scalar element)
                        self.declare_binding(name, 1, -1, false, false, false, false)
                    }
                    return
                }
                if ty.len() > 0 && self.let_value_is_bounded_call(value.value) {
                    // A bounded generic call returning a struct (`var b: Bag<int> = new_bag()`): the erased
                    // result is a boxed struct of the annotation's type. Declare a boxed struct binding so
                    // `b.method(..)` dispatches to the struct's methods (OFI-174).
                    let annsid = self.type_struct_id(ty[0])
                    if annsid >= 0 {
                        self.gen_expr(value.value, value.line)
                        self.declare_binding(name, 1, annsid, false, true, true, false)
                        // Record the receiver's concrete type-args so `b.method(..)` retargets to the
                        // monomorphized method instance (`Bag.add<int>`) (OFI-174).
                        self.mrecv_name.append(name)
                        self.mrecv_args.append(ty_args_key(ty[0]))
                        return
                    }
                }
                let sid = self.struct_value_info(value.value)
                if sid >= 0 {
                    if is_var == false && self.struct_all_scalar(sid) {
                        self.gen_struct_construct(value.value, value.line, false)   // multi-slot: span slots
                        self.declare_binding(name, self.struct_field_count(sid), sid, false, false, false, false)
                    } else {
                        self.gen_struct_construct(value.value, value.line, true)    // boxed: NEW_STRUCT
                        self.declare_binding(name, 1, sid, false, true, true, false)
                    }
                } else if is_array_lit(value.value) {
                    var done = false
                    if ty.len() > 0 && array_lit_is_empty(value.value) {
                        // an empty `[]` has no element to infer the kind from; take it from the `[T]`
                        // annotation: an all-scalar struct element packs inline (NEW_STRUCT_ARRAY), else the
                        // element kind (e.g. `[string]` -> 0, not int).
                        self.emit_empty_array(elem_ty_of(ty[0]), value.line)
                        done = true
                    } else if ty.len() > 0 {
                        // a non-empty array with a SIZED-scalar annotation (`[u8]`/`[u64]`/`[f32]`) must pack
                        // at the annotation's width, not the first element's inferred kind (`[u8] = [1,2,3]`
                        // is bytes, not i64s). A boxed/inline-struct element (aek 0 / 12) falls to gen_expr.
                        let aek = array_elem_kind_from_ty(elem_ty_of(ty[0]))
                        if aek >= 1 && aek <= 11 {
                            match value.value {
                                case EArray(elems, lines) {
                                    var ai = 0
                                    loop {
                                        if ai >= elems.len() {
                                            break
                                        }
                                        self.gen_consume(elems[ai], lines[ai])
                                        ai = ai + 1
                                    }
                                    self.emit(OP_NEW_ARRAY)
                                    self.emit_idx(elems.len())
                                    self.emit(aek)
                                    done = true
                                }
                                case _ {
                                }
                            }
                        }
                    }
                    if done == false {
                        self.gen_expr(value.value, value.line)       // NEW_ARRAY -> one owned array slot
                    }
                    self.declare_binding(name, 1, -1, false, true, false, true)
                    if ty.len() > 0 {
                        // Record the element type from the `[T]` annotation so a later `arr[i]` read knows
                        // its element kind (e.g. `var q: [string] = []` -> `q[i]` is a refcounted place read
                        // that INCREFs when consumed). An empty literal has no element to infer it from.
                        self.slot_elem[self.slot_elem.len() - 1] = self.array_elem_type_code(elem_ty_of(ty[0]))
                    } else {
                        // No annotation: infer the element type from the first literal element (`["a", …]` ->
                        // string, -3), so `words[i].len()` (and a generic call keyed on words's element) knows it.
                        let ec = self.array_lit_elem_code(value.value)
                        if ec != 0 - 1 {
                            self.slot_elem[self.slot_elem.len() - 1] = ec
                        }
                    }
                } else {
                    // An initialiser that is a same-file call to a function returning an owned type lands an
                    // owned-droppable value (array/struct/string) the checker would track; re-derive it here.
                    let rk = self.expr_ret_kind(value.value)
                    if rk == -2 {
                        self.gen_expr(value.value, value.line)       // CALL -> one owned array slot
                        self.declare_binding(name, 1, -1, false, true, false, true)
                        self.slot_elem[self.slot_elem.len() - 1] = self.expr_ret_elem(value.value)   // so `xs[i]` knows its element kind
                    } else if rk >= 0 && is_var == false && self.struct_all_scalar(rk) {
                        self.gen_expr(value.value, value.line)       // CALL -> RETURN_STRUCT span slots
                        self.declare_binding(name, self.struct_field_count(rk), rk, false, false, false, false)
                    } else if rk >= 0 && is_var == false {
                        self.gen_expr(value.value, value.line)       // CALL -> one owned boxed-struct slot
                        self.declare_binding(name, 1, rk, false, true, true, false)
                    } else if rk == -3 {
                        self.gen_expr(value.value, value.line)       // CALL -> one owned string slot (fresh)
                        self.declare_binding(name, 1, -1, true, true, false, false)
                    } else if self.is_erased_read(value.value) {
                        // `let a = x` of an erased type-param: INCREF on consume, NEVER dropped (over-retain)
                        self.gen_consume(value.value, value.line)
                        self.declare_binding(name, 1, -1, true, false, false, false)
                    } else if self.expr_is_string(value.value) {
                        self.gen_consume(value.value, value.line)    // a string place-read INCREFs; owned/droppable
                        self.declare_binding(name, 1, -1, true, true, false, false)
                    } else if self.is_str_local_read(value.value) {
                        // a refcounted ENUM read from a place (`let op = self.advance().kind`, an enum field
                        // or an owned-enum local): aliasing an existing owner INCREFs (gen_consume), and the
                        // binding is an owned/droppable enum — but NOT a string.
                        self.gen_consume(value.value, value.line)
                        self.declare_binding(name, 1, -1, false, true, false, false)
                    } else {
                        self.gen_expr(value.value, value.line)       // a scalar initialiser stays on the stack
                        self.declare_binding(name, 1, -1, false, false, false, false)
                        // Record the scalar width so later arithmetic/comparison/interpolation on this local
                        // emits the right num_kind: a `[T]`-style annotation drives it, else infer it from the
                        // initialiser (so `let s: u64 = …` and `let s = u64a + u64b` are both u64).
                        if ty.len() > 0 {
                            self.slot_kind[self.slot_kind.len() - 1] = ty_scalar_kind(ty[0])
                        } else {
                            self.slot_kind[self.slot_kind.len() - 1] = self.infer_render_kind(value.value)
                        }
                    }
                }
            }
            case SReturn(value, line) {
                if value.len() > 0 {
                    if self.cur_return_span > 0 {
                        self.gen_expr(value[0].value, value[0].line) // struct construction -> span slots
                        self.emit_drops()
                        self.emit(OP_RETURN_STRUCT)
                        self.emit_idx(self.cur_return_span)
                    } else {
                        self.gen_consume(value[0].value, value[0].line)  // incref a borrowed-string return
                        self.emit_ensures()                              // check `ensures` with `result` on the stack
                        self.emit_drops()
                        self.emit(OP_RETURN)
                    }
                } else {
                    // a bare `return` in a void function still leaves the unit value (0) the VM RETURN pops,
                    // attributed to the `return` keyword's line
                    self.cur_line = line
                    let zidx = self.add_const_int(0)
                    self.emit(OP_CONST)
                    self.emit_idx(zidx)
                    self.emit_ensures()
                    self.emit_drops()
                    self.emit(OP_RETURN)
                }
            }
            case SExpr(expr) {
                self.gen_expr(expr.value, expr.line)
                self.emit(OP_POP)
            }
            case SAssign(target, value) {
                match target.value {
                    case EIdent(name) {
                        self.gen_consume(value.value, value.line)   // string→incref / move-local→move
                        let dslot = self.resolve_slot(name)
                        if dslot >= 0 && self.local_drop[dslot] {
                            self.emit(OP_DROP)        // release the old owned value before overwriting it
                            self.emit_idx(dslot)
                        }
                        self.emit(OP_SET_LOCAL)       // SET_LOCAL leaves the value; the statement POPs it
                        self.emit_idx(dslot)
                        self.emit(OP_POP)
                    }
                    case EGet(object, fname) {
                        // boxed struct field assignment `p.f = v`: GET_LOCAL p; <value>; SET_FIELD index.
                        match object.value {
                            case EIdent(oname) {
                                let slot = self.resolve_slot(oname)
                                if slot >= 0 {
                                    let sid = self.slot_struct[slot]
                                    if sid >= 0 && self.slot_boxed[slot] {
                                        self.cur_line = target.line
                                        self.emit(OP_GET_LOCAL)
                                        self.emit_idx(slot)
                                        if array_lit_is_empty(value.value) {
                                            // an empty `[]` field value carries no element kind — take it from
                                            // the FIELD's declared `[T]` (else the context-free `[]` defaults to
                                            // int — wrong for a `[bool]`/`[Stmt]` boxed-element field).
                                            self.cur_line = value.line
                                            let esid = self.field_elem_code(sid, fname)
                                            if esid >= 0 && self.struct_array_inline(esid) {
                                                self.emit(OP_NEW_STRUCT_ARRAY)
                                                self.emit_idx(0)
                                                self.emit_idx(esid)
                                            } else {
                                                self.emit(OP_NEW_ARRAY)
                                                self.emit_idx(0)
                                                self.emit(self.field_arr_kind(sid, fname))
                                            }
                                        } else {
                                            self.gen_consume(value.value, value.line)   // field takes the value
                                        }
                                        self.emit(OP_SET_FIELD)
                                        self.emit_idx(self.struct_field_index(sid, fname))
                                    }
                                }
                            }
                            case _ {
                            }
                        }
                    }
                    case EIndex(object, index) {
                        // array element assignment `a[i] = v`: GET_LOCAL a; <index>; <value>; SET_INDEX.
                        self.gen_expr(object.value, target.line)
                        self.gen_expr(index.value, target.line)
                        self.gen_consume(value.value, value.line)
                        self.emit(OP_SET_INDEX)
                    }
                    case _ {
                    }
                }
            }
            case SIf(cond, then_blk, els) {
                self.gen_expr(cond.value, cond.line)
                let else_jump = self.emit_jump(OP_JUMP_IF_FALSE)
                self.emit(OP_POP)                     // true path: discard the condition
                self.gen_block(then_blk)
                let end_jump = self.emit_jump(OP_JUMP)
                self.patch_jump(else_jump)
                self.emit(OP_POP)                     // false path: discard the condition
                if els.len() > 0 {
                    self.gen_stmt(els[0])
                }
                self.patch_jump(end_jump)
            }
            case SBlock(body) {
                self.gen_block(body)
            }
            case SMatch(value, cases) {
                // Evaluate the scrutinee once into an anonymous subject slot the case tests + payload bindings
                // read from. A subject that is a fresh OWNING temp (a call / construction) is dropped on the
                // fall-through and via early exits (OFI-118); a borrowed local/param subject is only POP'd.
                self.gen_expr(value.value, value.line)
                let subj_drop = self.is_owning_temp_obj(value.value)   // `arr[i]` of a boxed array is a borrow (POP), not owning
                let subject = self.locals.len()
                self.declare_binding("", 1, -1, false, subj_drop, false, false)
                var end_jumps: [int] = []
                var ci = 0
                loop {
                    if ci >= cases.len() {
                        break
                    }
                    if cases[ci].pattern.wildcard {
                        self.gen_block(cases[ci].body)           // catch-all: no tag test, body + unwind
                        if end_jumps.len() < 64 {
                            end_jumps.append(self.emit_jump(OP_JUMP))
                        }
                    } else {
                        let vi = cg_index_of(self.ev_name, cases[ci].pattern.variant)
                        // An imported enum's variant (e.g. matching `ps.Decl`) is not in this module's table
                        // yet — guard against OOB. Cross-module enum resolution (so the tag is correct) is the
                        // next milestone; for now a placeholder tag keeps codegen crash-free.
                        var vtag = 0
                        if vi >= 0 {
                            vtag = self.ev_tag[vi]
                        }
                        self.emit(OP_GET_LOCAL)
                        self.emit_idx(subject)
                        self.emit(OP_GET_TAG)
                        let tidx = self.add_const_int(vtag)
                        self.emit(OP_CONST)
                        self.emit_idx(tidx)
                        self.emit(OP_EQ)
                        let next = self.emit_jump(OP_JUMP_IF_FALSE)
                        self.emit(OP_POP)                        // matched (true path): drop the test copy
                        let bind_base = self.locals.len()
                        var b = 0
                        loop {
                            if b >= cases[ci].pattern.bindings.len() {
                                break
                            }
                            self.emit(OP_GET_LOCAL)              // each binding borrows a payload field
                            self.emit_idx(subject)
                            self.emit(OP_GET_FIELD)
                            self.emit_idx(b)
                            // A binding BORROWS the scrutinee's field (never dropped here — drop=false). Its
                            // type drives the discipline: a string binding INCREFs when consumed; a struct
                            // binding resolves `.field`; an array binding resolves `[i]`/`.len()`.
                            let fidx = self.variant_field_index(vi, b)
                            let scpay = self.scrutinee_payload_sid(value.value)
                            if scpay >= 0 && (fidx < 0 || self.ev_fstruct[fidx] < 0) {
                                // Nested-generic enum-payload typing: `case Some(e)` over a `[Option<Struct>]`
                                // field element binds e as the concrete payload struct, so `e.key.eq(..)` / `e.val`
                                // resolve — even though the prelude Option's payload type is the abstract T (OFI-174).
                                self.declare_binding(cases[ci].pattern.bindings[b], 1, scpay, false, false, true, false)
                            } else if fidx >= 0 && self.ev_fstring[fidx] {
                                self.declare_binding(cases[ci].pattern.bindings[b], 1, -1, true, false, false, false)
                            } else if fidx >= 0 && self.ev_fstruct[fidx] >= 0 {
                                self.declare_binding(cases[ci].pattern.bindings[b], 1, self.ev_fstruct[fidx], false, false, true, false)
                            } else if fidx >= 0 && self.ev_farray[fidx] {
                                self.declare_binding(cases[ci].pattern.bindings[b], 1, -1, false, false, false, true)
                                self.slot_elem[self.slot_elem.len() - 1] = self.ev_felem[fidx]   // so `arr[i]` knows its element kind
                            } else if fidx >= 0 && self.ev_fenum[fidx] {
                                // an enum binding is a refcounted single Value: INCREF when consumed, but a
                                // BORROW (the scrutinee owns it) so never dropped here — is_str flags the former.
                                self.declare_binding(cases[ci].pattern.bindings[b], 1, -1, true, false, false, false)
                            } else {
                                // a SCALAR payload binding (`case EFloat(v)`): record its numeric/render kind so
                                // an interpolation hole `{v}` renders with the right TO_STRING kind (float=9, …).
                                self.declare_binding(cases[ci].pattern.bindings[b], 1, -1, false, false, false, false)
                                if fidx >= 0 {
                                    self.slot_kind[self.slot_kind.len() - 1] = self.ev_fkind[fidx]
                                }
                            }
                            b = b + 1
                        }
                        var si = 0
                        loop {
                            if si >= cases[ci].body.len() {
                                break
                            }
                            self.gen_stmt(cases[ci].body[si])
                            si = si + 1
                        }
                        self.unwind_to(bind_base)                // release+pop bindings & body locals
                        if end_jumps.len() < 64 {
                            end_jumps.append(self.emit_jump(OP_JUMP))
                        }
                        self.patch_jump(next)
                        self.emit(OP_POP)                        // not matched (false path): drop the test copy
                    }
                    ci = ci + 1
                }
                var ej = 0
                loop {
                    if ej >= end_jumps.len() {
                        break
                    }
                    self.patch_jump(end_jumps[ej])
                    ej = ej + 1
                }
                if subj_drop {
                    self.emit(OP_DROP)                           // release an owning-temp subject
                    self.emit_idx(subject)
                }
                self.emit(OP_POP)                               // pop the subject
                self.truncate_to(subject)                       // logical unwind (cleanup already emitted)
            }
            case SLoop(body) {
                let loop_start = self.code.len()
                self.cont_targets.append(loop_start)
                self.loop_bases.append(self.locals.len())
                self.break_bases.append(self.break_jumps.len())
                self.gen_block(body)
                self.emit_loop(loop_start)
                let base = self.break_bases[self.break_bases.len() - 1]
                var bi = base
                loop {
                    if bi >= self.break_jumps.len() {
                        break
                    }
                    self.patch_jump(self.break_jumps[bi])   // code.len() is now the loop-exit target
                    bi = bi + 1
                }
                self.pop_loop_ctx(base)
            }
            case SFor(vname, index_var, iter, body) {
                // Two fused forms (FOR_RANGE / FOR_ARRAY), each carrying its own exit offset. The loop slots
                // (index + bounds + the borrowed element) are declared before the fused op; the op pre-
                // increments the index (initialised to lo-1 / -1) so `continue` (a back-edge to the op) steps.
                let loop_base = self.locals.len()
                match iter.value {
                    case ERange(lo, hi) {
                        self.gen_expr(lo.value, lo.line)     // i = lo - 1
                        let one = self.add_const_int(1)
                        self.emit(OP_CONST)
                        self.emit_idx(one)
                        self.emit(OP_SUB)
                        self.emit(0)
                        let i_slot = self.locals.len()
                        self.declare_binding(vname, 1, -1, false, false, false, false)
                        self.gen_expr(hi.value, hi.line)     // the end bound
                        let end_slot = self.locals.len()
                        self.declare_binding("", 1, -1, false, false, false, false)
                        let start = self.code.len()
                        self.cont_targets.append(start)
                        self.loop_bases.append(self.locals.len())
                        self.break_bases.append(self.break_jumps.len())
                        self.emit(OP_FOR_RANGE)
                        self.emit_idx(i_slot)
                        self.emit_idx(end_slot)
                        self.emit(255)
                        self.emit(255)
                        let exit_jump = self.code.len() - 2
                        self.gen_block(body)
                        self.emit_loop(start)
                        self.patch_jump(exit_jump)
                        let base = self.break_bases[self.break_bases.len() - 1]
                        self.patch_breaks(base)
                        self.pop_loop_ctx(base)
                        self.emit(OP_POP)                    // hidden: end, then index
                        self.emit(OP_POP)
                        self.truncate_to(loop_base)
                    }
                    case _ {
                        self.gen_expr(iter.value, iter.line) // the array
                        let arr_slot = self.locals.len()
                        self.declare_binding("", 1, -1, false, false, false, false)
                        let neg1 = self.add_const_int(0 - 1)
                        self.emit(OP_CONST)
                        self.emit_idx(neg1)
                        let idx_slot = self.locals.len()
                        self.declare_binding(index_var, 1, -1, false, false, false, false)
                        self.emit(OP_GET_LOCAL)
                        self.emit_idx(arr_slot)
                        self.emit(OP_ARRAY_LEN)
                        let len_slot = self.locals.len()
                        self.declare_binding("", 1, -1, false, false, false, false)
                        let zero = self.add_const_int(0)
                        self.emit(OP_CONST)
                        self.emit_idx(zero)
                        let var_slot = self.locals.len()
                        self.declare_binding(vname, 1, -1, false, false, false, false)
                        let start = self.code.len()
                        self.cont_targets.append(start)
                        self.loop_bases.append(self.locals.len())
                        self.break_bases.append(self.break_jumps.len())
                        self.emit(OP_FOR_ARRAY)
                        self.emit_idx(arr_slot)
                        self.emit_idx(idx_slot)
                        self.emit_idx(len_slot)
                        self.emit_idx(var_slot)
                        self.emit(255)
                        self.emit(255)
                        let exit_jump = self.code.len() - 2
                        self.gen_block(body)
                        self.emit_loop(start)
                        self.patch_jump(exit_jump)
                        let base = self.break_bases[self.break_bases.len() - 1]
                        self.patch_breaks(base)
                        self.pop_loop_ctx(base)
                        self.emit(OP_POP)                    // hidden: var, len, index, array
                        self.emit(OP_POP)
                        self.emit(OP_POP)
                        self.emit(OP_POP)
                        self.truncate_to(loop_base)
                    }
                }
            }
            case SBreak(line) {
                self.cur_line = line
                self.emit_unwind(self.loop_bases[self.loop_bases.len() - 1])   // release body locals first
                let j = self.emit_jump(OP_JUMP)
                self.break_jumps.append(j)
            }
            case SContinue(line) {
                self.cur_line = line
                self.emit_unwind(self.loop_bases[self.loop_bases.len() - 1])   // release body locals first
                self.emit_loop(self.cont_targets[self.cont_targets.len() - 1])
            }
            case SNursery(body, line) {
                // open a task group, run the body (which spawns into it), then join at NURSERY_END.
                self.cur_line = line
                self.emit(OP_NURSERY_BEGIN)
                self.gen_block(body)
                self.emit(OP_NURSERY_END)
            }
            case SSpawn(call) {
                self.gen_spawn(call.value, call.line)
            }
            case _ {
            }
        }
    }
}


// ---- the operand codec (opcode.h operand_read / operand_width) ------------------------------------
// op_width: the byte width of one operand of `kind` whose first byte is at `pos` (IDX is LEB128).
fn op_width(code: [int], pos: int, kind: int) -> int {
    if kind == OPK_U8 {
        return 1
    }
    if kind == OPK_U16 {
        return 2
    }
    if kind == OPK_OFF16 {
        return 2
    }
    if kind == OPK_U24 {
        return 3
    }
    var n = 1                                       // OPK_IDX: count LEB128 continuation bytes
    loop {
        if (code[pos + n - 1] & 128) == 0 {
            break
        }
        n = n + 1
    }
    return n
}


// op_value: decode one operand of `kind` at `pos` (fixed kinds big-endian; IDX unsigned LEB128).
fn op_value(code: [int], pos: int, kind: int) -> int {
    if kind == OPK_U8 {
        return code[pos]
    }
    if kind == OPK_U16 {
        return code[pos] * 256 + code[pos + 1]
    }
    if kind == OPK_OFF16 {
        return code[pos] * 256 + code[pos + 1]
    }
    if kind == OPK_U24 {
        return code[pos] * 65536 + code[pos + 1] * 256 + code[pos + 2]
    }
    var v = 0                                       // OPK_IDX
    var shift = 0
    var i = pos
    loop {
        let b = code[i]
        v = v | ((b & 127) << shift)
        shift = shift + 7
        i = i + 1
        if (b & 128) == 0 {
            break
        }
    }
    return v
}


// ---- text formatting helpers (reproduce the printf widths in src/chunk.c byte-for-byte) ------------
fn pad_zero4(n: int) -> string {                    // %04d: zero-pad to at least 4 digits
    var s = "{n}"
    loop {
        if s.len() >= 4 {
            break
        }
        s = "0" + s
    }
    return s
}


fn pad_left_sp(s: string, w: int) -> string {       // %4d: right-justify with spaces to width w
    var r = s
    loop {
        if r.len() >= w {
            break
        }
        r = " " + r
    }
    return r
}


fn pad_right_sp(s: string, w: int) -> string {      // %-8s: left-justify with spaces to width w
    var r = s
    loop {
        if r.len() >= w {
            break
        }
        r = r + " "
    }
    return r
}


// disassemble prints `chunk` in stage-0's exact `--emit=bytecode` format (src/chunk.c chunk_disassemble):
//   OFFSET(%04d) LINE(%4d or "|")  OPCODE(%-8s) [operands]   with CONST/STRING showing their pool value.
fn disassemble(chunk: Chunk) {
    let names = op_names()
    let kstart = op_kstart()
    let kcount = op_kcount()
    let kflat = op_kflat()
    var offset = 0
    var prev_line = 0
    var first = true
    loop {
        if offset >= chunk.code.len() {
            break
        }
        let op = chunk.code[offset]
        let line = chunk.lines[offset]
        var out = ""
        if first == false && line == prev_line {
            out = pad_zero4(offset) + "    |  " + pad_right_sp(names[op], 8)
        } else {
            out = pad_zero4(offset) + " " + pad_left_sp("{line}", 4) + "  " + pad_right_sp(names[op], 8)
        }
        prev_line = line
        first = false
        let kc = kcount[op]
        let ks = kstart[op]
        // First pass: total operand bytes (the jump base is the ip AFTER all operands).
        var total = 0
        var p = offset + 1
        var ki = 0
        loop {
            if ki >= kc {
                break
            }
            let w = op_width(chunk.code, p, kflat[ks + ki])
            total = total + w
            p = p + w
            ki = ki + 1
        }
        // Second pass: render each operand.
        var p2 = offset + 1
        var kj = 0
        loop {
            if kj >= kc {
                break
            }
            let kind = kflat[ks + kj]
            let v = op_value(chunk.code, p2, kind)
            if kind == OPK_OFF16 {
                let base = offset + 1 + total
                var target = base + v
                if op == OP_LOOP {
                    target = base - v
                }
                out = out + " {v} (-> " + pad_zero4(target) + ")"
            } else {
                out = out + " {v}"
            }
            p2 = p2 + op_width(chunk.code, p2, kind)
            kj = kj + 1
        }
        // CONST / STRING annotate the pool value they load.
        if op == OP_CONST {
            let index = op_value(chunk.code, offset + 1, OPK_IDX)
            if chunk.const_is_float[index] {
                out = out + "  (= {chunk.const_float[index]})"
            } else {
                out = out + "  (= {chunk.const_int[index]})"
            }
        } else if op == OP_STRING {
            let index = op_value(chunk.code, offset + 1, OPK_IDX)
            out = out + "  (= \"" + chunk.strings[index] + "\")"
        }
        println(out)
        offset = offset + 1 + total
    }
}


// clone_strs returns an owned copy of a string list (so a Chunk can hold the fn-name table without
// borrowing a value that would escape the function).
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


// RetInfo classifies a binding/return TYPE so codegen can track owned-droppable bindings whose init is a
// call (the checker would supply this; codegen re-derives it). Exactly one of str/arr/(sid>=0) holds, or
// none (a scalar).
struct RetInfo {
    str: bool                  // a string (refcounted)
    arr: bool                  // an array (move, owned-droppable)
    sid: int                   // a struct id (boxed, owned-droppable), else -1
    enm: bool                  // an enum (heap/move, owned-droppable)
    elem: int                  // for an ARRAY return: its element type code (struct sid / -3 / -4 / -1), else -1
}


// ret_info classifies a `[Ty]` return/annotation type.
fn ret_info(ret: [ps.Ty], structs: StructTable, enum_names: [string]) -> RetInfo {
    if ret.len() == 0 {
        return RetInfo { str: false, arr: false, sid: -1, enm: false, elem: -1 }
    }
    if ty_is_array(ret[0]) {
        return RetInfo { str: false, arr: true, sid: -1, enm: false, elem: elem_type_code(elem_ty_of(ret[0]), structs.names, enum_names) }
    }
    if ty_is_string(ret[0]) {
        return RetInfo { str: true, arr: false, sid: -1, enm: false, elem: -1 }
    }
    match ret[0] {
        case TyName(qual, name) {
            if cg_index_of(enum_names, name) >= 0 {
                return RetInfo { str: false, arr: false, sid: -1, enm: true, elem: -1 }
            }
            return RetInfo { str: false, arr: false, sid: cg_index_of(structs.names, name), enm: false, elem: -1 }
        }
        case TyGeneric(qual, name, args) {
            // a generic ENUM (`Option<…>`/`Result<…>`) is a move value; a generic STRUCT (`Box<Expr>`) returns
            // BOXED, bound by its BASE struct id (field layout is the base — the instance id only rides the
            // NEW_STRUCT operand at construction).
            if cg_index_of(enum_names, name) >= 0 {
                return RetInfo { str: false, arr: false, sid: -1, enm: true, elem: -1 }
            }
            return RetInfo { str: false, arr: false, sid: cg_index_of(structs.names, name), enm: false, elem: -1 }
        }
        case _ {
            return RetInfo { str: false, arr: false, sid: -1, enm: false, elem: -1 }
        }
    }
}


// FnRets holds every function's return classification, parallel to build_fn_names' order.
struct FnRets {
    str: [bool]
    arr: [bool]
    sid: [int]
    enm: [bool]
    elem: [int]
    kind: [int]
    ext_names: [string]     // every `extern "c"` fn name (parallel to ext_kinds/ext_pquals)
    ext_kinds: [int]        // ...its DECLARED return scalar kind (i32=3, i64=0, f64=9, …) for a call's render/num kind
    ext_pquals: [string]    // ...one char per param: '0' none / '1' mut / '2' move (a `move Ptr` arg is move-consumed)
}


// ret_scalar_kind returns the render/num kind (int=0, sized 1..7, f32=8, f64=9, bool=10) of a `[Ty]` return
// (unit = 0), so an interpolation hole `{f(x)}` (or a wrapping/binary operand) that is a call renders/widths
// at the function's declared return width.
fn ret_scalar_kind(ret: [ps.Ty]) -> int {
    if ret.len() > 0 {
        return ty_scalar_kind(ret[0])
    }
    return 0
}


fn build_fn_rets(decls: [ps.Decl], structs: StructTable, enum_names: [string]) -> FnRets {
    var rs: [bool] = []
    var ra: [bool] = []
    var rsid: [int] = []
    var ren: [bool] = []
    var rel: [int] = []
    var rk: [int] = []
    var exn: [string] = []
    var exk: [int] = []
    var exq: [string] = []
    var i = 0
    loop {
        if i >= decls.len() {
            break
        }
        match decls[i] {
            case DStruct(name, generics, impls, fields, methods, kind) {
                var mi = 0
                loop {
                    if mi >= methods.len() {
                        break
                    }
                    let r = ret_info(methods[mi].ret, structs, enum_names)
                    rs.append(r.str)
                    ra.append(r.arr)
                    rsid.append(r.sid)
                    ren.append(r.enm)
                    rel.append(r.elem)
                    rk.append(ret_scalar_kind(methods[mi].ret))
                    mi = mi + 1
                }
            }
            case DFn(f) {
                let r = ret_info(f.ret, structs, enum_names)
                rs.append(r.str)
                ra.append(r.arr)
                rsid.append(r.sid)
                ren.append(r.enm)
                rel.append(r.elem)
                rk.append(ret_scalar_kind(f.ret))
            }
            case DExtern(abi, fns) {
                // extern fns get NO CALL-index entry (they lower to CALL_C by registry index), but their
                // DECLARED return kind drives a `let r = strncmp(...)` binding's width (i32 vs i64 differ,
                // yet both are 'i' in the ABI registry — only the declaration distinguishes them).
                var ei = 0
                loop {
                    if ei >= fns.len() {
                        break
                    }
                    exn.append(fns[ei].name)
                    exk.append(ret_scalar_kind(fns[ei].ret))
                    var q = ""
                    var pi = 0
                    loop {
                        if pi >= fns[ei].params.len() {
                            break
                        }
                        q = q + "{fns[ei].params[pi].qual}"
                        pi = pi + 1
                    }
                    exq.append(q)
                    ei = ei + 1
                }
            }
            case _ {
            }
        }
        i = i + 1
    }
    return FnRets { str: rs, arr: ra, sid: rsid, enm: ren, elem: rel, kind: rk, ext_names: exn, ext_kinds: exk, ext_pquals: exq }
}


// build_fn_names collects every function's name in the order stage-0 assigns function indices (a CALL
// operand): walking decls in order, a struct's methods (named `Struct.method`) are numbered when the
// struct is reached, then free functions — interleaved exactly so the indices match.
fn build_fn_names(decls: [ps.Decl]) -> [string] {
    var out: [string] = []
    var i = 0
    loop {
        if i >= decls.len() {
            break
        }
        match decls[i] {
            case DStruct(name, generics, impls, fields, methods, kind) {
                var mi = 0
                loop {
                    if mi >= methods.len() {
                        break
                    }
                    out.append(name + "." + methods[mi].name)
                    mi = mi + 1
                }
            }
            case DFn(f) {
                out.append(f.name)
            }
            case _ {
            }
        }
        i = i + 1
    }
    return out
}


// param_is_string reports whether a parameter is declared `string` (a refcounted, droppable binding).
fn param_is_string(p: ps.Param) -> bool {
    if p.ty.len() == 0 {
        return false
    }
    match p.ty[0] {
        case TyName(qual, name) {
            return qual == "" && name == "string"
        }
        case _ {
            return false
        }
    }
}


// FvCtx drives a lambda's FREE-VARIABLE walk: `bound` = names bound INSIDE the lambda (params + inner
// let/for/match bindings, scoped), `free` = distinct outer names referenced (the capture candidates, in
// traversal order). A name is captured iff referenced, NOT bound inside, and (checked at the MAKE_CLOSURE
// site) resolves to an enclosing local. Scope is saved/restored around each block by copying `bound`.
struct FvCtx {
    bound: [string]
    free: [string]


    fn note(mut self, name: string) {
        if cg_index_of(self.bound, name) >= 0 {
            return
        }
        if cg_index_of(self.free, name) >= 0 {
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


// CaptureFlag records ONE capture's binding flags, copied from the enclosing local at the MAKE_CLOSURE site,
// so the lifted lambda can re-declare it (as a leading param) with the exact refcount/drop discipline.
struct CaptureFlag {
    name: string
    is_str: bool
    droppable: bool
    struct_id: int
    boxed: bool
    is_array: bool
    elem: int
    kind: int
}


// LambdaSpec is a lifted lambda pending compilation: a pre-built synthetic FnDecl (params = the lambda's own
// params, body = the lambda body) plus the capture flags resolved at its MAKE_CLOSURE site. Stored on the
// Chunk (`lifted`) and compiled AFTER all declared functions by the driver, reading `.fn`/`.caps` IN PLACE
// (a whole-struct move out of an array is rejected; the FnDecl is built here where params/body are values).
struct LambdaSpec {
    decl: ps.FnDecl
    caps: [CaptureFlag]
}


// lambda_captures returns the free-variable NAMES of a lambda, in traversal order (capture candidates).
fn lambda_captures(params: [ps.Param], body: [ps.Stmt]) -> [string] {
    var seed: [string] = []
    var p = 0
    loop {
        if p >= params.len() {
            break
        }
        seed.append(params[p].name)
        p = p + 1
    }
    var ctx = FvCtx { bound: seed, free: [] }
    ctx.walk_block(body)
    return clone_strs(ctx.free)
}


// StrInfer infers which UNTYPED lambda params are STRINGS from the body: a param that appears as an operand of
// a string `+` (concat) — where the other operand is a known string (a string capture, a string literal, or a
// string `+`-chain) — is itself a string, so the lifted lambda gives it the INCREF-on-consume + drop-at-exit
// discipline. `snames` seeds with the string captures and grows as params are confirmed (a re-scan reaches
// chained cases). Only the string case matters — a scalar param needs no drop.
struct StrInfer {
    snames: [string]
    targets: [string]


    fn is_str(self, e: ps.Expr) -> bool {
        match e {
            case EStr(parts) {
                return true
            }
            case EIdent(name) {
                return cg_index_of(self.snames, name) >= 0
            }
            case EBinary(op, l, r) {
                if ps.binop_id(op) == 1 {
                    return self.is_str(l.value) || self.is_str(r.value)
                }
                return false
            }
            case _ {
                return false
            }
        }
    }


    fn mark(mut self, cand: ps.Expr, other: ps.Expr) {
        match cand {
            case EIdent(name) {
                if cg_index_of(self.targets, name) >= 0 && cg_index_of(self.snames, name) < 0 {
                    if self.is_str(other) {
                        self.snames.append(name)
                    }
                }
            }
            case _ {
            }
        }
    }


    fn scan_expr(mut self, e: ps.Expr) {
        match e {
            case EBinary(op, l, r) {
                if ps.binop_id(op) == 1 {
                    self.mark(l.value, r.value)
                    self.mark(r.value, l.value)
                }
                self.scan_expr(l.value)
                self.scan_expr(r.value)
            }
            case EUnary(op, operand) {
                self.scan_expr(operand.value)
            }
            case ECall(callee, args) {
                // A string-method receiver (`p.len()` / `p.bytes()` / `p.chars()`) marks an untyped param p as a
                // string, so a HOF predicate `|a, b| a.len() < b.len()` emits STR_LEN — its erased element is a
                // string (OFI-174). `.len()` is array-or-string, but a lambda comparing element lengths is over
                // strings across the corpus; string-only `.bytes()`/`.chars()` are unambiguous.
                match callee.value {
                    case EGet(object, mname) {
                        if mname == "len" || mname == "bytes" || mname == "chars" {
                            match object.value {
                                case EIdent(pname) {
                                    if cg_index_of(self.targets, pname) >= 0 && cg_index_of(self.snames, pname) < 0 {
                                        self.snames.append(pname)
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
                self.scan_expr(callee.value)
                var i = 0
                loop {
                    if i >= args.len() {
                        break
                    }
                    self.scan_expr(args[i])
                    i = i + 1
                }
            }
            case EGet(object, name) {
                self.scan_expr(object.value)
            }
            case EIndex(object, index) {
                self.scan_expr(object.value)
                self.scan_expr(index.value)
            }
            case ETry(operand) {
                self.scan_expr(operand.value)
            }
            case EStr(parts) {
                var i = 0
                loop {
                    if i >= parts.len() {
                        break
                    }
                    if parts[i].hole.len() > 0 {
                        self.scan_expr(parts[i].hole[0])
                    }
                    i = i + 1
                }
            }
            case _ {
            }
        }
    }


    fn scan_stmt(mut self, s: ps.Stmt) {
        match s {
            case SLet(is_var, name, ty, value) {
                self.scan_expr(value.value)
            }
            case SReturn(value, line) {
                if value.len() > 0 {
                    self.scan_expr(value[0].value)
                }
            }
            case SExpr(expr) {
                self.scan_expr(expr.value)
            }
            case SAssign(target, value) {
                self.scan_expr(value.value)
            }
            case SIf(cond, then_blk, els) {
                self.scan_expr(cond.value)
                self.scan_block(then_blk)
                self.scan_block(els)
            }
            case SFor(vname, index_var, iter, body) {
                self.scan_block(body)
            }
            case SLoop(body) {
                self.scan_block(body)
            }
            case SMatch(value, cases) {
                var ci = 0
                loop {
                    if ci >= cases.len() {
                        break
                    }
                    self.scan_block(cases[ci].body)
                    ci = ci + 1
                }
            }
            case SBlock(body) {
                self.scan_block(body)
            }
            case _ {
            }
        }
    }


    fn scan_block(mut self, body: [ps.Stmt]) {
        var i = 0
        loop {
            if i >= body.len() {
                break
            }
            self.scan_stmt(body[i])
            i = i + 1
        }
    }
}


// infer_str_params returns the untyped lambda params that are strings (used in a string concat). Seeded with
// the string captures; two scans reach chained cases (`a + b + suffix`).
fn infer_str_params(caps: [CaptureFlag], params: [ps.Param], body: [ps.Stmt]) -> [string] {
    var snames: [string] = []
    var ci = 0
    loop {
        if ci >= caps.len() {
            break
        }
        if caps[ci].is_str {
            snames.append(caps[ci].name)
        }
        ci = ci + 1
    }
    var targets: [string] = []
    var pi = 0
    loop {
        if pi >= params.len() {
            break
        }
        if params[pi].ty.len() == 0 {                // only UNTYPED params need inference
            targets.append(params[pi].name)
        }
        pi = pi + 1
    }
    var ctx = StrInfer { snames: snames, targets: targets }
    ctx.scan_block(body)
    ctx.scan_block(body)                             // second pass for chained concats
    // return only the confirmed TARGET params (drop the seed captures)
    var out: [string] = []
    var k = 0
    loop {
        if k >= ctx.targets.len() {
            break
        }
        if cg_index_of(ctx.snames, ctx.targets[k]) >= 0 {
            out.append(ctx.targets[k])
        }
        k = k + 1
    }
    return out
}


// emit_lifted_disasm compiles + disassembles each lifted lambda of `ch` (reading spec.fn/spec.caps IN PLACE —
// a whole-struct move out of the array is rejected), as `== fn <lambda> (arity C+P) ==`. Nested lambdas
// (a lambda inside a lambda) are a documented gap — flat lambdas cover the corpus.
fn emit_lifted_disasm(ch: Chunk, fn_names: [string], fn_rets: FnRets, structs: StructTable, enums: EnumTable, globals: GlobalConsts, instances: [string], generic_fns: [string], generic_pquals: [string], fn_inst_keys: [string], inst_base: int, wit: WitInfo) {
    var li = 0
    loop {
        if li >= ch.lifted.len() {
            break
        }
        println("== fn <lambda> (arity {ch.lifted[li].caps.len() + ch.lifted[li].decl.params.len()}) ==")
        let lch = compile_fn(ch.lifted[li].decl, fn_names, fn_rets, structs, enums, globals, instances, 0 - 1, 0, ch.lifted[li].caps, generic_fns, generic_pquals, fn_inst_keys, inst_base, wit)
        disassemble(lch)
        li = li + 1
    }
}


// disassemble_program prints the whole program in stage-0's `--emit=bytecode` format: ALL declared functions
// first (pass 1), THEN the lifted lambdas (pass 2), so the fn-table numbering matches. Lambda indices are
// assigned at each MAKE_CLOSURE site as `lambda_base + ordinal`; the two passes recompute the same base per
// function (declared fns re-compiled in pass 2 only to re-derive their `lifted` specs — Ember's ownership
// model forbids holding the specs across the passes).
fn disassemble_program(decls: [ps.Decl], fn_names: [string], fn_rets: FnRets, structs: StructTable, enums: EnumTable, globals: GlobalConsts, instances: [string]) {
    var no_caps: [CaptureFlag] = []
    var no_keys: [string] = []
    let gf = build_generic_fns(decls)
    let wit = build_wit_info(decls)
    // Pass 0: count lifted lambdas (compile with a dummy instance context; read only ch.lifted.len()) so the
    // instance base (= after declared fns AND lambdas) is known before pass 1 resolves any generic call.
    var total_lambdas = 0
    var sid0 = 0
    var i0 = 0
    loop {
        if i0 >= decls.len() {
            break
        }
        match decls[i0] {
            case DStruct(name, generics, impls, fields, methods, kind) {
                var mi = 0
                loop {
                    if mi >= methods.len() {
                        break
                    }
                    if methods[mi].has_body {
                        let ch = compile_fn(methods[mi], fn_names, fn_rets, structs, enums, globals, instances, sid0, fn_names.len(), no_caps, gf.names, gf.pquals, no_keys, fn_names.len(), wit)
                        total_lambdas = total_lambdas + ch.lifted.len()
                    }
                    mi = mi + 1
                }
                sid0 = sid0 + 1
            }
            case DFn(f) {
                if f.has_body {
                    let ch = compile_fn(f, fn_names, fn_rets, structs, enums, globals, instances, 0 - 1, fn_names.len(), no_caps, gf.names, gf.pquals, no_keys, fn_names.len(), wit)
                    total_lambdas = total_lambdas + ch.lifted.len()
                }
            }
            case _ {
            }
        }
        i0 = i0 + 1
    }
    let inst_base = fn_names.len() + total_lambdas
    let insts = build_fn_instances(decls, gf.names, wit)
    // Pass 1: declared functions (generic calls in their bodies now resolve to instance slots).
    var lambda_base = fn_names.len()
    var sid = 0
    var i = 0
    loop {
        if i >= decls.len() {
            break
        }
        match decls[i] {
            case DStruct(name, generics, impls, fields, methods, kind) {
                var mi = 0
                loop {
                    if mi >= methods.len() {
                        break
                    }
                    if methods[mi].has_body {
                        println("== fn {name}.{methods[mi].name} (arity {methods[mi].params.len()}) ==")
                        let ch = compile_fn(methods[mi], fn_names, fn_rets, structs, enums, globals, instances, sid, lambda_base, no_caps, gf.names, gf.pquals, insts.keys, inst_base, wit)
                        disassemble(ch)
                        lambda_base = lambda_base + ch.lifted.len()
                    }
                    mi = mi + 1
                }
                sid = sid + 1
            }
            case DFn(f) {
                if f.has_body {
                    println("== fn {f.name} (arity {f.params.len()}) ==")
                    let ch = compile_fn(f, fn_names, fn_rets, structs, enums, globals, instances, 0 - 1, lambda_base, no_caps, gf.names, gf.pquals, insts.keys, inst_base, wit)
                    disassemble(ch)
                    lambda_base = lambda_base + ch.lifted.len()
                }
            }
            case _ {
            }
        }
        i = i + 1
    }
    // Pass 2: the lifted lambdas, in the same fn order (recompute each fn's lambda_base identically).
    var lb2 = fn_names.len()
    var sid2 = 0
    var j = 0
    loop {
        if j >= decls.len() {
            break
        }
        match decls[j] {
            case DStruct(name, generics, impls, fields, methods, kind) {
                var mi = 0
                loop {
                    if mi >= methods.len() {
                        break
                    }
                    if methods[mi].has_body {
                        let ch = compile_fn(methods[mi], fn_names, fn_rets, structs, enums, globals, instances, sid2, lb2, no_caps, gf.names, gf.pquals, insts.keys, inst_base, wit)
                        emit_lifted_disasm(ch, fn_names, fn_rets, structs, enums, globals, instances, gf.names, gf.pquals, insts.keys, inst_base, wit)
                        lb2 = lb2 + ch.lifted.len()
                    }
                    mi = mi + 1
                }
                sid2 = sid2 + 1
            }
            case DFn(f) {
                if f.has_body {
                    let ch = compile_fn(f, fn_names, fn_rets, structs, enums, globals, instances, 0 - 1, lb2, no_caps, gf.names, gf.pquals, insts.keys, inst_base, wit)
                    emit_lifted_disasm(ch, fn_names, fn_rets, structs, enums, globals, instances, gf.names, gf.pquals, insts.keys, inst_base, wit)
                    lb2 = lb2 + ch.lifted.len()
                }
            }
            case _ {
            }
        }
        j = j + 1
    }
    // Pass 3: the monomorphized instances, in first-use order (each = the base body under a new slot; erased ⇒
    // byte-identical to the base). A free-fn instance re-emits its base DFn; a generic-struct METHOD instance
    // (base "Struct.method") re-emits the struct's method with its self struct id.
    var xi = 0
    loop {
        if xi >= insts.keys.len() {
            break
        }
        var di = 0
        var sidp = 0
        loop {
            if di >= decls.len() {
                break
            }
            match decls[di] {
                case DFn(f) {
                    if f.has_body && f.name == insts.bases[xi] {
                        println("== fn {f.name} (arity {f.params.len()}) ==")
                        let ich = compile_fn(f, fn_names, fn_rets, structs, enums, globals, instances, 0 - 1, inst_base, no_caps, gf.names, gf.pquals, insts.keys, inst_base, wit)
                        disassemble(ich)
                    }
                }
                case DStruct(name, generics, impls, fields, methods, kind) {
                    var mi = 0
                    loop {
                        if mi >= methods.len() {
                            break
                        }
                        if methods[mi].has_body && "{name}.{methods[mi].name}" == insts.bases[xi] {
                            println("== fn {name}.{methods[mi].name} (arity {methods[mi].params.len()}) ==")
                            let ich = compile_fn(methods[mi], fn_names, fn_rets, structs, enums, globals, instances, sidp, inst_base, no_caps, gf.names, gf.pquals, insts.keys, inst_base, wit)
                            disassemble(ich)
                        }
                        mi = mi + 1
                    }
                    sidp = sidp + 1
                }
                case _ {
                }
            }
            di = di + 1
        }
        xi = xi + 1
    }
}


// compile_fn lowers one function body to a Chunk. Params occupy slots 0..arity-1; every function ends with
// the implicit trailing `CONST <0>; <drops>; RETURN` stage-0 appends (the drops release string locals).
// A lifted lambda passes its capture flags as `caps` (declared as leading slots before the lambda's params);
// `lambda_base` is the fn-table index of this function's first lambda (used for MAKE_CLOSURE operands).
fn compile_fn(f: ps.FnDecl, fn_names: [string], fn_rets: FnRets, structs: StructTable, enums: EnumTable, globals: GlobalConsts, instances: [string], self_struct_id: int, lambda_base: int, caps: [CaptureFlag], generic_fns: [string], generic_pquals: [string], fn_inst_keys: [string], inst_base: int, wit: WitInfo) -> Chunk {
    var code: [int] = []
    var lines: [int] = []
    var cif: [bool] = []
    var ci: [int] = []
    var cf: [float] = []
    var strs: [string] = []
    var locals: [string] = []
    var lstr: [bool] = []
    var ldr: [bool] = []
    var sslot: [int] = []
    var sbox: [bool] = []
    var sarr: [bool] = []
    var selem: [int] = []
    var skind: [int] = []
    var conts: [int] = []
    var loopb: [int] = []
    var brkj: [int] = []
    var brkb: [int] = []
    var ret_k = 0
    if f.ret.len() > 0 {
        ret_k = ty_scalar_kind(f.ret[0])
    }
    // Copy the `ensures` predicate/line arrays into the Chunk (element-wise: passing f.enss directly would be
    // a partial move of `f`). Each read is a plain array-index place-read (INCREF), not a move.
    var ee: [ps.Expr] = []
    var el: [int] = []
    var ek = 0
    loop {
        if ek >= f.enss.len() {
            break
        }
        ee.append(f.enss[ek])
        el.append(f.ens_lines[ek])
        ek = ek + 1
    }
    var ch = Chunk { code: code, lines: lines, const_is_float: cif, const_int: ci, const_float: cf, strings: strs, locals: locals, local_str: lstr, local_drop: ldr, cur_line: 0, fn_names: clone_strs(fn_names), fn_ret_str: clone_bools(fn_rets.str), fn_ret_arr: clone_bools(fn_rets.arr), fn_ret_elem: clone_ints(fn_rets.elem), fn_ret_sid: clone_ints(fn_rets.sid), fn_ret_enum: clone_bools(fn_rets.enm), fn_ret_kind: clone_ints(fn_rets.kind), ext_names: clone_strs(fn_rets.ext_names), ext_kinds: clone_ints(fn_rets.ext_kinds), ext_pquals: clone_strs(fn_rets.ext_pquals), lambda_base: lambda_base, lifted: [], generic_fns: clone_strs(generic_fns), generic_pquals: clone_strs(generic_pquals), fn_inst_keys: clone_strs(fn_inst_keys), inst_base: inst_base, cont_targets: conts, loop_bases: loopb, break_jumps: brkj, break_bases: brkb, slot_struct: sslot, slot_boxed: sbox, slot_array: sarr, slot_elem: selem, slot_kind: skind, cur_return_span: 0, cur_fn_name: f.name, fn_ens_e: ee, fn_ens_l: el, ret_kind: ret_k, st_names: clone_strs(structs.names), st_fowner: clone_ints(structs.f_owner), st_fname: clone_strs(structs.f_name), st_fscalar: clone_bools(structs.f_scalar), st_fstring: clone_bools(structs.f_string), st_farray: clone_bools(structs.f_array), st_fstruct: clone_ints(structs.f_struct), st_felem: clone_ints(structs.f_elem), st_farrkind: clone_ints(structs.f_arrkind), st_fenum: clone_bools(structs.f_enum), st_fkind: clone_ints(structs.f_kind), st_ftpname: clone_strs(structs.f_tpname), st_felem_payload: clone_ints(structs.f_elem_payload), inst_keys: clone_strs(instances), et_names: clone_strs(enums.e_names), ev_owner: clone_ints(enums.v_owner), ev_name: clone_strs(enums.v_name), ev_tag: clone_ints(enums.v_tag), ev_arity: clone_ints(enums.v_arity), ev_fvar: clone_ints(enums.vf_var), ev_fstring: clone_bools(enums.vf_string), ev_fstruct: clone_ints(enums.vf_struct), ev_farray: clone_bools(enums.vf_array), ev_felem: clone_ints(enums.vf_elem), ev_fenum: clone_bools(enums.vf_enum), ev_fkind: clone_ints(enums.vf_kind), gc_names: clone_strs(globals.names), gc_kind: clone_ints(globals.kind), gc_ival: clone_ints(globals.ival), gc_sval: clone_strs(globals.sval), gc_bval: clone_bools(globals.bval), gc_fval: clone_floats(globals.fval), expected_key: "", if_names: clone_strs(wit.if_names), ifm_iface: clone_ints(wit.ifm_iface), ifm_name: clone_strs(wit.ifm_name), ifm_owning: clone_bools(wit.ifm_owning), gb_fn: clone_strs(wit.gb_fn), gb_tpname: clone_strs(wit.gb_tpname), gb_bound: clone_strs(wit.gb_bound), gb_argidx: clone_ints(wit.gb_argidx), impl_struct: clone_strs(wit.impl_struct), impl_iface: clone_strs(wit.impl_iface), sg_struct: clone_strs(wit.sg_struct), sg_tparam: clone_strs(wit.sg_tparam), sg_bound: clone_strs(wit.sg_bound), gret_fn: clone_strs(wit.gret_fn), gret_arr: clone_bools(wit.gret_arr), gret_argidx: clone_ints(wit.gret_argidx), wit_tpname: [], wit_bound: [], wit_slot: [], tp_pslot: [], tp_pname: [], cur_tp_names: [], cur_tp_types: [], mwit_tpname: [], mwit_bound: [], mwit_field: [], mrecv_name: [], mrecv_args: [] }
    ch.cur_return_span = ch.return_struct_span(f.ret)
    // Bind this fn's type params to concrete types for baking witnesses in a bounded generic-struct
    // construction (`Bag<K>{}` in new_bag bakes K=int's Hash/Eq). Derived from the fn's monomorphized instance
    // key ("new_bag<int>"); a single-instantiation bounded generic bakes the same witnesses in base + instance,
    // matching stage-0 (OFI-174).
    if f.generics.len() > 0 {
        // cur_tp_names is ALWAYS this fn's type-param names (so an erased `[T]` array element is recognised as
        // refcounted even for a fn with no monomorphized instance); cur_tp_types binds them to concrete types
        // from a matching instance key when one exists (for witness baking). Find the instance types first,
        // then append in one pass (an element-into-element SET_INDEX would trip the cgen_c own_into_slot gap).
        var types: [string] = []
        var ki = 0
        loop {
            if ki >= ch.fn_inst_keys.len() {
                break
            }
            if str_starts_with(ch.fn_inst_keys[ki], "{f.name}<") {
                types = parse_inst_types(ch.fn_inst_keys[ki], f.name)
                break
            }
            ki = ki + 1
        }
        var gi = 0
        loop {
            if gi >= f.generics.len() {
                break
            }
            ch.cur_tp_names.append(f.generics[gi].name)
            if gi < types.len() {
                ch.cur_tp_types.append(types[gi])
            } else {
                ch.cur_tp_types.append("")
            }
            gi = gi + 1
        }
    }
    if self_struct_id >= 0 {
        // a method receiver: `self` is a BOXED struct in slot 0 (so self.field is GET_FIELD even for an
        // all-scalar struct), and a BORROW — not dropped at exit.
        ch.declare_binding("self", 1, self_struct_id, false, false, true, false)
    }
    // A lifted lambda's CAPTURES are its leading params (slots 0..C-1), re-declared with the exact flags they
    // had in the enclosing scope (so a string/enum capture INCREFs-on-consume + drops, a scalar copies).
    var cx = 0
    loop {
        if cx >= caps.len() {
            break
        }
        ch.declare_binding(caps[cx].name, 1, caps[cx].struct_id, caps[cx].is_str, caps[cx].droppable, caps[cx].boxed, caps[cx].is_array)
        ch.slot_elem[ch.slot_elem.len() - 1] = caps[cx].elem
        ch.slot_kind[ch.slot_kind.len() - 1] = caps[cx].kind
        cx = cx + 1
    }
    // Witness leading params (OFI-174): a bounded generic fn (`max<T: Ord>`) receives one hidden witness per
    // (type-param, bound), in declaration order, BEFORE its value params. Each is a borrowed `Some(method-ref)`
    // enum in a plain non-droppable slot (stage-0 never drops a witness). Record each slot's (type-param,
    // bound) so a bound-method call in the body can find which witness to GET_FIELD its method-ref from.
    var gwi = 0
    loop {
        if gwi >= ch.gb_fn.len() {
            break
        }
        if ch.gb_fn[gwi] == f.name {
            ch.declare_binding("$wit", 1, 0 - 1, false, false, false, false)
            ch.wit_slot.append(ch.locals.len() - 1)
            ch.wit_tpname.append(ch.gb_tpname[gwi])
            ch.wit_bound.append(ch.gb_bound[gwi])
        }
        gwi = gwi + 1
    }
    // An UNTYPED lambda param used as a string (`|s| s + suffix`) is declared as an owned/droppable string so
    // it INCREFs on consume + drops at exit (regular fns have typed params, so this is empty for them).
    let str_params = infer_str_params(caps, f.params, f.body)
    // Type-param names erased in THIS body: the function's own generics, plus (for a generic-struct METHOD)
    // the struct's type params — so `Bag<K>.add(x: K)` erases K (INCREF on consume/append), like a free
    // generic fn's `T` (OFI-174).
    var erased_gnames: [string] = []
    var eg = 0
    loop {
        if eg >= f.generics.len() {
            break
        }
        erased_gnames.append(f.generics[eg].name)
        eg = eg + 1
    }
    if self_struct_id >= 0 {
        var sgx = 0
        loop {
            if sgx >= ch.sg_struct.len() {
                break
            }
            if ch.sg_struct[sgx] == ch.st_names[self_struct_id] {
                erased_gnames.append(ch.sg_tparam[sgx])
            }
            sgx = sgx + 1
        }
    }
    // For a method of a bounded generic struct (Map<K:Hash+Eq,V>.set), map each (struct type-param, bound) to
    // its witness FIELD index in self, so a bound-method call in the body (`key.hash()`) dispatches through
    // self's witness field. Witness fields follow the declared fields, in (type-param, bound) order (OFI-174).
    if self_struct_id >= 0 && ch.struct_is_bounded(ch.st_names[self_struct_id]) {
        let sname = ch.st_names[self_struct_id]
        var widx = ch.struct_declared_field_count(self_struct_id)
        var mgx = 0
        loop {
            if mgx >= ch.sg_struct.len() {
                break
            }
            if ch.sg_struct[mgx] == sname {
                let mb = split_plus(ch.sg_bound[mgx])
                var mbi = 0
                loop {
                    if mbi >= mb.len() {
                        break
                    }
                    if mb[mbi] != "" {
                        ch.mwit_tpname.append(ch.sg_tparam[mgx])
                        ch.mwit_bound.append(mb[mbi])
                        ch.mwit_field.append(widx)
                        widx = widx + 1
                    }
                    mbi = mbi + 1
                }
            }
            mgx = mgx + 1
        }
    }
    var p = 0
    loop {
        if p >= f.params.len() {
            break
        }
        if f.params[p].is_self == false {
            if f.params[p].ty.len() > 0 && ty_tparam_name_in(f.params[p].ty[0], erased_gnames) != "" {
                if f.params[p].qual == 2 {
                    // a `move T` param: consuming it MOVES (zero the slot); the slot is droppable (the exit
                    // DROP is a no-op once zeroed). Realized as droppable + boxed (move_local_slot moves it).
                    ch.declare_binding(f.params[p].name, 1, 0 - 1, false, true, true, false)
                } else {
                    // a Copy/borrow erased type-param: INCREF on consume (local_str), NEVER dropped (over-retain)
                    ch.declare_binding(f.params[p].name, 1, 0 - 1, true, false, false, false)
                }
                // Record this param's slot + its type-param name so a bound-method call `p.method(..)` on it
                // dispatches through the matching witness (OFI-174).
                ch.tp_pslot.append(ch.locals.len() - 1)
                ch.tp_pname.append(ty_tparam_name_in(f.params[p].ty[0], erased_gnames))
            } else if cg_index_of(str_params, f.params[p].name) >= 0 {
                ch.declare_binding(f.params[p].name, 1, 0 - 1, true, true, false, false)
            } else if self_struct_id >= 0 && ch.method_is_iface_impl(ch.st_names[self_struct_id], f.name) && ch.param_is_self_typed(f.params[p], self_struct_id) {
                // An interface-method param typed as the struct itself (Ord.compare's `other: Self`) arrives
                // BOXED through the witness's CALL_INDIRECT, so declare it as a single boxed struct slot (OFI-174).
                ch.declare_binding(f.params[p].name, 1, self_struct_id, false, false, true, false)
            } else {
                ch.declare_param(f.params[p])
            }
        }
        p = p + 1
    }
    // `requires` clauses are checked at entry: evaluate each predicate, then CONTRACT_CHECK <running index>.
    var rq = 0
    loop {
        if rq >= f.reqs.len() {
            break
        }
        ch.gen_expr(f.reqs[rq], f.req_lines[rq])
        let rmsg = "precondition failed in '{f.name}' (requires, line {f.req_lines[rq]})"
        ch.emit(OP_CONTRACT_CHECK)
        ch.emit_idx(ch.add_string(rmsg))
        rq = rq + 1
    }
    var i = 0
    loop {
        if i >= f.body.len() {
            break
        }
        ch.gen_stmt(f.body[i])
        i = i + 1
    }
    // Trailing implicit return: an all-scalar-struct-returning function pushes N zeros + RETURN_STRUCT N;
    // otherwise CONST <0> + drop string locals + RETURN.
    let rspan = ch.return_struct_span(f.ret)
    if rspan > 0 {
        var z = 0
        loop {
            if z >= rspan {
                break
            }
            let zidx = ch.add_const_int(0)
            ch.emit(OP_CONST)
            ch.emit_idx(zidx)
            z = z + 1
        }
        ch.emit(OP_RETURN_STRUCT)
        ch.emit_idx(rspan)
    } else {
        let idx = ch.add_const_int(0)
        ch.emit(OP_CONST)
        ch.emit_idx(idx)
        ch.emit_ensures()
        ch.emit_drops()
        ch.emit(OP_RETURN)
    }
    return ch
}
