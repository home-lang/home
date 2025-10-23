const std = @import("std");

/// Simple allocation profiler for tracking memory usage
pub const AllocationProfiler = struct {
    allocator: std.mem.Allocator,
    allocations: std.ArrayList(Allocation),
    total_allocated: usize,
    total_freed: usize,
    peak_memory: usize,
    current_memory: usize,

    const Allocation = struct {
        size: usize,
        timestamp: i64,
        freed: bool,
    };

    pub fn init(allocator: std.mem.Allocator) AllocationProfiler {
        return .{
            .allocator = allocator,
            .allocations = .{},
            .total_allocated = 0,
            .total_freed = 0,
            .peak_memory = 0,
            .current_memory = 0,
        };
    }

    pub fn deinit(self: *AllocationProfiler) void {
        self.allocations.deinit(self.allocator);
    }

    pub fn trackAllocation(self: *AllocationProfiler, size: usize) !void {
        const timestamp = std.time.milliTimestamp();
        try self.allocations.append(self.allocator, .{
            .size = size,
            .timestamp = timestamp,
            .freed = false,
        });

        self.total_allocated += size;
        self.current_memory += size;

        if (self.current_memory > self.peak_memory) {
            self.peak_memory = self.current_memory;
        }
    }

    pub fn trackFree(self: *AllocationProfiler, size: usize) void {
        self.total_freed += size;
        self.current_memory -= size;
    }

    pub fn report(self: *const AllocationProfiler) void {
        std.debug.print("\n" ++ "=" ** 60 ++ "\n", .{});
        std.debug.print("Memory Allocation Profile\n", .{});
        std.debug.print("=" ** 60 ++ "\n", .{});
        std.debug.print("Total Allocations:  {d}\n", .{self.allocations.items.len});
        std.debug.print("Total Allocated:    {d} bytes ({d:.2} MB)\n", .{
            self.total_allocated,
            @as(f64, @floatFromInt(self.total_allocated)) / 1024.0 / 1024.0,
        });
        std.debug.print("Total Freed:        {d} bytes ({d:.2} MB)\n", .{
            self.total_freed,
            @as(f64, @floatFromInt(self.total_freed)) / 1024.0 / 1024.0,
        });
        std.debug.print("Peak Memory Usage:  {d} bytes ({d:.2} MB)\n", .{
            self.peak_memory,
            @as(f64, @floatFromInt(self.peak_memory)) / 1024.0 / 1024.0,
        });
        std.debug.print("Current Memory:     {d} bytes ({d:.2} MB)\n", .{
            self.current_memory,
            @as(f64, @floatFromInt(self.current_memory)) / 1024.0 / 1024.0,
        });
        std.debug.print("=" ** 60 ++ "\n\n", .{});
    }

    pub fn getHotspots(self: *const AllocationProfiler, allocator: std.mem.Allocator) ![]Hotspot {
        var size_map = std.AutoHashMap(usize, usize).init(allocator);
        defer size_map.deinit();

        // Group allocations by size
        for (self.allocations.items) |alloc| {
            const count = size_map.get(alloc.size) orelse 0;
            try size_map.put(alloc.size, count + 1);
        }

        // Convert to array
        var hotspots: std.ArrayList(Hotspot) = .{};
        var it = size_map.iterator();
        while (it.next()) |entry| {
            try hotspots.append(allocator, .{
                .size = entry.key_ptr.*,
                .count = entry.value_ptr.*,
                .total_bytes = entry.key_ptr.* * entry.value_ptr.*,
            });
        }

        // Sort by total bytes (descending)
        const items = try hotspots.toOwnedSlice(allocator);
        std.mem.sort(Hotspot, items, {}, struct {
            fn lessThan(_: void, a: Hotspot, b: Hotspot) bool {
                return a.total_bytes > b.total_bytes;
            }
        }.lessThan);

        return items;
    }

    pub const Hotspot = struct {
        size: usize,
        count: usize,
        total_bytes: usize,
    };
};
