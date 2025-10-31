// Intel VT-d (DMA Remapping) Implementation
// Implements DMA remapping hardware support

const std = @import("std");
const iommu = @import("iommu.zig");
const domain = @import("domain.zig");

/// DMA Remapping Hardware Unit
pub const DRHD = struct {
    base_addr: u64, // Base address of remapping hardware
    segment: u16, // PCI segment number
    flags: Flags,
    scope: []const DeviceScope,

    pub const Flags = packed struct {
        include_pci_all: bool, // Covers all PCI devices under segment
        reserved: u7 = 0,
    };

    pub const DeviceScope = struct {
        scope_type: ScopeType,
        bus: u8,
        path: []const PathEntry,

        pub const ScopeType = enum(u8) {
            pci_endpoint = 1,
            pci_bridge = 2,
            ioapic = 3,
            msi_capable_hpet = 4,
            acpi_namespace = 5,
        };

        pub const PathEntry = struct {
            device: u5,
            function: u3,
        };
    };
};

/// DMA remapping engine
pub const DMAREngine = struct {
    drhd: DRHD,
    root_table: ?*RootTable,
    enabled: bool,
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator, drhd: DRHD) DMAREngine {
        return .{
            .drhd = drhd,
            .root_table = null,
            .enabled = false,
            .allocator = allocator,
            .mutex = std.Thread.Mutex{},
        };
    }

    pub fn enable(self: *DMAREngine) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.root_table == null) {
            return error.RootTableNotInitialized;
        }

        // In production, would program IOMMU registers:
        // 1. Write root table address to RTADDR_REG
        // 2. Clear any pending faults
        // 3. Enable translation via GCMD_REG
        // 4. Wait for status in GSTS_REG

        self.enabled = true;
    }

    pub fn disable(self: *DMAREngine) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.enabled = false;
    }

    pub fn isEnabled(self: *const DMAREngine) bool {
        return self.enabled;
    }

    pub fn setRootTable(self: *DMAREngine, root_table: *RootTable) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.root_table = root_table;
    }
};

/// Root table (one per IOMMU)
pub const RootTable = struct {
    entries: [256]*RootEntry, // One entry per bus (0-255)
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !*RootTable {
        const table = try allocator.create(RootTable);
        table.allocator = allocator;

        // Initialize all entries
        for (&table.entries) |*entry_ptr| {
            const entry = try allocator.create(RootEntry);
            entry.* = RootEntry.init();
            entry_ptr.* = entry;
        }

        return table;
    }

    pub fn deinit(self: *RootTable) void {
        for (self.entries) |entry| {
            self.allocator.destroy(entry);
        }
        self.allocator.destroy(self);
    }

    pub fn getEntry(self: *RootTable, bus: u8) *RootEntry {
        return self.entries[bus];
    }
};

/// Root table entry (one per bus)
pub const RootEntry = struct {
    present: bool,
    context_table_ptr: ?*ContextTable,

    pub fn init() RootEntry {
        return .{
            .present = false,
            .context_table_ptr = null,
        };
    }

    pub fn setContextTable(self: *RootEntry, table: *ContextTable) void {
        self.context_table_ptr = table;
        self.present = true;
    }

    pub fn isPresent(self: *const RootEntry) bool {
        return self.present;
    }
};

/// Context table (one per bus, 256 entries for devfn)
pub const ContextTable = struct {
    entries: [256]*ContextEntry, // One entry per device-function (0-255)
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !*ContextTable {
        const table = try allocator.create(ContextTable);
        table.allocator = allocator;

        for (&table.entries) |*entry_ptr| {
            const entry = try allocator.create(ContextEntry);
            entry.* = ContextEntry.init();
            entry_ptr.* = entry;
        }

        return table;
    }

    pub fn deinit(self: *ContextTable) void {
        for (self.entries) |entry| {
            self.allocator.destroy(entry);
        }
        self.allocator.destroy(self);
    }

    pub fn getEntry(self: *ContextTable, devfn: u8) *ContextEntry {
        return self.entries[devfn];
    }
};

