//! A number as JavaScript's `Number.prototype.toString` writes it, which is
//! how TypeScript prints a number literal type and how it names a numeric
//! property key.

const std = @import("std");

/// Format `value` into `buf` the way JavaScript does:
///
/// - the shortest digits that round-trip
/// - exponent form for a magnitude of at least 1e21 or below 1e-6, with an
///   explicit `+` on a positive exponent
/// - `0` for `-0`, plus `NaN`, `Infinity` and `-Infinity`
///
/// A whole number up to 2^53 prints exactly. A larger one prints its
/// shortest digits padded with zeros: `2 ** 60` is `1152921504606847000`.
pub fn format(buf: []u8, value: f64) ![]const u8 {
    if (std.math.isNan(value)) return "NaN";
    if (std.math.isPositiveInf(value)) return "Infinity";
    if (std.math.isNegativeInf(value)) return "-Infinity";
    if (value == 0) return "0";

    const magnitude = @abs(value);
    if (magnitude >= 1e21 or magnitude < 1e-6) {
        var scientific_buf: [128]u8 = undefined;
        const scientific = try std.fmt.bufPrint(&scientific_buf, "{e}", .{value});
        const exponent = std.mem.indexOfScalar(u8, scientific, 'e') orelse
            return std.fmt.bufPrint(buf, "{s}", .{scientific});
        if (exponent + 1 < scientific.len and scientific[exponent + 1] != '-') {
            return std.fmt.bufPrint(buf, "{s}e+{s}", .{
                scientific[0..exponent],
                scientific[exponent + 1 ..],
            });
        }
        return std.fmt.bufPrint(buf, "{s}", .{scientific});
    }
    const max_exact: f64 = 9007199254740992; // 2^53
    if (@floor(value) == value and magnitude <= max_exact) {
        return std.fmt.bufPrint(buf, "{d}", .{@as(i64, @intFromFloat(value))});
    }
    return std.fmt.bufPrint(buf, "{d}", .{value});
}

test "number literal text matches JavaScript's Number.prototype.toString" {
    const cases = [_]struct { value: f64, text: []const u8 }{
        .{ .value = 1e21, .text = "1e+21" },
        .{ .value = -1e21, .text = "-1e+21" },
        .{ .value = 1.5e-7, .text = "1.5e-7" },
        .{ .value = -1e-7, .text = "-1e-7" },
        .{ .value = 1e-7, .text = "1e-7" },
        .{ .value = -2.5e-10, .text = "-2.5e-10" },
        .{ .value = 1.2345678901234567e-7, .text = "1.2345678901234566e-7" },
        .{ .value = 5e-324, .text = "5e-324" },
        .{ .value = 1.7976931348623157e308, .text = "1.7976931348623157e+308" },
        .{ .value = 1e300, .text = "1e+300" },
        .{ .value = 123456789012345680000.0, .text = "123456789012345680000" },
        .{ .value = 999999999999999900000.0, .text = "999999999999999900000" },
        .{ .value = 1e20, .text = "100000000000000000000" },
        .{ .value = 1152921504606846976, .text = "1152921504606847000" },
        .{ .value = 9007199254740994, .text = "9007199254740994" },
        .{ .value = 0.1, .text = "0.1" },
        .{ .value = 1e-6, .text = "0.000001" },
        .{ .value = 0.000012, .text = "0.000012" },
        .{ .value = 123.456, .text = "123.456" },
        .{ .value = 4.35, .text = "4.35" },
        .{ .value = 1.5, .text = "1.5" },
        .{ .value = 100, .text = "100" },
        .{ .value = -16, .text = "-16" },
        .{ .value = -0.0, .text = "0" },
        .{ .value = std.math.nan(f64), .text = "NaN" },
        .{ .value = std.math.inf(f64), .text = "Infinity" },
        .{ .value = -std.math.inf(f64), .text = "-Infinity" },
    };
    for (cases) |case| {
        var buf: [128]u8 = undefined;
        const text = try format(&buf, case.value);
        std.testing.expectEqualStrings(case.text, text) catch |err| {
            std.debug.print("value {e}\n", .{case.value});
            return err;
        };
    }
}
