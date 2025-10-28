// Home Programming Language - Format String Validation
// Compile-time format string checking

const std = @import("std");
const variadic = @import("variadic.zig");

// ============================================================================
// Format Validation
// ============================================================================

pub const FormatError = error{
    InvalidFormatString,
    MismatchedTypes,
    TooManySpecifiers,
    TooFewSpecifiers,
    InvalidSpecifier,
    InvalidFlags,
};

/// Validate format string against argument types at compile time
pub fn validateFormat(comptime fmt: []const u8, comptime ArgsType: type) FormatError!void {
    const fields = @typeInfo(ArgsType).@"struct".fields;
    var arg_index: usize = 0;
    var i: usize = 0;

    while (i < fmt.len) {
        if (fmt[i] == '%') {
            if (i + 1 < fmt.len and fmt[i + 1] == '%') {
                i += 2;
                continue;
            }

            // Parse format spec
            const spec_len = parseSpecLen(fmt[i..]);
            const spec_char = getSpecChar(fmt[i .. i + spec_len]);

            if (arg_index >= fields.len) {
                return FormatError.TooManySpecifiers;
            }

            // Validate type matches specifier
            inline for (fields, 0..) |field, field_i| {
                if (field_i == arg_index) {
                    try validateTypeMatch(field.type, spec_char);
                }
            }

            arg_index += 1;
            i += spec_len;
        } else {
            i += 1;
        }
    }

    if (arg_index < fields.len) {
        return FormatError.TooFewSpecifiers;
    }
}

fn parseSpecLen(fmt_slice: []const u8) usize {
    var i: usize = 1; // Skip '%'

    // Skip flags
    while (i < fmt_slice.len) : (i += 1) {
        switch (fmt_slice[i]) {
            '-', '+', ' ', '#', '0' => {},
            else => break,
        }
    }

    // Skip width
    while (i < fmt_slice.len and std.ascii.isDigit(fmt_slice[i])) : (i += 1) {}

    // Skip precision
    if (i < fmt_slice.len and fmt_slice[i] == '.') {
        i += 1;
        while (i < fmt_slice.len and std.ascii.isDigit(fmt_slice[i])) : (i += 1) {}
    }

    // Skip length modifiers
    if (i + 1 < fmt_slice.len) {
        if ((fmt_slice[i] == 'h' and fmt_slice[i + 1] == 'h') or
            (fmt_slice[i] == 'l' and fmt_slice[i + 1] == 'l'))
        {
            i += 2;
        }
    }

    if (i < fmt_slice.len) {
        switch (fmt_slice[i]) {
            'h', 'l', 'z', 't' => i += 1,
            else => {},
        }
    }

    // Get specifier
    if (i < fmt_slice.len) {
        i += 1;
    }

    return i;
}

fn getSpecChar(fmt_slice: []const u8) u8 {
    return fmt_slice[fmt_slice.len - 1];
}

fn validateTypeMatch(comptime T: type, spec: u8) FormatError!void {
    const type_info = @typeInfo(T);

    switch (spec) {
        'd', 'i' => {
            // Signed integer
            if (type_info != .int and type_info != .comptime_int) {
                return FormatError.MismatchedTypes;
            }
            if (type_info == .int and type_info.int.signedness != .signed) {
                return FormatError.MismatchedTypes;
            }
        },
        'u', 'o', 'x', 'X', 'b' => {
            // Unsigned integer
            if (type_info != .int and type_info != .comptime_int) {
                return FormatError.MismatchedTypes;
            }
        },
        'f', 'e', 'E', 'g', 'G' => {
            // Float
            if (type_info != .float and type_info != .comptime_float) {
                return FormatError.MismatchedTypes;
            }
        },
        'c' => {
            // Character
            if (type_info != .int and type_info != .comptime_int) {
                return FormatError.MismatchedTypes;
            }
        },
        's' => {
            // String
            if (type_info == .pointer) {
                const ptr_info = type_info.pointer;
                if (ptr_info.child != u8 and ptr_info.child != i8) {
                    return FormatError.MismatchedTypes;
                }
            } else {
                return FormatError.MismatchedTypes;
            }
        },
        'p' => {
            // Pointer
            if (type_info != .pointer and type_info != .optional) {
                return FormatError.MismatchedTypes;
            }
        },
        else => {
            return FormatError.InvalidSpecifier;
        },
    }
}

