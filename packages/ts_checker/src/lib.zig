//! Built-in lib types — minimal `lib.d.ts` substitute.
//!
//! TypeScript ships a sizable `lib.es*.d.ts` declaring `String`,
//! `Array<T>`, `Object`, etc. We don't yet parse those files; instead
//! this module hard-codes a small subset of common members so that
//! everyday code (`s.length`, `s.toUpperCase()`, `arr.push(x)`,
//! `Object.keys(o)`) typechecks instead of falling through to `any`.
//!
//! Scope is intentionally small. Anything more elaborate (full
//! generic instantiation of `Array.prototype.map<U>`, the dozens of
//! string methods, regex / iterator types, …) is a follow-up. For
//! now `map` / `flatMap` / `filter` / `forEach` use loose signatures that accept
//! a callback and return `any[]` / `any[]` / `T[]` / `void` respectively. The
//! arity-and-existence check still fires; sharper inference of `U`
//! is deferred until the generic-instantiation work lands here.
//!
//! All types are interned lazily on first use so initialization
//! cost is paid only when checking touches strings/arrays/Object.

const std = @import("std");
const types = @import("types.zig");
const interner_mod = @import("interner.zig");
const string_interner = @import("string_interner");

pub const TypeId = types.TypeId;
pub const StringId = types.StringId;

/// Cache of pre-built lib types. Lives on `Checker` and is populated
/// lazily by the `*Proto*` accessors below.
pub const LibCache = struct {
    /// `String.prototype` shape — non-generic, parameterised over
    /// `string` itself. Built once and reused for every `string`-typed
    /// member access.
    string_proto: TypeId = types.Primitive.none,
    /// `Number.prototype` shape — common formatting/conversion
    /// methods on the primitive `number` receiver.
    number_proto: TypeId = types.Primitive.none,
    /// `Symbol` global-object (boxed) shape — the apparent type of the
    /// `symbol` primitive. Built once and reused so `var x: Symbol`
    /// resolves (instead of `unknown`) and `symbol` boxes into it.
    symbol_proto: TypeId = types.Primitive.none,
    /// `Object` global — `keys / values / entries / assign`. Built
    /// once on first access.
    object_global: TypeId = types.Primitive.none,
    /// `Array` global — static helpers such as `isArray`.
    array_global: TypeId = types.Primitive.none,
    /// `Math` global — `PI`, `E`, `abs`, `floor`, etc. Built once on
    /// first access.
    math_global: TypeId = types.Primitive.none,
    /// `console` global — `log`, `error`, `warn`, `info`. Built once
    /// on first access.
    console_global: TypeId = types.Primitive.none,
    /// `Number` global — `MAX_VALUE`, `isInteger`, etc. Built once
    /// on first access.
    number_global: TypeId = types.Primitive.none,
    /// `JSON` global — `parse(text, reviver?)` / `stringify(value,
    /// replacer?, space?)`. Built once on first access.
    json_global: TypeId = types.Primitive.none,
    /// `String` global — `fromCharCode`, `fromCodePoint`, `raw`.
    string_global: TypeId = types.Primitive.none,
    /// `Boolean` global — call/construct coercion shape.
    boolean_global: TypeId = types.Primitive.none,
    /// `BigInt` global — call coercion + `asIntN` / `asUintN`.
    bigint_global: TypeId = types.Primitive.none,
    /// Element-type → `Array<T>.prototype` shape mapping. Cached so a
    /// repeated `T[]` member access doesn't re-intern the dozen-ish
    /// methods on every lookup.
    array_proto_by_elem: std.AutoHashMapUnmanaged(TypeId, TypeId) = .empty,

    pub fn deinit(self: *LibCache, gpa: std.mem.Allocator) void {
        self.array_proto_by_elem.deinit(gpa);
    }
};

/// Build (or fetch from cache) the `String.prototype` member shape.
/// All methods are typed against the concrete `string` primitive —
/// generics aren't needed here.
/// Build a fixed-arity tuple type `[E0, E1, …]` using the same
/// structural encoding the checker's `internTupleFromTypes` produces:
/// an object type carrying numeric-named members (`"0"`, `"1"`, …),
/// a `readonly length` number-literal, and a `number`-key index
/// signature whose value is the union of the element types. Keeping
/// the encoding identical means tuples built here are
/// indistinguishable (for assignability / element access) from tuples
/// the checker synthesizes for tuple literals, and `substituteType`
/// rewrites a `U` appearing inside an element through the object-type
/// path it already walks. Used to give `Object.entries` its precise
/// `[string, T][]` element shape.
pub fn internTuple(
    ti: *interner_mod.Interner,
    sint: *string_interner.Interner,
    elems: []const TypeId,
) !TypeId {
    // Our use sites build small (2-element) tuples; cap the stack
    // buffer at 16 elements + the trailing `length` member.
    std.debug.assert(elems.len <= 16);
    var all: [17]types.ObjectMember = undefined;
    for (elems, 0..) |t, i| {
        var nbuf: [12]u8 = undefined;
        const name_str = std.fmt.bufPrint(&nbuf, "{d}", .{i}) catch unreachable;
        const name = try sint.intern(name_str);
        all[i] = .{
            .name = name,
            .type = t,
            .is_optional = false,
            .is_readonly = false,
            .is_method = false,
        };
    }
    const length_id = try sint.intern("length");
    const length_t = ti.internNumberLiteral(@floatFromInt(elems.len)) catch types.Primitive.number_t;
    all[elems.len] = .{
        .name = length_id,
        .type = length_t,
        .is_optional = false,
        .is_readonly = true,
        .is_method = false,
    };
    const elem_union: TypeId = if (elems.len == 0)
        types.Primitive.never
    else if (elems.len == 1)
        elems[0]
    else
        ti.internUnion(elems) catch types.Primitive.any;
    return ti.internObjectTypeWithIndex(all[0 .. elems.len + 1], types.Primitive.none, elem_union);
}

/// Build the `RegExpMatchArray` shape — upstream
/// `interface RegExpMatchArray extends Array<string>` with the extra
/// `index?: number`, `input?: string`, and a guaranteed `0: string`
/// member (the whole match). Encoded as a `string[]`-shaped object
/// (number-key index → `string`, `length: number`) augmented with the
/// three extra members, so it remains assignable where `string[]` is
/// expected while also exposing `m.index` / `m.input` / `m[0]`. Used by
/// `String.prototype.match`'s precise `RegExpMatchArray | null` return.
pub fn internRegExpMatchArray(
    ti: *interner_mod.Interner,
    sint: *string_interner.Interner,
) !TypeId {
    const string_t = types.Primitive.string_t;
    const number_t = types.Primitive.number_t;
    const members = [_]types.ObjectMember{
        .{ .name = try sint.intern("length"), .type = number_t, .is_optional = false, .is_readonly = false, .is_method = false },
        // `index?: number` — start offset of the match in the input.
        .{ .name = try sint.intern("index"), .type = number_t, .is_optional = true, .is_readonly = false, .is_method = false },
        // `input?: string` — copy of the searched string.
        .{ .name = try sint.intern("input"), .type = string_t, .is_optional = true, .is_readonly = false, .is_method = false },
        // `0: string` — the whole-match capture, always present.
        .{ .name = try sint.intern("0"), .type = string_t, .is_optional = false, .is_readonly = false, .is_method = false },
    };
    // Number-key index → `string` mirrors `extends Array<string>`.
    return ti.internObjectTypeWithIndex(&members, types.Primitive.none, string_t);
}

