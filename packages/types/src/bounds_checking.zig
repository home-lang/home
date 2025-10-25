const std = @import("std");
const Type = @import("type_system.zig").Type;
const ast = @import("ast");

/// Bounds checking mode
pub const BoundsCheckMode = enum(u8) {
    /// No bounds checking (unsafe, fast)
    Unchecked = 0,
    /// Runtime bounds checks (safe, some overhead)
    Runtime = 1,
    /// Compile-time bounds verification (safest)
    CompileTime = 2,
    /// Debug mode only
    Debug = 3,
};

/// Array/slice bounds information
pub const BoundsInfo = struct {
    /// Known length (if constant)
    known_length: ?usize,
    /// Minimum possible length
    min_length: usize,
    /// Maximum possible length
    max_length: ?usize,

    pub fn init(len: ?usize) BoundsInfo {
        if (len) |l| {
            return .{
                .known_length = l,
                .min_length = l,
                .max_length = l,
            };
        }
        return .{
            .known_length = null,
            .min_length = 0,
            .max_length = null,
        };
    }

    pub fn unknown() BoundsInfo {
        return .{
            .known_length = null,
            .min_length = 0,
            .max_length = null,
        };
    }

    pub fn constant(len: usize) BoundsInfo {
        return .{
            .known_length = len,
            .min_length = len,
            .max_length = len,
        };
    }

    /// Check if index is definitely in bounds
    pub fn isInBounds(self: BoundsInfo, index: IndexRange) bool {
        if (self.known_length) |len| {
            return index.max_index < len;
        }
        return false;
    }

    /// Check if index might be out of bounds
    pub fn mightBeOutOfBounds(self: BoundsInfo, index: IndexRange) bool {
        if (self.known_length) |len| {
            return index.max_index >= len or index.min_index < 0;
        }
        // Unknown length - might be out of bounds
        return true;
    }
};

/// Index range for static analysis
pub const IndexRange = struct {
    min_index: i64,
    max_index: i64,

    pub fn init(min: i64, max: i64) IndexRange {
        return .{ .min_index = min, .max_index = max };
    }

    pub fn constant(index: i64) IndexRange {
        return .{ .min_index = index, .max_index = index };
    }

    pub fn unknown() IndexRange {
        return .{
            .min_index = std.math.minInt(i64),
            .max_index = std.math.maxInt(i64),
        };
    }

    pub fn isDefinitelyValid(self: IndexRange, bounds: BoundsInfo) bool {
        if (bounds.known_length) |len| {
            return self.min_index >= 0 and self.max_index < @as(i64, @intCast(len));
        }
        return false;
    }

    pub fn isDefinitelyInvalid(self: IndexRange, bounds: BoundsInfo) bool {
        // Definitely invalid if min is negative
        if (self.min_index < 0) return true;

        // Definitely invalid if max exceeds known length
        if (bounds.known_length) |len| {
            return self.max_index >= @as(i64, @intCast(len));
        }

        return false;
    }
};

