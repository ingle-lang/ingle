// selfhost/serialize.em — the self-hosted BYTECODE SERIALIZER (docs/design/bytecode-container.md, Phase 1c
// of the standalone-toolchain campaign). It turns a parsed program into a `.emb` container — the exact same
// bytes stage 0's C serializer (src/bytecode_io.c) produces — so the self-hosted compiler can emit a
// RUNNABLE artifact, not just a disassembly. It reuses codegen.em's tables + compile_fn for the bytecode
// and mirrors bytecode_write's layout; correctness is the byte-diff against stage 0 (tools/embdiff.sh).
//
// The container is LINE-precise (no columns): the codegen tracks per-node lines but not columns, which is
// exactly what lets this serializer be byte-identical to stage 0 (which now also stores lines only).

import "parser" as ps
import "codegen" as cg


// Writer accumulates the container bytes. All emission is through `mut self` METHODS (a free function with
// a `mut struct` parameter does NOT persist its mutation on the native backend — OFI-161 — but a method
// does), so the byte buffer threads correctly on both backends.
struct Writer {
    bytes: [u8]


    // emit_u8 appends one byte (the low 8 bits of v).
    fn emit_u8(mut self, v: int) {
        self.bytes.append(u8(v & 255))
    }


    // emit_bytes appends a [u8] slice verbatim.
    fn emit_bytes(mut self, data: [u8]) {
        var i = 0
        loop {
            if i >= data.len() {
                break
            }
            self.bytes.append(data[i])
            i = i + 1
        }
    }


    // emit_u32 / emit_u64 write a fixed-width little-endian integer.
    fn emit_u32(mut self, v: int) {
        var k = 0
        loop {
            if k >= 4 {
                break
            }
            self.emit_u8((v >> (8 * k)) & 255)
            k = k + 1
        }
    }


    fn emit_u64(mut self, v: int) {
        var k = 0
        loop {
            if k >= 8 {
                break
            }
            self.emit_u8((v >> (8 * k)) & 255)
            k = k + 1
        }
    }


    // emit_uvarint writes an unsigned LEB128 (7 bits per byte, high bit = continuation).
    fn emit_uvarint(mut self, v: int) {
        var vv = v
        loop {
            var b = vv & 127
            vv = vv >> 7
            if vv != 0 {
                self.emit_u8(b | 128)
            } else {
                self.emit_u8(b)
                break
            }
        }
    }


    // emit_svarint writes a zig-zag LEB128 (so small negatives like -1 stay one byte).
    fn emit_svarint(mut self, v: int) {
        self.emit_uvarint((v << 1) ^ (v >> 63))
    }


    // emit_str writes a non-NULL string as {uvarint byte-length, raw bytes}.
    fn emit_str(mut self, s: string) {
        self.emit_uvarint(s.len())
        self.emit_bytes(s.bytes())
    }


    // emit_optstr writes a NULL-able string: here always present, so length+1 then the bytes (0 = NULL).
    fn emit_optstr(mut self, s: string) {
        self.emit_uvarint(s.len() + 1)
        self.emit_bytes(s.bytes())
    }


