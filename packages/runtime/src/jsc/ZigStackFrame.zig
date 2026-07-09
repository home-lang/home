// Copied from bun/src/jsc/ZigStackFrame.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// Structural port. Upstream extern struct layout (function_name, source_url,
// position, code_type, is_async, remapped, jsc_stack_frame_index) is kept
// byte-for-byte so the C++ side keeps passing/returning frames unchanged.
//
// Re-attached 2026-06-23: the full SourceURLFormatter / NameFormatter now that
// home_rt exposes Output.prettyFmt, the strings path helpers, and url.URL. The
// earlier stub formatters dropped the ":line:col" suffix and the <anonymous> /
// async / new / eval name decoration, so stack traces printed "at fn (file)"
// instead of upstream's "at fn (file:line:col)".
//
// `toAPI` (projects into bun.schema.api.StackFrame) is still omitted; it
// re-lands with the bindgen IPC payload type.

const std = @import("std");
const ZigURL = @import("../url/url.zig").URL;

const bun = @import("home");
const Output = bun.Output;
const String = @import("home").String;
const strings = bun.strings;
const string = []const u8;

const ZigStackFrameCode = @import("ZigStackFrameCode.zig").ZigStackFrameCode;
const ZigStackFramePosition = @import("ZigStackFramePosition.zig").ZigStackFramePosition;