/// Build (or fetch from cache) the `String.prototype` member shape.
/// All methods are typed against the concrete `string` primitive —
/// generics aren't needed here.
pub fn stringProto(
    cache: *LibCache,
    ti: *interner_mod.Interner,
    sint: *string_interner.Interner,
    gpa: std.mem.Allocator,
    rest_set: *std.AutoHashMapUnmanaged(TypeId, void),
) !TypeId {
    if (cache.string_proto != types.Primitive.none) return cache.string_proto;

    const string_t = types.Primitive.string_t;
    const number_t = types.Primitive.number_t;
    const boolean_t = types.Primitive.boolean_t;
    const any_t = types.Primitive.any;

    // `string[]` for `split`'s return.
    const string_arr = try ti.internArrayType(sint, string_t);

    // `(): string`
    const sig_void_string = try ti.internSignature(&[_]TypeId{}, string_t, false);
    var number_or_undefined_members = [_]TypeId{ number_t, types.Primitive.undefined_t };
    const optional_number_t = try ti.internUnion(&number_or_undefined_members);

    // `(s: string, position?: number): boolean` — used by `includes`,
    // `startsWith`, `endsWith`. Upstream signatures all take an
    // optional second-arg position offset; we declared just `(s)`,
    // tripping TS2554 on `s.startsWith("x", 0)` etc.
    const sig_str_pos_bool = try ti.internSignature(&[_]TypeId{ string_t, optional_number_t }, boolean_t, false);
    // `(s: string): boolean` — legacy single-arg form, kept for
    // tests that only need the simple shape.
    const sig_str_bool = try ti.internSignature(&[_]TypeId{string_t}, boolean_t, false);
    _ = sig_str_bool;
    // `(s: string, fromIndex?: number): number` — used by `indexOf`.
    // Optional fromIndex matches upstream and our `lastIndexOf`.
    const sig_str_num = try ti.internSignature(&[_]TypeId{ string_t, optional_number_t }, number_t, false);
    // `(i: number): string`
    const sig_num_string = try ti.internSignature(&[_]TypeId{number_t}, string_t, false);
    // `split(separator?: string | RegExp, limit?: number): string[]`.
    // The separator accepts both `string` and `RegExp`; model it as `any`
    // like `match`/`replace` so regex literals don't spuriously fail.
    const sig_split = try ti.internSignature(&[_]TypeId{ any_t, optional_number_t }, string_arr, false);
    // `(start: number, end?: number): string`.
    const sig_slice = try ti.internSignature(&[_]TypeId{ number_t, optional_number_t }, string_t, false);
    // `concat(...strs: string[]): string` — rest accepting any number
    // of additional strings. Registered in `rest_set` so call sites
    // expand to 0+ string args.
    const sig_str_string = try ti.internSignature(&[_]TypeId{string_arr}, string_t, false);
    try rest_set.put(gpa, sig_str_string, {});

    // `(pos: number): number` — used by `charCodeAt` (returns the
    // UTF-16 code unit at the given index, NaN if out of range).
    const sig_num_num = try ti.internSignature(&[_]TypeId{number_t}, number_t, false);

    const undef_t = types.Primitive.undefined_t;
    const string_or_undefined_t = try ti.internUnion(&[_]TypeId{ string_t, undef_t });
    const number_or_undefined_t = optional_number_t;

    // `replace(pattern: string | RegExp, replacement): string`. The
    // pattern accepts both `string` and `RegExp`; modeled as `any` so
    // `s.replace(/re/, "x")` and `s.replace("a", "b")` both resolve.
    // Replacement may be a string or a replacer function — modeled `any`.
    const sig_replace = try ti.internSignature(&[_]TypeId{ any_t, any_t }, string_t, false);
    // `match(regexp: string | RegExp): RegExpMatchArray | null` — precise
    // match-array result unioned with `null` (es5). The pattern accepts
    // both `string` and `RegExp`, modeled `any`.
    //
    // NOTE: the faithful upstream return is `RegExpMatchArray | null`, but
    // Home's flow engine has a pre-existing gap narrowing a CALL-RESULT
    // union of `Obj | null` — `const m = s.match(re); if (m) { m.index }`
    // fails to strip `null` (the same gap reproduces for a hand-written
    // `declare function g(): Foo | null; const f = g(); if (f) f.bar`,
    // i.e. it is orthogonal to lib typing). Unioning with `null` here
    // would therefore turn the dominant `if (m)` idiom into a false
    // positive. We return the precise NON-NULL `RegExpMatchArray` instead
    // (a strict improvement over the old bare `any`: `m.index` / `m[0]` /
    // `m.length` resolve), and defer the `| null` until the call-result
    // narrowing gap is fixed in the flow engine.
    const regexp_match_array = try internRegExpMatchArray(ti, sint);
    const sig_match = try ti.internSignature(&[_]TypeId{any_t}, regexp_match_array, false);
    // `matchAll(regexp): IterableIterator<RegExpMatchArray>` — Home models
    // iterables as arrays on the iteration path, so `RegExpMatchArray[]`
    // is the closest faithful approximation (each yielded match has the
    // precise shape). Better than `any` for `for (const m of s.matchAll(...))`.
    const match_array_arr = try ti.internArrayType(sint, regexp_match_array);
    const sig_match_all = try ti.internSignature(&[_]TypeId{any_t}, match_array_arr, false);
    // `search(pattern): number`.
    const sig_search = try ti.internSignature(&[_]TypeId{any_t}, number_t, false);
    // `padStart(maxLength: number, fillString?: string): string` /
    // `padEnd(...)`.
    const sig_pad = try ti.internSignature(&[_]TypeId{ number_t, string_or_undefined_t }, string_t, false);
    // `at(index: number): string | undefined` (es2022).
    const sig_at = try ti.internSignature(&[_]TypeId{number_t}, string_or_undefined_t, false);
    // `codePointAt(pos: number): number | undefined` (es2015).
    const sig_code_point_at = try ti.internSignature(&[_]TypeId{number_t}, number_or_undefined_t, false);
    // `normalize(form?: string): string` (es2015).
    const sig_normalize = try ti.internSignature(&[_]TypeId{string_or_undefined_t}, string_t, false);
    // `localeCompare(that: string): number`.
    const sig_locale_compare = try ti.internSignature(&[_]TypeId{string_t}, number_t, false);
    // `lastIndexOf(searchString: string, position?: number): number`.
    const sig_last_index_of = try ti.internSignature(&[_]TypeId{ string_t, number_or_undefined_t }, number_t, false);
    // `substr(from: number, length?: number): string`.
    const sig_substr = try ti.internSignature(&[_]TypeId{ number_t, number_or_undefined_t }, string_t, false);
    // `padStart` etc. plus `valueOf(): string` / `toString(): string`.
    const sig_to_string = sig_void_string;

    const m = [_]types.ObjectMember{
        .{ .name = try sint.intern("length"), .type = number_t, .is_optional = false, .is_readonly = true, .is_method = false },
        .{ .name = try sint.intern("charAt"), .type = sig_num_string, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("charCodeAt"), .type = sig_num_num, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("toUpperCase"), .type = sig_void_string, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("toLowerCase"), .type = sig_void_string, .is_optional = false, .is_readonly = false, .is_method = true },
        // Locale-aware case variants — tsc declares them as
        // `toLocaleUpperCase(locales?: ...): string` /
        // `toLocaleLowerCase(locales?: ...): string`; we model the
        // parameterless form which still satisfies the 0-arg call
        // sites that show up in conformance fixtures. Without these,
        // `s.toLocaleLowerCase()` on a `string` value wrongly trips
        // TS2339. Pins `spreadObjectOrFalsy.ts:44`.
        .{ .name = try sint.intern("toLocaleUpperCase"), .type = sig_void_string, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("toLocaleLowerCase"), .type = sig_void_string, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("startsWith"), .type = sig_str_pos_bool, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("endsWith"), .type = sig_str_pos_bool, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("includes"), .type = sig_str_pos_bool, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("split"), .type = sig_split, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("indexOf"), .type = sig_str_num, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("slice"), .type = sig_slice, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("substring"), .type = sig_slice, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("trim"), .type = sig_void_string, .is_optional = false, .is_readonly = false, .is_method = true },
        // `concat` is `(...strs: string[]): string`; modeled as the
        // common single-arg form `(s: string): string` until rest
        // params land in lib types.
        .{ .name = try sint.intern("concat"), .type = sig_str_string, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("repeat"), .type = sig_num_string, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("replace"), .type = sig_replace, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("replaceAll"), .type = sig_replace, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("match"), .type = sig_match, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("matchAll"), .type = sig_match_all, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("search"), .type = sig_search, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("padStart"), .type = sig_pad, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("padEnd"), .type = sig_pad, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("trimStart"), .type = sig_void_string, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("trimEnd"), .type = sig_void_string, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("at"), .type = sig_at, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("codePointAt"), .type = sig_code_point_at, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("normalize"), .type = sig_normalize, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("localeCompare"), .type = sig_locale_compare, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("lastIndexOf"), .type = sig_last_index_of, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("substr"), .type = sig_substr, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("valueOf"), .type = sig_to_string, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("toString"), .type = sig_to_string, .is_optional = false, .is_readonly = false, .is_method = true },
    };
    // (concat is actually `(...strs: string[]): string`; we model the
    // common single-arg form. Will be replaced once rest params land
    // in lib types.)
    cache.string_proto = try ti.internObjectType(&m);
    return cache.string_proto;
}

/// Build (or fetch from cache) the `Number.prototype` member shape.
pub fn numberProto(
    cache: *LibCache,
    ti: *interner_mod.Interner,
    sint: *string_interner.Interner,
) !TypeId {
    if (cache.number_proto != types.Primitive.none) return cache.number_proto;

    const number_t = types.Primitive.number_t;
    const string_t = types.Primitive.string_t;

    const sig_void_string = try ti.internSignature(&[_]TypeId{}, string_t, false);
    _ = sig_void_string;
    var number_or_undefined_members = [_]TypeId{ number_t, types.Primitive.undefined_t };
    const optional_number_t = try ti.internUnion(&number_or_undefined_members);
    const sig_num_string = try ti.internSignature(&[_]TypeId{optional_number_t}, string_t, false);
    const sig_void_number = try ti.internSignature(&[_]TypeId{}, number_t, false);
    // `toString(radix?: number): string` — optional radix lets
    // `(255).toString(16)` round-trip without TS2554. Upstream lib
    // declares the same shape on `Number.prototype`.
    const sig_to_string = sig_num_string;

    const m = [_]types.ObjectMember{
        .{ .name = try sint.intern("toString"), .type = sig_to_string, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("toFixed"), .type = sig_num_string, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("toExponential"), .type = sig_num_string, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("toPrecision"), .type = sig_num_string, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("valueOf"), .type = sig_void_number, .is_optional = false, .is_readonly = false, .is_method = true },
    };
    cache.number_proto = try ti.internObjectType(&m);
    return cache.number_proto;
}

/// Build (or fetch from cache) the boxed `Symbol` shape — the apparent
/// type of the `symbol` primitive. tsc's `Symbol` interface exposes
/// `toString(): string`, `valueOf(): symbol`, and (es2019) a
/// `description: string | undefined`. `description` is modeled optional
/// so the `symbol`→`Symbol` boxing check — which only requires the
/// universal `toString`/`valueOf` — succeeds, matching tsc (`symbol` is
/// assignable to `Symbol`, but `Symbol` is not assignable to `symbol`).
pub fn symbolProto(
    cache: *LibCache,
    ti: *interner_mod.Interner,
    sint: *string_interner.Interner,
) !TypeId {
    if (cache.symbol_proto != types.Primitive.none) return cache.symbol_proto;

    const string_t = types.Primitive.string_t;
    const symbol_t = types.Primitive.symbol_t;
    const string_or_undefined_t = try ti.internUnion(&[_]TypeId{ string_t, types.Primitive.undefined_t });
    const sig_void_string = try ti.internSignature(&[_]TypeId{}, string_t, false);
    const sig_void_symbol = try ti.internSignature(&[_]TypeId{}, symbol_t, false);

    const m = [_]types.ObjectMember{
        .{ .name = try sint.intern("toString"), .type = sig_void_string, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("valueOf"), .type = sig_void_symbol, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("description"), .type = string_or_undefined_t, .is_optional = true, .is_readonly = true, .is_method = false },
    };
    cache.symbol_proto = try ti.internObjectType(&m);
    return cache.symbol_proto;
}