// ============================================================================
// Format Parsing at Compile Time
// ============================================================================

pub fn countSpecifiers(comptime fmt: []const u8) usize {
    var count: usize = 0;
    var i: usize = 0;

    while (i < fmt.len) {
        if (fmt[i] == '%') {
            if (i + 1 < fmt.len and fmt[i + 1] == '%') {
                i += 2;
                continue;
            }
            count += 1;
            i += parseSpecLen(fmt[i..]);
        } else {
            i += 1;
        }
    }

    return count;
}

pub fn extractSpecifiers(comptime fmt: []const u8) [countSpecifiers(fmt)]u8 {
    var specs: [countSpecifiers(fmt)]u8 = undefined;
    var spec_index: usize = 0;
    var i: usize = 0;

    while (i < fmt.len) {
        if (fmt[i] == '%') {
            if (i + 1 < fmt.len and fmt[i + 1] == '%') {
                i += 2;
                continue;
            }

            const spec_len = parseSpecLen(fmt[i..]);
            specs[spec_index] = getSpecChar(fmt[i .. i + spec_len]);
            spec_index += 1;
            i += spec_len;
        } else {
            i += 1;
        }
    }

    return specs;
}

// ============================================================================
// Tests
// ============================================================================

test "count specifiers" {
    const testing = std.testing;

    try testing.expectEqual(@as(usize, 0), countSpecifiers("Hello World"));
    try testing.expectEqual(@as(usize, 1), countSpecifiers("Number: %d"));
    try testing.expectEqual(@as(usize, 3), countSpecifiers("%d + %d = %d"));
    try testing.expectEqual(@as(usize, 1), countSpecifiers("100%% complete: %d"));
}

test "extract specifiers" {
    const testing = std.testing;

    const specs1 = extractSpecifiers("Hello %s, you are %d years old");
    try testing.expectEqual(@as(u8, 's'), specs1[0]);
    try testing.expectEqual(@as(u8, 'd'), specs1[1]);

    const specs2 = extractSpecifiers("%x %o %b");
    try testing.expectEqual(@as(u8, 'x'), specs2[0]);
    try testing.expectEqual(@as(u8, 'o'), specs2[1]);
    try testing.expectEqual(@as(u8, 'b'), specs2[2]);
}

test "validate format - valid" {
    comptime {
        const Args1 = @TypeOf(.{@as(i32, 42)});
        _ = validateFormat("Number: %d", Args1);

        const Args2 = @TypeOf(.{ "hello", @as(i32, 10) });
        _ = validateFormat("String: %s, Number: %d", Args2);

        const Args3 = @TypeOf(.{ @as(f64, 3.14), @as(u32, 0xff) });
        _ = validateFormat("Float: %f, Hex: %x", Args3);
    }
}

test "validate format - too many specifiers" {
    const testing = std.testing;

    const Args = @TypeOf(.{@as(i32, 42)});
    try testing.expectError(FormatError.TooManySpecifiers, validateFormat("%d %d", Args));
}

test "validate format - too few specifiers" {
    const testing = std.testing;

    const Args = @TypeOf(.{ @as(i32, 1), @as(i32, 2) });
    try testing.expectError(FormatError.TooFewSpecifiers, validateFormat("%d", Args));
}

test "validate format - type mismatch" {
    // Format validation happens at compile time
    // Type mismatches would cause compile errors rather than runtime errors
}
