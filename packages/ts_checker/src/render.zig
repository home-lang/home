//! TypeId → TS-source renderer.
//!
//! Produces a TS-shaped string from an interned TypeId. Used by the
//! LSP for hover/completion display, by the .d.ts emitter when a
//! function lacks a return-type annotation (so the inferred type
//! still shows up in the declaration file), and by tooling that
//! wants a human-readable type string.
//!
//! Output mirrors how `tsc` formats types — `string`, `(a: T) => U`,
//! `{ x: number; y: string }`, `A | B`, etc. Recursion is depth-
//! capped so cyclic / deeply-nested types degrade to `…` rather than
//! recursing forever.

const std = @import("std");
const string_interner = @import("string_interner");
const types = @import("types.zig");
const interner_mod = @import("interner.zig");

pub const RenderError = error{OutOfMemory};

const max_depth: u32 = 8;

/// Render `id` into a freshly allocated string the caller owns.
pub fn renderType(
    gpa: std.mem.Allocator,
    ti: *const interner_mod.Interner,
    sint: *const string_interner.Interner,
    id: types.TypeId,
) RenderError![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(gpa);
    try renderTypeInto(&buf, gpa, ti, sint, id, 0);
    return buf.toOwnedSlice(gpa);
}

/// Escape a string-literal payload for diagnostic display so that
/// control characters mirror tsc's `getLiteralText` output. tsc maps
/// CR/LF/tab/etc. to their `\x` escape sequences and leaves other
/// printable characters untouched; without this, an interned literal
/// containing a real newline (e.g. from a template-string source)
/// would render as `'AB
/// C'` instead of the `'AB\nC'` tsc emits. Backslashes are passed
/// through unchanged because some upstream-aligned lowering paths
/// intern source-form literal-type text where the `\r` / `\n` escapes
/// are still literal `\` + letter sequences — re-escaping them here
/// would double them and break the
/// `stringLiteralTypesWithTemplateStrings02` baseline.
fn appendEscapedStringLiteral(
    buf: *std.ArrayListUnmanaged(u8),
    gpa: std.mem.Allocator,
    s: []const u8,
) RenderError!void {
    for (s) |c| {
        switch (c) {
            '\n' => try buf.appendSlice(gpa, "\\n"),
            '\r' => try buf.appendSlice(gpa, "\\r"),
            '\t' => try buf.appendSlice(gpa, "\\t"),
            8 => try buf.appendSlice(gpa, "\\b"),
            12 => try buf.appendSlice(gpa, "\\f"),
            11 => try buf.appendSlice(gpa, "\\v"),
            0 => try buf.appendSlice(gpa, "\\0"),
            '"' => try buf.appendSlice(gpa, "\\\""),
            else => try buf.append(gpa, c),
        }
    }
}

