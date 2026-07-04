// Home Runtime — formatting helpers.
//
// Mirrors the small subset of Bun's `fmt` namespace that the copied
// source needs. Coverage grows as more files land.

const std = @import("std");
pub const formatJSONStringUTF8 = @import("bun_core/fmt.zig").formatJSONStringUTF8;
pub const fmtSlice = @import("bun_core/fmt.zig").fmtSlice;

const strings = @import("strings.zig");
const bun = @import("home");

/// Faithful to upstream `bun_core/fmt.zig:214`.
const JSONFormatter = struct {
    input: []const u8,

    pub fn format(self: JSONFormatter, writer: *std.Io.Writer) !void {
        try bun.js_printer.writeJSONString(self.input, @TypeOf(writer), writer, .latin1);
    }
};

/// Expects latin1. Faithful to upstream `bun_core/fmt.zig:240`.
pub fn formatJSONStringLatin1(text: []const u8) JSONFormatter {
    return .{ .input = text };
}

/// Faithful to upstream `bun_core/fmt.zig:1361`. Formats an IP address to a bare
/// Node-style presentation string (no `:port`, no IPv6 brackets) by formatting
/// then stripping. `address` is Home's `net.Address` shim (backed by std.Io.net).
pub fn formatIp(address: bun.net.Address, into: []u8) ![]u8 {
    var result = try std.fmt.bufPrint(into, "{f}", .{address});

    // Strip `:<port>`
    if (std.mem.lastIndexOfScalar(u8, result, ':')) |colon| {
        result = result[0..colon];
    }
    // Strip brackets
    if (result[0] == '[' and result[result.len - 1] == ']') {
        result = result[1 .. result.len - 1];
    }
    return result;
}

/// `std.fmt` formatter that prints a quoted string with backslash escapes.
/// Used by Bun source as `bun.fmt.quote(some_string)` -> `"...escaped..."`.
pub const QuotedFormatter = struct {
    text: []const u8,

    pub fn format(self: QuotedFormatter, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeByte('"');
        for (self.text) |c| switch (c) {
            '\\' => try writer.writeAll("\\\\"),
            '"' => try writer.writeAll("\\\""),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(c),
        };
        try writer.writeByte('"');
    }
};

pub fn quote(text: []const u8) QuotedFormatter {
    return .{ .text = text };
}

pub fn githubActionWriter(writer: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    for (text) |c| switch (c) {
        '\n' => try writer.writeAll("%0A"),
        '\r' => try writer.writeAll("%0D"),
        ':' => try writer.writeAll("%3A"),
        else => try writer.writeByte(c),
    };
}