    // emit_chunk writes one function's bytecode: verbatim code bytes, the run-length-encoded line table,
    // the int/float constant pool, and the string-literal pool — mirroring bytecode_write's per-fn block.
    fn emit_chunk(mut self, ch: cg.Chunk) {
        // Code bytes, verbatim.
        self.emit_uvarint(ch.code.len())
        var i = 0
        loop {
            if i >= ch.code.len() {
                break
            }
            self.emit_u8(ch.code[i])
            i = i + 1
        }

        // Line table, run-length-encoded: count runs (a maximal span of one line), then emit {len, line}.
        var runs = 0
        var j = 0
        loop {
            if j >= ch.code.len() {
                break
            }
            let line = ch.lines[j]
            var k = j + 1
            loop {
                if k >= ch.code.len() {
                    break
                }
                if ch.lines[k] != line {
                    break
                }
                k = k + 1
            }
            runs = runs + 1
            j = k
        }
        self.emit_uvarint(runs)
        j = 0
        loop {
            if j >= ch.code.len() {
                break
            }
            let line = ch.lines[j]
            var k = j + 1
            loop {
                if k >= ch.code.len() {
                    break
                }
                if ch.lines[k] != line {
                    break
                }
                k = k + 1
            }
            self.emit_uvarint(k - j)
            self.emit_svarint(line)
            j = k
        }

        // Constant pool (parallel arrays; const_is_float selects). int/float only.
        self.emit_uvarint(ch.const_int.len())
        var ci = 0
        loop {
            if ci >= ch.const_int.len() {
                break
            }
            if ch.const_is_float[ci] {
                self.emit_u8(1)
                self.emit_u64(float_bits(ch.const_float[ci]))
            } else {
                self.emit_u8(0)
                self.emit_u64(ch.const_int[ci])
            }
            ci = ci + 1
        }

        // String-literal pool.
        self.emit_uvarint(ch.strings.len())
        var si = 0
        loop {
            if si >= ch.strings.len() {
                break
            }
            self.emit_str(ch.strings[si])
            si = si + 1
        }
    }


    // emit_one_struct writes a single struct entry from a DStruct's fields: name, rc/resource flags,
    // drop-fn index, then per-field {ArrayElemKind, nested-struct-id, name}. The AEK comes from the field's
    // type via codegen's array_elem_kind_from_ty (the same mapping stage 0's checker uses): a scalar packs
    // at its natural width, an aggregate / erased generic parameter is boxed. The loader repacks offsets
    // from the kinds. (rc/resource/drop_fn, nested inline value-struct fields, and bounded-generic witness
    // fields are the next increments — the compiler's own structs use none of them.)
    // emit_one_struct writes one struct entry. For a monomorphized generic instance, `gparams`/`gargs` are
    // the base's type-parameter names and this instance's concrete type arguments (empty for a declared
    // struct); a field whose type IS a type parameter takes the substituted argument's kind (so Box<int>'s
    // `value` packs as I64, not boxed).
    fn emit_one_struct(mut self, name: string, fields: [ps.Field], structs: cg.StructTable,
                       gparams: [string], gargs: [string]) {
        self.emit_str(name)
        self.emit_u8(0)             // flags: is_rc | is_resource<<1 (TODO)
        self.emit_svarint(0 - 1)    // drop_fn (TODO)
        self.emit_uvarint(fields.len())
        var fi = 0
        loop {
            if fi >= fields.len() {
                break
            }
            let ty = fields[fi].ty
            let gi = cg.cg_index_of(gparams, ty_name_of(ty))
            if gi >= 0 && gi < gargs.len() {
                // A type-parameter field in an instance: pack at the concrete argument's width.
                self.emit_uvarint(aek_of_typename(gargs[gi]))
                self.emit_svarint(0 - 1)
            } else {
                let nsid = cg.ty_struct_id(ty, structs.names)
                if nsid >= 0 && struct_all_scalar_st(structs, nsid) {
                    // A nested all-scalar struct field is packed INLINE (kind AEK_INLINE_STRUCT, the nested
                    // struct id in field_struct) — mirrors stage 0's nested_inline_sid.
                    self.emit_uvarint(12)          // AEK_INLINE_STRUCT
                    self.emit_svarint(nsid)
                } else {
                    self.emit_uvarint(cg.array_elem_kind_from_ty(ty))
                    self.emit_svarint(0 - 1)
                }
            }
            self.emit_optstr(fields[fi].name)
            fi = fi + 1
        }
    }


