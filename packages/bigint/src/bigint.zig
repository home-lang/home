/// Home BigInt/BigDecimal Module
///
/// Arbitrary precision integer and decimal arithmetic.
/// Supports integers of any size and high-precision decimal calculations.
///
/// Example usage:
/// ```home
/// const a = try BigInt.fromString("123456789012345678901234567890");
/// const b = try BigInt.fromString("987654321098765432109876543210");
/// const sum = try a.add(b);
/// print("{}", sum); // 1111111110111111111011111111100
///
/// const price = try BigDecimal.fromString("19.99");
/// const tax = try price.multiply(BigDecimal.fromString("0.0825"));
/// ```
const std = @import("std");

/// Arbitrary precision integer
pub const BigInt = struct {
    allocator: std.mem.Allocator,
    /// Digits stored in little-endian order (least significant first)
    digits: []u64,
    /// Sign: true for negative
    negative: bool,

    const BASE: u128 = 1 << 64;

    pub fn init(allocator: std.mem.Allocator) BigInt {
        return .{
            .allocator = allocator,
            .digits = &.{},
            .negative = false,
        };
    }

    pub fn deinit(self: *BigInt) void {
        if (self.digits.len > 0) {
            self.allocator.free(self.digits);
        }
    }

    /// Create BigInt from i64
    pub fn fromInt(allocator: std.mem.Allocator, value: i64) !BigInt {
        var bi = BigInt.init(allocator);
        errdefer bi.deinit();

        if (value == 0) {
            bi.digits = try allocator.alloc(u64, 1);
            bi.digits[0] = 0;
            return bi;
        }

        bi.negative = value < 0;
        const abs_value: u64 = @intCast(@abs(value));

        bi.digits = try allocator.alloc(u64, 1);
        bi.digits[0] = abs_value;

        return bi;
    }

    /// Create BigInt from u64
    pub fn fromUInt(allocator: std.mem.Allocator, value: u64) !BigInt {
        var bi = BigInt.init(allocator);
        errdefer bi.deinit();

        bi.digits = try allocator.alloc(u64, 1);
        bi.digits[0] = value;

        return bi;
    }

    /// Create BigInt from string
    pub fn fromString(allocator: std.mem.Allocator, str: []const u8) !BigInt {
        if (str.len == 0) return error.InvalidFormat;

        var bi = BigInt.init(allocator);
        errdefer bi.deinit();

        var start: usize = 0;

        // Handle sign
        if (str[0] == '-') {
            bi.negative = true;
            start = 1;
        } else if (str[0] == '+') {
            start = 1;
        }

        if (start >= str.len) return error.InvalidFormat;

        // Initialize to zero
        bi.digits = try allocator.alloc(u64, 1);
        bi.digits[0] = 0;

        // Parse digits
        for (str[start..]) |c| {
            if (c < '0' or c > '9') {
                if (c == '_') continue; // Allow underscores
                return error.InvalidFormat;
            }

            const digit: u64 = c - '0';

            // Multiply by 10 and add digit
            var new_bi = try bi.multiplySmall(10);
            bi.deinit();
            bi = new_bi;

            new_bi = try bi.addSmall(digit);
            bi.deinit();
            bi = new_bi;
        }

        // Handle negative zero
        if (bi.isZero()) {
            bi.negative = false;
        }

        return bi;
    }

    /// Create a copy
    pub fn clone(self: *const BigInt) !BigInt {
        return .{
            .allocator = self.allocator,
            .digits = try self.allocator.dupe(u64, self.digits),
            .negative = self.negative,
        };
    }

    /// Check if zero
    pub fn isZero(self: *const BigInt) bool {
        if (self.digits.len == 0) return true;
        for (self.digits) |d| {
            if (d != 0) return false;
        }
        return true;
    }

    /// Check if positive
    pub fn isPositive(self: *const BigInt) bool {
        return !self.negative and !self.isZero();
    }

    /// Check if negative
    pub fn isNegative(self: *const BigInt) bool {
        return self.negative and !self.isZero();
    }

    /// Get sign: -1, 0, or 1
    pub fn sign(self: *const BigInt) i2 {
        if (self.isZero()) return 0;
        return if (self.negative) -1 else 1;
    }

    /// Compare absolute values
    fn compareAbs(self: *const BigInt, other: *const BigInt) std.math.Order {
        // Remove leading zeros conceptually
        var self_len = self.digits.len;
        while (self_len > 1 and self.digits[self_len - 1] == 0) {
            self_len -= 1;
        }

        var other_len = other.digits.len;
        while (other_len > 1 and other.digits[other_len - 1] == 0) {
            other_len -= 1;
        }

        if (self_len != other_len) {
            return if (self_len > other_len) .gt else .lt;
        }

        var i = self_len;
        while (i > 0) {
            i -= 1;
            if (self.digits[i] != other.digits[i]) {
                return if (self.digits[i] > other.digits[i]) .gt else .lt;
            }
        }

        return .eq;
    }

    /// Compare two BigInts
    pub fn compare(self: *const BigInt, other: *const BigInt) std.math.Order {
        // Handle signs
        const self_sign = self.sign();
        const other_sign = other.sign();

        if (self_sign != other_sign) {
            return if (self_sign > other_sign) .gt else .lt;
        }

        if (self_sign == 0) return .eq;

        const abs_cmp = self.compareAbs(other);

        // If negative, reverse comparison
        if (self_sign < 0) {
            return switch (abs_cmp) {
                .lt => .gt,
                .gt => .lt,
                .eq => .eq,
            };
        }

        return abs_cmp;
    }

    /// Add a small value
    fn addSmall(self: *const BigInt, value: u64) !BigInt {
        var result = try self.clone();
        errdefer result.deinit();

        var carry: u64 = value;
        for (result.digits) |*d| {
            const sum: u128 = @as(u128, d.*) + @as(u128, carry);
            d.* = @truncate(sum);
            carry = @truncate(sum >> 64);
            if (carry == 0) break;
        }

        if (carry > 0) {
            var new_digits = try result.allocator.alloc(u64, result.digits.len + 1);
            @memcpy(new_digits[0..result.digits.len], result.digits);
            new_digits[result.digits.len] = carry;
            result.allocator.free(result.digits);
            result.digits = new_digits;
        }

        return result;
    }

    /// Multiply by a small value
    fn multiplySmall(self: *const BigInt, value: u64) !BigInt {
        if (value == 0) {
            return fromInt(self.allocator, 0);
        }

        var result_digits = try self.allocator.alloc(u64, self.digits.len + 1);
        @memset(result_digits, 0);

        var carry: u64 = 0;
        for (self.digits, 0..) |d, i| {
            const prod: u128 = @as(u128, d) * @as(u128, value) + @as(u128, carry);
            result_digits[i] = @truncate(prod);
            carry = @truncate(prod >> 64);
        }
        result_digits[self.digits.len] = carry;

        // Remove trailing zeros
        var len = result_digits.len;
        while (len > 1 and result_digits[len - 1] == 0) {
            len -= 1;
        }

        if (len < result_digits.len) {
            var trimmed = try self.allocator.alloc(u64, len);
            @memcpy(trimmed, result_digits[0..len]);
            self.allocator.free(result_digits);
            result_digits = trimmed;
        }

        return .{
            .allocator = self.allocator,
            .digits = result_digits,
            .negative = self.negative,
        };
    }

    /// Add two BigInts (handles signs)
    pub fn add(self: *const BigInt, other: *const BigInt) !BigInt {
        // Handle sign cases
        if (!self.negative and !other.negative) {
            return self.addAbs(other, false);
        } else if (self.negative and other.negative) {
            return self.addAbs(other, true);
        } else if (self.negative) {
            // -a + b = b - a
            return other.subtractAbs(self);
        } else {
            // a + (-b) = a - b
            return self.subtractAbs(other);
        }
    }

    /// Add absolute values
    fn addAbs(self: *const BigInt, other: *const BigInt, negative: bool) !BigInt {
        const max_len = @max(self.digits.len, other.digits.len);
        var result_digits = try self.allocator.alloc(u64, max_len + 1);
        @memset(result_digits, 0);

        var carry: u64 = 0;
        for (0..max_len) |i| {
            const a: u128 = if (i < self.digits.len) self.digits[i] else 0;
            const b: u128 = if (i < other.digits.len) other.digits[i] else 0;
            const sum: u128 = a + b + @as(u128, carry);
            result_digits[i] = @truncate(sum);
            carry = @truncate(sum >> 64);
        }
        result_digits[max_len] = carry;

        // Remove trailing zeros
        var len = result_digits.len;
        while (len > 1 and result_digits[len - 1] == 0) {
            len -= 1;
        }

        if (len < result_digits.len) {
            var trimmed = try self.allocator.alloc(u64, len);
            @memcpy(trimmed, result_digits[0..len]);
            self.allocator.free(result_digits);
            result_digits = trimmed;
        }

        return .{
            .allocator = self.allocator,
            .digits = result_digits,
            .negative = negative,
        };
    }

    /// Subtract two BigInts
    pub fn subtract(self: *const BigInt, other: *const BigInt) !BigInt {
        // Handle sign cases
        if (!self.negative and !other.negative) {
            return self.subtractAbs(other);
        } else if (self.negative and other.negative) {
            // -a - (-b) = b - a
            return other.subtractAbs(self);
        } else if (self.negative) {
            // -a - b = -(a + b)
            return self.addAbs(other, true);
        } else {
            // a - (-b) = a + b
            return self.addAbs(other, false);
        }
    }

    /// Subtract absolute values (self - other)
    fn subtractAbs(self: *const BigInt, other: *const BigInt) !BigInt {
        const cmp = self.compareAbs(other);

        if (cmp == .eq) {
            return fromInt(self.allocator, 0);
        }

        var larger: *const BigInt = undefined;
        var smaller: *const BigInt = undefined;
        var negative: bool = undefined;

        if (cmp == .gt) {
            larger = self;
            smaller = other;
            negative = false;
        } else {
            larger = other;
            smaller = self;
            negative = true;
        }

        var result_digits = try self.allocator.alloc(u64, larger.digits.len);
        @memset(result_digits, 0);

        var borrow: u64 = 0;
        for (0..larger.digits.len) |i| {
            const a: u128 = larger.digits[i];
            const b: u128 = if (i < smaller.digits.len) smaller.digits[i] else 0;
            const b_plus_borrow: u128 = b + @as(u128, borrow);

            if (a >= b_plus_borrow) {
                result_digits[i] = @truncate(a - b_plus_borrow);
                borrow = 0;
            } else {
                result_digits[i] = @truncate(BASE + a - b_plus_borrow);
                borrow = 1;
            }
        }

        // Remove trailing zeros
        var len = result_digits.len;
        while (len > 1 and result_digits[len - 1] == 0) {
            len -= 1;
        }

        if (len < result_digits.len) {
            var trimmed = try self.allocator.alloc(u64, len);
            @memcpy(trimmed, result_digits[0..len]);
            self.allocator.free(result_digits);
            result_digits = trimmed;
        }

        return .{
            .allocator = self.allocator,
            .digits = result_digits,
            .negative = negative,
        };
    }

    /// Multiply two BigInts
    pub fn multiply(self: *const BigInt, other: *const BigInt) !BigInt {
        if (self.isZero() or other.isZero()) {
            return fromInt(self.allocator, 0);
        }

        const result_len = self.digits.len + other.digits.len;
        var result_digits = try self.allocator.alloc(u64, result_len);
        @memset(result_digits, 0);

        for (self.digits, 0..) |a, i| {
            var carry: u64 = 0;
            for (other.digits, 0..) |b, j| {
                const prod: u128 = @as(u128, a) * @as(u128, b) + @as(u128, result_digits[i + j]) + @as(u128, carry);
                result_digits[i + j] = @truncate(prod);
                carry = @truncate(prod >> 64);
            }
            result_digits[i + other.digits.len] = carry;
        }

        // Remove trailing zeros
        var len = result_digits.len;
        while (len > 1 and result_digits[len - 1] == 0) {
            len -= 1;
        }

        if (len < result_digits.len) {
            var trimmed = try self.allocator.alloc(u64, len);
            @memcpy(trimmed, result_digits[0..len]);
            self.allocator.free(result_digits);
            result_digits = trimmed;
        }

        return .{
            .allocator = self.allocator,
            .digits = result_digits,
            .negative = self.negative != other.negative,
        };
    }

    /// Divide two BigInts (returns quotient)
    pub fn divide(self: *const BigInt, other: *const BigInt) !BigInt {
        if (other.isZero()) return error.DivisionByZero;

        if (self.compareAbs(other) == .lt) {
            return fromInt(self.allocator, 0);
        }

        // Simple long division for now
        var quotient = try fromInt(self.allocator, 0);
        errdefer quotient.deinit();

        var remainder = try self.clone();
        remainder.negative = false;
        errdefer remainder.deinit();

        var divisor = try other.clone();
        divisor.negative = false;
        defer divisor.deinit();

        // Find shift amount
        var shift: usize = 0;
        var shifted_divisor = try divisor.clone();
        defer shifted_divisor.deinit();

        while (shifted_divisor.compareAbs(&remainder) != .gt) {
            var doubled = try shifted_divisor.addAbs(&shifted_divisor, false);
            shifted_divisor.deinit();
            shifted_divisor = doubled;
            shift += 1;
        }

        // Perform division
        while (shift > 0) {
            shift -= 1;

            // Halve the shifted divisor
            var half = try self.allocator.alloc(u64, shifted_divisor.digits.len);
            var carry: u64 = 0;
            var i = shifted_divisor.digits.len;
            while (i > 0) {
                i -= 1;
                const val: u128 = @as(u128, carry) << 64 | shifted_divisor.digits[i];
                half[i] = @truncate(val >> 1);
                carry = @truncate(val & 1);
            }

            self.allocator.free(shifted_divisor.digits);
            shifted_divisor.digits = half;

            // Remove leading zeros
            var len = half.len;
            while (len > 1 and half[len - 1] == 0) {
                len -= 1;
            }
            if (len < half.len) {
                var trimmed = try self.allocator.alloc(u64, len);
                @memcpy(trimmed, half[0..len]);
                self.allocator.free(half);
                shifted_divisor.digits = trimmed;
            }

            if (shifted_divisor.compareAbs(&remainder) != .gt) {
                var new_remainder = try remainder.subtractAbs(&shifted_divisor);
                remainder.deinit();
                remainder = new_remainder;

                // Add 2^shift to quotient
                var bit = try fromInt(self.allocator, 1);
                defer bit.deinit();

                for (0..shift) |_| {
                    var doubled = try bit.addAbs(&bit, false);
                    bit.deinit();
                    bit = doubled;
                }

                var new_quotient = try quotient.add(&bit);
                quotient.deinit();
                quotient = new_quotient;
            }
        }

        quotient.negative = self.negative != other.negative;
        if (quotient.isZero()) quotient.negative = false;

        return quotient;
    }

    /// Modulo operation
    pub fn mod(self: *const BigInt, other: *const BigInt) !BigInt {
        if (other.isZero()) return error.DivisionByZero;

        var quotient = try self.divide(other);
        defer quotient.deinit();

        var product = try quotient.multiply(other);
        defer product.deinit();

        return self.subtract(&product);
    }

    /// Power
    pub fn pow(self: *const BigInt, exp: u64) !BigInt {
        if (exp == 0) {
            return fromInt(self.allocator, 1);
        }

        var result = try fromInt(self.allocator, 1);
        errdefer result.deinit();

        var base = try self.clone();
        defer base.deinit();

        var e = exp;
        while (e > 0) {
            if (e & 1 == 1) {
                var new_result = try result.multiply(&base);
                result.deinit();
                result = new_result;
            }
            e >>= 1;
            if (e > 0) {
                var squared = try base.multiply(&base);
                base.deinit();
                base = squared;
            }
        }

        return result;
    }

    /// Absolute value
    pub fn abs(self: *const BigInt) !BigInt {
        var result = try self.clone();
        result.negative = false;
        return result;
    }

    /// Negate
    pub fn negate(self: *const BigInt) !BigInt {
        var result = try self.clone();
        if (!result.isZero()) {
            result.negative = !result.negative;
        }
        return result;
    }

    /// Convert to string
    pub fn toString(self: *const BigInt, allocator: std.mem.Allocator) ![]u8 {
        if (self.isZero()) {
            return allocator.dupe(u8, "0");
        }

        var result = std.ArrayList(u8).init(allocator);
        errdefer result.deinit();

        // Clone for division
        var num = try self.clone();
        num.negative = false;
        defer num.deinit();

        var ten = try fromInt(allocator, 10);
        defer ten.deinit();

        while (!num.isZero()) {
            var remainder = try num.mod(&ten);
            defer remainder.deinit();

            const digit: u8 = @intCast(remainder.digits[0]);
            try result.append('0' + digit);

            var quotient = try num.divide(&ten);
            num.deinit();
            num = quotient;
        }

        if (self.negative) {
            try result.append('-');
        }

        // Reverse
        const slice = try result.toOwnedSlice();
        var i: usize = 0;
        var j: usize = slice.len - 1;
        while (i < j) {
            const tmp = slice[i];
            slice[i] = slice[j];
            slice[j] = tmp;
            i += 1;
            j -= 1;
        }

        return slice;
    }

    /// Convert to i64 (may overflow)
    pub fn toInt(self: *const BigInt) ?i64 {
        if (self.digits.len > 1) return null;
        if (self.digits.len == 0) return 0;

        const value = self.digits[0];
        if (value > @as(u64, @intCast(std.math.maxInt(i64)))) {
            if (self.negative and value == @as(u64, @intCast(std.math.maxInt(i64))) + 1) {
                return std.math.minInt(i64);
            }
            return null;
        }

        const result: i64 = @intCast(value);
        return if (self.negative) -result else result;
    }

    /// Format for printing
    pub fn format(self: BigInt, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;

        if (self.isZero()) {
            try writer.writeAll("0");
            return;
        }

        var num = self.clone() catch return;
        num.negative = false;
        defer num.deinit();

        var digits_buf: [256]u8 = undefined;
        var pos: usize = digits_buf.len;

        var ten = fromInt(self.allocator, 10) catch return;
        defer ten.deinit();

        while (!num.isZero()) {
            var remainder = num.mod(&ten) catch return;
            defer remainder.deinit();

            pos -= 1;
            digits_buf[pos] = '0' + @as(u8, @intCast(remainder.digits[0]));

            var quotient = num.divide(&ten) catch return;
            num.deinit();
            num = quotient;
        }

        if (self.negative) {
            try writer.writeAll("-");
        }
        try writer.writeAll(digits_buf[pos..]);
    }
};

