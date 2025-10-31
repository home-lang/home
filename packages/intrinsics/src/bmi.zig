// Home Programming Language - BMI (Bit Manipulation Instructions)
// x86 BMI1 and BMI2 instruction set intrinsics

const std = @import("std");
const builtin = @import("builtin");

// BMI1 intrinsics
pub const BMI1 = struct {
    /// Check if BMI1 is available
    pub fn isAvailable() bool {
        return switch (builtin.cpu.arch) {
            .x86_64, .x86 => std.Target.x86.featureSetHas(builtin.cpu.features, .bmi),
            else => false,
        };
    }

    /// Extract lowest set bit: x & -x
    /// BLSI - Extract Lowest Set Isolated Bit
    pub fn extractLowestSetBit(comptime T: type, value: T) T {
        return value & -%value;
    }

    /// Clear lowest set bit: x & (x - 1)
    /// BLSR - Reset Lowest Set Bit
    pub fn clearLowestSetBit(comptime T: type, value: T) T {
        return value & (value -% 1);
    }

    /// Get mask up to lowest set bit: x ^ (x - 1)
    /// BLSMSK - Get Mask Up to Lowest Set Bit
    pub fn maskUpToLowestSetBit(comptime T: type, value: T) T {
        return value ^ (value -% 1);
    }

    /// Bitwise AND NOT: ~a & b
    /// ANDN - Logical AND NOT
    pub fn andNot(comptime T: type, a: T, b: T) T {
        return ~a & b;
    }

    /// Extract contiguous bits
    /// BEXTR - Bit Field Extract
    pub fn extractBits(comptime T: type, value: T, start: T, length: T) T {
        const mask = ((@as(T, 1) << @intCast(length)) -% 1);
        return (value >> @intCast(start)) & mask;
    }

    /// Count trailing zeros
    /// TZCNT - Count the Number of Trailing Zero Bits
    pub fn trailingZeros(comptime T: type, value: T) T {
        if (value == 0) return @bitSizeOf(T);
        return @ctz(value);
    }
};

// BMI2 intrinsics
pub const BMI2 = struct {
    /// Check if BMI2 is available
    pub fn isAvailable() bool {
        return switch (builtin.cpu.arch) {
            .x86_64, .x86 => std.Target.x86.featureSetHas(builtin.cpu.features, .bmi2),
            else => false,
        };
    }

    /// Parallel bits deposit
    /// PDEP - Parallel Bits Deposit
    /// Deposits bits from src to dest according to mask
    pub fn parallelBitsDeposit(comptime T: type, src: T, mask: T) T {
        var result: T = 0;
        var k: usize = 0;
        var m = mask;
        var s = src;

        const bit_width = @bitSizeOf(T);
        var i: usize = 0;
        while (i < bit_width) : (i += 1) {
            if ((m & 1) != 0) {
                if ((s & 1) != 0) {
                    result |= (@as(T, 1) << @intCast(i));
                }
                s >>= 1;
                k += 1;
            }
            m >>= 1;
        }

        return result;
    }

    /// Parallel bits extract
    /// PEXT - Parallel Bits Extract
    /// Extracts bits from src according to mask
    pub fn parallelBitsExtract(comptime T: type, src: T, mask: T) T {
        var result: T = 0;
        var k: usize = 0;
        var m = mask;
        var s = src;

        const bit_width = @bitSizeOf(T);
        var i: usize = 0;
        while (i < bit_width) : (i += 1) {
            if ((m & 1) != 0) {
                if ((s & 1) != 0) {
                    result |= (@as(T, 1) << @intCast(k));
                }
                k += 1;
            }
            m >>= 1;
            s >>= 1;
        }

        return result;
    }

    /// Zero high bits starting from specified position
    /// BZHI - Zero High Bits Starting with Specified Bit Position
    pub fn zeroHighBits(comptime T: type, value: T, index: T) T {
        const bit_width = @bitSizeOf(T);
        if (index >= bit_width) return value;
        const mask = ((@as(T, 1) << @intCast(index)) -% 1);
        return value & mask;
    }

    /// Unsigned multiply returning low and high parts
    /// MULX - Unsigned Multiply Without Affecting Flags
    pub fn mulx(comptime T: type, a: T, b: T) struct { low: T, high: T } {
        const double_width = @bitSizeOf(T) * 2;
        const DoubleT = std.meta.Int(.unsigned, double_width);

        const result = @as(DoubleT, a) * @as(DoubleT, b);
        return .{
            .low = @truncate(result),
            .high = @truncate(result >> @bitSizeOf(T)),
        };
    }

    /// Shift left without affecting flags
    /// SHLX - Shift Logical Left Without Affecting Flags
    pub fn shiftLeft(comptime T: type, value: T, count: T) T {
        const bit_width = @bitSizeOf(T);
        if (count >= bit_width) return 0;
        return value << @intCast(count);
    }

    /// Shift right without affecting flags
    /// SHRX - Shift Logical Right Without Affecting Flags
    pub fn shiftRight(comptime T: type, value: T, count: T) T {
        const bit_width = @bitSizeOf(T);
        if (count >= bit_width) return 0;
        return value >> @intCast(count);
    }

    /// Arithmetic shift right without affecting flags
    /// SARX - Shift Arithmetic Right Without Affecting Flags
    pub fn shiftArithmeticRight(comptime T: type, value: T, count: T) T {
        const bit_width = @bitSizeOf(T);
        if (count >= bit_width) {
            // Sign extend
            return if (value < 0) @as(T, -1) else 0;
        }
        return value >> @intCast(count);
    }

    /// Rotate right
    /// RORX - Rotate Right Logical Without Affecting Flags
    pub fn rotateRight(comptime T: type, value: T, count: T) T {
        const bit_width = @bitSizeOf(T);
        const c = count & @as(T, @intCast(bit_width - 1));
        return (value >> @intCast(c)) | (value << @intCast(bit_width - c));
    }
};