    // emit_struct_table writes the whole struct-type table: the declared structs in DECL_STRUCT order, then
    // the monomorphized generic-struct instances (Box<Expr>, …) — each with its BASE struct's name + fields
    // (an erased generic-parameter field maps to boxed through the same kind map, matching stage 0's
    // append-model layout for a Box<Aggregate>).
    fn emit_struct_table(mut self, decls: [ps.Decl], instances: [string], structs: cg.StructTable) {
        var i = 0
        loop {
            if i >= decls.len() {
                break
            }
            match decls[i] {
                case DStruct(name, generics, impls, fields, methods, kind) {
                    let none: [string] = []
                    self.emit_one_struct(name, fields, structs, none, none)
                }
                case _ {
                }
            }
            i = i + 1
        }
        var ii = 0
        loop {
            if ii >= instances.len() {
                break
            }
            let base = base_name(instances[ii])
            var j = 0
            loop {
                if j >= decls.len() {
                    break
                }
                match decls[j] {
                    case DStruct(name, generics, impls, fields, methods, kind) {
                        if name == base {
                            var gnames: [string] = []
                            var gk = 0
                            loop {
                                if gk >= generics.len() {
                                    break
                                }
                                gnames.append(generics[gk].name)
                                gk = gk + 1
                            }
                            let gargs = type_args(instances[ii])
                            self.emit_one_struct(name, fields, structs, gnames, gargs)
                        }
                    }
                    case _ {
                    }
                }
                j = j + 1
            }
            ii = ii + 1
        }
    }
}


// struct_all_scalar_st reports whether every field of struct `sid` is a packed scalar (the StructTable
// counterpart of codegen's Chunk.struct_all_scalar) — the test for an inline-able nested value struct.
fn struct_all_scalar_st(structs: cg.StructTable, sid: int) -> bool {
    var seen = false
    var i = 0
    loop {
        if i >= structs.f_owner.len() {
            break
        }
        if structs.f_owner[i] == sid {
            seen = true
            if structs.f_scalar[i] == false {
                return false
            }
        }
        i = i + 1
    }
    return seen
}


// base_name returns the base struct name of a monomorphized-instance key ("Box<Expr>" -> "Box").
fn base_name(key: string) -> string {
    let bs = key.bytes()
    var i = 0
    loop {
        if i >= bs.len() {
            break
        }
        if int(bs[i]) == 60 {          // '<'
            return byte_slice(key, 0, i)
        }
        i = i + 1
    }
    return key
}


// ty_name_of returns the bare name of a TyName type (a plain identifier such as a type parameter `T` or
// `int`), or "" for any other type form (array, generic application, …).
fn ty_name_of(ty: ps.Ty) -> string {
    match ty {
        case TyName(q, n) {
            return n
        }
        case _ {
            return ""
        }
    }
}


// aek_of_typename maps a scalar type NAME to its ArrayElemKind (the string counterpart of codegen's
// array_elem_kind_from_ty), used to pack a monomorphized type argument; a non-scalar (string/struct/enum
// or another generic) is boxed.
fn aek_of_typename(name: string) -> int {
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
    return 0
}


// type_args splits a monomorphized-instance key's type arguments ("Box<int>" -> ["int"], "Map<K,V>" ->
// ["K","V"], "Box<Map<K,V>>" -> ["Map<K,V>"]) — top-level commas only, tracking `<`/`>` nesting depth.
fn type_args(key: string) -> [string] {
    var out: [string] = []
    let bs = key.bytes()
    var depth = 0
    var argstart = 0
    var i = 0
    loop {
        if i >= bs.len() {
            break
        }
        let c = int(bs[i])
        if c == 60 {              // '<'
            depth = depth + 1
            if depth == 1 {
                argstart = i + 1
            }
        } else if c == 62 {       // '>'
            if depth == 1 {
                out.append(byte_slice(key, argstart, i))
            }
            depth = depth - 1
        } else if c == 44 && depth == 1 {   // ',' at the top level
            out.append(byte_slice(key, argstart, i))
            argstart = i + 1
        }
        i = i + 1
    }
    return out
}


// variant_tag returns the tag of the variant named `name` in enum `enum_id`, or 0 if not found (the prelude
// Result::Err / Option::None failure tags).
fn variant_tag(enums: cg.EnumTable, enum_id: int, name: string) -> int {
    var vi = 0
    loop {
        if vi >= enums.v_name.len() {
            break
        }
        if enums.v_owner[vi] == enum_id && enums.v_name[vi] == name {
            return enums.v_tag[vi]
        }
        vi = vi + 1
    }
    return 0
}


