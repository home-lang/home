// Core dump capture functionality

const std = @import("std");
const coredump = @import("coredump.zig");

/// Memory region types
pub const RegionType = enum {
    stack,
    heap,
    code,
    data,
    registers,
    unknown,
};

/// Memory region
pub const MemoryRegion = struct {
    type: RegionType,
    start_addr: usize,
    end_addr: usize,
    permissions: u8, // rwx
    data: []u8,
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        region_type: RegionType,
        start: usize,
        end: usize,
        perms: u8,
    ) !MemoryRegion {
        const region_size = end - start;
        const data = try allocator.alloc(u8, region_size);

        return .{
            .type = region_type,
            .start_addr = start,
            .end_addr = end,
            .permissions = perms,
            .data = data,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MemoryRegion) void {
        self.allocator.free(self.data);
    }

    pub fn size(self: *const MemoryRegion) usize {
        return self.end_addr - self.start_addr;
    }

    pub fn isReadable(self: *const MemoryRegion) bool {
        return (self.permissions & 0x4) != 0;
    }

    pub fn isWritable(self: *const MemoryRegion) bool {
        return (self.permissions & 0x2) != 0;
    }

    pub fn isExecutable(self: *const MemoryRegion) bool {
        return (self.permissions & 0x1) != 0;
    }
};

/// Process state snapshot
pub const ProcessSnapshot = struct {
    pid: u32,
    tid: u32,
    regions: std.ArrayList(MemoryRegion),
    registers: [32]u64, // General purpose registers
    signal: u32,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, pid: u32) ProcessSnapshot {
        return .{
            .pid = pid,
            .tid = 0,
            .regions = std.ArrayList(MemoryRegion){},
            .registers = [_]u64{0} ** 32,
            .signal = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ProcessSnapshot) void {
        for (self.regions.items) |*region| {
            region.deinit();
        }
        self.regions.deinit(self.allocator);
    }

    pub fn addRegion(self: *ProcessSnapshot, region: MemoryRegion) !void {
        try self.regions.append(self.allocator, region);
    }

    pub fn totalSize(self: *const ProcessSnapshot) usize {
        var total: usize = 0;
        for (self.regions.items) |*region| {
            total += region.size();
        }
        return total;
    }

    pub fn serialize(self: *const ProcessSnapshot, allocator: std.mem.Allocator) ![]u8 {
        var buffer = std.ArrayList(u8){};
        defer buffer.deinit(allocator);

        // Write PID, TID, signal
        try buffer.appendSlice(allocator, &std.mem.toBytes(self.pid));
        try buffer.appendSlice(allocator, &std.mem.toBytes(self.tid));
        try buffer.appendSlice(allocator, &std.mem.toBytes(self.signal));

        // Write registers
        for (self.registers) |reg| {
            try buffer.appendSlice(allocator, &std.mem.toBytes(reg));
        }

        // Write region count
        const region_count: u32 = @truncate(self.regions.items.len);
        try buffer.appendSlice(allocator, &std.mem.toBytes(region_count));

        // Write each region
        for (self.regions.items) |*region| {
            try buffer.appendSlice(allocator, &std.mem.toBytes(@intFromEnum(region.type)));
            try buffer.appendSlice(allocator, &std.mem.toBytes(region.start_addr));
            try buffer.appendSlice(allocator, &std.mem.toBytes(region.end_addr));
            try buffer.appendSlice(allocator, &std.mem.toBytes(region.permissions));

            const size: u64 = region.size();
            try buffer.appendSlice(allocator, &std.mem.toBytes(size));
            try buffer.appendSlice(allocator, region.data);
        }

        return buffer.toOwnedSlice(allocator);
    }
};

/// Capture process snapshot (simplified)
pub fn captureProcess(allocator: std.mem.Allocator, pid: u32, config: coredump.DumpConfig) !ProcessSnapshot {
    var snapshot = ProcessSnapshot.init(allocator, pid);
    errdefer snapshot.deinit();

    // In production, would read from /proc/[pid]/maps and /proc/[pid]/mem
    // For demonstration, create dummy regions

    if (config.encrypt_stack) {
        const stack = try MemoryRegion.init(allocator, .stack, 0x7fff_0000, 0x7fff_1000, 0x6);
        // Fill with dummy data
        @memset(stack.data, 0xAA);
        try snapshot.addRegion(stack);
    }

    if (config.encrypt_heap) {
        const heap = try MemoryRegion.init(allocator, .heap, 0x0000_1000, 0x0000_2000, 0x6);
        @memset(heap.data, 0xBB);
        try snapshot.addRegion(heap);
    }

    if (config.encrypt_registers) {
        // Dummy register values
        var i: usize = 0;
        while (i < 32) : (i += 1) {
            snapshot.registers[i] = 0x1000 + i;
        }
    }

    snapshot.signal = 11; // SIGSEGV

    return snapshot;
}

/// Filter sensitive regions
pub fn filterSensitiveRegions(snapshot: *ProcessSnapshot, config: coredump.DumpConfig) void {
    if (!config.redact_sensitive) return;

    // Zero out regions that might contain sensitive data
    for (snapshot.regions.items) |*region| {
        // Redact writable regions (likely contain runtime data)
        if (region.isWritable() and !region.isExecutable()) {
            // Scan for potential sensitive patterns
            redactSensitivePatterns(region.data);
        }
    }
}

fn redactSensitivePatterns(data: []u8) void {
    // Look for patterns like environment variables, API keys, etc.
    var i: usize = 0;
    while (i < data.len) : (i += 1) {
        // Redact anything that looks like "TOKEN=", "KEY=", etc.
        if (i + 6 < data.len) {
            if ((data[i] == 'T' or data[i] == 'K') and
                (i + 5 < data.len and data[i + 5] == '='))
            {
                // Redact next 32 bytes
                const end = @min(i + 6 + 32, data.len);
                @memset(data[i + 6 .. end], 0);
            }
        }
    }
}

test "memory region" {
    const testing = std.testing;

    const region = try MemoryRegion.init(testing.allocator, .stack, 0x1000, 0x2000, 0x6);
    defer {
        var mut_region = region;
        mut_region.deinit();
    }

    try testing.expectEqual(@as(usize, 0x1000), region.size());
    try testing.expect(region.isReadable());
    try testing.expect(region.isWritable());
    try testing.expect(!region.isExecutable());
}

test "process snapshot" {
    const testing = std.testing;

    var snapshot = ProcessSnapshot.init(testing.allocator, 1234);
    defer snapshot.deinit();

    var region = try MemoryRegion.init(testing.allocator, .heap, 0x1000, 0x2000, 0x6);
    try snapshot.addRegion(region);

    try testing.expectEqual(@as(usize, 0x1000), snapshot.totalSize());
}

test "capture process" {
    const testing = std.testing;

    const config = coredump.DumpConfig{};

    var snapshot = try captureProcess(testing.allocator, 9999, config);
    defer snapshot.deinit();

    try testing.expect(snapshot.regions.items.len > 0);
    try testing.expect(snapshot.totalSize() > 0);
}