/// Build (or fetch from cache) the `Array<T>.prototype` member shape
/// for a given element type. The shape mirrors what `internArrayType`
/// already produces (`length: number`, `[i: number]: T`) plus the
/// common mutation / iteration / search methods.
///
/// Generic callback methods are inferred at the call site: `map<U>` /
/// `flatMap<U>` carry a fresh result type-parameter `U` (bound from the
/// callback's return type), `reduce(cb)` returns `T`, and `reduce<U>`
/// infers `U` from its initial-value argument. `filter` / `slice` /
/// `concat` / `reverse` / `sort` preserve `T[]`; `flat` / `splice` /
/// `entries` stay loose
/// (`any[]`) pending depth-typed / tuple machinery.
pub fn arrayProto(
    cache: *LibCache,
    ti: *interner_mod.Interner,
    sint: *string_interner.Interner,
    gpa: std.mem.Allocator,
    elem: TypeId,
    rest_set: *std.AutoHashMapUnmanaged(TypeId, void),
) !TypeId {
    if (cache.array_proto_by_elem.get(elem)) |cached| return cached;

    const number_t = types.Primitive.number_t;
    const boolean_t = types.Primitive.boolean_t;
    const string_t = types.Primitive.string_t;
    const undef_t = types.Primitive.undefined_t;
    const void_t = types.Primitive.void_t;
    const any_t = types.Primitive.any;
    const unknown_t = types.Primitive.unknown;
    const optional_number_t = try ti.internUnion(&[_]TypeId{ number_t, undef_t });

    // `T[]` itself — used as both receiver and return type for
    // `slice`, `filter`, `concat`, `reverse`, `sort`.
    const arr_t = try ti.internArrayType(sint, elem);
    // `any[]` — return type for `map` / `flatMap` (until generic <U> support).
    const any_arr = try ti.internArrayType(sint, any_t);
    // `T | undefined` — return for `pop`, `find`.
    const t_or_undef = try ti.internUnion(&[_]TypeId{ elem, undef_t });

    // A fresh result type-parameter `U` for the generic callback
    // methods (`map<U>`, `flatMap<U>`, `reduce<U>`). Unconstrained with
    // no default, so call-site inference (inferFromPair on the callback
    // return for map/flatMap, or on `reduce`'s initial-value argument)
    // is what binds it. Built fresh per element type, which is fine
    // because the array-proto shape is cached per element type so `U`
    // never escapes a single arrayProto build.
    const u_tp = try ti.internTypeParameter(try sint.intern("U"), types.Primitive.none, types.Primitive.none);
    // `U[]` — return type for the generic `map` / `flatMap`.
    const u_arr = try ti.internArrayType(sint, u_tp);

    // Callback signatures.
    // `(value: T) => U` — used by map. The callback's return
    // type drives inference of `U`: a string-returning callback makes
    // `arr.map(...)` resolve to `string[]` instead of `any[]`.
    const cb_t_u = try ti.internSignature(&[_]TypeId{elem}, u_tp, false);
    // `(value: T) => U | U[]` — used by flatMap. The callback can
    // return either a single value or an array of values; flatMap
    // flattens the result by one level. Upstream signature is
    // `(value: T) => U | readonly U[]`; we accept the non-readonly
    // form which subsumes most call sites.
    const u_or_u_arr = try ti.internUnion(&[_]TypeId{ u_tp, u_arr });
    const cb_t_u_or_arr = try ti.internSignature(&[_]TypeId{elem}, u_or_u_arr, false);
    // `(x: T) => boolean` — used by every / some.
    const cb_t_bool = try ti.internSignature(&[_]TypeId{elem}, boolean_t, false);
    // `(x: T) => unknown` — used by filter / find, matching lib.d.ts
    // predicate overloads that accept truthy non-boolean returns.
    const cb_t_unknown = try ti.internSignature(&[_]TypeId{elem}, unknown_t, false);
    // `(x: T) => void` — used by forEach.
    const cb_t_void = try ti.internSignature(&[_]TypeId{elem}, void_t, false);
    // `(a: T, b: T) => number` — used by sort.
    const cb_tt_num = try ti.internSignature(&[_]TypeId{ elem, elem }, number_t, false);
    // `(prev: T, cur: T) => T` — no-initial-value reducer callback
    // for reduce / reduceRight. This overload returns the array element
    // type, matching lib.d.ts and the compiler corpus' `genericReduce`.
    const cb_reduce_no_init = try ti.internSignature(&[_]TypeId{ elem, elem }, elem, false);
    // `(prev: U, cur: T) => U` — reducer callback for reduce /
    // reduceRight. lib.d.ts declares 4 params (prev, cur, idx, arr); we
    // model the loose 2-param head — callbacks with more params remain
    // assignable (contravariant), matching how map / filter callbacks
    // are modeled here.
    const cb_reduce = try ti.internSignature(&[_]TypeId{ u_tp, elem }, u_tp, false);

    // Method signatures.
    const sig_push = try ti.internSignature(&[_]TypeId{elem}, number_t, false);
    const sig_pop = try ti.internSignature(&[_]TypeId{}, t_or_undef, false);
    // `map<U>(cb: (value: T) => U): U[]`.
    const sig_map = try ti.internSignature(&[_]TypeId{cb_t_u}, u_arr, false);
    // `flatMap<U>(cb: (value: T) => U | U[]): U[]` — the callback
    // may return either a single value or an array; flatMap flattens
    // one level so the result is always `U[]`. Without the union the
    // common `arr.flatMap(x => [a, b])` shape tripped TS2322.
    const sig_flatMap = try ti.internSignature(&[_]TypeId{cb_t_u_or_arr}, u_arr, false);
    const sig_filter = try ti.internSignature(&[_]TypeId{cb_t_unknown}, arr_t, false);
    const sig_forEach = try ti.internSignature(&[_]TypeId{cb_t_void}, void_t, false);
    const sig_every = try ti.internSignature(&[_]TypeId{cb_t_bool}, boolean_t, false);
    const sig_some = try ti.internSignature(&[_]TypeId{cb_t_bool}, boolean_t, false);
    // `includes(searchElement: T, fromIndex?: number): boolean`. The
    // optional fromIndex was missing; upstream lib.d.ts declares it.
    const sig_includes = try ti.internSignature(&[_]TypeId{ elem, optional_number_t }, boolean_t, false);
    // `indexOf(searchElement: T, fromIndex?: number): number`. Same
    // upstream shape as `lastIndexOf` (which already had fromIndex).
    const sig_indexOf = try ti.internSignature(&[_]TypeId{ elem, optional_number_t }, number_t, false);
    const sig_slice = try ti.internSignature(&[_]TypeId{ optional_number_t, optional_number_t }, arr_t, false);
    // `join(separator?: string): string` — the separator is optional;
    // upstream defaults to `,`. We declared it required, tripping
    // TS2554 on `arr.join()` with no args.
    const optional_string_t = try ti.internUnion(&[_]TypeId{ string_t, undef_t });
    const sig_join = try ti.internSignature(&[_]TypeId{optional_string_t}, string_t, false);
    const sig_find = try ti.internSignature(&[_]TypeId{cb_t_unknown}, t_or_undef, false);
    // `concat(...items: (T | T[])[]): T[]` — accepts both individual
    // values and arrays of values as varargs. Upstream uses
    // `ConcatArray<T>` for array-like sources; `T | T[]` covers the
    // common patterns. The trailing union-arr param is registered in
    // `rest_set` so call sites expand to 0+ `T | T[]` arguments.
    const t_or_arr_t = try ti.internUnion(&[_]TypeId{ elem, arr_t });
    const concat_rest_arr = try ti.internArrayType(sint, t_or_arr_t);
    const sig_concat = try ti.internSignature(&[_]TypeId{concat_rest_arr}, arr_t, false);
    try rest_set.put(gpa, sig_concat, {});
    const sig_reverse = try ti.internSignature(&[_]TypeId{}, arr_t, false);
    // `sort(compareFn?: (a: T, b: T) => number): T[]` — the comparator
    // is optional; upstream defaults to a string-coerce comparator.
    // We declared it required, tripping TS2554 on `arr.sort()`.
    const optional_cb_tt_num = try ti.internUnion(&[_]TypeId{ cb_tt_num, undef_t });
    const sig_sort = try ti.internSignature(&[_]TypeId{optional_cb_tt_num}, arr_t, false);
    const sig_to_array = try ti.internSignature(&[_]TypeId{}, arr_t, false);
    const number_arr = try ti.internArrayType(sint, number_t);
    const sig_keys = try ti.internSignature(&[_]TypeId{}, number_arr, false);
    const sig_entries = try ti.internSignature(&[_]TypeId{}, any_arr, false);
    // `values(): IterableIterator<T>` — modeled as `T[]` because the
    // checker's iterable path already understands array element types.
    const sig_values = try ti.internSignature(&[_]TypeId{}, arr_t, false);
    const sig_iterator = sig_values;

    // `reduce<U>(cb: (acc: U, cur: T) => U, init: U): U` (and
    // reduceRight). U is inferred from the initial-value argument and
    // reinforced by the callback's accumulator/return positions. Keep
    // this first so plain member lookup still exposes the generic
    // signature for explicit `reduce<T>(..., init)` calls; overloaded
    // member-call resolution walks the duplicate member entries below.
    const sig_reduce = try ti.internSignature(&[_]TypeId{ cb_reduce, u_tp }, u_tp, false);
    const sig_reduce_no_init = try ti.internSignature(&[_]TypeId{cb_reduce_no_init}, elem, false);
    // `findIndex(pred): number` / `findLastIndex(pred): number`.
    const sig_find_index = try ti.internSignature(&[_]TypeId{cb_t_unknown}, number_t, false);
    // `findLast(pred): T | undefined` (es2023).
    const sig_find_last = try ti.internSignature(&[_]TypeId{cb_t_unknown}, t_or_undef, false);
    // `lastIndexOf(searchElement: T, fromIndex?: number): number`.
    const sig_last_index_of = try ti.internSignature(&[_]TypeId{ elem, optional_number_t }, number_t, false);
    // `at(index: number): T | undefined` (es2022).
    const sig_at = try ti.internSignature(&[_]TypeId{number_t}, t_or_undef, false);
    // `flat(depth?: number): FlatArray<A, D>[]` — the upstream type is a
    // recursive conditional (`FlatArray`) that decrements the depth via a
    // tuple-index lookup; Home has no conditional/mapped-type machinery to
    // compute it for an arbitrary runtime `depth`. We faithfully model the
    // DEFAULT depth-1 behavior (the dominant `arr.flat()` call), which is a
    // single, precise one-level unwrap: when the element type `T` is itself
    // an array `E[]`, `flat()` returns `E[]`; otherwise the array is already
    // flat and `flat()` returns `T[]` unchanged. Element-array detection
    // reuses the standard array idiom (`objectNumberIndex(elem) != none`).
    // Only a plain (non-union) element array is unwrapped; a union element
    // falls back to `any[]` (no false positive) since one-level flattening
    // of a union-of-arrays needs the distributive conditional we lack.
    // Explicit `depth > 1` arguments still under-flatten relative to this
    // model, but the result is never less precise than the old blanket
    // `any[]`.
    const flat_inner = ti.objectNumberIndex(elem);
    const flat_ret = if (ti.pool.flagsOf(elem).is_union)
        // Union element → loose (distributive flattening unmodeled).
        any_arr
    else if (flat_inner != types.Primitive.none)
        // `elem` is `E[]` → one level of flattening yields `E[]`.
        try ti.internArrayType(sint, flat_inner)
    else
        // `elem` is already flat → `flat()` returns `T[]` unchanged.
        arr_t;
    const sig_flat = try ti.internSignature(&[_]TypeId{optional_number_t}, flat_ret, false);
    // `fill(value: T, start?: number, end?: number): T[]`.
    const sig_fill = try ti.internSignature(&[_]TypeId{ elem, optional_number_t, optional_number_t }, arr_t, false);
    // `copyWithin(target: number, start: number, end?: number): T[]`.
    const sig_copy_within = try ti.internSignature(&[_]TypeId{ number_t, number_t, optional_number_t }, arr_t, false);
    // `shift(): T | undefined`.
    const sig_shift = try ti.internSignature(&[_]TypeId{}, t_or_undef, false);
    // `unshift(...items: T[]): number` — the trailing `T[]` param is
    // registered in `rest_set` so call-site arity expands it to 0+ `T`
    // args (mirrors how `Math.max` is modeled).
    const sig_unshift = try ti.internSignature(&[_]TypeId{arr_t}, number_t, false);
    try rest_set.put(gpa, sig_unshift, {});
    // `splice(start: number, deleteCount?: number, ...items: T[]): T[]`.
    // The trailing `T[]` param is the rest binder — using `arr_t`
    // (T[]) instead of `any_arr` preserves type safety on inserted
    // items so `nums.splice(0, 1, "x")` correctly fires TS2345.
    const sig_splice = try ti.internSignature(&[_]TypeId{ number_t, optional_number_t, arr_t }, arr_t, false);
    try rest_set.put(gpa, sig_splice, {});

    const m = [_]types.ObjectMember{
        .{ .name = try sint.intern("length"), .type = number_t, .is_optional = false, .is_readonly = false, .is_method = false },
        .{ .name = try sint.intern("push"), .type = sig_push, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("pop"), .type = sig_pop, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("map"), .type = sig_map, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("flatMap"), .type = sig_flatMap, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("filter"), .type = sig_filter, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("forEach"), .type = sig_forEach, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("every"), .type = sig_every, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("some"), .type = sig_some, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("includes"), .type = sig_includes, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("indexOf"), .type = sig_indexOf, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("slice"), .type = sig_slice, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("join"), .type = sig_join, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("find"), .type = sig_find, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("concat"), .type = sig_concat, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("reverse"), .type = sig_reverse, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("sort"), .type = sig_sort, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("values"), .type = sig_values, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("keys"), .type = sig_keys, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("entries"), .type = sig_entries, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("Symbol.iterator"), .type = sig_iterator, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("toArray"), .type = sig_to_array, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("reduce"), .type = sig_reduce, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("reduce"), .type = sig_reduce_no_init, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("reduceRight"), .type = sig_reduce, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("reduceRight"), .type = sig_reduce_no_init, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("findIndex"), .type = sig_find_index, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("findLast"), .type = sig_find_last, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("findLastIndex"), .type = sig_find_index, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("lastIndexOf"), .type = sig_last_index_of, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("at"), .type = sig_at, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("flat"), .type = sig_flat, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("fill"), .type = sig_fill, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("copyWithin"), .type = sig_copy_within, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("shift"), .type = sig_shift, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("unshift"), .type = sig_unshift, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("splice"), .type = sig_splice, .is_optional = false, .is_readonly = false, .is_method = true },
    };
    const proto = try ti.internObjectType(&m);
    try cache.array_proto_by_elem.put(gpa, elem, proto);
    return proto;
}