/// Bounds checking tracker
pub const BoundsTracker = struct {
    allocator: std.mem.Allocator,
    /// Default checking mode
    default_mode: BoundsCheckMode,
    /// Array/slice bounds information
    array_bounds: std.StringHashMap(BoundsInfo),
    /// Index ranges for variables
    index_ranges: std.StringHashMap(IndexRange),
    /// Checked indices (after bounds check)
    checked_indices: std.StringHashMap(bool),
    /// Errors found
    errors: std.ArrayList(BoundsError),
    /// Warnings
    warnings: std.ArrayList(BoundsWarning),

    pub fn init(allocator: std.mem.Allocator) BoundsTracker {
        return .{
            .allocator = allocator,
            .default_mode = .Runtime,
            .array_bounds = std.StringHashMap(BoundsInfo).init(allocator),
            .index_ranges = std.StringHashMap(IndexRange).init(allocator),
            .checked_indices = std.StringHashMap(bool).init(allocator),
            .errors = std.ArrayList(BoundsError).init(allocator),
            .warnings = std.ArrayList(BoundsWarning).init(allocator),
        };
    }

    pub fn deinit(self: *BoundsTracker) void {
        self.array_bounds.deinit();
        self.index_ranges.deinit();
        self.checked_indices.deinit();
        self.errors.deinit();
        self.warnings.deinit();
    }

    pub fn setMode(self: *BoundsTracker, mode: BoundsCheckMode) void {
        self.default_mode = mode;
    }

    /// Set bounds information for an array
    pub fn setBounds(self: *BoundsTracker, array_name: []const u8, bounds: BoundsInfo) !void {
        try self.array_bounds.put(array_name, bounds);
    }

    /// Get bounds information for an array
    pub fn getBounds(self: *BoundsTracker, array_name: []const u8) BoundsInfo {
        return self.array_bounds.get(array_name) orelse BoundsInfo.unknown();
    }

    /// Set index range for a variable
    pub fn setIndexRange(self: *BoundsTracker, var_name: []const u8, range: IndexRange) !void {
        try self.index_ranges.put(var_name, range);
    }

    /// Get index range for a variable
    pub fn getIndexRange(self: *BoundsTracker, var_name: []const u8) IndexRange {
        return self.index_ranges.get(var_name) orelse IndexRange.unknown();
    }

    /// Check array access
    pub fn checkAccess(
        self: *BoundsTracker,
        array_name: []const u8,
        index: IndexRange,
        loc: ast.SourceLocation,
    ) !void {
        const bounds = self.getBounds(array_name);

        // Check if definitely out of bounds
        if (index.isDefinitelyInvalid(bounds)) {
            try self.addError(.{
                .kind = .DefinitelyOutOfBounds,
                .message = try std.fmt.allocPrint(
                    self.allocator,
                    "Index [{}, {}] is definitely out of bounds for array '{s}'",
                    .{ index.min_index, index.max_index, array_name },
                ),
                .location = loc,
                .array_name = array_name,
                .index = index,
            });
            return;
        }

        // Check if definitely in bounds
        if (index.isDefinitelyValid(bounds)) {
            // Definitely safe!
            return;
        }

        // Possibly out of bounds - need runtime check
        if (self.default_mode == .CompileTime or self.default_mode == .Runtime) {
            // Check if already verified
            const check_key = try std.fmt.allocPrint(
                self.allocator,
                "{s}[{}-{}]",
                .{ array_name, index.min_index, index.max_index },
            );
            defer self.allocator.free(check_key);

            if (self.checked_indices.get(check_key)) |_| {
                // Already checked
                return;
            }

            if (bounds.mightBeOutOfBounds(index)) {
                try self.addError(.{
                    .kind = .PossiblyOutOfBounds,
                    .message = try std.fmt.allocPrint(
                        self.allocator,
                        "Index [{}, {}] might be out of bounds for array '{s}' (needs bounds check)",
                        .{ index.min_index, index.max_index, array_name },
                    ),
                    .location = loc,
                    .array_name = array_name,
                    .index = index,
                });
            }
        }
    }

    /// Record bounds check
    pub fn recordBoundsCheck(
        self: *BoundsTracker,
        array_name: []const u8,
        index: IndexRange,
    ) !void {
        const check_key = try std.fmt.allocPrint(
            self.allocator,
            "{s}[{}-{}]",
            .{ array_name, index.min_index, index.max_index },
        );
        try self.checked_indices.put(check_key, true);
    }

    /// Check slice operation
    pub fn checkSlice(
        self: *BoundsTracker,
        array_name: []const u8,
        start: IndexRange,
        end: IndexRange,
        loc: ast.SourceLocation,
    ) !BoundsInfo {
        const bounds = self.getBounds(array_name);

        // Check start index
        try self.checkAccess(array_name, start, loc);

        // Check end index
        try self.checkAccess(array_name, end, loc);

        // Check that start <= end
        if (start.min_index > end.max_index) {
            try self.addError(.{
                .kind = .InvalidSlice,
                .message = try std.fmt.allocPrint(
                    self.allocator,
                    "Invalid slice: start [{}, {}] > end [{}, {}]",
                    .{ start.min_index, start.max_index, end.min_index, end.max_index },
                ),
                .location = loc,
                .array_name = array_name,
                .index = start,
            });
        }

        // Compute resulting slice bounds
        const slice_len = if (start.max_index >= 0 and end.min_index >= start.max_index)
            @as(usize, @intCast(end.min_index - start.max_index))
        else
            null;

        return BoundsInfo.init(slice_len);
    }

    /// Check loop with array iteration
    pub fn checkLoop(
        self: *BoundsTracker,
        array_name: []const u8,
        index_var: []const u8,
        loc: ast.SourceLocation,
    ) !void {
        const bounds = self.getBounds(array_name);

        if (bounds.known_length) |len| {
            // Set index range for loop variable
            try self.setIndexRange(index_var, IndexRange.init(0, @as(i64, @intCast(len - 1))));
        } else {
            try self.addWarning(.{
                .message = try std.fmt.allocPrint(
                    self.allocator,
                    "Loop over array '{s}' with unknown length - consider bounds checks",
                    .{array_name},
                ),
                .location = loc,
            });
        }
    }

    /// Infer bounds from conditional
    pub fn inferFromConditional(
        self: *BoundsTracker,
        var_name: []const u8,
        operator: ComparisonOp,
        value: i64,
    ) !IndexRange {
        const current = self.getIndexRange(var_name);

        return switch (operator) {
            .LessThan => IndexRange.init(current.min_index, @min(current.max_index, value - 1)),
            .LessEqual => IndexRange.init(current.min_index, @min(current.max_index, value)),
            .GreaterThan => IndexRange.init(@max(current.min_index, value + 1), current.max_index),
            .GreaterEqual => IndexRange.init(@max(current.min_index, value), current.max_index),
            .Equal => IndexRange.constant(value),
            .NotEqual => current, // Can't refine much
        };
    }

    fn addError(self: *BoundsTracker, err: BoundsError) !void {
        try self.errors.append(err);
    }

    fn addWarning(self: *BoundsTracker, warning: BoundsWarning) !void {
        try self.warnings.append(warning);
    }

    pub fn hasErrors(self: *BoundsTracker) bool {
        return self.errors.items.len > 0;
    }
};