const lower_hex_table = [_]u8{ '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f' };
const upper_hex_table = [_]u8{ '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'A', 'B', 'C', 'D', 'E', 'F' };

/// Lowercase / uppercase hex-int formatter. Used by Bun's source as
/// `bun.fmt.hexIntLower(value)` to print things like ETag hashes, npm cache
/// keys, and sourcemap debug IDs. Faithful to upstream `bun_core/fmt.zig` —
/// zero-pads to the value type's full nibble width (`@bitSizeOf(Int)/4`), which
/// the earlier Home `{x}`/`{X}` shim did NOT, breaking e.g. `Bun.color(x,"hex")`
/// (u8 → 2 digits) and 32-char sourcemap debug IDs with leading zeros.
pub fn HexIntFormatter(comptime Int: type, comptime lower: bool) type {
    return struct {
        value: Int,

        const table = if (lower) lower_hex_table else upper_hex_table;

        const BufType = [@bitSizeOf(Int) / 4]u8;

        fn getOutBuf(value: Int) BufType {
            var buf: BufType = undefined;
            inline for (&buf, 0..) |*c, i| {
                // value relative to the current nibble
                c.* = table[@as(u8, @as(u4, @truncate(value >> comptime ((buf.len - i - 1) * 4)))) & 0xF];
            }
            return buf;
        }

        pub fn format(self: @This(), writer: *std.Io.Writer) !void {
            const value = self.value;
            try writer.writeAll(&getOutBuf(value));
        }
    };
}

pub fn hexIntLower(value: anytype) HexIntFormatter(@TypeOf(value), true) {
    const Formatter = HexIntFormatter(@TypeOf(value), true);
    return Formatter{ .value = value };
}

/// Equivalent to `{d:.<precision>}` but trims trailing zeros from the
/// fractional part. Faithful to upstream `bun_core/fmt.zig:1560`.
fn TrimmedPrecisionFormatter(comptime precision: usize) type {
    return struct {
        num: f64,
        precision: usize,

        pub fn format(self: @This(), writer: *std.Io.Writer) !void {
            const whole = @trunc(self.num);
            try writer.print("{d}", .{whole});
            const rem = self.num - whole;
            if (rem != 0) {
                var buf: [2 + precision]u8 = undefined;
                var formatted = std.fmt.bufPrint(&buf, "{d:." ++ std.fmt.comptimePrint("{d}", .{precision}) ++ "}", .{rem}) catch unreachable;
                formatted = formatted[2..];
                var trimmed_len = formatted.len;
                while (trimmed_len > 0 and formatted[trimmed_len - 1] == '0') {
                    trimmed_len -= 1;
                }
                const trimmed = formatted[0..trimmed_len];
                try writer.print(".{s}", .{trimmed});
            }
        }
    };
}

pub fn trimmedPrecision(value: f64, comptime precision: usize) TrimmedPrecisionFormatter(precision) {
    const Formatter = TrimmedPrecisionFormatter(precision);
    return Formatter{ .num = value, .precision = precision };
}

/// Re-export of the URL formatter (bun.fmt.URLFormatter) for server code.
pub const URLFormatter = @import("bun_core/fmt.zig").URLFormatter;

pub fn hexIntUpper(value: anytype) HexIntFormatter(@TypeOf(value), false) {
    const Formatter = HexIntFormatter(@TypeOf(value), false);
    return Formatter{ .value = value };
}

pub const DurationOneDecimalFormatter = struct {
    ns: u64,

    pub fn format(self: DurationOneDecimalFormatter, writer: *std.Io.Writer) !void {
        if (self.ns >= std.time.ns_per_s) {
            try writer.print("{d:.1}s", .{@as(f64, @floatFromInt(self.ns)) / @as(f64, @floatFromInt(std.time.ns_per_s))});
        } else {
            try writer.print("{d:.1}ms", .{@as(f64, @floatFromInt(self.ns)) / @as(f64, @floatFromInt(std.time.ns_per_ms))});
        }
    }
};

pub fn fmtDurationOneDecimal(ns: u64) DurationOneDecimalFormatter {
    return .{ .ns = ns };
}

pub fn fastDigitCount(value: anytype) u64 {
    var n: u64 = @intCast(value);
    var count: u64 = 1;
    while (n >= 10) : (count += 1) {
        n /= 10;
    }
    return count;
}

pub const QuickAndDirtyJavaScriptSyntaxHighlighter = struct {
    text: []const u8,
    opts: Options,

    pub const Options = struct {
        enable_colors: bool = false,
        // Accepted for source-compatibility with bun_core/fmt.zig's richer
        // highlighter (the markdown ANSI renderer passes this). This stub
        // does not syntax-highlight, so the flag has no effect here.
        check_for_unhighlighted_write: bool = false,
        redact_sensitive_information: bool = false,
    };

    pub fn format(self: QuickAndDirtyJavaScriptSyntaxHighlighter, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        _ = self.opts;
        try writer.writeAll(self.text);
    }
};

pub fn fmtJavaScript(text: []const u8, opts: QuickAndDirtyJavaScriptSyntaxHighlighter.Options) QuickAndDirtyJavaScriptSyntaxHighlighter {
    return .{ .text = text, .opts = opts };
}

pub fn truncatedHash32(int: u64) std.fmt.Alt(u64, truncatedHash32Impl) {
    return .{ .data = int };
}

fn truncatedHash32Impl(int: u64, writer: *std.Io.Writer) !void {
    const in_bytes = std.mem.asBytes(&int);
    const chars = "0123456789abcdefghjkmnpqrstvwxyz";
    try writer.writeAll(&.{
        chars[in_bytes[0] & 31],
        chars[in_bytes[1] & 31],
        chars[in_bytes[2] & 31],
        chars[in_bytes[3] & 31],
        chars[in_bytes[4] & 31],
        chars[in_bytes[5] & 31],
        chars[in_bytes[6] & 31],
        chars[in_bytes[7] & 31],
    });
}

pub fn fmtIdentifier(name: []const u8) FormatValidIdentifier {
    return .{ .name = name };
}

pub const FormatValidIdentifier = struct {
    name: []const u8,

    pub fn format(self: FormatValidIdentifier, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        var iterator = strings.CodepointIterator.init(self.name);
        var cursor = strings.CodepointIterator.Cursor{};

        if (self.name.len == 0) {
            try writer.writeByte('_');
            return;
        }

        _ = iterator.next(&cursor);
        var needs_gap = !isIdentifierStart(cursor.c);
        var start_i: usize = 0;

        if (!needs_gap) {
            while (iterator.next(&cursor)) {
                if (!isIdentifierContinue(cursor.c) or cursor.width > 1) {
                    needs_gap = true;
                    start_i = cursor.i;
                    break;
                }
            }
        }

        if (!needs_gap) {
            try writer.writeAll(self.name);
            return;
        }

        needs_gap = false;
        if (start_i > 0) try writer.writeAll(self.name[0..start_i]);

        const slice = self.name[start_i..];
        iterator = strings.CodepointIterator.init(slice);
        cursor = strings.CodepointIterator.Cursor{};
        while (iterator.next(&cursor)) {
            if (isIdentifierContinue(cursor.c) and cursor.width == 1) {
                if (needs_gap) {
                    try writer.writeByte('_');
                    needs_gap = false;
                }
                try writer.writeAll(slice[cursor.i..][0..cursor.width]);
            } else if (!needs_gap) {
                needs_gap = true;
            }
        }

        if (needs_gap) {
            try writer.writeByte('_');
        }
    }
};

fn isIdentifierStart(codepoint: i32) bool {
    return switch (codepoint) {
        'A'...'Z', 'a'...'z', '_', '$' => true,
        else => codepoint >= 0x80,
    };
}

fn isIdentifierContinue(codepoint: i32) bool {
    return isIdentifierStart(codepoint) or switch (codepoint) {
        '0'...'9' => true,
        else => false,
    };
}

/// Faithful to upstream `bun_core/fmt.zig:1670`.
pub fn double(number: f64) FormatDouble {
    return .{ .number = number };
}

pub const FormatLatin1 = struct {
    text: []const u8,

    pub fn format(self: FormatLatin1, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll(self.text);
    }
};

pub fn latin1(text: []const u8) FormatLatin1 {
    return .{ .text = text };
}

pub fn formatLatin1(text: []const u8, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.writeAll(text);
}

pub inline fn utf16(slice: []const u16) FormatUTF16 {
    return .{ .buf = slice };
}

pub const FormatUTF16 = struct {
    buf: []const u16,
    path_fmt_opts: ?PathFormatOptions = null,

    pub fn format(self: FormatUTF16, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.path_fmt_opts) |opts| {
            try formatUTF16TypeWithPathOptions(self.buf, writer, opts);
            return;
        }

        try formatUTF16Type(self.buf, writer);
    }
};