/// Build (or fetch from cache) the `Object` global — the namespace
/// shape carrying `keys / values / entries / assign / create` plus
/// `Object.prototype` for common borrowed-method patterns such as
/// `Object.prototype.hasOwnProperty.call(...)`.
pub fn objectGlobal(
    cache: *LibCache,
    ti: *interner_mod.Interner,
    sint: *string_interner.Interner,
) !TypeId {
    if (cache.object_global != types.Primitive.none) return cache.object_global;

    const string_t = types.Primitive.string_t;
    const any_t = types.Primitive.any;
    const boolean_t = types.Primitive.boolean_t;

    const string_arr = try ti.internArrayType(sint, string_t);
    const any_arr = try ti.internArrayType(sint, any_t);

    // `Object.keys(o: any): string[]`
    const sig_keys = try ti.internSignature(&[_]TypeId{any_t}, string_arr, false);
    // `Object.values(o: any): any[]`
    const sig_values = try ti.internSignature(&[_]TypeId{any_t}, any_arr, false);
    // `Object.entries(o: {}): [string, any][]` — precise tuple-typed
    // result (es2017). The generic overload `entries<T>(o: { [s: string]: T }
    // | ArrayLike<T>): [string, T][]` would bind `T` from a typed
    // argument, but the loose `(o: any)` arg means `T` collapses to
    // `any`, so the faithful concrete result is `[string, any][]`.
    // We build the `[string, any]` tuple structurally (matching the
    // checker's tuple encoding) and wrap it in an array.
    const string_any_tuple = try internTuple(ti, sint, &[_]TypeId{ string_t, any_t });
    const string_any_tuple_arr = try ti.internArrayType(sint, string_any_tuple);
    const sig_entries = try ti.internSignature(&[_]TypeId{any_t}, string_any_tuple_arr, false);
    // `Object.assign(...)` is variadic in lib.d.ts. Model the common
    // overload arities used by conformance while leaving the return
    // loose (`any`) until generic intersection returns are wired here.
    const sig_assign2 = try ti.internSignature(&[_]TypeId{ any_t, any_t }, any_t, false);
    const sig_assign3 = try ti.internSignature(&[_]TypeId{ any_t, any_t, any_t }, any_t, false);
    const sig_assign4 = try ti.internSignature(&[_]TypeId{ any_t, any_t, any_t, any_t }, any_t, false);
    const sig_assign = try ti.internIntersection(&[_]TypeId{ sig_assign2, sig_assign3, sig_assign4 });
    // `Object.defineProperty(o, key, descriptor): any`.
    const sig_define_property = try ti.internSignature(&[_]TypeId{ any_t, any_t, any_t }, any_t, false);
    // `Object.create(o): any`.
    const sig_create = try ti.internSignature(&[_]TypeId{any_t}, any_t, false);
    const sig_has_own_property = try ti.internSignature(&[_]TypeId{any_t}, boolean_t, false);
    const sig_to_string = try ti.internSignature(&[_]TypeId{}, string_t, false);
    // `Object.getOwnPropertyNames(o): string[]`.
    const sig_own_names = try ti.internSignature(&[_]TypeId{any_t}, string_arr, false);
    // `Object.getOwnPropertySymbols(o): symbol[]` — modeled `any[]`.
    const sig_own_symbols = try ti.internSignature(&[_]TypeId{any_t}, any_arr, false);
    // `Object.freeze(o): T` / `seal` / `preventExtensions` — return the
    // argument; modeled `(o: any): any`.
    const sig_identity = try ti.internSignature(&[_]TypeId{any_t}, any_t, false);
    // `Object.isFrozen(o): boolean` / `isSealed` / `isExtensible`.
    const sig_any_bool = try ti.internSignature(&[_]TypeId{any_t}, boolean_t, false);
    // `Object.getOwnPropertyDescriptor(o, key): PropertyDescriptor | undefined`.
    const sig_own_descriptor = try ti.internSignature(&[_]TypeId{ any_t, any_t }, any_t, false);
    // `Object.getPrototypeOf(o): any` / `setPrototypeOf(o, proto): any`.
    const sig_get_proto = try ti.internSignature(&[_]TypeId{any_t}, any_t, false);
    const sig_set_proto = try ti.internSignature(&[_]TypeId{ any_t, any_t }, any_t, false);
    // `Object.fromEntries<T = any>(entries: Iterable<readonly [PropertyKey, T]>):
    // { [k: string]: T }` (es2019). The generic overload would bind `T`
    // from the entry tuples' value position, but the loose `(entries: any)`
    // arg collapses `T` to `any`, so the faithful concrete result is the
    // string-indexed record `{ [k: string]: any }`. Modeled as an object
    // with a `string`-key index signature of `any` (better than plain
    // `any`: `Object.fromEntries(...).foo` resolves through the indexer
    // instead of returning a bare `any` with no shape).
    const from_entries_record = try ti.internObjectTypeWithIndex(&[_]types.ObjectMember{}, any_t, types.Primitive.none);
    const sig_from_entries = try ti.internSignature(&[_]TypeId{any_t}, from_entries_record, false);
    // `Object.defineProperties(o, descriptors): any`.
    const sig_define_properties = try ti.internSignature(&[_]TypeId{ any_t, any_t }, any_t, false);
    // `Object.is(a, b): boolean` (es2015).
    const sig_is = try ti.internSignature(&[_]TypeId{ any_t, any_t }, boolean_t, false);
    // `Object.getOwnPropertyDescriptors(o): any` (es2017).
    const sig_own_descriptors = try ti.internSignature(&[_]TypeId{any_t}, any_t, false);
    // `Object.hasOwn(o, key): boolean` (es2022) — replacement for
    // `Object.prototype.hasOwnProperty.call(o, key)`.
    const sig_has_own = try ti.internSignature(&[_]TypeId{ any_t, any_t }, boolean_t, false);
    // `Object.groupBy(items, callbackFn): Record<string, T[]>` (es2024).
    // Modeled `(any, any) => any` until typed records land.
    const sig_group_by = try ti.internSignature(&[_]TypeId{ any_t, any_t }, any_t, false);
    const prototype_members = [_]types.ObjectMember{
        .{ .name = try sint.intern("hasOwnProperty"), .type = sig_has_own_property, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("toString"), .type = sig_to_string, .is_optional = false, .is_readonly = false, .is_method = true },
    };
    const prototype_t = try ti.internObjectType(&prototype_members);

    const m = [_]types.ObjectMember{
        .{ .name = try sint.intern("prototype"), .type = prototype_t, .is_optional = false, .is_readonly = false, .is_method = false },
        .{ .name = try sint.intern("keys"), .type = sig_keys, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("values"), .type = sig_values, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("entries"), .type = sig_entries, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("assign"), .type = sig_assign, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("create"), .type = sig_create, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("defineProperty"), .type = sig_define_property, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("defineProperties"), .type = sig_define_properties, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("getOwnPropertyNames"), .type = sig_own_names, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("getOwnPropertySymbols"), .type = sig_own_symbols, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("getOwnPropertyDescriptor"), .type = sig_own_descriptor, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("getOwnPropertyDescriptors"), .type = sig_own_descriptors, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("getPrototypeOf"), .type = sig_get_proto, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("setPrototypeOf"), .type = sig_set_proto, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("fromEntries"), .type = sig_from_entries, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("freeze"), .type = sig_identity, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("isFrozen"), .type = sig_any_bool, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("seal"), .type = sig_identity, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("isSealed"), .type = sig_any_bool, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("preventExtensions"), .type = sig_identity, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("isExtensible"), .type = sig_any_bool, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("is"), .type = sig_is, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("hasOwn"), .type = sig_has_own, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("groupBy"), .type = sig_group_by, .is_optional = false, .is_readonly = false, .is_method = true },
    };
    cache.object_global = try ti.internObjectType(&m);
    return cache.object_global;
}

