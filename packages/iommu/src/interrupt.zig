// Interrupt Remapping
// Protects against interrupt injection attacks

const std = @import("std");
const iommu = @import("iommu.zig");

/// Interrupt remapping table entry (IRTE)
pub const IRTE = struct {
    present: bool,
    destination_id: u32, // Target CPU/APIC ID
    vector: u8, // Interrupt vector
    delivery_mode: DeliveryMode,
    trigger_mode: TriggerMode,
    destination_mode: DestinationMode,
    posted: bool, // Posted interrupt support

    pub const DeliveryMode = enum(u3) {
        fixed = 0,
        lowest_priority = 1,
        smi = 2,
        nmi = 4,
        init = 5,
        ext_int = 7,
    };

    pub const TriggerMode = enum(u1) {
        edge = 0,
        level = 1,
    };

    pub const DestinationMode = enum(u1) {
        physical = 0,
        logical = 1,
    };

    pub fn init() IRTE {
        return .{
            .present = false,
            .destination_id = 0,
            .vector = 0,
            .delivery_mode = .fixed,
            .trigger_mode = .edge,
            .destination_mode = .physical,
            .posted = false,
        };
    }

    pub fn configure(
        self: *IRTE,
        destination: u32,
        vector: u8,
        delivery_mode: DeliveryMode,
    ) void {
        self.present = true;
        self.destination_id = destination;
        self.vector = vector;
        self.delivery_mode = delivery_mode;
    }

    pub fn isPresent(self: *const IRTE) bool {
        return self.present;
    }
};

/// Interrupt remapping table
pub const InterruptRemappingTable = struct {
    entries: []IRTE,
    size: usize, // Number of entries (must be power of 2)
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator, size: usize) !InterruptRemappingTable {
        // Size must be power of 2
        if (size == 0 or (size & (size - 1)) != 0) {
            return error.InvalidSize;
        }

        const entries = try allocator.alloc(IRTE, size);
        for (entries) |*entry| {
            entry.* = IRTE.init();
        }

        return .{
            .entries = entries,
            .size = size,
            .allocator = allocator,
            .mutex = std.Thread.Mutex{},
        };
    }

    pub fn deinit(self: *InterruptRemappingTable) void {
        self.allocator.free(self.entries);
    }

    pub fn getEntry(self: *InterruptRemappingTable, index: usize) ?*IRTE {
        if (index >= self.size) return null;

        self.mutex.lock();
        defer self.mutex.unlock();

        return &self.entries[index];
    }

    pub fn setEntry(self: *InterruptRemappingTable, index: usize, entry: IRTE) !void {
        if (index >= self.size) return error.IndexOutOfBounds;

        self.mutex.lock();
        defer self.mutex.unlock();

        self.entries[index] = entry;
    }

    pub fn allocateEntry(self: *InterruptRemappingTable) ?usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Find first free entry
        for (self.entries, 0..) |*entry, i| {
            if (!entry.present) {
                return i;
            }
        }

        return null;
    }

    pub fn freeEntry(self: *InterruptRemappingTable, index: usize) !void {
        if (index >= self.size) return error.IndexOutOfBounds;

        self.mutex.lock();
        defer self.mutex.unlock();

        self.entries[index] = IRTE.init();
    }

    pub fn getPresentCount(self: *InterruptRemappingTable) usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        var count: usize = 0;
        for (self.entries) |entry| {
            if (entry.present) count += 1;
        }
        return count;
    }
};

/// MSI (Message Signaled Interrupt) address
pub const MSIAddress = packed struct {
    reserved1: u2 = 0,
    destination_mode: u1, // 0=physical, 1=logical
    redirection_hint: u1,
    reserved2: u8 = 0,
    destination_id: u8,
    base_address: u12 = 0xFEE, // Fixed MSI base (0xFEE00000)

    pub fn init(destination_id: u8, physical: bool) MSIAddress {
        return .{
            .destination_mode = if (physical) 0 else 1,
            .redirection_hint = 0,
            .destination_id = destination_id,
        };
    }

    pub fn toU32(self: MSIAddress) u32 {
        return @bitCast(self);
    }
};

/// MSI data
pub const MSIData = packed struct {
    vector: u8,
    delivery_mode: u3, // Same as IRTE.DeliveryMode
    reserved1: u3 = 0,
    level_assert: u1,
    trigger_mode: u1, // 0=edge, 1=level
    reserved2: u16 = 0,

    pub fn init(vector: u8, edge_triggered: bool) MSIData {
        return .{
            .vector = vector,
            .delivery_mode = 0, // Fixed
            .level_assert = 1,
            .trigger_mode = if (edge_triggered) 0 else 1,
        };
    }

    pub fn toU32(self: MSIData) u32 {
        return @bitCast(self);
    }
};