pub const FormatUTF8 = struct {
    buf: []const u8,
    path_fmt_opts: ?PathFormatOptions = null,

    pub fn format(self: FormatUTF8, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.path_fmt_opts) |opts| {
            try formatPathBytes(self.buf, writer, opts);
            return;
        }

        try writer.writeAll(self.buf);
    }
};

pub const PathFormatOptions = struct {
    path_sep: Sep = .any,
    escape_backslashes: bool = false,

    pub const Sep = enum {
        any,
        auto,
        posix,
        windows,
    };
};

pub const FormatOSPath = if (bun.Environment.isWindows) FormatUTF16 else FormatUTF8;

pub fn fmtOSPath(buf: bun.OSPathSlice, options: PathFormatOptions) FormatOSPath {
    return .{
        .buf = buf,
        .path_fmt_opts = options,
    };
}

pub fn fmtPath(
    comptime T: type,
    path: []const T,
    options: PathFormatOptions,
) if (T == u8) FormatUTF8 else FormatUTF16 {
    if (T == u8) {
        return .{
            .buf = path,
            .path_fmt_opts = options,
        };
    }

    return .{
        .buf = path,
        .path_fmt_opts = options,
    };
}

pub const HostFormatter = struct {
    host: []const u8,
    port: ?u16 = null,
    is_https: bool = false,

    pub fn format(self: HostFormatter, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll(self.host);
        const is_port_optional = self.port == null or
            (self.is_https and self.port.? == 443) or
            (!self.is_https and self.port.? == 80);
        if (!is_port_optional) try writer.print(":{d}", .{self.port.?});
    }
};