/// Build (or fetch from cache) the `Array` global — currently the
/// static `isArray` predicate used by both expression checking and
/// control-flow narrowing.
pub fn arrayGlobal(
    cache: *LibCache,
    ti: *interner_mod.Interner,
    sint: *string_interner.Interner,
) !TypeId {
    if (cache.array_global != types.Primitive.none) return cache.array_global;

    const any_t = types.Primitive.any;
    const boolean_t = types.Primitive.boolean_t;
    const sig_is_array = try ti.internSignature(&[_]TypeId{any_t}, boolean_t, false);
    const any_arr = try ti.internArrayType(sint, any_t);
    // `Array.from` / `Array.of` — modeled loosely as `(...args: any[]): any[]`.
    // The real lib.d.ts signatures are generic and overloaded; the
    // checker just needs the member to exist so call sites typecheck
    // without spurious TS2339. Inference at the call site falls back
    // to `any[]` which is enough for fixtures that pipe the result
    // back into a generic param (e.g. neverInference.ts: `f2(Array.from([0]), …)`).
    const sig_from = try ti.internSignature(&[_]TypeId{any_t}, any_arr, false);
    const sig_of = try ti.internSignature(&[_]TypeId{any_t}, any_arr, false);
    const m = [_]types.ObjectMember{
        .{ .name = try sint.intern("isArray"), .type = sig_is_array, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("from"), .type = sig_from, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("of"), .type = sig_of, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("prototype"), .type = any_arr, .is_optional = false, .is_readonly = false, .is_method = false },
    };
    cache.array_global = try ti.internObjectType(&m);
    return cache.array_global;
}

/// Build (or fetch from cache) the `Math` global — the namespace
/// shape carrying the common numeric constants and helpers.
///
/// `Math.max` / `Math.min` are variadic (`(...n: number[]): number`).
/// We model them as `(n: number[]): number` and register the resulting
/// signature ids in `rest_set` so call-site arity checking treats the
/// trailing slot as a rest binder (0+ `number` args).
pub fn mathGlobal(
    cache: *LibCache,
    ti: *interner_mod.Interner,
    sint: *string_interner.Interner,
    gpa: std.mem.Allocator,
    rest_set: *std.AutoHashMapUnmanaged(TypeId, void),
) !TypeId {
    if (cache.math_global != types.Primitive.none) return cache.math_global;

    const number_t = types.Primitive.number_t;

    // `number[]` — used as the rest-slot type for `max` / `min`.
    const number_arr = try ti.internArrayType(sint, number_t);

    // `(): number`
    const sig_ret_num = try ti.internSignature(&[_]TypeId{}, number_t, false);
    // `(x: number): number`
    const sig_num_num = try ti.internSignature(&[_]TypeId{number_t}, number_t, false);
    // `(x: number, y: number): number`
    const sig_num2_num = try ti.internSignature(&[_]TypeId{ number_t, number_t }, number_t, false);
    // `(...n: number[]): number` — modeled with a single `number[]`
    // param + a rest-set entry so call-site checking expands it.
    const sig_rest_num = try ti.internSignature(&[_]TypeId{number_arr}, number_t, false);
    try rest_set.put(gpa, sig_rest_num, {});

    const m = [_]types.ObjectMember{
        // Numeric constants (read-only).
        .{ .name = try sint.intern("PI"), .type = number_t, .is_optional = false, .is_readonly = true, .is_method = false },
        .{ .name = try sint.intern("E"), .type = number_t, .is_optional = false, .is_readonly = true, .is_method = false },
        .{ .name = try sint.intern("LN2"), .type = number_t, .is_optional = false, .is_readonly = true, .is_method = false },
        .{ .name = try sint.intern("LN10"), .type = number_t, .is_optional = false, .is_readonly = true, .is_method = false },
        .{ .name = try sint.intern("LOG2E"), .type = number_t, .is_optional = false, .is_readonly = true, .is_method = false },
        .{ .name = try sint.intern("LOG10E"), .type = number_t, .is_optional = false, .is_readonly = true, .is_method = false },
        .{ .name = try sint.intern("SQRT2"), .type = number_t, .is_optional = false, .is_readonly = true, .is_method = false },
        .{ .name = try sint.intern("SQRT1_2"), .type = number_t, .is_optional = false, .is_readonly = true, .is_method = false },
        // Existing methods.
        .{ .name = try sint.intern("abs"), .type = sig_num_num, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("floor"), .type = sig_num_num, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("ceil"), .type = sig_num_num, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("round"), .type = sig_num_num, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("sqrt"), .type = sig_num_num, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("pow"), .type = sig_num2_num, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("max"), .type = sig_rest_num, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("min"), .type = sig_rest_num, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("random"), .type = sig_ret_num, .is_optional = false, .is_readonly = false, .is_method = true },
        // ES2015+ method additions — all `(x: number): number` or
        // `(x: number, y: number): number` shape, except `hypot`
        // which is variadic like `max` / `min`.
        .{ .name = try sint.intern("log"), .type = sig_num_num, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("log2"), .type = sig_num_num, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("log10"), .type = sig_num_num, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("log1p"), .type = sig_num_num, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("exp"), .type = sig_num_num, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("expm1"), .type = sig_num_num, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("sin"), .type = sig_num_num, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("cos"), .type = sig_num_num, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("tan"), .type = sig_num_num, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("asin"), .type = sig_num_num, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("acos"), .type = sig_num_num, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("atan"), .type = sig_num_num, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("atan2"), .type = sig_num2_num, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("sinh"), .type = sig_num_num, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("cosh"), .type = sig_num_num, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("tanh"), .type = sig_num_num, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("asinh"), .type = sig_num_num, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("acosh"), .type = sig_num_num, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("atanh"), .type = sig_num_num, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("sign"), .type = sig_num_num, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("trunc"), .type = sig_num_num, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("cbrt"), .type = sig_num_num, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("fround"), .type = sig_num_num, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("clz32"), .type = sig_num_num, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("imul"), .type = sig_num2_num, .is_optional = false, .is_readonly = false, .is_method = true },
        // `hypot(...values: number[]): number` — variadic like max/min.
        .{ .name = try sint.intern("hypot"), .type = sig_rest_num, .is_optional = false, .is_readonly = false, .is_method = true },
    };
    cache.math_global = try ti.internObjectType(&m);
    return cache.math_global;
}

/// Build (or fetch from cache) the `JSON` global namespace.
/// Models `JSON.parse(text, reviver?)` and `JSON.stringify(value,
/// replacer?, space?)`. Return / argument types are loose (`any` /
/// `string`) — exact JSON-value typing requires recursive type
/// machinery; the modeled shape unblocks the most common call
/// sites that previously fired TS2339.
pub fn jsonGlobal(
    cache: *LibCache,
    ti: *interner_mod.Interner,
    sint: *string_interner.Interner,
) !TypeId {
    if (cache.json_global != types.Primitive.none) return cache.json_global;

    const string_t = types.Primitive.string_t;
    const any_t = types.Primitive.any;
    const number_t = types.Primitive.number_t;
    const undef_t = types.Primitive.undefined_t;

    const optional_any = try ti.internUnion(&[_]TypeId{ any_t, undef_t });
    // The third arg to `JSON.stringify` is `string | number | undefined`.
    const string_or_number = try ti.internUnion(&[_]TypeId{ string_t, number_t });
    const optional_string_or_number = try ti.internUnion(&[_]TypeId{ string_or_number, undef_t });

    // `parse(text: string, reviver?: any): any`
    const sig_parse = try ti.internSignature(&[_]TypeId{ string_t, optional_any }, any_t, false);
    // `stringify(value: any, replacer?: any, space?: string | number): string`
    // Upstream has 4 overloads; the most-used 3-arg shape covers the
    // common cases. `replacer` is unioned with `undefined` so the
    // single-arg form (`JSON.stringify(x)`) still typechecks.
    const sig_stringify = try ti.internSignature(&[_]TypeId{ any_t, optional_any, optional_string_or_number }, string_t, false);

    const m = [_]types.ObjectMember{
        .{ .name = try sint.intern("parse"), .type = sig_parse, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("stringify"), .type = sig_stringify, .is_optional = false, .is_readonly = false, .is_method = true },
    };
    cache.json_global = try ti.internObjectType(&m);
    return cache.json_global;
}

