const std = @import("std");
const Type = @import("type_system.zig").Type;
const ast = @import("ast");

/// Overflow checking mode
pub const OverflowMode = enum(u8) {
    /// No overflow checking (unsafe, fast)
    Unchecked = 0,
    /// Runtime overflow checks (safe, some overhead)
    Runtime = 1,
    /// Compile-time overflow detection (safest)
    CompileTime = 2,
    /// Saturating arithmetic (clamp to min/max)
    Saturating = 3,
    /// Wrapping arithmetic (explicit wrap-around)
    Wrapping = 4,
};

/// Integer type information for overflow detection
pub const IntegerInfo = struct {
    is_signed: bool,
    bit_width: u16,
    min_value: i128,
    max_value: i128,

    pub fn fromType(typ: Type) ?IntegerInfo {
        return switch (typ) {
            .Int => .{
                .is_signed = true,
                .bit_width = 64,
                .min_value = std.math.minInt(i64),
                .max_value = std.math.maxInt(i64),
            },
            .U8 => .{
                .is_signed = false,
                .bit_width = 8,
                .min_value = 0,
                .max_value = 255,
            },
            .U16 => .{
                .is_signed = false,
                .bit_width = 16,
                .min_value = 0,
                .max_value = 65535,
            },
            .U32 => .{
                .is_signed = false,
                .bit_width = 32,
                .min_value = 0,
                .max_value = 4294967295,
            },
            .U64 => .{
                .is_signed = false,
                .bit_width = 64,
                .min_value = 0,
                .max_value = std.math.maxInt(i64), // Use i64 max for now
            },
            .I8 => .{
                .is_signed = true,
                .bit_width = 8,
                .min_value = -128,
                .max_value = 127,
            },
            .I16 => .{
                .is_signed = true,
                .bit_width = 16,
                .min_value = -32768,
                .max_value = 32767,
            },
            .I32 => .{
                .is_signed = true,
                .bit_width = 32,
                .min_value = -2147483648,
                .max_value = 2147483647,
            },
            .I64 => .{
                .is_signed = true,
                .bit_width = 64,
                .min_value = std.math.minInt(i64),
                .max_value = std.math.maxInt(i64),
            },
            else => null,
        };
    }

    /// Check if value is in range
    pub fn inRange(self: IntegerInfo, value: i128) bool {
        return value >= self.min_value and value <= self.max_value;
    }
};

/// Value range for static analysis
pub const ValueRange = struct {
    min: i128,
    max: i128,

    pub fn init(min: i128, max: i128) ValueRange {
        return .{ .min = min, .max = max };
    }

    pub fn fromConstant(value: i128) ValueRange {
        return .{ .min = value, .max = value };
    }

    pub fn full(int_info: IntegerInfo) ValueRange {
        return .{ .min = int_info.min_value, .max = int_info.max_value };
    }

    /// Check if range can overflow when added
    pub fn canOverflowAdd(self: ValueRange, other: ValueRange, int_info: IntegerInfo) bool {
        const min_sum = self.min + other.min;
        const max_sum = self.max + other.max;
        return min_sum < int_info.min_value or max_sum > int_info.max_value;
    }

    /// Check if range can overflow when subtracted
    pub fn canOverflowSub(self: ValueRange, other: ValueRange, int_info: IntegerInfo) bool {
        const min_diff = self.min - other.max;
        const max_diff = self.max - other.min;
        return min_diff < int_info.min_value or max_diff > int_info.max_value;
    }

    /// Check if range can overflow when multiplied
    pub fn canOverflowMul(self: ValueRange, other: ValueRange, int_info: IntegerInfo) bool {
        // Check all combinations of min/max
        const products = [4]i128{
            self.min * other.min,
            self.min * other.max,
            self.max * other.min,
            self.max * other.max,
        };

        for (products) |p| {
            if (p < int_info.min_value or p > int_info.max_value) {
                return true;
            }
        }
        return false;
    }

    /// Check if range can overflow when divided (division by zero)
    pub fn canOverflowDiv(self: ValueRange, other: ValueRange) bool {
        // Division can fail if divisor includes zero
        return other.min <= 0 and other.max >= 0;
    }

    /// Compute resulting range after addition
    pub fn add(self: ValueRange, other: ValueRange, int_info: IntegerInfo) ValueRange {
        const min_sum = @max(self.min + other.min, int_info.min_value);
        const max_sum = @min(self.max + other.max, int_info.max_value);
        return .{ .min = min_sum, .max = max_sum };
    }

    /// Compute resulting range after subtraction
    pub fn sub(self: ValueRange, other: ValueRange, int_info: IntegerInfo) ValueRange {
        const min_diff = @max(self.min - other.max, int_info.min_value);
        const max_diff = @min(self.max - other.min, int_info.max_value);
        return .{ .min = min_diff, .max = max_diff };
    }

    /// Compute resulting range after multiplication
    pub fn mul(self: ValueRange, other: ValueRange, int_info: IntegerInfo) ValueRange {
        const products = [4]i128{
            self.min * other.min,
            self.min * other.max,
            self.max * other.min,
            self.max * other.max,
        };

        var min_prod = int_info.max_value;
        var max_prod = int_info.min_value;

        for (products) |p| {
            min_prod = @min(min_prod, p);
            max_prod = @max(max_prod, p);
        }

        return .{
            .min = @max(min_prod, int_info.min_value),
            .max = @min(max_prod, int_info.max_value),
        };
    }
};