pub const SizeFormatter = struct {
    value: usize = 0,
    opts: Options = .{},

    pub const Options = struct {
        space_between_number_and_unit: bool = true,
    };

    pub fn format(self: SizeFormatter, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const suffixes = " KMGTPE";
        if (self.value == 0) {
            return if (self.opts.space_between_number_and_unit) writer.writeAll("0 KB") else writer.writeAll("0KB");
        }
        if (self.value < 512) {
            if (self.opts.space_between_number_and_unit) {
                return writer.print("{d} bytes", .{self.value});
            }
            return writer.print("{d}B", .{self.value});
        }

        var value: f64 = @floatFromInt(self.value);
        var suffix_index: usize = 0;
        while (value >= 1000.0 and suffix_index + 1 < suffixes.len) : (suffix_index += 1) {
            value /= 1000.0;
        }
        if (suffixes[suffix_index] == ' ') {
            value /= 1000.0;
            suffix_index = 1;
        }
        if (self.opts.space_between_number_and_unit) {
            try writer.print("{d:.2} {c}B", .{ value, suffixes[suffix_index] });
        } else {
            try writer.print("{d:.2}{c}B", .{ value, suffixes[suffix_index] });
        }
    }
};

pub fn size(bytes: anytype, opts: SizeFormatter.Options) SizeFormatter {
    return .{
        .value = switch (@typeInfo(@TypeOf(bytes))) {
            .float, .comptime_float => @intFromFloat(@max(bytes, 0)),
            .int, .comptime_int => @intCast(@max(bytes, 0)),
            else => @intCast(bytes),
        },
        .opts = opts,
    };
}

pub const OutOfRangeOptions = struct {
    min: i64 = std.math.maxInt(i64),
    max: i64 = std.math.maxInt(i64),
    field_name: []const u8,
    msg: []const u8 = "",
};

pub fn outOfRange(value: anytype, options: OutOfRangeOptions) OutOfRangeFormatter(@TypeOf(value)) {
    return .{ .value = value, .options = options };
}