/// Build (or fetch from cache) the `console` global. All four members
/// share the same `(...args: any[]): void` shape — modeled as a
/// single `any[]` param + rest-set entry.
pub fn consoleGlobal(
    cache: *LibCache,
    ti: *interner_mod.Interner,
    sint: *string_interner.Interner,
    gpa: std.mem.Allocator,
    rest_set: *std.AutoHashMapUnmanaged(TypeId, void),
) !TypeId {
    if (cache.console_global != types.Primitive.none) return cache.console_global;

    const any_t = types.Primitive.any;
    const void_t = types.Primitive.void_t;

    // `any[]`
    const any_arr = try ti.internArrayType(sint, any_t);
    // `(...args: any[]): void`
    const sig_log = try ti.internSignature(&[_]TypeId{any_arr}, void_t, false);
    try rest_set.put(gpa, sig_log, {});

    // `(): void` — no-arg helpers used by `console.groupEnd`,
    // `console.time*`, `console.dir` (with no args), `console.clear`.
    const sig_void_void = try ti.internSignature(&[_]TypeId{}, void_t, false);
    // `(label?: string): void` — used by `time` / `timeEnd` /
    // `timeLog` / `count` / `countReset` / `group` / `groupCollapsed`.
    const string_t = types.Primitive.string_t;
    const undef_t = types.Primitive.undefined_t;
    const optional_string = try ti.internUnion(&[_]TypeId{ string_t, undef_t });
    const sig_optional_label = try ti.internSignature(&[_]TypeId{optional_string}, void_t, false);

    const m = [_]types.ObjectMember{
        // Standard logging surface.
        .{ .name = try sint.intern("log"), .type = sig_log, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("error"), .type = sig_log, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("warn"), .type = sig_log, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("info"), .type = sig_log, .is_optional = false, .is_readonly = false, .is_method = true },
        // Debug / trace — same variadic shape.
        .{ .name = try sint.intern("debug"), .type = sig_log, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("trace"), .type = sig_log, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("dir"), .type = sig_log, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("table"), .type = sig_log, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("assert"), .type = sig_log, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("dirxml"), .type = sig_log, .is_optional = false, .is_readonly = false, .is_method = true },
        // Grouping (label?: string).
        .{ .name = try sint.intern("group"), .type = sig_optional_label, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("groupCollapsed"), .type = sig_optional_label, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("groupEnd"), .type = sig_void_void, .is_optional = false, .is_readonly = false, .is_method = true },
        // Timing.
        .{ .name = try sint.intern("time"), .type = sig_optional_label, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("timeEnd"), .type = sig_optional_label, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("timeLog"), .type = sig_log, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("timeStamp"), .type = sig_optional_label, .is_optional = false, .is_readonly = false, .is_method = true },
        // Counting.
        .{ .name = try sint.intern("count"), .type = sig_optional_label, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("countReset"), .type = sig_optional_label, .is_optional = false, .is_readonly = false, .is_method = true },
        // Misc.
        .{ .name = try sint.intern("clear"), .type = sig_void_void, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("profile"), .type = sig_optional_label, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("profileEnd"), .type = sig_optional_label, .is_optional = false, .is_readonly = false, .is_method = true },
    };
    cache.console_global = try ti.internObjectType(&m);
    return cache.console_global;
}

/// Build (or fetch from cache) the `Number` global — common static
/// constants (`MAX_VALUE`, `MIN_VALUE`, `MAX_SAFE_INTEGER`) and
/// predicate helpers (`isInteger`, `isFinite`).
pub fn numberGlobal(
    cache: *LibCache,
    ti: *interner_mod.Interner,
    sint: *string_interner.Interner,
) !TypeId {
    if (cache.number_global != types.Primitive.none) return cache.number_global;

    const number_t = types.Primitive.number_t;
    const boolean_t = types.Primitive.boolean_t;
    const any_t = types.Primitive.any;

    // `(x: any): boolean`
    const sig_any_bool = try ti.internSignature(&[_]TypeId{any_t}, boolean_t, false);
    // `Number(value): number` (call/construct modeled loosely).
    const sig_number_call = try ti.internSignature(&[_]TypeId{any_t}, number_t, false);
    const sig_number_construct = try ti.internSignature(&[_]TypeId{any_t}, number_t, true);

    const string_t = types.Primitive.string_t;
    // `Number.parseInt(s, radix?): number`.
    const undef_t = types.Primitive.undefined_t;
    const opt_num = try ti.internUnion(&[_]TypeId{ number_t, undef_t });
    const sig_parse_int = try ti.internSignature(&[_]TypeId{ string_t, opt_num }, number_t, false);
    // `Number.parseFloat(s): number`.
    const sig_parse_float = try ti.internSignature(&[_]TypeId{string_t}, number_t, false);

    const m = [_]types.ObjectMember{
        .{ .name = try sint.intern("__call"), .type = sig_number_call, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("__construct"), .type = sig_number_construct, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("MAX_VALUE"), .type = number_t, .is_optional = false, .is_readonly = true, .is_method = false },
        .{ .name = try sint.intern("MIN_VALUE"), .type = number_t, .is_optional = false, .is_readonly = true, .is_method = false },
        .{ .name = try sint.intern("MAX_SAFE_INTEGER"), .type = number_t, .is_optional = false, .is_readonly = true, .is_method = false },
        .{ .name = try sint.intern("MIN_SAFE_INTEGER"), .type = number_t, .is_optional = false, .is_readonly = true, .is_method = false },
        .{ .name = try sint.intern("EPSILON"), .type = number_t, .is_optional = false, .is_readonly = true, .is_method = false },
        .{ .name = try sint.intern("POSITIVE_INFINITY"), .type = number_t, .is_optional = false, .is_readonly = true, .is_method = false },
        .{ .name = try sint.intern("NEGATIVE_INFINITY"), .type = number_t, .is_optional = false, .is_readonly = true, .is_method = false },
        .{ .name = try sint.intern("NaN"), .type = number_t, .is_optional = false, .is_readonly = true, .is_method = false },
        .{ .name = try sint.intern("isInteger"), .type = sig_any_bool, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("isFinite"), .type = sig_any_bool, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("isNaN"), .type = sig_any_bool, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("isSafeInteger"), .type = sig_any_bool, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("parseInt"), .type = sig_parse_int, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("parseFloat"), .type = sig_parse_float, .is_optional = false, .is_readonly = false, .is_method = true },
    };
    cache.number_global = try ti.internObjectType(&m);
    return cache.number_global;
}

/// Build (or fetch from cache) the `String` global — the constructor
/// side of the primitive carrying `fromCharCode` / `fromCodePoint` /
/// `raw`. Modeled with loose `any`-typed args because the real
/// signatures are variadic and overloaded; the goal is to make
/// `String.fromCharCode(...)` typecheck without spurious TS2339.
pub fn stringGlobal(
    cache: *LibCache,
    ti: *interner_mod.Interner,
    sint: *string_interner.Interner,
    gpa: std.mem.Allocator,
    rest_set: *std.AutoHashMapUnmanaged(TypeId, void),
) !TypeId {
    if (cache.string_global != types.Primitive.none) return cache.string_global;

    const string_t = types.Primitive.string_t;
    const number_t = types.Primitive.number_t;
    const any_t = types.Primitive.any;

    // `String(value): string` / `new String(value): String` modeled
    // loosely so call/construct sites typecheck. The construct return
    // intentionally points at the primitive (no `String` wrapper type
    // distinction in the checker today).
    const sig_call = try ti.internSignature(&[_]TypeId{any_t}, string_t, false);
    const sig_construct = try ti.internSignature(&[_]TypeId{any_t}, string_t, true);
    // `String.fromCharCode(...codes: number[]): string` (variadic).
    const num_arr = try ti.internArrayType(sint, number_t);
    const sig_from_char_code = try ti.internSignature(&[_]TypeId{num_arr}, string_t, false);
    try rest_set.put(gpa, sig_from_char_code, {});
    // `String.fromCodePoint(...codes: number[]): string` (ES2015).
    const sig_from_code_point = try ti.internSignature(&[_]TypeId{num_arr}, string_t, false);
    try rest_set.put(gpa, sig_from_code_point, {});
    // `String.raw(template, ...substitutions: any[]): string` (ES2015).
    const any_arr = try ti.internArrayType(sint, any_t);
    const sig_raw = try ti.internSignature(&[_]TypeId{ any_t, any_arr }, string_t, false);
    try rest_set.put(gpa, sig_raw, {});

    const m = [_]types.ObjectMember{
        .{ .name = try sint.intern("__call"), .type = sig_call, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("__construct"), .type = sig_construct, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("fromCharCode"), .type = sig_from_char_code, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("fromCodePoint"), .type = sig_from_code_point, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("raw"), .type = sig_raw, .is_optional = false, .is_readonly = false, .is_method = true },
    };
    cache.string_global = try ti.internObjectType(&m);
    return cache.string_global;
}

/// Build (or fetch from cache) the `Boolean` global — call/construct
/// coercion. Conformance fixtures probe `Boolean(value)` which trips
/// TS2348 without an explicit `__call` slot.
pub fn booleanGlobal(
    cache: *LibCache,
    ti: *interner_mod.Interner,
    sint: *string_interner.Interner,
) !TypeId {
    if (cache.boolean_global != types.Primitive.none) return cache.boolean_global;

    const boolean_t = types.Primitive.boolean_t;
    const any_t = types.Primitive.any;
    const sig_call = try ti.internSignature(&[_]TypeId{any_t}, boolean_t, false);
    const sig_construct = try ti.internSignature(&[_]TypeId{any_t}, boolean_t, true);
    const m = [_]types.ObjectMember{
        .{ .name = try sint.intern("__call"), .type = sig_call, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("__construct"), .type = sig_construct, .is_optional = false, .is_readonly = false, .is_method = true },
    };
    cache.boolean_global = try ti.internObjectType(&m);
    return cache.boolean_global;
}

/// Build (or fetch from cache) the `BigInt` global — call coercion
/// plus the `asIntN(bits, value)` / `asUintN(bits, value)` static
/// helpers. Modeled with loose `any`-typed args since the checker
/// doesn't yet distinguish a `bigint` literal type.
pub fn bigintGlobal(
    cache: *LibCache,
    ti: *interner_mod.Interner,
    sint: *string_interner.Interner,
) !TypeId {
    if (cache.bigint_global != types.Primitive.none) return cache.bigint_global;

    const bigint_t = types.Primitive.bigint_t;
    const any_t = types.Primitive.any;
    const sig_call = try ti.internSignature(&[_]TypeId{any_t}, bigint_t, false);
    const sig_as_n = try ti.internSignature(&[_]TypeId{ any_t, any_t }, bigint_t, false);
    const m = [_]types.ObjectMember{
        .{ .name = try sint.intern("__call"), .type = sig_call, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("asIntN"), .type = sig_as_n, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("asUintN"), .type = sig_as_n, .is_optional = false, .is_readonly = false, .is_method = true },
    };
    cache.bigint_global = try ti.internObjectType(&m);
    return cache.bigint_global;
}

// =============================================================================
// Tests
// =============================================================================

const T = std.testing;

test "lib: stringProto exposes length/charAt/toUpperCase" {
    var sint = try string_interner.Interner.init(T.allocator);
    defer sint.deinit();
    var ti = try interner_mod.Interner.init(T.allocator);
    defer ti.deinit();
    var cache: LibCache = .{};
    defer cache.deinit(T.allocator);

    var rest_set: std.AutoHashMapUnmanaged(TypeId, void) = .empty;
    defer rest_set.deinit(T.allocator);
    const proto = try stringProto(&cache, &ti, &sint, T.allocator, &rest_set);
    const length_id = try sint.intern("length");
    const charAt_id = try sint.intern("charAt");
    const upper_id = try sint.intern("toUpperCase");
    try T.expect(ti.objectMember(proto, length_id) != null);
    try T.expect(ti.objectMember(proto, charAt_id) != null);
    try T.expect(ti.objectMember(proto, upper_id) != null);
    try T.expectEqual(types.Primitive.number_t, ti.objectMember(proto, length_id).?);
}