/// Context entry (maps device to domain)
pub const ContextEntry = struct {
    present: bool,
    fault_processing_disable: bool,
    translation_type: TranslationType,
    domain_id: u16,
    address_width: AddressWidth,
    second_level_page_table: ?u64, // Physical address of page table

    pub const TranslationType = enum(u2) {
        untranslated = 0, // Pass-through (no translation)
        translated_requests_only = 1,
        translated_all = 2,
        reserved = 3,
    };

    pub const AddressWidth = enum(u3) {
        width_30bit = 0, // 1GB (2^30)
        width_39bit = 1, // 512GB (2^39)
        width_48bit = 2, // 256TB (2^48)
        width_57bit = 3, // 128PB (2^57)
        width_64bit = 4, // 16EB (2^64, not widely supported)
        reserved1 = 5,
        reserved2 = 6,
        reserved3 = 7,
    };

    pub fn init() ContextEntry {
        return .{
            .present = false,
            .fault_processing_disable = false,
            .translation_type = .untranslated,
            .domain_id = 0,
            .address_width = .width_48bit,
            .second_level_page_table = null,
        };
    }

    pub fn setDomain(self: *ContextEntry, domain_id: u16, page_table_addr: u64) void {
        self.present = true;
        self.translation_type = .translated_all;
        self.domain_id = domain_id;
        self.second_level_page_table = page_table_addr;
    }

    pub fn setPassthrough(self: *ContextEntry) void {
        self.present = true;
        self.translation_type = .untranslated;
    }

    pub fn isPresent(self: *const ContextEntry) bool {
        return self.present;
    }

    pub fn isPassthrough(self: *const ContextEntry) bool {
        return self.present and self.translation_type == .untranslated;
    }
};

/// DMA remapping manager
pub const DMARManager = struct {
    engines: std.ArrayList(DMAREngine),
    device_mappings: std.AutoHashMap(iommu.DeviceID, u16), // Device -> Domain ID
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator) DMARManager {
        return .{
            .engines = std.ArrayList(DMAREngine){},
            .device_mappings = std.AutoHashMap(iommu.DeviceID, u16).init(allocator),
            .allocator = allocator,
            .mutex = std.Thread.Mutex{},
        };
    }

    pub fn deinit(self: *DMARManager) void {
        self.engines.deinit(self.allocator);
        self.device_mappings.deinit();
    }

    pub fn addEngine(self: *DMARManager, engine: DMAREngine) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.engines.append(self.allocator, engine);
    }

    pub fn attachDevice(
        self: *DMARManager,
        device_id: iommu.DeviceID,
        domain_id: u16,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.device_mappings.put(device_id, domain_id);
    }

    pub fn detachDevice(self: *DMARManager, device_id: iommu.DeviceID) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        _ = self.device_mappings.remove(device_id);
    }

    pub fn getDeviceDomain(self: *DMARManager, device_id: iommu.DeviceID) ?u16 {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.device_mappings.get(device_id);
    }

    pub fn getDeviceCount(self: *DMARManager) usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.device_mappings.count();
    }
};

test "DMAR engine" {
    const testing = std.testing;

    const drhd = DRHD{
        .base_addr = 0xFED90000,
        .segment = 0,
        .flags = .{ .include_pci_all = false },
        .scope = &.{},
    };

    var engine = DMAREngine.init(testing.allocator, drhd);

    try testing.expect(!engine.isEnabled());
}

test "root and context tables" {
    const testing = std.testing;

    var root_table = try RootTable.init(testing.allocator);
    defer root_table.deinit();

    const bus0_entry = root_table.getEntry(0);
    try testing.expect(!bus0_entry.isPresent());

    var context_table = try ContextTable.init(testing.allocator);
    defer context_table.deinit();

    bus0_entry.setContextTable(context_table);
    try testing.expect(bus0_entry.isPresent());
}

test "context entry" {
    const testing = std.testing;

    var entry = ContextEntry.init();

    try testing.expect(!entry.isPresent());
    try testing.expect(!entry.isPassthrough());

    entry.setPassthrough();
    try testing.expect(entry.isPresent());
    try testing.expect(entry.isPassthrough());

    entry.setDomain(42, 0x1000);
    try testing.expect(entry.isPresent());
    try testing.expect(!entry.isPassthrough());
    try testing.expectEqual(@as(u16, 42), entry.domain_id);
}

test "DMAR manager" {
    const testing = std.testing;

    var manager = DMARManager.init(testing.allocator);
    defer manager.deinit();

    const dev = iommu.DeviceID.init(0, 0x00, 0x1F, 0x0);

    // Attach device to domain
    try manager.attachDevice(dev, 1);
    try testing.expectEqual(@as(usize, 1), manager.getDeviceCount());

    // Check domain mapping
    const domain_id = manager.getDeviceDomain(dev);
    try testing.expectEqual(@as(u16, 1), domain_id.?);

    // Detach device
    try manager.detachDevice(dev);
    try testing.expectEqual(@as(usize, 0), manager.getDeviceCount());
}