/// Append the TS source representation of `id` to `buf`.
pub fn renderTypeInto(
    buf: *std.ArrayListUnmanaged(u8),
    gpa: std.mem.Allocator,
    ti: *const interner_mod.Interner,
    sint: *const string_interner.Interner,
    id: types.TypeId,
    depth: u32,
) RenderError!void {
    if (depth > max_depth) {
        try buf.appendSlice(gpa, "…");
        return;
    }
    const flags = ti.pool.flagsOf(id);
    // Union flags OR-merge their constituents, so guard the
    // primitive shortcuts against `is_union` — otherwise a union
    // like `string | null` would render as `null` here. The union
    // branch below handles each constituent recursively.
    if (!flags.is_union and !flags.is_intersection) {
        if (flags.is_any) return buf.appendSlice(gpa, "any");
        if (flags.is_unknown) return buf.appendSlice(gpa, "unknown");
        if (flags.is_never) return buf.appendSlice(gpa, "never");
        if (flags.is_void) return buf.appendSlice(gpa, "void");
        if (flags.is_null) return buf.appendSlice(gpa, "null");
        if (flags.is_undefined) return buf.appendSlice(gpa, "undefined");
    }
    if (flags.is_literal) {
        const lit = ti.literalOf(id);
        switch (lit) {
            .string_lit => |sid| {
                try buf.append(gpa, '"');
                try appendEscapedStringLiteral(buf, gpa, sint.get(sid));
                try buf.append(gpa, '"');
            },
            .number_lit => |bits| {
                const v: f64 = @bitCast(bits);
                var nbuf: [32]u8 = undefined;
                const formatted = std.fmt.bufPrint(&nbuf, "{d}", .{v}) catch "NaN";
                try buf.appendSlice(gpa, formatted);
            },
            .boolean_lit => |b| try buf.appendSlice(gpa, if (b) "true" else "false"),
            .bigint_lit => |sid| {
                try buf.appendSlice(gpa, sint.get(sid));
                try buf.append(gpa, 'n');
            },
        }
        return;
    }
    if (flags.is_object_type) {
        const payload = ti.pool.object_type_payloads.items[ti.pool.payloadOf(id)];
        const members = ti.pool.object_member_pool.items[payload.members_start .. payload.members_start + payload.members_len];
        try buf.appendSlice(gpa, "{ ");
        for (members, 0..) |m, i| {
            if (i > 0) try buf.appendSlice(gpa, "; ");
            if (m.is_readonly) try buf.appendSlice(gpa, "readonly ");
            try buf.appendSlice(gpa, sint.get(m.name));
            if (m.is_optional) try buf.append(gpa, '?');
            // Render method-shorthand members as `name(params): ret`
            // so error messages mirror upstream tsc — `{ f(): void }`
            // stays in that shape instead of widening to property
            // form `{ f: () => void }`.
            if (m.is_method and ti.isSignature(m.type)) {
                try buf.append(gpa, '(');
                const sig_params = ti.signatureParams(m.type);
                for (sig_params, 0..) |p, pi| {
                    if (pi > 0) try buf.appendSlice(gpa, ", ");
                    try renderTypeInto(buf, gpa, ti, sint, p, depth + 1);
                }
                try buf.appendSlice(gpa, "): ");
                if (ti.signatureReturn(m.type)) |ret| {
                    try renderTypeInto(buf, gpa, ti, sint, ret, depth + 1);
                } else {
                    try buf.appendSlice(gpa, "void");
                }
            } else {
                try buf.appendSlice(gpa, ": ");
                try renderTypeInto(buf, gpa, ti, sint, m.type, depth + 1);
            }
        }
        try buf.appendSlice(gpa, " }");
        return;
    }
    if (flags.is_signature) {
        try buf.append(gpa, '(');
        const params = ti.signatureParams(id);
        for (params, 0..) |p, i| {
            if (i > 0) try buf.appendSlice(gpa, ", ");
            try renderTypeInto(buf, gpa, ti, sint, p, depth + 1);
        }
        try buf.appendSlice(gpa, ") => ");
        if (ti.signatureReturn(id)) |ret| {
            try renderTypeInto(buf, gpa, ti, sint, ret, depth + 1);
        } else {
            try buf.appendSlice(gpa, "void");
        }
        return;
    }
    if (flags.is_union) {
        // Render order mirrors tsc: regular members in their
        // interner order first, then `null`, then `undefined`.
        // Without this, `T | undefined` parameter targets render as
        // `undefined | T` because `undefined`'s primitive TypeId is
        // numerically smaller. Fixture: `callWithSpread5.ts(6,4)`.
        const members = ti.unionMembers(id);
        var first = true;
        var has_null = false;
        var has_undefined = false;
        for (members) |m| {
            const mf = ti.pool.flagsOf(m);
            if (mf.is_null) {
                has_null = true;
                continue;
            }
            if (mf.is_undefined) {
                has_undefined = true;
                continue;
            }
            if (!first) try buf.appendSlice(gpa, " | ");
            try renderTypeInto(buf, gpa, ti, sint, m, depth + 1);
            first = false;
        }
        if (has_null) {
            if (!first) try buf.appendSlice(gpa, " | ");
            try buf.appendSlice(gpa, "null");
            first = false;
        }
        if (has_undefined) {
            if (!first) try buf.appendSlice(gpa, " | ");
            try buf.appendSlice(gpa, "undefined");
        }
        return;
    }
    if (flags.is_intersection) {
        const members = ti.intersectionMembers(id);
        for (members, 0..) |m, i| {
            if (i > 0) try buf.appendSlice(gpa, " & ");
            try renderTypeInto(buf, gpa, ti, sint, m, depth + 1);
        }
        return;
    }
    if (flags.is_string) return buf.appendSlice(gpa, "string");
    if (flags.is_number) return buf.appendSlice(gpa, "number");
    if (flags.is_boolean) return buf.appendSlice(gpa, "boolean");
    if (flags.is_bigint) return buf.appendSlice(gpa, "bigint");
    if (flags.is_symbol) return buf.appendSlice(gpa, "symbol");
    if (flags.is_object) return buf.appendSlice(gpa, "object");
    if (flags.is_type_parameter) {
        // Type parameters carry the original name in their payload.
        const tp = ti.pool.type_parameter_payloads.items[ti.pool.payloadOf(id)];
        try buf.appendSlice(gpa, sint.get(tp.name));
        return;
    }
    // Fallthrough — unknown shape, emit `any` so downstream stays
    // syntactically valid.
    try buf.appendSlice(gpa, "any");
}

const T = std.testing;