/// Overflow detection tracker
pub const OverflowTracker = struct {
    allocator: std.mem.Allocator,
    /// Default overflow mode
    default_mode: OverflowMode,
    /// Variable value ranges (for static analysis)
    var_ranges: std.StringHashMap(ValueRange),
    /// Detected overflow errors
    errors: std.ArrayList(OverflowError),
    /// Warnings
    warnings: std.ArrayList(OverflowWarning),

    pub fn init(allocator: std.mem.Allocator) OverflowTracker {
        return .{
            .allocator = allocator,
            .default_mode = .Runtime,
            .var_ranges = std.StringHashMap(ValueRange).init(allocator),
            .errors = std.ArrayList(OverflowError).init(allocator),
            .warnings = std.ArrayList(OverflowWarning).init(allocator),
        };
    }

    pub fn deinit(self: *OverflowTracker) void {
        self.var_ranges.deinit();
        self.errors.deinit();
        self.warnings.deinit();
    }

    pub fn setMode(self: *OverflowTracker, mode: OverflowMode) void {
        self.default_mode = mode;
    }

    /// Set value range for a variable
    pub fn setRange(self: *OverflowTracker, var_name: []const u8, range: ValueRange) !void {
        try self.var_ranges.put(var_name, range);
    }

    /// Get value range for a variable
    pub fn getRange(self: *OverflowTracker, var_name: []const u8) ?ValueRange {
        return self.var_ranges.get(var_name);
    }

    /// Check addition for potential overflow
    pub fn checkAdd(
        self: *OverflowTracker,
        left: ValueRange,
        right: ValueRange,
        result_type: Type,
        loc: ast.SourceLocation,
    ) !ValueRange {
        const int_info = IntegerInfo.fromType(result_type) orelse {
            return ValueRange.init(0, 0);
        };

        if (left.canOverflowAdd(right, int_info)) {
            if (self.default_mode == .CompileTime or self.default_mode == .Runtime) {
                try self.addError(.{
                    .kind = .Addition,
                    .message = try std.fmt.allocPrint(
                        self.allocator,
                        "Potential overflow in addition: [{}, {}] + [{}, {}] may exceed {s} range",
                        .{ left.min, left.max, right.min, right.max, @tagName(result_type) },
                    ),
                    .location = loc,
                    .operation = .Addition,
                });
            } else {
                try self.addWarning(.{
                    .message = try std.fmt.allocPrint(
                        self.allocator,
                        "Potential overflow in addition (unchecked mode)",
                        .{},
                    ),
                    .location = loc,
                });
            }
        }

        return left.add(right, int_info);
    }

    /// Check subtraction for potential overflow
    pub fn checkSub(
        self: *OverflowTracker,
        left: ValueRange,
        right: ValueRange,
        result_type: Type,
        loc: ast.SourceLocation,
    ) !ValueRange {
        const int_info = IntegerInfo.fromType(result_type) orelse {
            return ValueRange.init(0, 0);
        };

        if (left.canOverflowSub(right, int_info)) {
            if (self.default_mode == .CompileTime or self.default_mode == .Runtime) {
                try self.addError(.{
                    .kind = .Subtraction,
                    .message = try std.fmt.allocPrint(
                        self.allocator,
                        "Potential overflow in subtraction: [{}, {}] - [{}, {}] may exceed {s} range",
                        .{ left.min, left.max, right.min, right.max, @tagName(result_type) },
                    ),
                    .location = loc,
                    .operation = .Subtraction,
                });
            }
        }

        return left.sub(right, int_info);
    }

    /// Check multiplication for potential overflow
    pub fn checkMul(
        self: *OverflowTracker,
        left: ValueRange,
        right: ValueRange,
        result_type: Type,
        loc: ast.SourceLocation,
    ) !ValueRange {
        const int_info = IntegerInfo.fromType(result_type) orelse {
            return ValueRange.init(0, 0);
        };

        if (left.canOverflowMul(right, int_info)) {
            if (self.default_mode == .CompileTime or self.default_mode == .Runtime) {
                try self.addError(.{
                    .kind = .Multiplication,
                    .message = try std.fmt.allocPrint(
                        self.allocator,
                        "Potential overflow in multiplication: [{}, {}] * [{}, {}] may exceed {s} range",
                        .{ left.min, left.max, right.min, right.max, @tagName(result_type) },
                    ),
                    .location = loc,
                    .operation = .Multiplication,
                });
            }
        }

        return left.mul(right, int_info);
    }

    /// Check division for potential errors
    pub fn checkDiv(
        self: *OverflowTracker,
        left: ValueRange,
        right: ValueRange,
        loc: ast.SourceLocation,
    ) !void {
        if (right.canOverflowDiv(left)) {
            try self.addError(.{
                .kind = .DivisionByZero,
                .message = try std.fmt.allocPrint(
                    self.allocator,
                    "Potential division by zero: divisor range [{}, {}] includes zero",
                    .{ right.min, right.max },
                ),
                .location = loc,
                .operation = .Division,
            });
        }
    }

    /// Check cast for potential truncation
    pub fn checkCast(
        self: *OverflowTracker,
        value_range: ValueRange,
        source_type: Type,
        target_type: Type,
        loc: ast.SourceLocation,
    ) !void {
        const target_info = IntegerInfo.fromType(target_type) orelse return;

        if (value_range.min < target_info.min_value or value_range.max > target_info.max_value) {
            try self.addError(.{
                .kind = .Truncation,
                .message = try std.fmt.allocPrint(
                    self.allocator,
                    "Potential truncation in cast from {s} to {s}: range [{}, {}] exceeds target range",
                    .{ @tagName(source_type), @tagName(target_type), value_range.min, value_range.max },
                ),
                .location = loc,
                .operation = .Cast,
            });
        }
    }

    fn addError(self: *OverflowTracker, err: OverflowError) !void {
        try self.errors.append(err);
    }

    fn addWarning(self: *OverflowTracker, warning: OverflowWarning) !void {
        try self.warnings.append(warning);
    }

    pub fn hasErrors(self: *OverflowTracker) bool {
        return self.errors.items.len > 0;
    }
};