/// Comparison operators for bounds inference
pub const ComparisonOp = enum {
    LessThan,
    LessEqual,
    GreaterThan,
    GreaterEqual,
    Equal,
    NotEqual,
};

/// Bounds checking error
pub const BoundsError = struct {
    kind: ErrorKind,
    message: []const u8,
    location: ast.SourceLocation,
    array_name: []const u8,
    index: IndexRange,

    pub const ErrorKind = enum {
        DefinitelyOutOfBounds,
        PossiblyOutOfBounds,
        NegativeIndex,
        InvalidSlice,
        LengthMismatch,
    };
};

/// Bounds checking warning
pub const BoundsWarning = struct {
    message: []const u8,
    location: ast.SourceLocation,
};

// ============================================================================
// Runtime Bounds Checking Utilities
// ============================================================================

pub const RuntimeBoundsChecks = struct {
    /// Check single index access
    pub fn checkIndex(index: usize, length: usize) !void {
        if (index >= length) {
            return error.IndexOutOfBounds;
        }
    }

    /// Check slice bounds
    pub fn checkSlice(start: usize, end: usize, length: usize) !void {
        if (start > end) {
            return error.InvalidSlice;
        }
        if (end > length) {
            return error.SliceOutOfBounds;
        }
    }

    /// Safe array access (returns error on out of bounds)
    pub fn safeGet(comptime T: type, array: []const T, index: usize) !T {
        try checkIndex(index, array.len);
        return array[index];
    }

    /// Safe array write
    pub fn safeSet(comptime T: type, array: []T, index: usize, value: T) !void {
        try checkIndex(index, array.len);
        array[index] = value;
    }

    /// Safe slice
    pub fn safeSlice(comptime T: type, array: []const T, start: usize, end: usize) ![]const T {
        try checkSlice(start, end, array.len);
        return array[start..end];
    }
};

// ============================================================================
// Static Analysis Helpers
// ============================================================================

