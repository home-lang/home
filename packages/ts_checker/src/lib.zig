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
//! now `map` / `filter` / `forEach` use loose signatures that accept
//! a callback and return `T[]` / `T[]` / `void` respectively. The
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
    /// `Object` global — `keys / values / entries / assign`. Built
    /// once on first access.
    object_global: TypeId = types.Primitive.none,
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
) !TypeId {
    if (cache.string_proto != types.Primitive.none) return cache.string_proto;

    const string_t = types.Primitive.string_t;
    const number_t = types.Primitive.number_t;
    const boolean_t = types.Primitive.boolean_t;

    // `string[]` for `split`'s return.
    const string_arr = try ti.internArrayType(sint, string_t);

    // `(): string`
    const sig_void_string = try ti.internSignature(&[_]TypeId{}, string_t, false);
    // `(s: string): boolean`
    const sig_str_bool = try ti.internSignature(&[_]TypeId{string_t}, boolean_t, false);
    // `(s: string): number`
    const sig_str_num = try ti.internSignature(&[_]TypeId{string_t}, number_t, false);
    // `(i: number): string`
    const sig_num_string = try ti.internSignature(&[_]TypeId{number_t}, string_t, false);
    // `(sep: string): string[]`
    const sig_split = try ti.internSignature(&[_]TypeId{string_t}, string_arr, false);
    // `(start: number, end?: number): string` — modeled as
    // `(start: number, end: number): string`. Optional-arg arity is
    // handled by `signatureAccepts` checking `>=` rather than `==`,
    // but for simplicity we leave both required and let argument
    // count drive matching. v0.
    const sig_slice = try ti.internSignature(&[_]TypeId{ number_t, number_t }, string_t, false);
    // `(s: string): string` — used by `concat` (modeled as the
    // common single-arg form until rest params land in lib).
    const sig_str_string = try ti.internSignature(&[_]TypeId{string_t}, string_t, false);

    const m = [_]types.ObjectMember{
        .{ .name = try sint.intern("length"), .type = number_t, .is_optional = false, .is_readonly = true, .is_method = false },
        .{ .name = try sint.intern("charAt"), .type = sig_num_string, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("toUpperCase"), .type = sig_void_string, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("toLowerCase"), .type = sig_void_string, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("startsWith"), .type = sig_str_bool, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("endsWith"), .type = sig_str_bool, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("includes"), .type = sig_str_bool, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("split"), .type = sig_split, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("indexOf"), .type = sig_str_num, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("slice"), .type = sig_slice, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("trim"), .type = sig_void_string, .is_optional = false, .is_readonly = false, .is_method = true },
        // `concat` is `(...strs: string[]): string`; modeled as the
        // common single-arg form `(s: string): string` until rest
        // params land in lib types.
        .{ .name = try sint.intern("concat"), .type = sig_str_string, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("repeat"), .type = sig_num_string, .is_optional = false, .is_readonly = false, .is_method = true },
    };
    // (concat is actually `(...strs: string[]): string`; we model the
    // common single-arg form. Will be replaced once rest params land
    // in lib types.)
    cache.string_proto = try ti.internObjectType(&m);
    return cache.string_proto;
}