test "renderType: primitives" {
    var ti = try interner_mod.Interner.init(T.allocator);
    defer ti.deinit();
    var sint = try string_interner.Interner.init(T.allocator);
    defer sint.deinit();
    const out = try renderType(T.allocator, &ti, &sint, types.Primitive.string_t);
    defer T.allocator.free(out);
    try T.expectEqualStrings("string", out);
}

test "renderType: union" {
    var ti = try interner_mod.Interner.init(T.allocator);
    defer ti.deinit();
    var sint = try string_interner.Interner.init(T.allocator);
    defer sint.deinit();
    const u = try ti.internUnion(&.{ types.Primitive.number_t, types.Primitive.string_t });
    const out = try renderType(T.allocator, &ti, &sint, u);
    defer T.allocator.free(out);
    // Members are sorted by TypeId, so the order is interner-deterministic.
    // Both members must show up, separated by ` | `.
    try T.expect(std.mem.indexOf(u8, out, "number") != null);
    try T.expect(std.mem.indexOf(u8, out, "string") != null);
    try T.expect(std.mem.indexOf(u8, out, " | ") != null);
}

test "renderType: union renders undefined and null after non-nullish members" {
    var ti = try interner_mod.Interner.init(T.allocator);
    defer ti.deinit();
    var sint = try string_interner.Interner.init(T.allocator);
    defer sint.deinit();
    const u = try ti.internUnion(&.{ types.Primitive.undefined_t, types.Primitive.number_t });
    const out = try renderType(T.allocator, &ti, &sint, u);
    defer T.allocator.free(out);
    try T.expectEqualStrings("number | undefined", out);

    const u_nu = try ti.internUnion(&.{ types.Primitive.null_t, types.Primitive.undefined_t, types.Primitive.string_t });
    const out2 = try renderType(T.allocator, &ti, &sint, u_nu);
    defer T.allocator.free(out2);
    try T.expectEqualStrings("string | null | undefined", out2);
}

test "renderType: object with method-shorthand member" {
    var ti = try interner_mod.Interner.init(T.allocator);
    defer ti.deinit();
    var sint = try string_interner.Interner.init(T.allocator);
    defer sint.deinit();
    const sig = try ti.internSignature(&.{}, types.Primitive.void_t, false);
    const f_name = try sint.intern("f");
    const obj = try ti.internObjectType(&.{
        .{ .name = f_name, .type = sig, .is_optional = false, .is_readonly = false, .is_method = true },
    });
    const out = try renderType(T.allocator, &ti, &sint, obj);
    defer T.allocator.free(out);
    try T.expectEqualStrings("{ f(): void }", out);
}

test "renderType: object with property-form function member stays arrow" {
    var ti = try interner_mod.Interner.init(T.allocator);
    defer ti.deinit();
    var sint = try string_interner.Interner.init(T.allocator);
    defer sint.deinit();
    const sig = try ti.internSignature(&.{}, types.Primitive.void_t, false);
    const f_name = try sint.intern("f");
    const obj = try ti.internObjectType(&.{
        .{ .name = f_name, .type = sig, .is_optional = false, .is_readonly = false, .is_method = false },
    });
    const out = try renderType(T.allocator, &ti, &sint, obj);
    defer T.allocator.free(out);
    try T.expectEqualStrings("{ f: () => void }", out);
}

test "renderType: string literal with control chars escapes like tsc" {
    var ti = try interner_mod.Interner.init(T.allocator);
    defer ti.deinit();
    var sint = try string_interner.Interner.init(T.allocator);
    defer sint.deinit();
    // A literal payload whose raw interned text contains a real
    // newline must render with `\n` rather than the bare control
    // character — otherwise TS2322 prose breaks across multiple
    // diagnostic lines. Mirrors
    // `stringLiteralTypesWithTemplateStrings02.ts(1,5)`.
    const sid = try sint.intern("AB\nC");
    const lit = try ti.internStringLiteral(sid);
    const out = try renderType(T.allocator, &ti, &sint, lit);
    defer T.allocator.free(out);
    try T.expectEqualStrings("\"AB\\nC\"", out);

    const sid2 = try sint.intern("AB\r\nC");
    const lit2 = try ti.internStringLiteral(sid2);
    const out2 = try renderType(T.allocator, &ti, &sint, lit2);
    defer T.allocator.free(out2);
    try T.expectEqualStrings("\"AB\\r\\nC\"", out2);
}

test "renderType: signature" {
    var ti = try interner_mod.Interner.init(T.allocator);
    defer ti.deinit();
    var sint = try string_interner.Interner.init(T.allocator);
    defer sint.deinit();
    const sig = try ti.internSignature(
        &.{ types.Primitive.number_t, types.Primitive.string_t },
        types.Primitive.boolean_t,
        false,
    );
    const out = try renderType(T.allocator, &ti, &sint, sig);
    defer T.allocator.free(out);
    try T.expectEqualStrings("(number, string) => boolean", out);
}
