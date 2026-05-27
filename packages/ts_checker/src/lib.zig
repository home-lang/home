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
    // `(sep: string): string[]`
    const sig_split = try ti.internSignature(&[_]TypeId{string_t}, string_arr, false);
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

    const any_t = types.Primitive.any;
    const undef_t = types.Primitive.undefined_t;
    const string_or_undefined_t = try ti.internUnion(&[_]TypeId{ string_t, undef_t });
    const number_or_undefined_t = optional_number_t;

    // `replace(pattern: string | RegExp, replacement): string`. The
    // pattern accepts both `string` and `RegExp`; modeled as `any` so
    // `s.replace(/re/, "x")` and `s.replace("a", "b")` both resolve.
    // Replacement may be a string or a replacer function — modeled `any`.
    const sig_replace = try ti.internSignature(&[_]TypeId{ any_t, any_t }, string_t, false);
    // `match(pattern): RegExpMatchArray | null` / `matchAll(...)` —
    // modeled loosely as returning `any` (the precise match-array type
    // isn't wired). `search(pattern): number`.
    const sig_match = try ti.internSignature(&[_]TypeId{any_t}, any_t, false);
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
        .{ .name = try sint.intern("matchAll"), .type = sig_match, .is_optional = false, .is_readonly = false, .is_method = true },
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

/// Build (or fetch from cache) the `Array<T>.prototype` member shape
/// for a given element type. The shape mirrors what `internArrayType`
/// already produces (`length: number`, `[i: number]: T`) plus the
/// common mutation / iteration / search methods.
///
/// Generic callback methods are inferred at the call site: `map<U>` /
/// `flatMap<U>` carry a fresh result type-parameter `U` (bound from the
/// callback's return type), and `reduce<U>` infers `U` from its
/// initial-value argument. `filter` / `slice` / `concat` / `reverse` /
/// `sort` preserve `T[]`; `flat` / `splice` / `entries` stay loose
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
    // `(prev: any, cur: T) => any` — reducer callback for reduce /
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
    // reduceRight). Single generic signature: U is inferred from the
    // initial-value argument and reinforced by the callback's
    // accumulator/return positions. The no-initial-value overload that
    // returns T (and throws on an empty array) is intentionally not
    // modeled; the two-arg form is the common, precisely-inferable one.
    const sig_reduce = try ti.internSignature(&[_]TypeId{ cb_reduce, u_tp }, u_tp, false);
    // `findIndex(pred): number` / `findLastIndex(pred): number`.
    const sig_find_index = try ti.internSignature(&[_]TypeId{cb_t_unknown}, number_t, false);
    // `findLast(pred): T | undefined` (es2023).
    const sig_find_last = try ti.internSignature(&[_]TypeId{cb_t_unknown}, t_or_undef, false);
    // `lastIndexOf(searchElement: T, fromIndex?: number): number`.
    const sig_last_index_of = try ti.internSignature(&[_]TypeId{ elem, optional_number_t }, number_t, false);
    // `at(index: number): T | undefined` (es2022).
    const sig_at = try ti.internSignature(&[_]TypeId{number_t}, t_or_undef, false);
    // `flat(depth?: number): any[]` — exact depth-driven element type
    // needs recursive type machinery; `any[]` avoids the false positive.
    const sig_flat = try ti.internSignature(&[_]TypeId{optional_number_t}, any_arr, false);
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
        .{ .name = try sint.intern("reduceRight"), .type = sig_reduce, .is_optional = false, .is_readonly = false, .is_method = true },
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
    // `Object.entries(o: any): [string, any][]` — modeled loosely as
    // `any[]` (tuple-typed entries land later).
    const sig_entries = try ti.internSignature(&[_]TypeId{any_t}, any_arr, false);
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
    // `Object.fromEntries(entries): any` (es2019).
    const sig_from_entries = try ti.internSignature(&[_]TypeId{any_t}, any_t, false);
    // `Object.defineProperties(o, descriptors): any`.
    const sig_define_properties = try ti.internSignature(&[_]TypeId{ any_t, any_t }, any_t, false);
    // `Object.is(a, b): boolean` (es2015).
    const sig_is = try ti.internSignature(&[_]TypeId{ any_t, any_t }, boolean_t, false);
    // `Object.getOwnPropertyDescriptors(o): any` (es2017).
    const sig_own_descriptors = try ti.internSignature(&[_]TypeId{any_t}, any_t, false);
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

    const m = [_]types.ObjectMember{
        .{ .name = try sint.intern("log"), .type = sig_log, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("error"), .type = sig_log, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("warn"), .type = sig_log, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("info"), .type = sig_log, .is_optional = false, .is_readonly = false, .is_method = true },
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

    const m = [_]types.ObjectMember{
        .{ .name = try sint.intern("__call"), .type = sig_number_call, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("__construct"), .type = sig_number_construct, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("MAX_VALUE"), .type = number_t, .is_optional = false, .is_readonly = true, .is_method = false },
        .{ .name = try sint.intern("MIN_VALUE"), .type = number_t, .is_optional = false, .is_readonly = true, .is_method = false },
        .{ .name = try sint.intern("MAX_SAFE_INTEGER"), .type = number_t, .is_optional = false, .is_readonly = true, .is_method = false },
        .{ .name = try sint.intern("isInteger"), .type = sig_any_bool, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("isFinite"), .type = sig_any_bool, .is_optional = false, .is_readonly = false, .is_method = true },
    };
    cache.number_global = try ti.internObjectType(&m);
    return cache.number_global;
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
        "replace",   "replaceAll", "match",         "matchAll", "search",
        "padStart",  "padEnd",     "trimStart",     "trimEnd",  "at",
        "codePointAt", "normalize", "localeCompare", "lastIndexOf",
        "substr",    "valueOf",    "toString",
    }) |name| {
        try T.expect(ti.objectMember(proto, try sint.intern(name)) != null);
    }
    // `replace` returns `string`.
    try T.expectEqual(types.Primitive.string_t, ti.signatureReturn(ti.objectMember(proto, try sint.intern("replace")).?).?);
    // `search` returns `number`.
    try T.expectEqual(types.Primitive.number_t, ti.signatureReturn(ti.objectMember(proto, try sint.intern("search")).?).?);
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

    // `reduce<U>(cb, init: U): U`: the return is a free `U`, equal to the
    // second parameter (initial value) type, so init-value inference
    // resolves the result precisely.
    const red_sig = ti.objectMember(proto, try sint.intern("reduce")).?;
    const red_ret = ti.signatureReturn(red_sig).?;
    try T.expect(ti.pool.flagsOf(red_ret).is_type_parameter);
    const red_params = ti.signatureParams(red_sig);
    try T.expectEqual(@as(usize, 2), red_params.len);
    try T.expectEqual(red_ret, red_params[1]);
    // The reducer callback returns the same `U`.
    try T.expectEqual(red_ret, ti.signatureReturn(red_params[0]).?);
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
        "freeze",                "isFrozen",          "seal",
        "isSealed",              "preventExtensions", "isExtensible",
        "getOwnPropertyNames",   "getOwnPropertySymbols",
        "getOwnPropertyDescriptor", "getOwnPropertyDescriptors",
        "getPrototypeOf",        "setPrototypeOf",    "fromEntries",
        "defineProperties",      "is",
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