// count_functions counts the function slots the container holds: every free function and struct method with
// a body, in the order emit_program (and stage 0) walks them.
fn count_functions(decls: [ps.Decl]) -> int {
    var n = 0
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
                        n = n + 1
                    }
                    mi = mi + 1
                }
            }
            case DFn(f) {
                if f.has_body {
                    n = n + 1
                }
            }
            case _ {
            }
        }
        i = i + 1
    }
    return n
}


// serialize_program builds the whole `.emb` container for `decls` (the merged multi-module declaration
// list) and writes it to `out_path`. `sources[i]` is the module path declaration `decls[i]` came from, so
// each function's source_file is its OWN module (multi-module byte-identity). It writes the file directly
// rather than returning the byte array, because returning a struct FIELD is a partial move (unsupported);
// from_bytes borrows the field, so no move occurs.
fn serialize_program(decls: [ps.Decl], sources: [string], out_path: string) {
    let fn_names = cg.build_fn_names(decls)
    let structs = cg.build_structs(decls)
    let enums = cg.build_enums(decls, structs)
    let fn_rets = cg.build_fn_rets(decls, structs, enums.e_names)
    let globals = cg.build_globals(decls)
    let instances = cg.build_struct_instances(decls, structs.names)

    let func_count = count_functions(decls)
    let struct_count = structs.names.len() + instances.len()
    let variant_count = enums.v_name.len()
    let result_id = cg.cg_index_of(enums.e_names, "Result")
    let option_id = cg.cg_index_of(enums.e_names, "Option")
    // main_index defaults to 0 when there is no `main` (mirrors the checker's MonoPlan default, check.c:8477),
    // not -1 — a no-main module still serializes.
    var main_index = cg.cg_index_of(fn_names, "main")
    if main_index < 0 {
        main_index = 0
    }

    var w = Writer { bytes: [] }

    // Header.
    w.emit_u8(69)   // 'E'
    w.emit_u8(77)   // 'M'
    w.emit_u8(66)   // 'B'
    w.emit_u8(1)
    w.emit_u32(1)   // container format version
    w.emit_u32(1)   // vm ABI

    // Program header.
    w.emit_svarint(main_index)
    w.emit_svarint(result_id)
    w.emit_svarint(variant_tag(enums, result_id, "Err"))
    w.emit_svarint(option_id)
    w.emit_svarint(variant_tag(enums, option_id, "None"))
    w.emit_uvarint(func_count)
    w.emit_uvarint(struct_count)
    w.emit_uvarint(variant_count)

    // Struct-type table.
    w.emit_struct_table(decls, instances, structs)

    // Enum-variant table.
    var vi = 0
    loop {
        if vi >= variant_count {
            break
        }
        w.emit_str(enums.v_name[vi])
        w.emit_svarint(enums.v_owner[vi])
        w.emit_svarint(enums.v_tag[vi])
        w.emit_uvarint(enums.v_arity[vi])
        vi = vi + 1
    }

    // Function table (methods interleaved with free functions, declaration order — CALL operands index it).
    var no_caps: [cg.CaptureFlag] = []           // declared local: an inline `[]` caps arg mis-emits its elem kind
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
                        w.emit_str(name + "." + methods[mi].name)
                        w.emit_optstr(sources[i])
                        w.emit_uvarint(methods[mi].params.len())
                        let ch = cg.compile_fn(methods[mi], fn_names, fn_rets, structs, enums, globals, instances, sid, fn_names.len(), no_caps)
                        w.emit_chunk(ch)
                    }
                    mi = mi + 1
                }
                sid = sid + 1
            }
            case DFn(f) {
                if f.has_body {
                    w.emit_str(f.name)
                    w.emit_optstr(sources[i])
                    w.emit_uvarint(f.params.len())
                    let ch = cg.compile_fn(f, fn_names, fn_rets, structs, enums, globals, instances, 0 - 1, fn_names.len(), no_caps)
                    w.emit_chunk(ch)
                }
            }
            case _ {
            }
        }
        i = i + 1
    }

    write_file(out_path, from_bytes(w.bytes))
}
