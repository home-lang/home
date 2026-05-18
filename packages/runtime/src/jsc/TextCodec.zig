// Copied from bun/src/jsc/TextCodec.zig at upstream SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// `bun.String` and `jsc.markBinding` are not yet ported. Local stubs keep the
// public surface intact — the JSC bridge re-attaches in Phase 12.2.

const std = @import("std");

// JSC bridge bun.String stubbed — re-attaches in Phase 12.2.
// `BunString` C ABI is `{tag: u8, impl: *anyopaque}` (see upstream
// src/string/BunString.h). We model the on-the-wire layout so pass-by-value
// extern signatures stay correct, without depending on the real String API.
const String = extern struct {
    tag: u8 = 0,
    _padding: [7]u8 = @splat(0),
    impl: ?*anyopaque = null,
};

// JSC bridge markBinding stubbed — re-attaches in Phase 12.2.
fn markBinding(_: std.builtin.SourceLocation) void {}

extern fn Bun__createTextCodec(encodingName: [*]const u8, encodingNameLen: usize) ?*TextCodec;
extern fn Bun__decodeWithTextCodec(codec: *TextCodec, data: [*]const u8, length: usize, flush: bool, stopOnError: bool, outSawError: *bool) String;
extern fn Bun__deleteTextCodec(codec: *TextCodec) void;
extern fn Bun__stripBOMFromTextCodec(codec: *TextCodec) void;
extern fn Bun__isEncodingSupported(encodingName: [*]const u8, encodingNameLen: usize) bool;
extern fn Bun__getCanonicalEncodingName(encodingName: [*]const u8, encodingNameLen: usize, outLen: *usize) ?[*]const u8;

pub const TextCodec = opaque {
    pub fn create(encoding: []const u8) ?*TextCodec {
        markBinding(@src());
        return Bun__createTextCodec(encoding.ptr, encoding.len);
    }

    pub fn deinit(self: *TextCodec) void {
        markBinding(@src());
        Bun__deleteTextCodec(self);
    }

    pub fn decode(self: *TextCodec, data: []const u8, flush: bool, stopOnError: bool) struct { result: String, sawError: bool } {
        markBinding(@src());
        var sawError: bool = false;
        const result = Bun__decodeWithTextCodec(self, data.ptr, data.len, flush, stopOnError, &sawError);

        return .{ .result = result, .sawError = sawError };
    }

    pub fn stripBOM(self: *TextCodec) void {
        markBinding(@src());
        Bun__stripBOMFromTextCodec(self);
    }

    pub fn isSupported(encoding: []const u8) bool {
        markBinding(@src());
        return Bun__isEncodingSupported(encoding.ptr, encoding.len);
    }

    pub fn getCanonicalEncodingName(encoding: []const u8) ?[]const u8 {
        markBinding(@src());
        var len: usize = 0;
        const name = Bun__getCanonicalEncodingName(encoding.ptr, encoding.len, &len) orelse return null;
        return name[0..len];
    }
};

test "TextCodec is opaque pointer-only" {
    try std.testing.expect(@sizeOf(*TextCodec) == @sizeOf(usize));
}

test "TextCodec exposes expected public API" {
    try std.testing.expect(@hasDecl(TextCodec, "create"));
    try std.testing.expect(@hasDecl(TextCodec, "deinit"));
    try std.testing.expect(@hasDecl(TextCodec, "decode"));
    try std.testing.expect(@hasDecl(TextCodec, "stripBOM"));
    try std.testing.expect(@hasDecl(TextCodec, "isSupported"));
    try std.testing.expect(@hasDecl(TextCodec, "getCanonicalEncodingName"));
}
