// Home OS - /dev/random and /dev/urandom Character Devices
// Provides cryptographic random number generation to userspace

const Basics = @import("basics");
const random = @import("../../kernel/src/random.zig");

// ============================================================================
// Device Operations
// ============================================================================

/// Read from /dev/random (blocks until sufficient entropy)
pub fn readRandom(buffer: []u8) !usize {
    // For now, /dev/random acts like /dev/urandom (non-blocking)
    // In a full implementation, this would check entropy pool levels
    // and block if insufficient entropy is available

    for (buffer) |*byte| {
        byte.* = @truncate(random.getRandom());
    }

    return buffer.len;
}

/// Read from /dev/urandom (non-blocking, always returns)
pub fn readUrandom(buffer: []u8) !usize {
    for (buffer) |*byte| {
        byte.* = @truncate(random.getRandom());
    }

    return buffer.len;
}

/// Write to /dev/random (adds entropy to pool)
pub fn writeRandom(data: []const u8) !usize {
    // Add user-provided data to entropy pool
    random.addEntropy(data);
    return data.len;
}

/// Write to /dev/urandom (adds entropy to pool)
pub fn writeUrandom(data: []const u8) !usize {
    // Same as /dev/random
    random.addEntropy(data);
    return data.len;
}

// ============================================================================
// ioctl operations
// ============================================================================

pub const RNDGETENTCNT = 0x80045200; // Get entropy count
pub const RNDADDTOENTCNT = 0x40045201; // Add to entropy count
pub const RNDADDENTROPY = 0x40085203; // Add entropy

/// ioctl handler for /dev/random and /dev/urandom
pub fn ioctlRandom(cmd: u32, arg: usize) !usize {
    return switch (cmd) {
        RNDGETENTCNT => blk: {
            // Return current entropy count (in bits)
            // For now, we always report high entropy (256 bits)
            const entropy_bits: u32 = 256;
            const ptr: *u32 = @ptrFromInt(arg);
            ptr.* = entropy_bits;
            break :blk 0;
        },
        RNDADDTOENTCNT => blk: {
            // Add to entropy count (privileged operation)
            // For now, no-op
            break :blk 0;
        },
        RNDADDENTROPY => blk: {
            // Add entropy to pool (privileged operation)
            // Format: struct { entropy_count: u32, buf_size: u32, buf: [*]u8 }
            // For now, no-op
            _ = arg;
            break :blk 0;
        },
        else => error.InvalidIoctl,
    };
}

// ============================================================================
// Tests
// ============================================================================

test "read random fills buffer" {
    var buffer: [16]u8 = undefined;
    const bytes_read = try readRandom(&buffer);

    try Basics.testing.expect(bytes_read == 16);

    // Check that not all bytes are zero (very unlikely with real RNG)
    var all_zero = true;
    for (buffer) |byte| {
        if (byte != 0) {
            all_zero = false;
            break;
        }
    }
    try Basics.testing.expect(!all_zero);
}

test "read urandom fills buffer" {
    var buffer: [16]u8 = undefined;
    const bytes_read = try readUrandom(&buffer);

    try Basics.testing.expect(bytes_read == 16);
}

test "write random accepts entropy" {
    const entropy = "some random entropy data";
    const bytes_written = try writeRandom(entropy);

    try Basics.testing.expect(bytes_written == entropy.len);
}

test "ioctl get entropy count" {
    var entropy_count: u32 = 0;
    const result = try ioctlRandom(RNDGETENTCNT, @intFromPtr(&entropy_count));

    try Basics.testing.expect(result == 0);
    try Basics.testing.expect(entropy_count == 256); // We always report 256 bits
}
