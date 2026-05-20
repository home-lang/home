const std = @import("std");

pub const jsc = struct {
    pub const JSGlobalObject = opaque {};
    pub const JSValue = usize;
};

pub const JestPrettyFormat = struct {
    pub const FormatOptions = struct {
        enable_colors: bool,
        add_newline: bool,
        flush: bool,
        quote_strings: bool,
    };

    pub fn format(
        comptime _: anytype,
        _: *jsc.JSGlobalObject,
        _: [*]const jsc.JSValue,
        _: usize,
        writer: *std.Io.Writer,
        _: FormatOptions,
    ) !void {
        try writer.writeAll("<js-value>");
    }
};