/// Arbitrary precision decimal
pub const BigDecimal = struct {
    allocator: std.mem.Allocator,
    /// Unscaled value as BigInt
    unscaled: BigInt,
    /// Scale (number of decimal places)
    scale: i32,

    pub fn init(allocator: std.mem.Allocator) BigDecimal {
        return .{
            .allocator = allocator,
            .unscaled = BigInt.init(allocator),
            .scale = 0,
        };
    }

    pub fn deinit(self: *BigDecimal) void {
        self.unscaled.deinit();
    }

    /// Create from string
    pub fn fromString(allocator: std.mem.Allocator, str: []const u8) !BigDecimal {
        var bd = BigDecimal.init(allocator);
        errdefer bd.deinit();

        // Find decimal point
        var decimal_pos: ?usize = null;
        for (str, 0..) |c, i| {
            if (c == '.') {
                decimal_pos = i;
                break;
            }
        }

        if (decimal_pos) |pos| {
            // Has decimal point
            var int_part = std.ArrayList(u8).init(allocator);
            defer int_part.deinit();

            try int_part.appendSlice(str[0..pos]);
            try int_part.appendSlice(str[pos + 1 ..]);

            bd.unscaled = try BigInt.fromString(allocator, int_part.items);
            bd.scale = @intCast(str.len - pos - 1);
        } else {
            bd.unscaled = try BigInt.fromString(allocator, str);
            bd.scale = 0;
        }

        return bd;
    }

    /// Create from BigInt
    pub fn fromBigInt(allocator: std.mem.Allocator, value: *const BigInt, scale: i32) !BigDecimal {
        return .{
            .allocator = allocator,
            .unscaled = try value.clone(),
            .scale = scale,
        };
    }

    /// Create from f64
    pub fn fromFloat(allocator: std.mem.Allocator, value: f64) !BigDecimal {
        var buf: [64]u8 = undefined;
        const str = std.fmt.bufPrint(&buf, "{d:.15}", .{value}) catch return error.InvalidFormat;
        return fromString(allocator, str);
    }

    /// Create from integer
    pub fn fromInt(allocator: std.mem.Allocator, value: i64) !BigDecimal {
        return .{
            .allocator = allocator,
            .unscaled = try BigInt.fromInt(allocator, value),
            .scale = 0,
        };
    }

    /// Clone
    pub fn clone(self: *const BigDecimal) !BigDecimal {
        return .{
            .allocator = self.allocator,
            .unscaled = try self.unscaled.clone(),
            .scale = self.scale,
        };
    }

    /// Add two BigDecimals
    pub fn add(self: *const BigDecimal, other: *const BigDecimal) !BigDecimal {
        var result = BigDecimal.init(self.allocator);
        errdefer result.deinit();

        // Align scales
        const max_scale = @max(self.scale, other.scale);

        var self_adjusted = try self.adjustScale(max_scale);
        defer self_adjusted.deinit();

        var other_adjusted = try other.adjustScale(max_scale);
        defer other_adjusted.deinit();

        result.unscaled = try self_adjusted.unscaled.add(&other_adjusted.unscaled);
        result.scale = max_scale;

        return result;
    }

    /// Subtract two BigDecimals
    pub fn subtract(self: *const BigDecimal, other: *const BigDecimal) !BigDecimal {
        var result = BigDecimal.init(self.allocator);
        errdefer result.deinit();

        const max_scale = @max(self.scale, other.scale);

        var self_adjusted = try self.adjustScale(max_scale);
        defer self_adjusted.deinit();

        var other_adjusted = try other.adjustScale(max_scale);
        defer other_adjusted.deinit();

        result.unscaled = try self_adjusted.unscaled.subtract(&other_adjusted.unscaled);
        result.scale = max_scale;

        return result;
    }

    /// Multiply two BigDecimals
    pub fn multiply(self: *const BigDecimal, other: *const BigDecimal) !BigDecimal {
        return .{
            .allocator = self.allocator,
            .unscaled = try self.unscaled.multiply(&other.unscaled),
            .scale = self.scale + other.scale,
        };
    }

    /// Divide two BigDecimals
    pub fn divide(self: *const BigDecimal, other: *const BigDecimal, precision: i32) !BigDecimal {
        if (other.unscaled.isZero()) return error.DivisionByZero;

        // Scale up dividend for precision
        var dividend = try self.clone();
        defer dividend.deinit();

        const extra_scale = precision + other.scale - self.scale;
        if (extra_scale > 0) {
            var scaled = try dividend.adjustScale(self.scale + extra_scale);
            dividend.deinit();
            dividend = scaled;
        }

        return .{
            .allocator = self.allocator,
            .unscaled = try dividend.unscaled.divide(&other.unscaled),
            .scale = precision,
        };
    }

    /// Adjust scale (multiply/divide unscaled by power of 10)
    fn adjustScale(self: *const BigDecimal, new_scale: i32) !BigDecimal {
        if (new_scale == self.scale) {
            return self.clone();
        }

        var result = try self.clone();
        errdefer result.deinit();

        const diff = new_scale - self.scale;

        if (diff > 0) {
            // Multiply by 10^diff
            var ten = try BigInt.fromInt(self.allocator, 10);
            defer ten.deinit();

            for (0..@intCast(diff)) |_| {
                var new_unscaled = try result.unscaled.multiply(&ten);
                result.unscaled.deinit();
                result.unscaled = new_unscaled;
            }
        } else {
            // Divide by 10^(-diff)
            var ten = try BigInt.fromInt(self.allocator, 10);
            defer ten.deinit();

            for (0..@intCast(-diff)) |_| {
                var new_unscaled = try result.unscaled.divide(&ten);
                result.unscaled.deinit();
                result.unscaled = new_unscaled;
            }
        }

        result.scale = new_scale;
        return result;
    }

    /// Round to specified scale
    pub fn round(self: *const BigDecimal, scale: i32) !BigDecimal {
        if (scale >= self.scale) {
            return self.adjustScale(scale);
        }

        var result = try self.clone();
        errdefer result.deinit();

        // Get rounding digit
        var ten = try BigInt.fromInt(self.allocator, 10);
        defer ten.deinit();

        var temp = try result.unscaled.clone();
        defer temp.deinit();

        for (0..@intCast(self.scale - scale - 1)) |_| {
            var divided = try temp.divide(&ten);
            temp.deinit();
            temp = divided;
        }

        var rounding_digit = try temp.mod(&ten);
        defer rounding_digit.deinit();

        // Divide to target scale
        for (0..@intCast(self.scale - scale)) |_| {
            var divided = try result.unscaled.divide(&ten);
            result.unscaled.deinit();
            result.unscaled = divided;
        }

        // Round half up
        if (!rounding_digit.isZero() and rounding_digit.digits[0] >= 5) {
            var one = try BigInt.fromInt(self.allocator, 1);
            defer one.deinit();

            if (result.unscaled.negative) {
                var subtracted = try result.unscaled.subtract(&one);
                result.unscaled.deinit();
                result.unscaled = subtracted;
            } else {
                var added = try result.unscaled.add(&one);
                result.unscaled.deinit();
                result.unscaled = added;
            }
        }

        result.scale = scale;
        return result;
    }

    /// Compare two BigDecimals
    pub fn compare(self: *const BigDecimal, other: *const BigDecimal) !std.math.Order {
        const max_scale = @max(self.scale, other.scale);

        var self_adjusted = try self.adjustScale(max_scale);
        defer self_adjusted.deinit();

        var other_adjusted = try other.adjustScale(max_scale);
        defer other_adjusted.deinit();

        return self_adjusted.unscaled.compare(&other_adjusted.unscaled);
    }

    /// Absolute value
    pub fn abs(self: *const BigDecimal) !BigDecimal {
        return .{
            .allocator = self.allocator,
            .unscaled = try self.unscaled.abs(),
            .scale = self.scale,
        };
    }

    /// Negate
    pub fn negate(self: *const BigDecimal) !BigDecimal {
        return .{
            .allocator = self.allocator,
            .unscaled = try self.unscaled.negate(),
            .scale = self.scale,
        };
    }

    /// Convert to string
    pub fn toString(self: *const BigDecimal, allocator: std.mem.Allocator) ![]u8 {
        if (self.scale <= 0) {
            var str = try self.unscaled.toString(allocator);
            errdefer allocator.free(str);

            if (self.scale < 0) {
                // Append zeros
                const new_len = str.len + @as(usize, @intCast(-self.scale));
                var new_str = try allocator.alloc(u8, new_len);
                @memcpy(new_str[0..str.len], str);
                @memset(new_str[str.len..], '0');
                allocator.free(str);
                return new_str;
            }

            return str;
        }

        var unscaled_str = try self.unscaled.toString(allocator);
        defer allocator.free(unscaled_str);

        var result = std.ArrayList(u8).init(allocator);
        errdefer result.deinit();

        var str = unscaled_str;
        var negative = false;
        if (str[0] == '-') {
            negative = true;
            str = str[1..];
        }

        if (negative) {
            try result.append('-');
        }

        const scale_usize: usize = @intCast(self.scale);

        if (str.len <= scale_usize) {
            try result.appendSlice("0.");
            for (0..scale_usize - str.len) |_| {
                try result.append('0');
            }
            try result.appendSlice(str);
        } else {
            const decimal_pos = str.len - scale_usize;
            try result.appendSlice(str[0..decimal_pos]);
            try result.append('.');
            try result.appendSlice(str[decimal_pos..]);
        }

        return result.toOwnedSlice();
    }

    /// Convert to f64
    pub fn toFloat(self: *const BigDecimal) !f64 {
        const str = try self.toString(self.allocator);
        defer self.allocator.free(str);
        return std.fmt.parseFloat(f64, str) catch return error.InvalidFormat;
    }

    /// Format for printing
    pub fn format(self: BigDecimal, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;

        const str = self.toString(self.allocator) catch return;
        defer self.allocator.free(str);
        try writer.writeAll(str);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "BigInt from int" {
    var bi = try BigInt.fromInt(std.testing.allocator, 12345);
    defer bi.deinit();

    try std.testing.expectEqual(@as(?i64, 12345), bi.toInt());
}

test "BigInt from negative int" {
    var bi = try BigInt.fromInt(std.testing.allocator, -12345);
    defer bi.deinit();

    try std.testing.expectEqual(@as(?i64, -12345), bi.toInt());
    try std.testing.expect(bi.isNegative());
}

test "BigInt from string" {
    var bi = try BigInt.fromString(std.testing.allocator, "12345678901234567890");
    defer bi.deinit();

    const str = try bi.toString(std.testing.allocator);
    defer std.testing.allocator.free(str);

    try std.testing.expectEqualStrings("12345678901234567890", str);
}

test "BigInt add" {
    var a = try BigInt.fromInt(std.testing.allocator, 100);
    defer a.deinit();
    var b = try BigInt.fromInt(std.testing.allocator, 200);
    defer b.deinit();

    var sum = try a.add(&b);
    defer sum.deinit();

    try std.testing.expectEqual(@as(?i64, 300), sum.toInt());
}

test "BigInt multiply" {
    var a = try BigInt.fromInt(std.testing.allocator, 12345);
    defer a.deinit();
    var b = try BigInt.fromInt(std.testing.allocator, 67890);
    defer b.deinit();

    var prod = try a.multiply(&b);
    defer prod.deinit();

    try std.testing.expectEqual(@as(?i64, 838102050), prod.toInt());
}

test "BigInt divide" {
    var a = try BigInt.fromInt(std.testing.allocator, 1000);
    defer a.deinit();
    var b = try BigInt.fromInt(std.testing.allocator, 7);
    defer b.deinit();

    var quot = try a.divide(&b);
    defer quot.deinit();

    try std.testing.expectEqual(@as(?i64, 142), quot.toInt());
}

test "BigInt power" {
    var base = try BigInt.fromInt(std.testing.allocator, 2);
    defer base.deinit();

    var result = try base.pow(10);
    defer result.deinit();

    try std.testing.expectEqual(@as(?i64, 1024), result.toInt());
}

test "BigDecimal from string" {
    var bd = try BigDecimal.fromString(std.testing.allocator, "123.456");
    defer bd.deinit();

    const str = try bd.toString(std.testing.allocator);
    defer std.testing.allocator.free(str);

    try std.testing.expectEqualStrings("123.456", str);
}

test "BigDecimal add" {
    var a = try BigDecimal.fromString(std.testing.allocator, "10.5");
    defer a.deinit();
    var b = try BigDecimal.fromString(std.testing.allocator, "20.25");
    defer b.deinit();

    var sum = try a.add(&b);
    defer sum.deinit();

    const str = try sum.toString(std.testing.allocator);
    defer std.testing.allocator.free(str);

    try std.testing.expectEqualStrings("30.75", str);
}

test "BigDecimal multiply" {
    var a = try BigDecimal.fromString(std.testing.allocator, "12.5");
    defer a.deinit();
    var b = try BigDecimal.fromString(std.testing.allocator, "4.0");
    defer b.deinit();

    var prod = try a.multiply(&b);
    defer prod.deinit();

    const str = try prod.toString(std.testing.allocator);
    defer std.testing.allocator.free(str);

    try std.testing.expectEqualStrings("50.00", str);
}

test "BigDecimal round" {
    var bd = try BigDecimal.fromString(std.testing.allocator, "3.14159");
    defer bd.deinit();

    var rounded = try bd.round(2);
    defer rounded.deinit();

    const str = try rounded.toString(std.testing.allocator);
    defer std.testing.allocator.free(str);

    try std.testing.expectEqualStrings("3.14", str);
}