pub fn OutOfRangeFormatter(comptime T: type) type {
    return struct {
        value: T,
        options: OutOfRangeOptions,

        // Faithful to Bun's `NewOutOfRangeFormatter` (src/bun_core/fmt.zig).
        // The previous version printed `Received {d}` unconditionally, which
        // fails to compile for `bun.String`/`[]const u8`/`f64` values and
        // produced the wrong message text for the min-only / max-only / msg
        // cases that the node error corpus checks verbatim.
        pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
            const min = self.options.min;
            const max = self.options.max;
            const msg = self.options.msg;

            if (self.options.field_name.len > 0) {
                try writer.writeAll("The value of \"");
                try writer.writeAll(self.options.field_name);
                try writer.writeAll("\" is out of range. It must be ");
            } else {
                try writer.writeAll("The value is out of range. It must be ");
            }

            if (min != std.math.maxInt(i64) and max != std.math.maxInt(i64)) {
                try writer.print(">= {d} and <= {d}.", .{ min, max });
            } else if (min != std.math.maxInt(i64)) {
                try writer.print(">= {d}.", .{min});
            } else if (max != std.math.maxInt(i64)) {
                try writer.print("<= {d}.", .{max});
            } else if (msg.len > 0) {
                try writer.writeAll(msg);
                try writer.writeByte('.');
            } else {
                try writer.writeAll("within the range of values for type ");
                try writer.writeAll(comptime @typeName(T));
                try writer.writeAll(".");
            }

            if (comptime T == f64 or T == f32) {
                try writer.print(" Received {f}", .{double(self.value)});
            } else if (comptime T == []const u8) {
                try writer.print(" Received {s}", .{self.value});
            } else if (comptime std.meta.hasFn(T, "format")) {
                try writer.print(" Received {f}", .{self.value});
            } else {
                try writer.print(" Received {}", .{self.value});
            }
        }
    };
}

/// Faithful to upstream `bun_core/fmt.zig:257`. Streams a UTF-16 slice to the
/// writer as UTF-8 in chunks. Bun reuses a shared temp buffer with recursion
/// guards; Home uses a fixed stack chunk — identical observable behavior.
pub fn formatUTF16Type(slice_: []const u16, writer: *std.Io.Writer) !void {
    var chunk: [256]u8 = undefined;
    var slice = slice_;
    while (slice.len > 0) {
        const result = strings.copyUTF16IntoUTF8(&chunk, slice);
        if (result.read == 0 or result.written == 0)
            break;
        try writer.writeAll(chunk[0..result.written]);
        slice = slice[result.read..];
    }
}

pub fn formatUTF16TypeWithPathOptions(slice_: []const u16, writer: *std.Io.Writer, opts: PathFormatOptions) !void {
    var chunk: [256]u8 = undefined;
    var slice = slice_;
    while (slice.len > 0) {
        const result = strings.copyUTF16IntoUTF8(&chunk, slice);
        if (result.read == 0 or result.written == 0)
            break;
        try formatPathBytes(chunk[0..result.written], writer, opts);
        slice = slice[result.read..];
    }
}

fn formatPathBytes(bytes: []const u8, writer: *std.Io.Writer, opts: PathFormatOptions) std.Io.Writer.Error!void {
    if (opts.path_sep == .any and !opts.escape_backslashes) {
        try writer.writeAll(bytes);
        return;
    }

    var ptr = bytes;
    while (strings.indexOfAny(ptr, "\\/")) |i| {
        const sep: u8 = switch (opts.path_sep) {
            .windows => '\\',
            .posix => '/',
            .auto => std.fs.path.sep,
            .any => ptr[i],
        };
        try writer.writeAll(ptr[0..i]);
        try writer.writeByte(sep);
        if (opts.escape_backslashes and sep == '\\') {
            try writer.writeByte(sep);
        }
        ptr = ptr[i + 1 ..];
    }

    try writer.writeAll(ptr);
}

pub const FormatDouble = struct {
    number: f64,

    pub fn dtoa(buf: *[124]u8, number: f64) []const u8 {
        // JS `Number.prototype.toString` representation of the non-finite
        // values — JS (and Node's error messages) use "NaN"/"Infinity"/
        // "-Infinity".
        if (std.math.isNan(number)) return "NaN";
        if (std.math.isInf(number)) return if (number < 0) "-Infinity" else "Infinity";
        // Finite numbers go through WebKit's `WTF::dtoa` (the same shortest
        // round-trip + ECMAScript exponential formatting JSC uses for
        // `Number.prototype.toString`), matching upstream `bun_core/fmt.zig`.
        // Zig's `{d}` instead expands `1.7976931348623157e+308` and `5e-324`
        // to hundreds of digits, diverging from JS/Bun.
        const len = bun.cpp.WTF__dtoa(&buf.ptr[0], number);
        return buf[0..len];
    }

    pub fn dtoaWithNegativeZero(buf: *[124]u8, number: f64) []const u8 {
        if (std.math.isNegativeZero(number)) return "-0";
        return dtoa(buf, number);
    }

    pub fn format(self: FormatDouble, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        var buf: [124]u8 = undefined;
        try writer.writeAll(dtoa(&buf, self.number));
    }
};

