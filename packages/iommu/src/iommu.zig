// IOMMU (Input-Output Memory Management Unit) Support
// DMA protection, device isolation, and memory remapping

const std = @import("std");

pub const dmar = @import("dmar.zig"); // Intel VT-d (DMA Remapping)
pub const iommu_domain = @import("domain.zig");
pub const page_table = @import("page_table.zig");
pub const interrupt = @import("interrupt.zig");

/// IOMMU type
pub const IOMMUType = enum {
    intel_vtd, // Intel VT-d
    amd_vi, // AMD-Vi (IOMMU)
    arm_smmu, // ARM System MMU
    none, // No IOMMU
};

/// IOMMU capabilities
pub const Capabilities = packed struct {
    page_walk_coherency: bool, // Hardware page table walk cache coherency
    write_draining: bool, // Required write buffer draining
    protected_low_memory: bool, // Low memory region protection
    protected_high_memory: bool, // High memory region protection
    interrupt_remapping: bool, // Interrupt remapping support
    device_tlb: bool, // Device TLB support
    posted_interrupts: bool, // Posted interrupt support
    page_selective_invalidation: bool, // Page-selective invalidation
    nested_translation: bool, // Nested translation support
    pasid_support: bool, // Process Address Space ID support
    reserved: u22 = 0,

    pub fn hasBasicProtection(self: Capabilities) bool {
        return self.page_walk_coherency and self.write_draining;
    }

    pub fn hasAdvancedFeatures(self: Capabilities) bool {
        return self.interrupt_remapping and self.device_tlb;
    }
};

/// IOMMU protection level
pub const ProtectionLevel = enum {
    disabled, // No DMA protection (unsafe)
    basic, // Basic DMA remapping only
    standard, // DMA remapping + interrupt remapping
    strict, // Full isolation + additional checks
};

/// Device identifier (PCI BDF: Bus-Device-Function)
pub const DeviceID = struct {
    segment: u16, // PCI segment/domain
    bus: u8, // PCI bus number
    device: u5, // PCI device number (0-31)
    function: u3, // PCI function number (0-7)

    pub fn init(segment: u16, bus: u8, device: u5, function: u3) DeviceID {
        return .{
            .segment = segment,
            .bus = bus,
            .device = device,
            .function = function,
        };
    }

    pub fn toBDF(self: DeviceID) u16 {
        return (@as(u16, self.bus) << 8) | (@as(u16, self.device) << 3) | @as(u16, self.function);
    }

    pub fn eql(self: DeviceID, other: DeviceID) bool {
        return self.segment == other.segment and
            self.bus == other.bus and
            self.device == other.device and
            self.function == other.function;
    }

    pub fn format(
        self: DeviceID,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("{X:0>4}:{X:0>2}:{X:0>2}.{}", .{
            self.segment,
            self.bus,
            self.device,
            self.function,
        });
    }
};

/// DMA address space (Physical address that device sees)
pub const DMAAddress = struct {
    addr: u64,

    pub fn init(addr: u64) DMAAddress {
        return .{ .addr = addr };
    }

    pub fn isAligned(self: DMAAddress, alignment: u64) bool {
        return (self.addr & (alignment - 1)) == 0;
    }

    pub fn add(self: DMAAddress, offset: u64) DMAAddress {
        return .{ .addr = self.addr + offset };
    }
};

/// IOMMU status
pub const Status = struct {
    enabled: bool,
    fault_count: std.atomic.Value(u64),
    remapped_devices: std.atomic.Value(u32),
    translation_errors: std.atomic.Value(u64),
    interrupt_remaps: std.atomic.Value(u64),

    pub fn init() Status {
        return .{
            .enabled = false,
            .fault_count = std.atomic.Value(u64).init(0),
            .remapped_devices = std.atomic.Value(u32).init(0),
            .translation_errors = std.atomic.Value(u64).init(0),
            .interrupt_remaps = std.atomic.Value(u64).init(0),
        };
    }

    pub fn recordFault(self: *Status) void {
        _ = self.fault_count.fetchAdd(1, .monotonic);
    }

    pub fn recordTranslationError(self: *Status) void {
        _ = self.translation_errors.fetchAdd(1, .monotonic);
    }

    pub fn recordInterruptRemap(self: *Status) void {
        _ = self.interrupt_remaps.fetchAdd(1, .monotonic);
    }

    pub fn getFaultCount(self: *const Status) u64 {
        return self.fault_count.load(.monotonic);
    }

    pub fn getTranslationErrors(self: *const Status) u64 {
        return self.translation_errors.load(.monotonic);
    }
};