/// Build (or fetch from cache) the `Array<T>.prototype` member shape
/// for a given element type. The shape mirrors what `internArrayType`
/// already produces (`length: number`, `[i: number]: T`) plus the
/// common mutation / iteration / search methods.
///
/// For v0 the higher-order callbacks have loose return-type approxi-
/// mations: `map` returns `any[]` (since we'd need argument-driven
/// inference of `U` from the callback's return type); `filter` /
/// `slice` / `concat` / `reverse` / `sort` correctly preserve `T[]`.
pub fn arrayProto(
    cache: *LibCache,
    ti: *interner_mod.Interner,
    sint: *string_interner.Interner,
    gpa: std.mem.Allocator,
    elem: TypeId,
) !TypeId {
    if (cache.array_proto_by_elem.get(elem)) |cached| return cached;

    const number_t = types.Primitive.number_t;
    const boolean_t = types.Primitive.boolean_t;
    const string_t = types.Primitive.string_t;
    const undef_t = types.Primitive.undefined_t;
    const void_t = types.Primitive.void_t;
    const any_t = types.Primitive.any;

    // `T[]` itself — used as both receiver and return type for
    // `slice`, `filter`, `concat`, `reverse`, `sort`.
    const arr_t = try ti.internArrayType(sint, elem);
    // `any[]` — return type for `map` (until generic <U> support).
    const any_arr = try ti.internArrayType(sint, any_t);
    // `T | undefined` — return for `pop`, `find`.
    const t_or_undef = try ti.internUnion(&[_]TypeId{ elem, undef_t });

    // Callback signatures.
    // `(x: T) => any`  — used by map.
    const cb_t_any = try ti.internSignature(&[_]TypeId{elem}, any_t, false);
    // `(x: T) => boolean` — used by filter / find.
    const cb_t_bool = try ti.internSignature(&[_]TypeId{elem}, boolean_t, false);
    // `(x: T) => void` — used by forEach.
    const cb_t_void = try ti.internSignature(&[_]TypeId{elem}, void_t, false);
    // `(a: T, b: T) => number` — used by sort.
    const cb_tt_num = try ti.internSignature(&[_]TypeId{ elem, elem }, number_t, false);

    // Method signatures.
    const sig_push = try ti.internSignature(&[_]TypeId{elem}, number_t, false);
    const sig_pop = try ti.internSignature(&[_]TypeId{}, t_or_undef, false);
    const sig_map = try ti.internSignature(&[_]TypeId{cb_t_any}, any_arr, false);
    const sig_filter = try ti.internSignature(&[_]TypeId{cb_t_bool}, arr_t, false);
    const sig_forEach = try ti.internSignature(&[_]TypeId{cb_t_void}, void_t, false);
    const sig_includes = try ti.internSignature(&[_]TypeId{elem}, boolean_t, false);
    const sig_indexOf = try ti.internSignature(&[_]TypeId{elem}, number_t, false);
    const sig_slice = try ti.internSignature(&[_]TypeId{ number_t, number_t }, arr_t, false);
    const sig_join = try ti.internSignature(&[_]TypeId{string_t}, string_t, false);
    const sig_find = try ti.internSignature(&[_]TypeId{cb_t_bool}, t_or_undef, false);
    const sig_concat = try ti.internSignature(&[_]TypeId{arr_t}, arr_t, false);
    const sig_reverse = try ti.internSignature(&[_]TypeId{}, arr_t, false);
    const sig_sort = try ti.internSignature(&[_]TypeId{cb_tt_num}, arr_t, false);

    const m = [_]types.ObjectMember{
        .{ .name = try sint.intern("length"), .type = number_t, .is_optional = false, .is_readonly = false, .is_method = false },
        .{ .name = try sint.intern("push"), .type = sig_push, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("pop"), .type = sig_pop, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("map"), .type = sig_map, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("filter"), .type = sig_filter, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("forEach"), .type = sig_forEach, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("includes"), .type = sig_includes, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("indexOf"), .type = sig_indexOf, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("slice"), .type = sig_slice, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("join"), .type = sig_join, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("find"), .type = sig_find, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("concat"), .type = sig_concat, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("reverse"), .type = sig_reverse, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("sort"), .type = sig_sort, .is_optional = false, .is_readonly = false, .is_method = true },
    };
    const proto = try ti.internObjectType(&m);
    try cache.array_proto_by_elem.put(gpa, elem, proto);
    return proto;
}

/// Build (or fetch from cache) the `Object` global — the namespace
/// shape carrying `keys / values / entries / assign`.
pub fn objectGlobal(
    cache: *LibCache,
    ti: *interner_mod.Interner,
    sint: *string_interner.Interner,
) !TypeId {
    if (cache.object_global != types.Primitive.none) return cache.object_global;

    const string_t = types.Primitive.string_t;
    const any_t = types.Primitive.any;

    const string_arr = try ti.internArrayType(sint, string_t);
    const any_arr = try ti.internArrayType(sint, any_t);

    // `Object.keys(o: any): string[]`
    const sig_keys = try ti.internSignature(&[_]TypeId{any_t}, string_arr, false);
    // `Object.values(o: any): any[]`
    const sig_values = try ti.internSignature(&[_]TypeId{any_t}, any_arr, false);
    // `Object.entries(o: any): [string, any][]` — modeled loosely as
    // `any[]` (tuple-typed entries land later).
    const sig_entries = try ti.internSignature(&[_]TypeId{any_t}, any_arr, false);
    // `Object.assign(t: any, u: any): any` — generic intersection
    // `T & U` is deferred; loose `any` for now.
    const sig_assign = try ti.internSignature(&[_]TypeId{ any_t, any_t }, any_t, false);

    const m = [_]types.ObjectMember{
        .{ .name = try sint.intern("keys"), .type = sig_keys, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("values"), .type = sig_values, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("entries"), .type = sig_entries, .is_optional = false, .is_readonly = false, .is_method = true },
        .{ .name = try sint.intern("assign"), .type = sig_assign, .is_optional = false, .is_readonly = false, .is_method = true },
    };
    cache.object_global = try ti.internObjectType(&m);
    return cache.object_global;
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

    const proto = try stringProto(&cache, &ti, &sint);
    const length_id = try sint.intern("length");
    const charAt_id = try sint.intern("charAt");
    const upper_id = try sint.intern("toUpperCase");
    try T.expect(ti.objectMember(proto, length_id) != null);
    try T.expect(ti.objectMember(proto, charAt_id) != null);
    try T.expect(ti.objectMember(proto, upper_id) != null);
    try T.expectEqual(types.Primitive.number_t, ti.objectMember(proto, length_id).?);
}

test "lib: arrayProto exposes length/push/map" {
    var sint = try string_interner.Interner.init(T.allocator);
    defer sint.deinit();
    var ti = try interner_mod.Interner.init(T.allocator);
    defer ti.deinit();
    var cache: LibCache = .{};
    defer cache.deinit(T.allocator);

    const proto = try arrayProto(&cache, &ti, &sint, T.allocator, types.Primitive.number_t);
    const length_id = try sint.intern("length");
    const push_id = try sint.intern("push");
    const map_id = try sint.intern("map");
    try T.expect(ti.objectMember(proto, length_id) != null);
    try T.expect(ti.objectMember(proto, push_id) != null);
    try T.expect(ti.objectMember(proto, map_id) != null);
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
