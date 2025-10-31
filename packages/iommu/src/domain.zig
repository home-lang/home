// IOMMU Domain Management
// Provides isolated address spaces for device groups

const std = @import("std");
const iommu = @import("iommu.zig");

/// Domain type
pub const DomainType = enum {
    dma, // Normal DMA domain
    identity, // 1:1 mapping (passthrough)
    unmanaged, // User-managed mappings
};

/// Domain flags
pub const DomainFlags = packed struct {
    strict: bool, // Strict TLB flushing
    coherent: bool, // Cache coherent
    snoop: bool, // Snoop control
    reserved: u13 = 0,
};

/// Memory access permissions
pub const AccessFlags = packed struct {
    read: bool,
    write: bool,
    execute: bool, // Some IOMMUs support execute permission
    reserved: u5 = 0,
};

/// IOMMU domain (isolated address space)
pub const Domain = struct {
    id: u16,
    domain_type: DomainType,
    flags: DomainFlags,
    devices: std.ArrayList(iommu.DeviceID),
    mappings: std.ArrayList(Mapping),
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,
    geometry: Geometry,

    pub const Geometry = struct {
        aperture_start: u64,
        aperture_end: u64,
        force_aperture: bool,

        pub fn init() Geometry {
            return .{
                .aperture_start = 0,
                .aperture_end = 0xFFFFFFFF_FFFFFFFF,
                .force_aperture = false,
            };
        }

        pub fn contains(self: Geometry, addr: u64) bool {
            return addr >= self.aperture_start and addr <= self.aperture_end;
        }
    };

    pub fn init(allocator: std.mem.Allocator, id: u16, domain_type: DomainType) Domain {
        return .{
            .id = id,
            .domain_type = domain_type,
            .flags = .{
                .strict = true,
                .coherent = true,
                .snoop = true,
            },
            .devices = std.ArrayList(iommu.DeviceID){},
            .mappings = std.ArrayList(Mapping){},
            .allocator = allocator,
            .mutex = std.Thread.Mutex{},
            .geometry = Geometry.init(),
        };
    }

    pub fn deinit(self: *Domain) void {
        self.devices.deinit(self.allocator);
        self.mappings.deinit(self.allocator);
    }

    pub fn attachDevice(self: *Domain, device_id: iommu.DeviceID) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Check if already attached
        for (self.devices.items) |dev| {
            if (dev.eql(device_id)) return;
        }

        try self.devices.append(self.allocator, device_id);
    }

    pub fn detachDevice(self: *Domain, device_id: iommu.DeviceID) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var i: usize = 0;
        while (i < self.devices.items.len) {
            if (self.devices.items[i].eql(device_id)) {
                _ = self.devices.orderedRemove(i);
                return;
            }
            i += 1;
        }
    }

    pub fn map(
        self: *Domain,
        iova: u64, // I/O Virtual Address
        paddr: u64, // Physical Address
        size: usize,
        access: AccessFlags,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Validate geometry
        if (self.geometry.force_aperture) {
            if (!self.geometry.contains(iova) or !self.geometry.contains(iova + size - 1)) {
                return error.OutsideAperture;
            }
        }

        // Check for overlaps
        for (self.mappings.items) |mapping| {
            if (mapping.overlaps(iova, size)) {
                return error.MappingOverlap;
            }
        }

        const mapping = Mapping{
            .iova = iova,
            .paddr = paddr,
            .size = size,
            .access = access,
        };

        try self.mappings.append(self.allocator, mapping);
    }

    pub fn unmap(self: *Domain, iova: u64, size: usize) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var i: usize = 0;
        while (i < self.mappings.items.len) {
            const mapping = &self.mappings.items[i];
            if (mapping.iova == iova and mapping.size == size) {
                _ = self.mappings.orderedRemove(i);
                return;
            }
            i += 1;
        }

        return error.MappingNotFound;
    }

    pub fn lookup(self: *Domain, iova: u64) ?Mapping {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.mappings.items) |mapping| {
            if (mapping.contains(iova)) {
                return mapping;
            }
        }

        return null;
    }

    pub fn translate(self: *Domain, iova: u64) ?u64 {
        if (self.lookup(iova)) |mapping| {
            const offset = iova - mapping.iova;
            return mapping.paddr + offset;
        }
        return null;
    }

    pub fn getDeviceCount(self: *Domain) usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.devices.items.len;
    }

    pub fn getMappingCount(self: *Domain) usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.mappings.items.len;
    }
};

/// Memory mapping entry
pub const Mapping = struct {
    iova: u64, // I/O Virtual Address (device-visible address)
    paddr: u64, // Physical Address (actual memory)
    size: usize,
    access: AccessFlags,

    pub fn contains(self: Mapping, addr: u64) bool {
        return addr >= self.iova and addr < (self.iova + self.size);
    }

    pub fn overlaps(self: Mapping, iova: u64, size: usize) bool {
        const end1 = self.iova + self.size;
        const end2 = iova + size;

        return !(end1 <= iova or self.iova >= end2);
    }
};