/// DMA fault information
pub const Fault = struct {
    device_id: DeviceID,
    fault_addr: u64,
    fault_type: FaultType,
    timestamp: i64,
    reason: [256]u8,
    reason_len: usize,

    pub const FaultType = enum {
        invalid_address, // Device accessed invalid memory
        permission_denied, // Device doesn't have access rights
        page_not_present, // Page table entry not present
        write_to_readonly, // Write to read-only region
        reserved_field, // Reserved field violation
        context_entry_invalid, // Invalid context entry
        root_entry_invalid, // Invalid root entry
        interrupt_remap_fault, // Interrupt remapping fault
    };

    pub fn init(device_id: DeviceID, addr: u64, fault_type: FaultType, reason: []const u8) Fault {
        var fault: Fault = undefined;
        fault.device_id = device_id;
        fault.fault_addr = addr;
        fault.fault_type = fault_type;
        fault.timestamp = std.time.timestamp();

        @memset(&fault.reason, 0);
        @memcpy(fault.reason[0..reason.len], reason);
        fault.reason_len = reason.len;

        return fault;
    }

    pub fn getReason(self: *const Fault) []const u8 {
        return self.reason[0..self.reason_len];
    }
};

/// IOMMU instance
pub const IOMMU = struct {
    iommu_type: IOMMUType,
    capabilities: Capabilities,
    protection_level: ProtectionLevel,
    status: Status,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, iommu_type: IOMMUType) IOMMU {
        return .{
            .iommu_type = iommu_type,
            .capabilities = .{
                .page_walk_coherency = true,
                .write_draining = true,
                .protected_low_memory = true,
                .protected_high_memory = true,
                .interrupt_remapping = true,
                .device_tlb = true,
                .posted_interrupts = false,
                .page_selective_invalidation = true,
                .nested_translation = false,
                .pasid_support = false,
            },
            .protection_level = .standard,
            .status = Status.init(),
            .allocator = allocator,
        };
    }

    pub fn enable(self: *IOMMU) !void {
        if (self.iommu_type == .none) {
            return error.NoIOMMU;
        }

        if (!self.capabilities.hasBasicProtection()) {
            return error.InsufficientCapabilities;
        }

        self.status.enabled = true;
    }

    pub fn disable(self: *IOMMU) void {
        self.status.enabled = false;
    }

    pub fn isEnabled(self: *const IOMMU) bool {
        return self.status.enabled;
    }

    pub fn setProtectionLevel(self: *IOMMU, level: ProtectionLevel) !void {
        if (level == .disabled) {
            self.disable();
        }

        if (level == .strict and !self.capabilities.hasAdvancedFeatures()) {
            return error.UnsupportedProtectionLevel;
        }

        self.protection_level = level;
    }

    pub fn recordDeviceRemapped(self: *IOMMU) void {
        _ = self.status.remapped_devices.fetchAdd(1, .monotonic);
    }

    pub fn getRemappedDeviceCount(self: *const IOMMU) u32 {
        return self.status.remapped_devices.load(.monotonic);
    }
};

test "device ID formatting" {
    const testing = std.testing;

    const dev = DeviceID.init(0, 0x1A, 0x00, 0x3);
    const bdf = dev.toBDF();

    // BDF format: bus[15:8] | device[7:3] | function[2:0]
    try testing.expectEqual(@as(u16, 0x1A03), bdf);
}

test "device ID equality" {
    const testing = std.testing;

    const dev1 = DeviceID.init(0, 0x00, 0x1F, 0x0);
    const dev2 = DeviceID.init(0, 0x00, 0x1F, 0x0);
    const dev3 = DeviceID.init(0, 0x00, 0x1F, 0x1);

    try testing.expect(dev1.eql(dev2));
    try testing.expect(!dev1.eql(dev3));
}

test "IOMMU initialization" {
    const testing = std.testing;

    var iommu = IOMMU.init(testing.allocator, .intel_vtd);

    try testing.expect(!iommu.isEnabled());
    try testing.expectEqual(IOMMUType.intel_vtd, iommu.iommu_type);
    try testing.expectEqual(ProtectionLevel.standard, iommu.protection_level);
}

test "IOMMU enable" {
    const testing = std.testing;

    var iommu = IOMMU.init(testing.allocator, .intel_vtd);

    try iommu.enable();
    try testing.expect(iommu.isEnabled());

    iommu.disable();
    try testing.expect(!iommu.isEnabled());
}

test "capabilities" {
    const testing = std.testing;

    const caps = Capabilities{
        .page_walk_coherency = true,
        .write_draining = true,
        .protected_low_memory = true,
        .protected_high_memory = true,
        .interrupt_remapping = true,
        .device_tlb = true,
        .posted_interrupts = false,
        .page_selective_invalidation = true,
        .nested_translation = false,
        .pasid_support = false,
    };

    try testing.expect(caps.hasBasicProtection());
    try testing.expect(caps.hasAdvancedFeatures());
}

test "fault recording" {
    const testing = std.testing;

    var iommu = IOMMU.init(testing.allocator, .intel_vtd);

    iommu.status.recordFault();
    iommu.status.recordFault();
    iommu.status.recordTranslationError();

    try testing.expectEqual(@as(u64, 2), iommu.status.getFaultCount());
    try testing.expectEqual(@as(u64, 1), iommu.status.getTranslationErrors());
}
