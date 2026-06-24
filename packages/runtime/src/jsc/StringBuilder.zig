// Copied from bun/src/jsc/StringBuilder.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// Thin Zig view over WebKit's `WTF::StringBuilder`. The C++ object lives
// inside a 24-byte-aligned-to-8 backing buffer we own here — the only Zig
// state is `bytes: [24]u8`, and every method delegates to a `StringBuilder__`
// C entrypoint that reinterprets that buffer as the real C++ object.
//
// `toString` upstream returns `JSError!JSValue` after a `jsc.TopExceptionScope`
// roundtrip. We keep the extern declaration but defer the higher-level
// wrapper until `TopExceptionScope` lands (Phase 12.2). Callers needing the
// JS string today can invoke the extern directly.
//
// `bun.String` is stubbed as the C ABI `{tag, _padding, impl}` triple — the
// same layout the C++ side passes/returns. The real `bun.String` API
// (`ref`/`deref`/`fromBytes`/…) re-attaches in Phase 12.2.

const std = @import("std");

// JSC bridge stubs — re-attach in Phase 12.2.
const JSGlobalObject = @import("./JSGlobalObject.zig").JSGlobalObject;
const JSValue = @import("home").jsc.JSValue;

// The real `bun.String` (C ABI extern struct). Re-attached 2026-06-23 — the
// earlier local `{tag, _padding, impl}` stub matched the C++ layout but isn't
// the same Zig type the stringify callers pass, so use bun.String directly.
const String = @import("home").String;

pub const StringBuilder = @This();

const size = 24;
const alignment = 8;

bytes: [size]u8 align(alignment),

pub inline fn init() StringBuilder {
    var this: StringBuilder = undefined;
    StringBuilder__init(&this.bytes);
    return this;
}
extern fn StringBuilder__init(*anyopaque) void;

pub fn deinit(this: *StringBuilder) void {
    StringBuilder__deinit(&this.bytes);
}
extern fn StringBuilder__deinit(*anyopaque) void;

const Append = enum {
    latin1,
    utf16,
    double,
    int,
    usize,
    string,
    lchar,
    uchar,
    quoted_json_string,

    pub fn Type(comptime this: Append) type {
        return switch (this) {
            .latin1 => []const u8,
            .utf16 => []const u16,
            .double => f64,
            .int => i32,
            .usize => usize,
            .string => String,
            .lchar => u8,
            .uchar => u16,
            .quoted_json_string => String,
        };
    }
};

pub fn append(this: *StringBuilder, comptime append_type: Append, value: append_type.Type()) void {
    switch (comptime append_type) {
        .latin1 => StringBuilder__appendLatin1(&this.bytes, value.ptr, value.len),
        .utf16 => StringBuilder__appendUtf16(&this.bytes, value.ptr, value.len),
        .double => StringBuilder__appendDouble(&this.bytes, value),
        .int => StringBuilder__appendInt(&this.bytes, value),
        .usize => StringBuilder__appendUsize(&this.bytes, value),
        .string => StringBuilder__appendString(&this.bytes, value),
        .lchar => StringBuilder__appendLChar(&this.bytes, value),
        .uchar => StringBuilder__appendUChar(&this.bytes, value),
        .quoted_json_string => StringBuilder__appendQuotedJsonString(&this.bytes, value),
    }
}
extern fn StringBuilder__appendLatin1(*anyopaque, str: [*]const u8, len: usize) void;
extern fn StringBuilder__appendUtf16(*anyopaque, str: [*]const u16, len: usize) void;
extern fn StringBuilder__appendDouble(*anyopaque, num: f64) void;
extern fn StringBuilder__appendInt(*anyopaque, num: i32) void;
extern fn StringBuilder__appendUsize(*anyopaque, num: usize) void;
extern fn StringBuilder__appendString(*anyopaque, str: String) void;
extern fn StringBuilder__appendLChar(*anyopaque, c: u8) void;
extern fn StringBuilder__appendUChar(*anyopaque, c: u16) void;
extern fn StringBuilder__appendQuotedJsonString(*anyopaque, str: String) void;

// `toString` wraps the extern with a `jsc.TopExceptionScope` roundtrip,
// matching upstream. Re-attached 2026-06-23 now that TopExceptionScope is
// ported; used by `Bun.JSON5.stringify` / `Bun.YAML.stringify`.
pub fn toString(this: *StringBuilder, global: *JSGlobalObject) @import("home").JSError!JSValue {
    const jsc = @import("home").jsc;
    var scope: jsc.TopExceptionScope = undefined;
    scope.init(global, @src());
    defer scope.deinit();

    const result = StringBuilder__toString(&this.bytes, global);
    try scope.returnIfException();
    return result;
}
extern fn StringBuilder__toString(*anyopaque, global: *JSGlobalObject) JSValue;

pub fn ensureUnusedCapacity(this: *StringBuilder, additional: usize) void {
    StringBuilder__ensureUnusedCapacity(&this.bytes, additional);
}
extern fn StringBuilder__ensureUnusedCapacity(*anyopaque, usize) void;

test "StringBuilder is a 24-byte buffer aligned to 8" {
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(StringBuilder));
    try std.testing.expectEqual(@as(u29, 8), @alignOf(StringBuilder));
}

test "StringBuilder exposes the expected entrypoints" {
    try std.testing.expect(@hasDecl(StringBuilder, "init"));
    try std.testing.expect(@hasDecl(StringBuilder, "deinit"));
    try std.testing.expect(@hasDecl(StringBuilder, "append"));
    try std.testing.expect(@hasDecl(StringBuilder, "ensureUnusedCapacity"));
}

test "StringBuilder.Append.Type maps each tag to the right Zig type" {
    try std.testing.expect(Append.latin1.Type() == []const u8);
    try std.testing.expect(Append.utf16.Type() == []const u16);
    try std.testing.expect(Append.double.Type() == f64);
    try std.testing.expect(Append.int.Type() == i32);
    try std.testing.expect(Append.usize.Type() == usize);
    try std.testing.expect(Append.string.Type() == String);
    try std.testing.expect(Append.lchar.Type() == u8);
    try std.testing.expect(Append.uchar.Type() == u16);
    try std.testing.expect(Append.quoted_json_string.Type() == String);
}