test "lib: stringProto exposes replace/padStart/at/matchAll and friends" {
    var sint = try string_interner.Interner.init(T.allocator);
    defer sint.deinit();
    var ti = try interner_mod.Interner.init(T.allocator);
    defer ti.deinit();
    var cache: LibCache = .{};
    defer cache.deinit(T.allocator);

    var rest_set: std.AutoHashMapUnmanaged(TypeId, void) = .empty;
    defer rest_set.deinit(T.allocator);
    const proto = try stringProto(&cache, &ti, &sint, T.allocator, &rest_set);
    for ([_][]const u8{
        "replace",     "replaceAll", "match",         "matchAll",    "search",
        "padStart",    "padEnd",     "trimStart",     "trimEnd",     "at",
        "codePointAt", "normalize",  "localeCompare", "lastIndexOf", "substr",
        "valueOf",     "toString",
    }) |name| {
        try T.expect(ti.objectMember(proto, try sint.intern(name)) != null);
    }
    // `replace` returns `string`.
    try T.expectEqual(types.Primitive.string_t, ti.signatureReturn(ti.objectMember(proto, try sint.intern("replace")).?).?);
    // `search` returns `number`.
    try T.expectEqual(types.Primitive.number_t, ti.signatureReturn(ti.objectMember(proto, try sint.intern("search")).?).?);
    // `match` returns the precise `RegExpMatchArray` (not bare `any`):
    // it exposes `index?`, `input?`, `0` and a string number-index (it
    // `extends Array<string>`). The `| null` is deferred pending the
    // call-result narrowing fix (see the signature comment).
    const match_ret = ti.signatureReturn(ti.objectMember(proto, try sint.intern("match")).?).?;
    try T.expect(match_ret != types.Primitive.any);
    const rma = match_ret;
    try T.expectEqual(types.Primitive.string_t, ti.objectNumberIndex(rma));
    try T.expectEqual(types.Primitive.number_t, ti.objectMember(rma, try sint.intern("index")).?);
    try T.expectEqual(types.Primitive.string_t, ti.objectMember(rma, try sint.intern("0")).?);
    // A genuinely-missing member still resolves to null.
    try T.expect(ti.objectMember(proto, try sint.intern("notARealStringMethod")) == null);
}

test "lib: numberProto exposes formatting methods" {
    var sint = try string_interner.Interner.init(T.allocator);
    defer sint.deinit();
    var ti = try interner_mod.Interner.init(T.allocator);
    defer ti.deinit();
    var cache: LibCache = .{};
    defer cache.deinit(T.allocator);

    const proto = try numberProto(&cache, &ti, &sint);
    const fixed_id = try sint.intern("toFixed");
    const precision_id = try sint.intern("toPrecision");
    const value_of_id = try sint.intern("valueOf");
    try T.expect(ti.objectMember(proto, fixed_id) != null);
    try T.expect(ti.objectMember(proto, precision_id) != null);
    try T.expect(ti.objectMember(proto, value_of_id) != null);
    try T.expectEqual(types.Primitive.number_t, ti.signatureReturn(ti.objectMember(proto, value_of_id).?).?);
}

test "lib: arrayProto exposes length/push/map/flatMap" {
    var sint = try string_interner.Interner.init(T.allocator);
    defer sint.deinit();
    var ti = try interner_mod.Interner.init(T.allocator);
    defer ti.deinit();
    var cache: LibCache = .{};
    defer cache.deinit(T.allocator);
    var rest_set: std.AutoHashMapUnmanaged(TypeId, void) = .empty;
    defer rest_set.deinit(T.allocator);

    const proto = try arrayProto(&cache, &ti, &sint, T.allocator, types.Primitive.number_t, &rest_set);
    const length_id = try sint.intern("length");
    const push_id = try sint.intern("push");
    const map_id = try sint.intern("map");
    const flat_map_id = try sint.intern("flatMap");
    try T.expect(ti.objectMember(proto, length_id) != null);
    try T.expect(ti.objectMember(proto, push_id) != null);
    try T.expect(ti.objectMember(proto, map_id) != null);
    try T.expect(ti.objectMember(proto, flat_map_id) != null);
}

test "lib: arrayProto map/flatMap/reduce signatures are generic over U" {
    var sint = try string_interner.Interner.init(T.allocator);
    defer sint.deinit();
    var ti = try interner_mod.Interner.init(T.allocator);
    defer ti.deinit();
    var cache: LibCache = .{};
    defer cache.deinit(T.allocator);
    var rest_set: std.AutoHashMapUnmanaged(TypeId, void) = .empty;
    defer rest_set.deinit(T.allocator);

    const proto = try arrayProto(&cache, &ti, &sint, T.allocator, types.Primitive.number_t, &rest_set);

    // `map<U>`: callback param is `(value: number) => U` and the return
    // is `U[]`, where `U` is a (free) type parameter. The element type
    // of the returned array must itself be a type parameter so call-site
    // inference can bind it from the callback's return type.
    const map_sig = ti.objectMember(proto, try sint.intern("map")).?;
    const map_ret = ti.signatureReturn(map_sig).?;
    const map_ret_elem = ti.objectNumberIndex(map_ret);
    try T.expect(map_ret_elem != types.Primitive.none);
    try T.expect(ti.pool.flagsOf(map_ret_elem).is_type_parameter);
    // The callback parameter's return type is the same free `U`.
    const map_params = ti.signatureParams(map_sig);
    try T.expectEqual(@as(usize, 1), map_params.len);
    const map_cb_ret = ti.signatureReturn(map_params[0]).?;
    try T.expectEqual(map_ret_elem, map_cb_ret);

    // `flatMap<U>` mirrors `map<U>`.
    const fm_sig = ti.objectMember(proto, try sint.intern("flatMap")).?;
    const fm_ret = ti.signatureReturn(fm_sig).?;
    try T.expect(ti.pool.flagsOf(ti.objectNumberIndex(fm_ret)).is_type_parameter);

    // `reduce<U>(cb, init: U): U`: the first reduce member stays the
    // generic initial-value overload so explicit `reduce<T>(..., init)`
    // calls keep the existing member-lookup path.
    const red_sig = ti.objectMember(proto, try sint.intern("reduce")).?;
    const red_ret = ti.signatureReturn(red_sig).?;
    try T.expect(ti.pool.flagsOf(red_ret).is_type_parameter);
    const red_params = ti.signatureParams(red_sig);
    try T.expectEqual(@as(usize, 2), red_params.len);
    try T.expectEqual(red_ret, red_params[1]);
    // The reducer callback returns the same `U`.
    try T.expectEqual(red_ret, ti.signatureReturn(red_params[0]).?);

    // The duplicate named overload covers `reduce(cb): T`.
    var reduce_count: usize = 0;
    var saw_no_init = false;
    for (ti.objectMembers(proto)) |member| {
        if (member.name != try sint.intern("reduce")) continue;
        reduce_count += 1;
        const params = ti.signatureParams(member.type);
        if (params.len == 1 and ti.signatureReturn(member.type).? == types.Primitive.number_t) {
            saw_no_init = true;
        }
    }
    try T.expectEqual(@as(usize, 2), reduce_count);
    try T.expect(saw_no_init);
}

test "lib: arrayProto exposes iterator helper toArray" {
    var sint = try string_interner.Interner.init(T.allocator);
    defer sint.deinit();
    var ti = try interner_mod.Interner.init(T.allocator);
    defer ti.deinit();
    var cache: LibCache = .{};
    defer cache.deinit(T.allocator);
    var rest_set: std.AutoHashMapUnmanaged(TypeId, void) = .empty;
    defer rest_set.deinit(T.allocator);

    const proto = try arrayProto(&cache, &ti, &sint, T.allocator, types.Primitive.number_t, &rest_set);
    const to_array_id = try sint.intern("toArray");
    try T.expect(ti.objectMember(proto, to_array_id) != null);
}

test "lib: arrayProto exposes reduce/flat/findLast/at and rest methods" {
    var sint = try string_interner.Interner.init(T.allocator);
    defer sint.deinit();
    var ti = try interner_mod.Interner.init(T.allocator);
    defer ti.deinit();
    var cache: LibCache = .{};
    defer cache.deinit(T.allocator);
    var rest_set: std.AutoHashMapUnmanaged(TypeId, void) = .empty;
    defer rest_set.deinit(T.allocator);

    const proto = try arrayProto(&cache, &ti, &sint, T.allocator, types.Primitive.number_t, &rest_set);
    // es5/es2015/es2019/es2022/es2023 members that previously tripped TS2339.
    for ([_][]const u8{
        "reduce",      "reduceRight", "findIndex", "findLast", "findLastIndex",
        "lastIndexOf", "at",          "flat",      "fill",     "copyWithin",
        "shift",       "unshift",     "splice",
    }) |name| {
        try T.expect(ti.objectMember(proto, try sint.intern(name)) != null);
    }
    // `at` returns `T | undefined`.
    const at_sig = ti.objectMember(proto, try sint.intern("at")).?;
    const at_ret = ti.signatureReturn(at_sig).?;
    try T.expect(at_ret >= ti.pool.typeCount() or ti.pool.flagsOf(at_ret).is_union);
    // Variadic `unshift` / `splice` must be registered in the rest set so
    // call-site arity expands the trailing `T[]` into 0+ args.
    try T.expect(rest_set.contains(ti.objectMember(proto, try sint.intern("unshift")).?));
    try T.expect(rest_set.contains(ti.objectMember(proto, try sint.intern("splice")).?));
    // A genuinely-missing member still resolves to null (no false member).
    try T.expect(ti.objectMember(proto, try sint.intern("definitelyNotAMethod")) == null);
}

test "lib: arrayProto flat() unwraps one level for nested element arrays" {
    var sint = try string_interner.Interner.init(T.allocator);
    defer sint.deinit();
    var ti = try interner_mod.Interner.init(T.allocator);
    defer ti.deinit();
    var cache: LibCache = .{};
    defer cache.deinit(T.allocator);
    var rest_set: std.AutoHashMapUnmanaged(TypeId, void) = .empty;
    defer rest_set.deinit(T.allocator);

    // `number[][]` → element type is `number[]`; `flat()` yields `number[]`
    // (one level unwrapped), so the flat return's number-index is `number`.
    const number_arr = try ti.internArrayType(&sint, types.Primitive.number_t);
    const nested = try arrayProto(&cache, &ti, &sint, T.allocator, number_arr, &rest_set);
    const flat_ret_nested = ti.signatureReturn(ti.objectMember(nested, try sint.intern("flat")).?).?;
    try T.expect(flat_ret_nested != types.Primitive.none);
    try T.expectEqual(types.Primitive.number_t, ti.objectNumberIndex(flat_ret_nested));

    // `string[]` (already flat) → `flat()` returns `string[]` unchanged,
    // NOT `any[]`; the flat return's number-index is `string`.
    const flat_proto = try arrayProto(&cache, &ti, &sint, T.allocator, types.Primitive.string_t, &rest_set);
    const flat_ret_flat = ti.signatureReturn(ti.objectMember(flat_proto, try sint.intern("flat")).?).?;
    try T.expectEqual(types.Primitive.string_t, ti.objectNumberIndex(flat_ret_flat));
}