/// Domain allocator (manages domain IDs)
pub const DomainAllocator = struct {
    domains: std.AutoHashMap(u16, *Domain),
    next_id: u16,
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator) DomainAllocator {
        return .{
            .domains = std.AutoHashMap(u16, *Domain).init(allocator),
            .next_id = 1, // Domain 0 is usually reserved
            .allocator = allocator,
            .mutex = std.Thread.Mutex{},
        };
    }

    pub fn deinit(self: *DomainAllocator) void {
        var iter = self.domains.valueIterator();
        while (iter.next()) |domain_ptr| {
            domain_ptr.*.deinit();
            self.allocator.destroy(domain_ptr.*);
        }
        self.domains.deinit();
    }

    pub fn allocate(self: *DomainAllocator, domain_type: DomainType) !*Domain {
        self.mutex.lock();
        defer self.mutex.unlock();

        const id = self.next_id;
        self.next_id +%= 1; // Wrap around on overflow

        const domain = try self.allocator.create(Domain);
        domain.* = Domain.init(self.allocator, id, domain_type);

        try self.domains.put(id, domain);

        return domain;
    }

    pub fn free(self: *DomainAllocator, domain: *Domain) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        _ = self.domains.remove(domain.id);
        domain.deinit();
        self.allocator.destroy(domain);
    }

    pub fn get(self: *DomainAllocator, id: u16) ?*Domain {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.domains.get(id);
    }

    pub fn count(self: *DomainAllocator) usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.domains.count();
    }
};

test "domain creation" {
    const testing = std.testing;

    var domain = Domain.init(testing.allocator, 1, .dma);
    defer domain.deinit();

    try testing.expectEqual(@as(u16, 1), domain.id);
    try testing.expectEqual(DomainType.dma, domain.domain_type);
    try testing.expectEqual(@as(usize, 0), domain.getDeviceCount());
}

test "device attachment" {
    const testing = std.testing;

    var domain = Domain.init(testing.allocator, 1, .dma);
    defer domain.deinit();

    const dev1 = iommu.DeviceID.init(0, 0x00, 0x1F, 0x0);
    const dev2 = iommu.DeviceID.init(0, 0x00, 0x1F, 0x1);

    try domain.attachDevice(dev1);
    try domain.attachDevice(dev2);

    try testing.expectEqual(@as(usize, 2), domain.getDeviceCount());

    try domain.detachDevice(dev1);
    try testing.expectEqual(@as(usize, 1), domain.getDeviceCount());
}

test "memory mapping" {
    const testing = std.testing;

    var domain = Domain.init(testing.allocator, 1, .dma);
    defer domain.deinit();

    const access = AccessFlags{ .read = true, .write = true, .execute = false };

    // Map 4KB at IOVA 0x10000 to physical 0x50000
    try domain.map(0x10000, 0x50000, 4096, access);
    try testing.expectEqual(@as(usize, 1), domain.getMappingCount());

    // Lookup and translate
    const mapping = domain.lookup(0x10000);
    try testing.expect(mapping != null);
    try testing.expectEqual(@as(u64, 0x50000), mapping.?.paddr);

    const translated = domain.translate(0x10100);
    try testing.expectEqual(@as(u64, 0x50100), translated.?);

    // Unmap
    try domain.unmap(0x10000, 4096);
    try testing.expectEqual(@as(usize, 0), domain.getMappingCount());
}

test "mapping overlap detection" {
    const testing = std.testing;

    var domain = Domain.init(testing.allocator, 1, .dma);
    defer domain.deinit();

    const access = AccessFlags{ .read = true, .write = true, .execute = false };

    // Map region 0x10000-0x11000
    try domain.map(0x10000, 0x50000, 4096, access);

    // Try to map overlapping region - should fail
    const result = domain.map(0x10800, 0x60000, 4096, access);
    try testing.expectError(error.MappingOverlap, result);
}

test "domain allocator" {
    const testing = std.testing;

    var allocator = DomainAllocator.init(testing.allocator);
    defer allocator.deinit();

    // Allocate domains
    const domain1 = try allocator.allocate(.dma);
    const domain2 = try allocator.allocate(.identity);

    try testing.expectEqual(@as(usize, 2), allocator.count());
    try testing.expect(domain1.id != domain2.id);

    // Free domain
    allocator.free(domain1);
    try testing.expectEqual(@as(usize, 1), allocator.count());
}

test "geometry constraints" {
    const testing = std.testing;

    var domain = Domain.init(testing.allocator, 1, .dma);
    defer domain.deinit();

    // Set aperture constraints
    domain.geometry.aperture_start = 0x100000;
    domain.geometry.aperture_end = 0x200000;
    domain.geometry.force_aperture = true;

    const access = AccessFlags{ .read = true, .write = false, .execute = false };

    // Try to map outside aperture - should fail
    const result = domain.map(0x50000, 0x1000, 4096, access);
    try testing.expectError(error.OutsideAperture, result);

    // Map inside aperture - should succeed
    try domain.map(0x150000, 0x1000, 4096, access);
    try testing.expectEqual(@as(usize, 1), domain.getMappingCount());
}