/// Overflow error
pub const OverflowError = struct {
    kind: OperationKind,
    message: []const u8,
    location: ast.SourceLocation,
    operation: OperationKind,

    pub const OperationKind = enum {
        Addition,
        Subtraction,
        Multiplication,
        Division,
        DivisionByZero,
        Truncation,
        Cast,
        Negation,
        ShiftLeft,
        ShiftRight,
    };
};

/// Overflow warning
pub const OverflowWarning = struct {
    message: []const u8,
    location: ast.SourceLocation,
};

// ============================================================================
// Runtime Overflow Checking Utilities
// ============================================================================

pub const RuntimeChecks = struct {
    /// Checked addition
    pub fn addChecked(comptime T: type, a: T, b: T) !T {
        const result = @addWithOverflow(a, b);
        if (result[1] != 0) {
            return error.Overflow;
        }
        return result[0];
    }

    /// Checked subtraction
    pub fn subChecked(comptime T: type, a: T, b: T) !T {
        const result = @subWithOverflow(a, b);
        if (result[1] != 0) {
            return error.Overflow;
        }
        return result[0];
    }

    /// Checked multiplication
    pub fn mulChecked(comptime T: type, a: T, b: T) !T {
        const result = @mulWithOverflow(a, b);
        if (result[1] != 0) {
            return error.Overflow;
        }
        return result[0];
    }

    /// Saturating addition
    pub fn addSaturating(comptime T: type, a: T, b: T) T {
        const result = @addWithOverflow(a, b);
        if (result[1] != 0) {
            return if (b > 0) std.math.maxInt(T) else std.math.minInt(T);
        }
        return result[0];
    }

    /// Saturating subtraction
    pub fn subSaturating(comptime T: type, a: T, b: T) T {
        const result = @subWithOverflow(a, b);
        if (result[1] != 0) {
            return if (b > 0) std.math.minInt(T) else std.math.maxInt(T);
        }
        return result[0];
    }
};