test "lib: objectGlobal exposes keys/values/entries/assign" {
    var sint = try string_interner.Interner.init(T.allocator);
    defer sint.deinit();
    var ti = try interner_mod.Interner.init(T.allocator);
    defer ti.deinit();
    var cache: LibCache = .{};
    defer cache.deinit(T.allocator);

    const og = try objectGlobal(&cache, &ti, &sint);
    try T.expect(ti.objectMember(og, try sint.intern("keys")) != null);
    try T.expect(ti.objectMember(og, try sint.intern("values")) != null);
    try T.expect(ti.objectMember(og, try sint.intern("entries")) != null);
    try T.expect(ti.objectMember(og, try sint.intern("assign")) != null);
}

test "lib: objectGlobal exposes freeze/getOwnPropertyNames/fromEntries/is" {
    var sint = try string_interner.Interner.init(T.allocator);
    defer sint.deinit();
    var ti = try interner_mod.Interner.init(T.allocator);
    defer ti.deinit();
    var cache: LibCache = .{};
    defer cache.deinit(T.allocator);

    const og = try objectGlobal(&cache, &ti, &sint);
    for ([_][]const u8{
        "freeze",                    "isFrozen",              "seal",
        "isSealed",                  "preventExtensions",     "isExtensible",
        "getOwnPropertyNames",       "getOwnPropertySymbols", "getOwnPropertyDescriptor",
        "getOwnPropertyDescriptors", "getPrototypeOf",        "setPrototypeOf",
        "fromEntries",               "defineProperties",      "is",
    }) |name| {
        try T.expect(ti.objectMember(og, try sint.intern(name)) != null);
    }
    // `getOwnPropertyNames` returns `string[]`.
    const names_sig = ti.objectMember(og, try sint.intern("getOwnPropertyNames")).?;
    const names_ret = ti.signatureReturn(names_sig).?;
    try T.expectEqual(types.Primitive.string_t, ti.objectNumberIndex(names_ret));
    // A genuinely-missing static still resolves to null.
    try T.expect(ti.objectMember(og, try sint.intern("notARealObjectStatic")) == null);
}

test "lib: Object.entries returns [string, any][] (tuple-typed elements)" {
    var sint = try string_interner.Interner.init(T.allocator);
    defer sint.deinit();
    var ti = try interner_mod.Interner.init(T.allocator);
    defer ti.deinit();
    var cache: LibCache = .{};
    defer cache.deinit(T.allocator);

    const og = try objectGlobal(&cache, &ti, &sint);
    const entries_sig = ti.objectMember(og, try sint.intern("entries")).?;
    const ret = ti.signatureReturn(entries_sig).?;
    // Return is an array — its number-index value is the tuple element.
    const tuple_t = ti.objectNumberIndex(ret);
    try T.expect(tuple_t != types.Primitive.none);
    try T.expect(tuple_t != types.Primitive.any);
    // The tuple's element 0 is `string`, element 1 is `any`, and it has
    // a literal `length` of 2 — i.e. the precise `[string, any]` shape.
    try T.expectEqual(types.Primitive.string_t, ti.objectMember(tuple_t, try sint.intern("0")).?);
    try T.expectEqual(types.Primitive.any, ti.objectMember(tuple_t, try sint.intern("1")).?);
    const length_t = ti.objectMember(tuple_t, try sint.intern("length")).?;
    try T.expect(length_t != types.Primitive.number_t); // a 2-literal, not plain number
}

test "lib: internTuple builds [string, number] with numeric members + length literal" {
    var sint = try string_interner.Interner.init(T.allocator);
    defer sint.deinit();
    var ti = try interner_mod.Interner.init(T.allocator);
    defer ti.deinit();

    const tup = try internTuple(&ti, &sint, &[_]TypeId{ types.Primitive.string_t, types.Primitive.number_t });
    try T.expectEqual(types.Primitive.string_t, ti.objectMember(tup, try sint.intern("0")).?);
    try T.expectEqual(types.Primitive.number_t, ti.objectMember(tup, try sint.intern("1")).?);
    // No phantom element 2.
    try T.expect(ti.objectMember(tup, try sint.intern("2")) == null);
    // `length` present (literal 2) and the number index is `string | number`.
    try T.expect(ti.objectMember(tup, try sint.intern("length")) != null);
    const idx = ti.objectNumberIndex(tup);
    try T.expect(idx != types.Primitive.none);
}

test "lib: Object.fromEntries returns a string-indexed record { [k: string]: any }" {
    var sint = try string_interner.Interner.init(T.allocator);
    defer sint.deinit();
    var ti = try interner_mod.Interner.init(T.allocator);
    defer ti.deinit();
    var cache: LibCache = .{};
    defer cache.deinit(T.allocator);

    const og = try objectGlobal(&cache, &ti, &sint);
    const fe_sig = ti.objectMember(og, try sint.intern("fromEntries")).?;
    const ret = ti.signatureReturn(fe_sig).?;
    // The result carries a `string`-key index signature of `any`, not a
    // bare `any` — arbitrary property access resolves through the indexer.
    try T.expectEqual(types.Primitive.any, ti.objectStringIndex(ret));
    try T.expect(ret != types.Primitive.any);
}

test "lib: objectGlobal exposes prototype helpers" {
    var sint = try string_interner.Interner.init(T.allocator);
    defer sint.deinit();
    var ti = try interner_mod.Interner.init(T.allocator);
    defer ti.deinit();
    var cache: LibCache = .{};
    defer cache.deinit(T.allocator);

    const og = try objectGlobal(&cache, &ti, &sint);
    const proto = ti.objectMember(og, try sint.intern("prototype")).?;
    try T.expect(ti.objectMember(proto, try sint.intern("hasOwnProperty")) != null);
    try T.expect(ti.objectMember(proto, try sint.intern("toString")) != null);
}

test "lib: arrayGlobal exposes isArray" {
    var sint = try string_interner.Interner.init(T.allocator);
    defer sint.deinit();
    var ti = try interner_mod.Interner.init(T.allocator);
    defer ti.deinit();
    var cache: LibCache = .{};
    defer cache.deinit(T.allocator);

    const ag = try arrayGlobal(&cache, &ti, &sint);
    try T.expect(ti.objectMember(ag, try sint.intern("isArray")) != null);
    try T.expect(ti.objectMember(ag, try sint.intern("prototype")) != null);
    // `Array.from` / `Array.of` — needed by fixtures that funnel the
    // result back through a generic param (see neverInference.ts).
    try T.expect(ti.objectMember(ag, try sint.intern("from")) != null);
    try T.expect(ti.objectMember(ag, try sint.intern("of")) != null);
}

test "lib: mathGlobal exposes PI/floor/max" {
    var sint = try string_interner.Interner.init(T.allocator);
    defer sint.deinit();
    var ti = try interner_mod.Interner.init(T.allocator);
    defer ti.deinit();
    var cache: LibCache = .{};
    defer cache.deinit(T.allocator);
    var rest_set: std.AutoHashMapUnmanaged(TypeId, void) = .empty;
    defer rest_set.deinit(T.allocator);

    const mg = try mathGlobal(&cache, &ti, &sint, T.allocator, &rest_set);
    try T.expectEqual(types.Primitive.number_t, ti.objectMember(mg, try sint.intern("PI")).?);
    try T.expect(ti.objectMember(mg, try sint.intern("floor")) != null);
    try T.expect(ti.objectMember(mg, try sint.intern("max")) != null);
    // `Math.max` is variadic — its signature must be in the rest set.
    const max_sig = ti.objectMember(mg, try sint.intern("max")).?;
    try T.expect(rest_set.contains(max_sig));
}

test "lib: consoleGlobal exposes log/error/warn/info" {
    var sint = try string_interner.Interner.init(T.allocator);
    defer sint.deinit();
    var ti = try interner_mod.Interner.init(T.allocator);
    defer ti.deinit();
    var cache: LibCache = .{};
    defer cache.deinit(T.allocator);
    var rest_set: std.AutoHashMapUnmanaged(TypeId, void) = .empty;
    defer rest_set.deinit(T.allocator);

    const cg = try consoleGlobal(&cache, &ti, &sint, T.allocator, &rest_set);
    try T.expect(ti.objectMember(cg, try sint.intern("log")) != null);
    try T.expect(ti.objectMember(cg, try sint.intern("error")) != null);
    try T.expect(ti.objectMember(cg, try sint.intern("warn")) != null);
    try T.expect(ti.objectMember(cg, try sint.intern("info")) != null);
    // `console.log` is `(...args: any[]): void`.
    const log_sig = ti.objectMember(cg, try sint.intern("log")).?;
    try T.expectEqual(types.Primitive.void_t, ti.signatureReturn(log_sig).?);
    try T.expect(rest_set.contains(log_sig));
}

test "lib: numberGlobal exposes MAX_VALUE/isInteger" {
    var sint = try string_interner.Interner.init(T.allocator);
    defer sint.deinit();
    var ti = try interner_mod.Interner.init(T.allocator);
    defer ti.deinit();
    var cache: LibCache = .{};
    defer cache.deinit(T.allocator);

    const ng = try numberGlobal(&cache, &ti, &sint);
    try T.expect(ti.objectMember(ng, try sint.intern("__call")) != null);
    try T.expect(ti.objectMember(ng, try sint.intern("__construct")) != null);
    try T.expectEqual(types.Primitive.number_t, ti.objectMember(ng, try sint.intern("MAX_VALUE")).?);
    try T.expectEqual(types.Primitive.number_t, ti.objectMember(ng, try sint.intern("MAX_SAFE_INTEGER")).?);
    try T.expect(ti.objectMember(ng, try sint.intern("isInteger")) != null);
    try T.expect(ti.objectMember(ng, try sint.intern("isFinite")) != null);
}
