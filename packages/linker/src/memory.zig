// Home Programming Language - Linker Memory Region Definitions
// Defines memory regions for linker scripts

const std = @import("std");
const linker = @import("linker.zig");

pub const MemoryRegion = struct {
    name: []const u8,
    base: u64,
    size: u64,
    attributes: linker.MemoryAttributes,

    pub fn init(name: []const u8, base: u64, size: u64, attributes: linker.MemoryAttributes) MemoryRegion {
        return .{
            .name = name,
            .base = base,
            .size = size,
            .attributes = attributes,
        };
    }

    pub fn end(self: MemoryRegion) u64 {
        return self.base + self.size;
    }

    pub fn contains(self: MemoryRegion, addr: u64) bool {
        return addr >= self.base and addr < self.end();
    }

    pub fn overlaps(self: MemoryRegion, other: MemoryRegion) bool {
        return self.base < other.end() and other.base < self.end();
    }

    pub fn toAddressRange(self: MemoryRegion) !linker.AddressRange {
        return linker.AddressRange.init(self.base, self.end());
    }

    pub fn format(
        self: MemoryRegion,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("{s} : ORIGIN = 0x{x:0>16}, LENGTH = 0x{x}", .{
            self.name,
            self.base,
            self.size,
        });
    }
};

// Standard memory region templates
pub const StandardRegions = struct {
    // x86-64 higher-half kernel regions
    pub fn x86_64_higher_half() [2]MemoryRegion {
        return .{
            // Physical memory for boot code (first 2MB)
            MemoryRegion.init(
                "boot",
                0x0000_0000,
                0x0020_0000, // 2MB
                .{
                    .readable = true,
                    .writable = true,
                    .executable = true,
                    .cacheable = true,
                },
            ),
            // Kernel at higher half (-2GB)
            MemoryRegion.init(
                "kernel",
                linker.CommonAddresses.X86_64_HIGHER_HALF,
                0x4000_0000, // 1GB
                .{
                    .readable = true,
                    .writable = true,
                    .executable = true,
                    .cacheable = true,
                },
            ),
        };
    }

    // x86-64 lower-half kernel (identity mapped)
    pub fn x86_64_lower_half() [2]MemoryRegion {
        return .{
            // Kernel at 1MB
            MemoryRegion.init(
                "kernel",
                linker.CommonAddresses.X86_64_KERNEL_BASE,
                0x3f00_0000, // ~1GB
                .{
                    .readable = true,
                    .writable = true,
                    .executable = true,
                    .cacheable = true,
                },
            ),
            // User space above kernel
            MemoryRegion.init(
                "user",
                0x4000_0000,
                linker.CommonAddresses.X86_64_USER_END - 0x4000_0000,
                .{
                    .readable = true,
                    .writable = true,
                    .executable = true,
                    .cacheable = true,
                },
            ),
        };
    }

    // ARM64 kernel regions
    pub fn arm64_kernel() [2]MemoryRegion {
        return .{
            // Kernel at 1MB
            MemoryRegion.init(
                "kernel",
                linker.CommonAddresses.ARM64_KERNEL_BASE,
                0x4000_0000, // 1GB
                .{
                    .readable = true,
                    .writable = true,
                    .executable = true,
                    .cacheable = true,
                },
            ),
            // User space
            MemoryRegion.init(
                "user",
                0x0000_0000_0000_1000,
                linker.CommonAddresses.ARM64_USER_END,
                .{
                    .readable = true,
                    .writable = true,
                    .executable = true,
                    .cacheable = true,
                },
            ),
        };
    }

    // Embedded system (no MMU)
    pub fn embedded_nommu() [2]MemoryRegion {
        return .{
            // Flash/ROM
            MemoryRegion.init(
                "flash",
                0x0800_0000,
                0x0010_0000, // 1MB
                .{
                    .readable = true,
                    .writable = false,
                    .executable = true,
                    .cacheable = true,
                },
            ),
            // RAM
            MemoryRegion.init(
                "ram",
                0x2000_0000,
                0x0002_0000, // 128KB
                .{
                    .readable = true,
                    .writable = true,
                    .executable = false,
                    .cacheable = true,
                },
            ),
        };
    }
};