// ============================================================================
// Tests
// ============================================================================

test "integer info" {
    const i32_info = IntegerInfo.fromType(.I32).?;

    try std.testing.expect(i32_info.is_signed);
    try std.testing.expect(i32_info.bit_width == 32);
    try std.testing.expect(i32_info.min_value == -2147483648);
    try std.testing.expect(i32_info.max_value == 2147483647);
}

test "value range addition overflow" {
    const i8_info = IntegerInfo.fromType(.I8).?;

    const range1 = ValueRange.init(100, 120);
    const range2 = ValueRange.init(20, 30);

    // 120 + 30 = 150 > 127 (i8 max)
    try std.testing.expect(range1.canOverflowAdd(range2, i8_info));
}

test "value range subtraction overflow" {
    const u8_info = IntegerInfo.fromType(.U8).?;

    const range1 = ValueRange.init(10, 20);
    const range2 = ValueRange.init(30, 40);

    // 10 - 40 = -30 < 0 (u8 min)
    try std.testing.expect(range1.canOverflowSub(range2, u8_info));
}

test "value range multiplication overflow" {
    const i16_info = IntegerInfo.fromType(.I16).?;

    const range1 = ValueRange.init(200, 300);
    const range2 = ValueRange.init(100, 200);

    // 300 * 200 = 60000 > 32767 (i16 max)
    try std.testing.expect(range1.canOverflowMul(range2, i16_info));
}

test "overflow tracker addition" {
    var tracker = OverflowTracker.init(std.testing.allocator);
    defer tracker.deinit();

    tracker.setMode(.CompileTime);

    const range1 = ValueRange.init(100, 120);
    const range2 = ValueRange.init(20, 30);
    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    _ = try tracker.checkAdd(range1, range2, .I8, loc);

    try std.testing.expect(tracker.hasErrors());
}

test "runtime checked addition" {
    const result1 = try RuntimeChecks.addChecked(i32, 100, 200);
    try std.testing.expect(result1 == 300);

    const result2 = RuntimeChecks.addChecked(i8, 100, 100);
    try std.testing.expectError(error.Overflow, result2);
}

test "saturating arithmetic" {
    const result1 = RuntimeChecks.addSaturating(i8, 100, 100);
    try std.testing.expect(result1 == 127); // Saturated to max

    const result2 = RuntimeChecks.subSaturating(u8, 10, 50);
    try std.testing.expect(result2 == 0); // Saturated to min
}

test "division by zero detection" {
    var tracker = OverflowTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const dividend = ValueRange.init(100, 200);
    const divisor = ValueRange.init(-5, 5); // Includes zero
    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    try tracker.checkDiv(dividend, divisor, loc);

    try std.testing.expect(tracker.hasErrors());
}
