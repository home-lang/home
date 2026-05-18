// Copied from bun/src/jsc/ZigStackTrace.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// Structural port. The extern struct layout matches upstream so the C++
// side can keep populating it through the existing exception-collection path.
//
// `toAPI` flattens the trace into `bun.schema.api.StackTrace`, which lives
// in the bindgen schema layer not yet ported. The method is omitted and
// re-lands together with `ZigStackFrame.toAPI` once `api.StackFrame` /
// `api.SourceLine` are on the `home_rt` allow-list.
//
// `SourceLineIterator` calls `bun.String.toUTF8` which routes through the
// WTFStringImpl path. With the `bun.String` C ABI stub there is no live
// payload to iterate, so the iterator is omitted; the iterator surface is
// re-established alongside the real `bun.String`.

const std = @import("std");

const ZigStackFrame = @import("ZigStackFrame.zig").ZigStackFrame;

// `bun.String` C ABI stub — re-attaches in Phase 12.2.
const String = extern struct {
    tag: u8 = 0,
    _padding: [7]u8 = @splat(0),
    impl: ?*anyopaque = null,

    pub const empty: String = .{};

    pub fn ref(_: *const String) void {}
    pub fn deref(_: *const String) void {}
    pub fn isEmpty(this: *const String) bool {
        return this.tag == 0 and this.impl == null;
    }
};

// `jsc.SourceProvider` stubbed — opaque C++ type on the JSC side.
const SourceProvider = opaque {};

/// Represents a JavaScript stack trace
pub const ZigStackTrace = extern struct {
    source_lines_ptr: [*]String,
    source_lines_numbers: [*]i32,
    source_lines_len: u8,
    source_lines_to_collect: u8,

    frames_ptr: [*]ZigStackFrame,
    frames_len: u8,
    frames_cap: u8,

    /// Non-null if `source_lines_*` points into data owned by a JSC::SourceProvider.
    /// If so, then .deref must be called on it to release the memory.
    referenced_source_provider: ?*SourceProvider = null,

    pub fn fromFrames(frames_slice: []ZigStackFrame) ZigStackTrace {
        return .{
            .source_lines_ptr = &[0]String{},
            .source_lines_numbers = &[0]i32{},
            .source_lines_len = 0,
            .source_lines_to_collect = 0,

            .frames_ptr = frames_slice.ptr,
            .frames_len = @min(frames_slice.len, std.math.maxInt(u8)),
            .frames_cap = @min(frames_slice.len, std.math.maxInt(u8)),

            .referenced_source_provider = null,
        };
    }

    pub fn frames(this: *const ZigStackTrace) []const ZigStackFrame {
        return this.frames_ptr[0..this.frames_len];
    }

    pub fn framesMutable(this: *ZigStackTrace) []ZigStackFrame {
        return this.frames_ptr[0..this.frames_len];
    }
};

test "ZigStackTrace.fromFrames pins frames_len/cap to the slice length" {
    var buf: [3]ZigStackFrame = .{ ZigStackFrame.Zero, ZigStackFrame.Zero, ZigStackFrame.Zero };
    const trace = ZigStackTrace.fromFrames(buf[0..]);
    try std.testing.expectEqual(@as(u8, 3), trace.frames_len);
    try std.testing.expectEqual(@as(u8, 3), trace.frames_cap);
    try std.testing.expectEqual(@as(u8, 0), trace.source_lines_len);
    try std.testing.expect(trace.referenced_source_provider == null);
}

test "ZigStackTrace.frames returns a slice of the right shape" {
    var buf: [2]ZigStackFrame = .{ ZigStackFrame.Zero, ZigStackFrame.Zero };
    var trace = ZigStackTrace.fromFrames(buf[0..]);
    try std.testing.expectEqual(@as(usize, 2), trace.frames().len);
    try std.testing.expectEqual(@as(usize, 2), trace.framesMutable().len);
}

test "ZigStackTrace is an extern struct with the expected field order" {
    const info = @typeInfo(ZigStackTrace).@"struct";
    try std.testing.expect(info.layout == .@"extern");
    try std.testing.expectEqualStrings("source_lines_ptr", info.fields[0].name);
    try std.testing.expectEqualStrings("source_lines_numbers", info.fields[1].name);
    try std.testing.expectEqualStrings("source_lines_len", info.fields[2].name);
    try std.testing.expectEqualStrings("source_lines_to_collect", info.fields[3].name);
    try std.testing.expectEqualStrings("frames_ptr", info.fields[4].name);
    try std.testing.expectEqualStrings("frames_len", info.fields[5].name);
    try std.testing.expectEqualStrings("frames_cap", info.fields[6].name);
    try std.testing.expectEqualStrings("referenced_source_provider", info.fields[7].name);
}