/// Represents a single frame in a stack trace
pub const ZigStackFrame = extern struct {
    function_name: String,
    source_url: String,
    position: ZigStackFramePosition,
    code_type: ZigStackFrameCode,
    is_async: bool,

    /// This informs formatters whether to display as a blob URL or not
    remapped: bool = false,

    /// -1 means not set.
    jsc_stack_frame_index: i32 = -1,

    pub fn deinit(this: *ZigStackFrame) void {
        this.function_name.deref();
        this.source_url.deref();
    }

    pub const Zero: ZigStackFrame = .{
        .function_name = .empty,
        .code_type = .None,
        .source_url = .empty,
        .position = .invalid,
        .is_async = false,
        .jsc_stack_frame_index = -1,
    };

    pub const SourceURLFormatter = struct {
        source_url: bun.String,
        position: ZigStackFramePosition,
        enable_color: bool,
        origin: ?*const ZigURL,
        exclude_line_column: bool = false,
        remapped: bool = false,
        root_path: string = "",

        pub fn format(this: SourceURLFormatter, writer: *std.Io.Writer) !void {
            if (this.enable_color) {
                try writer.writeAll(Output.prettyFmt("<r><cyan>", true));
            }

            var source_slice_ = this.source_url.toUTF8(bun.default_allocator);
            var source_slice = source_slice_.slice();
            defer source_slice_.deinit();

            if (!this.remapped) {
                if (this.origin) |origin| {
                    try writer.writeAll(origin.displayProtocol());
                    try writer.writeAll("://");
                    try writer.writeAll(origin.displayHostname());
                    try writer.writeAll(":");
                    try writer.writeAll(origin.port);
                    try writer.writeAll("/blob:");

                    if (strings.startsWith(source_slice, this.root_path)) {
                        source_slice = source_slice[this.root_path.len..];
                    }
                }
                try writer.writeAll(source_slice);
            } else {
                if (this.enable_color) {
                    const not_root = if (comptime bun.Environment.isWindows) this.root_path.len > "C:\\".len else this.root_path.len > "/".len;
                    if (not_root and strings.startsWith(source_slice, this.root_path)) {
                        const root_path = strings.withoutTrailingSlash(this.root_path);
                        const relative_path = strings.withoutLeadingPathSeparator(source_slice[this.root_path.len..]);
                        try writer.writeAll(comptime Output.prettyFmt("<d>", true));
                        try writer.writeAll(root_path);
                        try writer.writeByte(std.fs.path.sep);
                        try writer.writeAll(comptime Output.prettyFmt("<r><cyan>", true));
                        try writer.writeAll(relative_path);
                    } else {
                        try writer.writeAll(source_slice);
                    }
                } else {
                    try writer.writeAll(source_slice);
                }
            }

            if (source_slice.len > 0 and (this.position.line.isValid() or this.position.column.isValid())) {
                if (this.enable_color) {
                    try writer.writeAll(comptime Output.prettyFmt("<r><d>:", true));
                } else {
                    try writer.writeAll(":");
                }
            }

            if (this.enable_color) {
                if (this.position.line.isValid() or this.position.column.isValid()) {
                    try writer.writeAll(comptime Output.prettyFmt("<r>", true));
                } else {
                    try writer.writeAll(comptime Output.prettyFmt("<r>", true));
                }
            }

            if (!this.exclude_line_column) {
                if (this.position.line.isValid() and this.position.column.isValid()) {
                    if (this.enable_color) {
                        try writer.print(
                            comptime Output.prettyFmt("<yellow>{d}<r><d>:<yellow>{d}<r>", true),
                            .{ this.position.line.oneBased(), this.position.column.oneBased() },
                        );
                    } else {
                        try writer.print("{d}:{d}", .{
                            this.position.line.oneBased(),
                            this.position.column.oneBased(),
                        });
                    }
                } else if (this.position.line.isValid()) {
                    if (this.enable_color) {
                        try writer.print(
                            comptime Output.prettyFmt("<yellow>{d}<r>", true),
                            .{
                                this.position.line.oneBased(),
                            },
                        );
                    } else {
                        try writer.print("{d}", .{
                            this.position.line.oneBased(),
                        });
                    }
                }
            }
        }
    };

    pub const NameFormatter = struct {
        function_name: String,
        code_type: ZigStackFrameCode,
        enable_color: bool,
        is_async: bool,

        pub fn format(this: NameFormatter, writer: *std.Io.Writer) !void {
            const name = this.function_name;

            switch (this.code_type) {
                .Eval => {
                    if (this.enable_color) {
                        try writer.print(comptime Output.prettyFmt("<r><d>", true) ++ "eval" ++ Output.prettyFmt("<r>", true), .{});
                    } else {
                        try writer.writeAll("eval");
                    }
                    if (!name.isEmpty()) {
                        if (this.enable_color) {
                            try writer.print(comptime Output.prettyFmt(" <r><b><i>{f}<r>", true), .{name});
                        } else {
                            try writer.print(" {f}", .{name});
                        }
                    }
                },
                .Function => {
                    if (!name.isEmpty()) {
                        if (this.enable_color) {
                            if (this.is_async) {
                                try writer.print(comptime Output.prettyFmt("<r><b><i>async {f}<r>", true), .{name});
                            } else {
                                try writer.print(comptime Output.prettyFmt("<r><b><i>{f}<r>", true), .{name});
                            }
                        } else {
                            if (this.is_async) {
                                try writer.print("async {f}", .{name});
                            } else {
                                try writer.print("{f}", .{name});
                            }
                        }
                    } else {
                        if (this.enable_color) {
                            if (this.is_async) {
                                try writer.print(comptime Output.prettyFmt("<r><d>", true) ++ "async <anonymous>" ++ Output.prettyFmt("<r>", true), .{});
                            } else {
                                try writer.print(comptime Output.prettyFmt("<r><d>", true) ++ "<anonymous>" ++ Output.prettyFmt("<r>", true), .{});
                            }
                        } else {
                            if (this.is_async) {
                                try writer.writeAll("async ");
                            }
                            try writer.writeAll("<anonymous>");
                        }
                    }
                },
                .Global => {},
                .Wasm => {
                    if (!name.isEmpty()) {
                        try writer.print("{f}", .{name});
                    } else {
                        try writer.writeAll("WASM");
                    }
                },
                .Constructor => {
                    try writer.print("new {f}", .{name});
                },
                else => {
                    if (!name.isEmpty()) {
                        try writer.print("{f}", .{name});
                    }
                },
            }
        }
    };

    pub fn nameFormatter(this: *const ZigStackFrame, comptime enable_color: bool) NameFormatter {
        return NameFormatter{ .function_name = this.function_name, .code_type = this.code_type, .enable_color = enable_color, .is_async = this.is_async };
    }

    pub fn sourceURLFormatter(this: *const ZigStackFrame, root_path: string, origin: ?*const ZigURL, exclude_line_column: bool, comptime enable_color: bool) SourceURLFormatter {
        return SourceURLFormatter{
            .source_url = this.source_url,
            .exclude_line_column = exclude_line_column,
            .origin = origin,
            .root_path = root_path,
            .position = this.position,
            .enable_color = enable_color,
            .remapped = this.remapped,
        };
    }
};

test "ZigStackFrame.Zero has expected defaults" {
    const f = ZigStackFrame.Zero;
    try std.testing.expect(f.function_name.isEmpty());
    try std.testing.expect(f.source_url.isEmpty());
    try std.testing.expectEqual(@as(i32, -1), f.jsc_stack_frame_index);
    try std.testing.expectEqual(@as(ZigStackFrameCode, .None), f.code_type);
    try std.testing.expectEqual(false, f.is_async);
    try std.testing.expectEqual(false, f.remapped);
}

test "ZigStackFrame is an extern struct with the expected field order" {
    const info = @typeInfo(ZigStackFrame).@"struct";
    try std.testing.expect(info.layout == .@"extern");
    try std.testing.expectEqualStrings("function_name", info.field_names[0]);
    try std.testing.expectEqualStrings("source_url", info.field_names[1]);
    try std.testing.expectEqualStrings("position", info.field_names[2]);
    try std.testing.expectEqualStrings("code_type", info.field_names[3]);
    try std.testing.expectEqualStrings("is_async", info.field_names[4]);
    try std.testing.expectEqualStrings("remapped", info.field_names[5]);
    try std.testing.expectEqualStrings("jsc_stack_frame_index", info.field_names[6]);
}