// Memory region builder for custom layouts
pub const MemoryRegionBuilder = struct {
    regions: std.ArrayList(MemoryRegion),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) MemoryRegionBuilder {
        return .{
            .regions = std.ArrayList(MemoryRegion){},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MemoryRegionBuilder) void {
        self.regions.deinit(self.allocator);
    }

    pub fn add(self: *MemoryRegionBuilder, region: MemoryRegion) !void {
        try self.regions.append(self.allocator, region);
    }

    pub fn addKernelRegion(self: *MemoryRegionBuilder, base: u64, size: u64) !void {
        try self.add(MemoryRegion.init(
            "kernel",
            base,
            size,
            .{
                .readable = true,
                .writable = true,
                .executable = true,
                .cacheable = true,
            },
        ));
    }

    pub fn addUserRegion(self: *MemoryRegionBuilder, base: u64, size: u64) !void {
        try self.add(MemoryRegion.init(
            "user",
            base,
            size,
            .{
                .readable = true,
                .writable = true,
                .executable = true,
                .cacheable = true,
            },
        ));
    }

    pub fn addRomRegion(self: *MemoryRegionBuilder, name: []const u8, base: u64, size: u64) !void {
        try self.add(MemoryRegion.init(
            name,
            base,
            size,
            .{
                .readable = true,
                .writable = false,
                .executable = true,
                .cacheable = true,
            },
        ));
    }

    pub fn addRamRegion(self: *MemoryRegionBuilder, name: []const u8, base: u64, size: u64) !void {
        try self.add(MemoryRegion.init(
            name,
            base,
            size,
            .{
                .readable = true,
                .writable = true,
                .executable = false,
                .cacheable = true,
            },
        ));
    }

    pub fn addDeviceRegion(self: *MemoryRegionBuilder, name: []const u8, base: u64, size: u64) !void {
        try self.add(MemoryRegion.init(
            name,
            base,
            size,
            .{
                .readable = true,
                .writable = true,
                .executable = false,
                .cacheable = false,
                .device = true,
            },
        ));
    }

    pub fn validate(self: *MemoryRegionBuilder) !void {
        // Check for overlaps
        for (self.regions.items, 0..) |region1, i| {
            for (self.regions.items[i + 1 ..]) |region2| {
                if (region1.overlaps(region2)) {
                    return error.OverlappingRegions;
                }
            }
        }

        // Check for zero-size regions
        for (self.regions.items) |region| {
            if (region.size == 0) {
                return error.ZeroSizeRegion;
            }
        }
    }

    pub fn build(self: *MemoryRegionBuilder) ![]const MemoryRegion {
        try self.validate();
        return self.regions.toOwnedSlice(self.allocator);
    }
};

// Tests
test "memory region basic operations" {
    const testing = std.testing;

    const region = MemoryRegion.init(
        "test",
        0x1000,
        0x1000,
        .{ .readable = true, .writable = true },
    );

    try testing.expectEqual(@as(u64, 0x1000), region.base);
    try testing.expectEqual(@as(u64, 0x1000), region.size);
    try testing.expectEqual(@as(u64, 0x2000), region.end());

    try testing.expect(region.contains(0x1000));
    try testing.expect(region.contains(0x1500));
    try testing.expect(!region.contains(0x2000));
    try testing.expect(!region.contains(0x500));
}

test "memory region overlaps" {
    const testing = std.testing;

    const region1 = MemoryRegion.init("r1", 0x1000, 0x1000, .{});
    const region2 = MemoryRegion.init("r2", 0x1800, 0x1000, .{});
    const region3 = MemoryRegion.init("r3", 0x3000, 0x1000, .{});

    try testing.expect(region1.overlaps(region2));
    try testing.expect(region2.overlaps(region1));
    try testing.expect(!region1.overlaps(region3));
    try testing.expect(!region3.overlaps(region1));
}

test "standard x86-64 higher-half regions" {
    const testing = std.testing;

    const regions = StandardRegions.x86_64_higher_half();

    try testing.expectEqual(@as(usize, 2), regions.len);
    try testing.expect(std.mem.eql(u8, regions[0].name, "boot"));
    try testing.expect(std.mem.eql(u8, regions[1].name, "kernel"));

    // Boot region at physical 0
    try testing.expectEqual(@as(u64, 0x0000_0000), regions[0].base);

    // Kernel at higher half
    try testing.expectEqual(linker.CommonAddresses.X86_64_HIGHER_HALF, regions[1].base);
}

test "memory region builder" {
    const testing = std.testing;

    var builder = MemoryRegionBuilder.init(testing.allocator);
    defer builder.deinit();

    try builder.addKernelRegion(0x1000, 0x1000);
    try builder.addUserRegion(0x3000, 0x1000);

    const regions = try builder.build();
    defer testing.allocator.free(regions);

    try testing.expectEqual(@as(usize, 2), regions.len);
}

test "memory region builder validation - overlaps" {
    const testing = std.testing;

    var builder = MemoryRegionBuilder.init(testing.allocator);
    defer builder.deinit();

    try builder.addKernelRegion(0x1000, 0x2000);
    try builder.addUserRegion(0x2000, 0x1000); // Overlaps at 0x2000

    try testing.expectError(error.OverlappingRegions, builder.validate());
}

test "memory region builder validation - zero size" {
    const testing = std.testing;

    var builder = MemoryRegionBuilder.init(testing.allocator);
    defer builder.deinit();

    try builder.add(MemoryRegion.init("test", 0x1000, 0, .{}));

    try testing.expectError(error.ZeroSizeRegion, builder.validate());
}