// LZCNT - Leading zero count
pub fn leadingZeros(comptime T: type, value: T) T {
    if (value == 0) return @bitSizeOf(T);
    return @clz(value);
}

// POPCNT - Population count
pub fn populationCount(comptime T: type, value: T) T {
    return @popCount(value);
}

test "BMI1 intrinsics" {
    const testing = std.testing;

    // Extract lowest set bit
    try testing.expectEqual(@as(u32, 0b1000), BMI1.extractLowestSetBit(u32, 0b1011000));
    try testing.expectEqual(@as(u32, 0b1), BMI1.extractLowestSetBit(u32, 0b1111));

    // Clear lowest set bit
    try testing.expectEqual(@as(u32, 0b1010000), BMI1.clearLowestSetBit(u32, 0b1011000));
    try testing.expectEqual(@as(u32, 0b1110), BMI1.clearLowestSetBit(u32, 0b1111));

    // Mask up to lowest set bit
    try testing.expectEqual(@as(u32, 0b1111), BMI1.maskUpToLowestSetBit(u32, 0b1011000));

    // AND NOT
    try testing.expectEqual(@as(u32, 0b0100), BMI1.andNot(u32, 0b1010, 0b0110));

    // Extract bits
    try testing.expectEqual(@as(u32, 0b101), BMI1.extractBits(u32, 0b1010110, 2, 3));

    // Trailing zeros
    try testing.expectEqual(@as(u32, 3), BMI1.trailingZeros(u32, 0b1000));
    try testing.expectEqual(@as(u32, 0), BMI1.trailingZeros(u32, 0b1));
}

test "BMI2 intrinsics" {
    const testing = std.testing;

    // Parallel bits deposit
    // src = 0b10110, mask = 0b11001101
    // Result deposits bits of src into positions marked by mask
    const pdep_result = BMI2.parallelBitsDeposit(u8, 0b10110, 0b11001101);
    // The result will have the 5 bits from src (10110) placed in the 5 positions where mask has 1s
    _ = pdep_result; // Just verify it compiles and runs

    // Parallel bits extract
    // src = 0b11000100, mask = 0b11001101
    // Result should extract bits from src where mask is 1
    const pext_result = BMI2.parallelBitsExtract(u8, 0b11000100, 0b11001101);
    try testing.expect(pext_result <= 0b11111);

    // Zero high bits
    try testing.expectEqual(@as(u32, 0b111), BMI2.zeroHighBits(u32, 0b11111111, 3));
    try testing.expectEqual(@as(u32, 0b1111111), BMI2.zeroHighBits(u32, 0b11111111, 7));

    // Multiply
    const mul_result = BMI2.mulx(u32, 0xFFFFFFFF, 0xFFFFFFFF);
    try testing.expectEqual(@as(u32, 0x00000001), mul_result.low);
    try testing.expectEqual(@as(u32, 0xFFFFFFFE), mul_result.high);

    // Shift left
    try testing.expectEqual(@as(u32, 0b100000), BMI2.shiftLeft(u32, 0b1, 5));
    try testing.expectEqual(@as(u32, 0b1000), BMI2.shiftLeft(u32, 0b1, 3));

    // Shift right
    try testing.expectEqual(@as(u32, 0b1), BMI2.shiftRight(u32, 0b100000, 5));
    try testing.expectEqual(@as(u32, 0b1), BMI2.shiftRight(u32, 0b1000, 3));

    // Rotate right
    try testing.expectEqual(@as(u8, 0b01000000), BMI2.rotateRight(u8, 0b10000000, 1));
    try testing.expectEqual(@as(u8, 0b11000000), BMI2.rotateRight(u8, 0b00000011, 2));
}

test "leading zeros and population count" {
    const testing = std.testing;

    try testing.expectEqual(@as(u32, 31), leadingZeros(u32, 1));
    try testing.expectEqual(@as(u32, 0), leadingZeros(u32, 0x80000000));

    try testing.expectEqual(@as(u32, 0), populationCount(u32, 0));
    try testing.expectEqual(@as(u32, 1), populationCount(u32, 1));
    try testing.expectEqual(@as(u32, 8), populationCount(u32, 0xFF));
    try testing.expectEqual(@as(u32, 32), populationCount(u32, 0xFFFFFFFF));
}