test "hexIntLower prints lowercase hex" {
    var buf: [32]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try writer.print("{f}", .{hexIntLower(@as(u32, 0xdeadbeef))});
    try std.testing.expectEqualStrings("deadbeef", writer.buffered());
}

test "hexIntUpper prints uppercase hex" {
    var buf: [32]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try writer.print("{f}", .{hexIntUpper(@as(u32, 0xCAFE))});
    // Zero-padded to the u32 nibble width (8 digits), matching upstream.
    try std.testing.expectEqualStrings("0000CAFE", writer.buffered());
}

test "quote escapes the standard control characters" {
    var buf: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try writer.print("{f}", .{quote("hello\nworld")});
    try std.testing.expectEqualStrings("\"hello\\nworld\"", writer.buffered());
}

test "quote escapes embedded quotes and backslashes" {
    var buf: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try writer.print("{f}", .{quote("a\"b\\c")});
    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\"", writer.buffered());
}

test "fmtIdentifier folds invalid separators into gaps" {
    var buf: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try writer.print("{f}", .{fmtIdentifier("pkg-name/file.ts")});
    try std.testing.expectEqualStrings("pkg_name_file_ts", writer.buffered());
}

test "FormatDouble dtoa writes a finite value" {
    var buf: [124]u8 = undefined;
    try std.testing.expectEqualStrings("1.5", FormatDouble.dtoa(&buf, 1.5));
}

test "FormatDouble dtoa uses JS spelling for non-finite values" {
    var buf: [124]u8 = undefined;
    try std.testing.expectEqualStrings("Infinity", FormatDouble.dtoa(&buf, std.math.inf(f64)));
    try std.testing.expectEqualStrings("-Infinity", FormatDouble.dtoa(&buf, -std.math.inf(f64)));
    try std.testing.expectEqualStrings("NaN", FormatDouble.dtoa(&buf, std.math.nan(f64)));
}

test "outOfRange formats an integer received value with min and max" {
    var buf: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try writer.print("{f}", .{outOfRange(@as(i64, 99), .{ .field_name = "mode", .min = 1, .max = 7 })});
    try std.testing.expectEqualStrings(
        "The value of \"mode\" is out of range. It must be >= 1 and <= 7. Received 99",
        writer.buffered(),
    );
}

test "outOfRange formats a []const u8 received value (bigint-as-string path)" {
    var buf: [160]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try writer.print("{f}", .{outOfRange(@as([]const u8, "99999999999999999999"), .{ .field_name = "position", .min = -1, .max = 100 })});
    try std.testing.expectEqualStrings(
        "The value of \"position\" is out of range. It must be >= -1 and <= 100. Received 99999999999999999999",
        writer.buffered(),
    );
}

test "outOfRange formats a float received value" {
    var buf: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try writer.print("{f}", .{outOfRange(@as(f64, 1.5), .{ .field_name = "length", .min = 0 })});
    try std.testing.expectEqualStrings(
        "The value of \"length\" is out of range. It must be >= 0. Received 1.5",
        writer.buffered(),
    );
}

test "outOfRange uses the msg branch when no min or max is set" {
    var buf: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try writer.print("{f}", .{outOfRange(@as(f64, 2.5), .{ .field_name = "length", .msg = "an integer" })});
    try std.testing.expectEqualStrings(
        "The value of \"length\" is out of range. It must be an integer. Received 2.5",
        writer.buffered(),
    );
}
