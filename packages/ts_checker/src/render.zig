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
    if (flags.is_any) return buf.appendSlice(gpa, "any");
    if (flags.is_unknown) return buf.appendSlice(gpa, "unknown");
    if (flags.is_never) return buf.appendSlice(gpa, "never");
    if (flags.is_void) return buf.appendSlice(gpa, "void");
    if (flags.is_null) return buf.appendSlice(gpa, "null");
    if (flags.is_undefined) return buf.appendSlice(gpa, "undefined");
    if (flags.is_literal) {
        const lit = ti.literalOf(id);
        switch (lit) {
            .string_lit => |sid| {
                try buf.append(gpa, '"');
                try buf.appendSlice(gpa, sint.get(sid));
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
            try buf.appendSlice(gpa, ": ");
            try renderTypeInto(buf, gpa, ti, sint, m.type, depth + 1);
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
        const members = ti.unionMembers(id);
        for (members, 0..) |m, i| {
            if (i > 0) try buf.appendSlice(gpa, " | ");
            try renderTypeInto(buf, gpa, ti, sint, m, depth + 1);
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