/// Interrupt remapping manager
pub const InterruptRemappingManager = struct {
    table: InterruptRemappingTable,
    enabled: bool,
    device_mappings: std.AutoHashMap(iommu.DeviceID, usize), // Device -> IRTE index
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator, table_size: usize) !InterruptRemappingManager {
        return .{
            .table = try InterruptRemappingTable.init(allocator, table_size),
            .enabled = false,
            .device_mappings = std.AutoHashMap(iommu.DeviceID, usize).init(allocator),
            .allocator = allocator,
            .mutex = std.Thread.Mutex{},
        };
    }

    pub fn deinit(self: *InterruptRemappingManager) void {
        self.table.deinit();
        self.device_mappings.deinit();
    }

    pub fn enable(self: *InterruptRemappingManager) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.enabled = true;

        // In production, would program IOMMU registers:
        // 1. Write interrupt remapping table address
        // 2. Set table size
        // 3. Enable interrupt remapping
        // 4. Enable extended interrupt mode if supported
    }

    pub fn disable(self: *InterruptRemappingManager) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.enabled = false;
    }

    pub fn mapDeviceInterrupt(
        self: *InterruptRemappingManager,
        device_id: iommu.DeviceID,
        destination: u32,
        vector: u8,
    ) !usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Allocate IRTE
        const index = self.table.allocateEntry() orelse return error.NoFreeEntries;

        // Configure IRTE
        if (self.table.getEntry(index)) |entry| {
            entry.configure(destination, vector, .fixed);
        }

        // Map device to IRTE
        try self.device_mappings.put(device_id, index);

        return index;
    }

    pub fn unmapDeviceInterrupt(
        self: *InterruptRemappingManager,
        device_id: iommu.DeviceID,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.device_mappings.get(device_id)) |index| {
            try self.table.freeEntry(index);
            _ = self.device_mappings.remove(device_id);
        }
    }

    pub fn getDeviceIRTEIndex(
        self: *InterruptRemappingManager,
        device_id: iommu.DeviceID,
    ) ?usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.device_mappings.get(device_id);
    }

    pub fn isEnabled(self: *const InterruptRemappingManager) bool {
        return self.enabled;
    }

    pub fn getMappedDeviceCount(self: *InterruptRemappingManager) usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.device_mappings.count();
    }
};

test "IRTE initialization" {
    const testing = std.testing;

    var irte = IRTE.init();
    try testing.expect(!irte.isPresent());

    irte.configure(0, 0x30, .fixed);
    try testing.expect(irte.isPresent());
    try testing.expectEqual(@as(u8, 0x30), irte.vector);
}

test "interrupt remapping table" {
    const testing = std.testing;

    var table = try InterruptRemappingTable.init(testing.allocator, 256);
    defer table.deinit();

    try testing.expectEqual(@as(usize, 256), table.size);
    try testing.expectEqual(@as(usize, 0), table.getPresentCount());

    // Allocate entry
    const index = table.allocateEntry();
    try testing.expect(index != null);
    try testing.expectEqual(@as(usize, 0), index.?);

    // Configure entry
    var irte = IRTE.init();
    irte.configure(0, 0x40, .fixed);
    try table.setEntry(index.?, irte);

    try testing.expectEqual(@as(usize, 1), table.getPresentCount());

    // Free entry
    try table.freeEntry(index.?);
    try testing.expectEqual(@as(usize, 0), table.getPresentCount());
}

test "MSI address and data" {
    const testing = std.testing;

    const msi_addr = MSIAddress.init(0x12, true);
    const addr_u32 = msi_addr.toU32();

    // MSI address should have 0xFEE as upper 12 bits
    try testing.expectEqual(@as(u32, 0xFEE00000), addr_u32 & 0xFFF00000);

    const msi_data = MSIData.init(0x50, true);
    const data_u32 = msi_data.toU32();

    try testing.expectEqual(@as(u8, 0x50), @as(u8, @truncate(data_u32)));
}

test "interrupt remapping manager" {
    const testing = std.testing;

    var manager = try InterruptRemappingManager.init(testing.allocator, 128);
    defer manager.deinit();

    try testing.expect(!manager.isEnabled());

    manager.enable();
    try testing.expect(manager.isEnabled());

    const dev = iommu.DeviceID.init(0, 0x00, 0x1F, 0x0);

    // Map device interrupt
    const irte_index = try manager.mapDeviceInterrupt(dev, 0, 0x42);
    try testing.expect(irte_index < 128);
    try testing.expectEqual(@as(usize, 1), manager.getMappedDeviceCount());

    // Check mapping
    const mapped_index = manager.getDeviceIRTEIndex(dev);
    try testing.expectEqual(irte_index, mapped_index.?);

    // Unmap device interrupt
    try manager.unmapDeviceInterrupt(dev);
    try testing.expectEqual(@as(usize, 0), manager.getMappedDeviceCount());
}

test "table size validation" {
    const testing = std.testing;

    // Size must be power of 2
    const result1 = InterruptRemappingTable.init(testing.allocator, 127);
    try testing.expectError(error.InvalidSize, result1);

    const result2 = InterruptRemappingTable.init(testing.allocator, 0);
    try testing.expectError(error.InvalidSize, result2);

    // Valid sizes
    var table = try InterruptRemappingTable.init(testing.allocator, 128);
    defer table.deinit();
    try testing.expectEqual(@as(usize, 128), table.size);
}