pub const StaticAnalysis = struct {
    /// Compute index range from addition
    pub fn rangeAdd(a: IndexRange, b: IndexRange) IndexRange {
        return IndexRange.init(a.min_index + b.min_index, a.max_index + b.max_index);
    }

    /// Compute index range from subtraction
    pub fn rangeSub(a: IndexRange, b: IndexRange) IndexRange {
        return IndexRange.init(a.min_index - b.max_index, a.max_index - b.min_index);
    }

    /// Compute index range from multiplication
    pub fn rangeMul(a: IndexRange, b: IndexRange) IndexRange {
        const products = [4]i64{
            a.min_index * b.min_index,
            a.min_index * b.max_index,
            a.max_index * b.min_index,
            a.max_index * b.max_index,
        };

        var min = products[0];
        var max = products[0];
        for (products) |p| {
            min = @min(min, p);
            max = @max(max, p);
        }

        return IndexRange.init(min, max);
    }

    /// Intersect two ranges (AND condition)
    pub fn rangeIntersect(a: IndexRange, b: IndexRange) IndexRange {
        return IndexRange.init(
            @max(a.min_index, b.min_index),
            @min(a.max_index, b.max_index),
        );
    }

    /// Union two ranges (OR condition)
    pub fn rangeUnion(a: IndexRange, b: IndexRange) IndexRange {
        return IndexRange.init(
            @min(a.min_index, b.min_index),
            @max(a.max_index, b.max_index),
        );
    }
};

// ============================================================================
// Tests
// ============================================================================

test "bounds info constant" {
    const bounds = BoundsInfo.constant(10);

    try std.testing.expect(bounds.known_length.? == 10);
    try std.testing.expect(bounds.min_length == 10);
    try std.testing.expect(bounds.max_length.? == 10);
}

test "index range in bounds" {
    const bounds = BoundsInfo.constant(100);
    const valid_index = IndexRange.constant(50);
    const invalid_index = IndexRange.constant(150);

    try std.testing.expect(bounds.isInBounds(valid_index));
    try std.testing.expect(!bounds.isInBounds(invalid_index));
}

test "definitely out of bounds" {
    const bounds = BoundsInfo.constant(10);
    const index = IndexRange.constant(20);

    try std.testing.expect(index.isDefinitelyInvalid(bounds));
}

test "bounds tracker basic" {
    var tracker = BoundsTracker.init(std.testing.allocator);
    defer tracker.deinit();

    const bounds = BoundsInfo.constant(100);
    try tracker.setBounds("array", bounds);

    const retrieved = tracker.getBounds("array");
    try std.testing.expect(retrieved.known_length.? == 100);
}

test "out of bounds detection" {
    var tracker = BoundsTracker.init(std.testing.allocator);
    defer tracker.deinit();

    tracker.setMode(.CompileTime);

    try tracker.setBounds("arr", BoundsInfo.constant(10));

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };
    try tracker.checkAccess("arr", IndexRange.constant(15), loc);

    try std.testing.expect(tracker.hasErrors());
}

test "safe in bounds access" {
    var tracker = BoundsTracker.init(std.testing.allocator);
    defer tracker.deinit();

    tracker.setMode(.CompileTime);

    try tracker.setBounds("arr", BoundsInfo.constant(100));

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };
    try tracker.checkAccess("arr", IndexRange.constant(50), loc);

    try std.testing.expect(!tracker.hasErrors());
}

test "runtime bounds check" {
    const array = [_]i32{ 1, 2, 3, 4, 5 };

    const result1 = try RuntimeBoundsChecks.safeGet(i32, &array, 2);
    try std.testing.expect(result1 == 3);

    const result2 = RuntimeBoundsChecks.safeGet(i32, &array, 10);
    try std.testing.expectError(error.IndexOutOfBounds, result2);
}

test "slice bounds check" {
    const array = [_]i32{ 1, 2, 3, 4, 5 };

    const slice1 = try RuntimeBoundsChecks.safeSlice(i32, &array, 1, 3);
    try std.testing.expect(slice1.len == 2);

    const slice2 = RuntimeBoundsChecks.safeSlice(i32, &array, 3, 1);
    try std.testing.expectError(error.InvalidSlice, slice2);
}

test "index range arithmetic" {
    const a = IndexRange.init(5, 10);
    const b = IndexRange.init(2, 3);

    const sum = StaticAnalysis.rangeAdd(a, b);
    try std.testing.expect(sum.min_index == 7);
    try std.testing.expect(sum.max_index == 13);

    const diff = StaticAnalysis.rangeSub(a, b);
    try std.testing.expect(diff.min_index == 2);
    try std.testing.expect(diff.max_index == 8);
}

test "range intersection" {
    const a = IndexRange.init(0, 10);
    const b = IndexRange.init(5, 15);

    const intersection = StaticAnalysis.rangeIntersect(a, b);
    try std.testing.expect(intersection.min_index == 5);
    try std.testing.expect(intersection.max_index == 10);
}
