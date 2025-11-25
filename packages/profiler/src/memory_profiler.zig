const std = @import("std");

/// Memory Profiler with allocation tracking
///
/// Features:
/// - Track all allocations and deallocations
/// - Memory leak detection
/// - Allocation hotspots
/// - Memory usage over time
/// - Heap fragmentation analysis
pub const MemoryProfiler = struct {
    allocator: std.mem.Allocator,
    allocations: std.AutoHashMap(usize, Allocation),
    allocation_sites: std.StringHashMap(AllocationSite),
    config: Config,
    enabled: bool,
    peak_memory: usize,
    current_memory: usize,
    total_allocated: usize,
    total_freed: usize,
    allocation_count: usize,
    free_count: usize,

    pub const Config = struct {
        track_stack_traces: bool = true,
        max_stack_depth: usize = 32,
        detect_leaks: bool = true,
    };

    pub const Allocation = struct {
        address: usize,
        size: usize,
        timestamp: i64,
        stack_trace: ?[]usize,
        allocation_site: []const u8,
    };

    pub const AllocationSite = struct {
        location: []const u8,
        count: usize,
        total_bytes: usize,
        peak_bytes: usize,
        current_bytes: usize,
        allocations: std.ArrayList(usize),
    };

    pub const MemorySnapshot = struct {
        timestamp: i64,
        current_memory: usize,
        peak_memory: usize,
        allocation_count: usize,
        free_count: usize,
    };

    pub const LeakReport = struct {
        allocator: std.mem.Allocator,
        leaks: std.ArrayList(Leak),
        total_leaked: usize,

        pub const Leak = struct {
            address: usize,
            size: usize,
            allocation_site: []const u8,
            stack_trace: ?[]usize,
        };

        pub fn deinit(self: *LeakReport) void {
            for (self.leaks.items) |leak| {
                if (leak.stack_trace) |trace| {
                    self.allocator.free(trace);
                }
            }
            self.leaks.deinit();
        }

        pub fn print(self: *LeakReport, writer: anytype) !void {
            try writer.print("\n=== Memory Leak Report ===\n\n", .{});

            if (self.leaks.items.len == 0) {
                try writer.print("No memory leaks detected! ✓\n\n", .{});
                return;
            }

            try writer.print("Total leaked: {} bytes in {} allocations\n\n", .{
                self.total_leaked,
                self.leaks.items.len,
            });

            // Group leaks by allocation site
            var sites = std.StringHashMap(SiteLeaks).init(self.allocator);
            defer {
                var it = sites.iterator();
                while (it.next()) |entry| {
                    entry.value_ptr.leaks.deinit();
                }
                sites.deinit();
            }

            const SiteLeaks = struct {
                leaks: std.ArrayList(Leak),
                total_bytes: usize,
            };

            for (self.leaks.items) |leak| {
                const entry = try sites.getOrPut(leak.allocation_site);
                if (!entry.found_existing) {
                    entry.value_ptr.* = .{
                        .leaks = std.ArrayList(Leak).init(self.allocator),
                        .total_bytes = 0,
                    };
                }
                try entry.value_ptr.leaks.append(leak);
                entry.value_ptr.total_bytes += leak.size;
            }

            try writer.print("Leaks by allocation site:\n\n", .{});

            var it = sites.iterator();
            while (it.next()) |entry| {
                const site = entry.key_ptr.*;
                const site_leaks = entry.value_ptr.*;

                try writer.print("  {s}\n", .{site});
                try writer.print("    {} allocation(s), {} bytes\n\n", .{
                    site_leaks.leaks.items.len,
                    site_leaks.total_bytes,
                });
            }
        }
    };

    pub fn init(allocator: std.mem.Allocator, config: Config) MemoryProfiler {
        return .{
            .allocator = allocator,
            .allocations = std.AutoHashMap(usize, Allocation).init(allocator),
            .allocation_sites = std.StringHashMap(AllocationSite).init(allocator),
            .config = config,
            .enabled = false,
            .peak_memory = 0,
            .current_memory = 0,
            .total_allocated = 0,
            .total_freed = 0,
            .allocation_count = 0,
            .free_count = 0,
        };
    }

    pub fn deinit(self: *MemoryProfiler) void {
        var alloc_it = self.allocations.valueIterator();
        while (alloc_it.next()) |alloc| {
            if (alloc.stack_trace) |trace| {
                self.allocator.free(trace);
            }
        }
        self.allocations.deinit();

        var site_it = self.allocation_sites.valueIterator();
        while (site_it.next()) |site| {
            self.allocator.free(site.location);
            site.allocations.deinit();
        }
        self.allocation_sites.deinit();
    }

    pub fn enable(self: *MemoryProfiler) void {
        self.enabled = true;
    }

    pub fn disable(self: *MemoryProfiler) void {
        self.enabled = false;
    }

    /// Record an allocation
    pub fn recordAllocation(
        self: *MemoryProfiler,
        address: usize,
        size: usize,
        site: []const u8,
    ) !void {
        if (!self.enabled) return;

        var stack_trace: ?[]usize = null;
        if (self.config.track_stack_traces) {
            var buffer: [32]usize = undefined;
            var trace = std.builtin.StackTrace{
                .instruction_addresses = &buffer,
                .index = 0,
            };
            std.debug.captureStackTrace(@returnAddress(), &trace);
            stack_trace = try self.allocator.dupe(usize, buffer[0..trace.index]);
        }

        const allocation = Allocation{
            .address = address,
            .size = size,
            .timestamp = std.time.milliTimestamp(),
            .stack_trace = stack_trace,
            .allocation_site = site,
        };

        try self.allocations.put(address, allocation);

        // Update statistics
        self.current_memory += size;
        self.total_allocated += size;
        self.allocation_count += 1;

        if (self.current_memory > self.peak_memory) {
            self.peak_memory = self.current_memory;
        }

        // Update allocation site
        const site_entry = try self.allocation_sites.getOrPut(site);
        if (!site_entry.found_existing) {
            site_entry.value_ptr.* = .{
                .location = try self.allocator.dupe(u8, site),
                .count = 0,
                .total_bytes = 0,
                .peak_bytes = 0,
                .current_bytes = 0,
                .allocations = std.ArrayList(usize).init(self.allocator),
            };
        }

        site_entry.value_ptr.count += 1;
        site_entry.value_ptr.total_bytes += size;
        site_entry.value_ptr.current_bytes += size;
        try site_entry.value_ptr.allocations.append(address);

        if (site_entry.value_ptr.current_bytes > site_entry.value_ptr.peak_bytes) {
            site_entry.value_ptr.peak_bytes = site_entry.value_ptr.current_bytes;
        }
    }

    /// Record a deallocation
    pub fn recordFree(self: *MemoryProfiler, address: usize) !void {
        if (!self.enabled) return;

        const allocation = self.allocations.get(address) orelse return;

        self.current_memory -= allocation.size;
        self.total_freed += allocation.size;
        self.free_count += 1;

        // Update allocation site
        if (self.allocation_sites.getPtr(allocation.allocation_site)) |site| {
            site.current_bytes -= allocation.size;
        }

        // Free stack trace if present
        if (allocation.stack_trace) |trace| {
            self.allocator.free(trace);
        }

        _ = self.allocations.remove(address);
    }

    /// Take a memory snapshot
    pub fn snapshot(self: *MemoryProfiler) MemorySnapshot {
        return .{
            .timestamp = std.time.milliTimestamp(),
            .current_memory = self.current_memory,
            .peak_memory = self.peak_memory,
            .allocation_count = self.allocation_count,
            .free_count = self.free_count,
        };
    }

    /// Check for memory leaks
    pub fn checkLeaks(self: *MemoryProfiler) !LeakReport {
        var report = LeakReport{
            .allocator = self.allocator,
            .leaks = std.ArrayList(LeakReport.Leak).init(self.allocator),
            .total_leaked = 0,
        };

        var it = self.allocations.valueIterator();
        while (it.next()) |alloc| {
            const leak = LeakReport.Leak{
                .address = alloc.address,
                .size = alloc.size,
                .allocation_site = alloc.allocation_site,
                .stack_trace = if (alloc.stack_trace) |trace|
                    try self.allocator.dupe(usize, trace)
                else
                    null,
            };

            try report.leaks.append(leak);
            report.total_leaked += alloc.size;
        }

        return report;
    }

    /// Print memory statistics
    pub fn printStats(self: *MemoryProfiler, writer: anytype) !void {
        try writer.print("\n=== Memory Profile Statistics ===\n\n", .{});
        try writer.print("Current memory:    {} bytes\n", .{self.current_memory});
        try writer.print("Peak memory:       {} bytes\n", .{self.peak_memory});
        try writer.print("Total allocated:   {} bytes\n", .{self.total_allocated});
        try writer.print("Total freed:       {} bytes\n", .{self.total_freed});
        try writer.print("Allocations:       {}\n", .{self.allocation_count});
        try writer.print("Frees:             {}\n", .{self.free_count});
        try writer.print("Outstanding:       {} allocations\n\n", .{self.allocations.count()});

        // Print top allocation sites
        var sites = std.ArrayList(AllocationSite).init(self.allocator);
        defer sites.deinit();

        var it = self.allocation_sites.valueIterator();
        while (it.next()) |site| {
            try sites.append(site.*);
        }

        std.mem.sort(AllocationSite, sites.items, {}, struct {
            fn lessThan(_: void, a: AllocationSite, b: AllocationSite) bool {
                return a.total_bytes > b.total_bytes;
            }
        }.lessThan);

        try writer.print("Top allocation sites:\n\n", .{});
        try writer.print("  {s:<50} {s:>10} {s:>12} {s:>12}\n", .{
            "Location",
            "Count",
            "Total",
            "Current",
        });
        try writer.print("  {s:-<50} {s:->10} {s:->12} {s:->12}\n", .{ "", "", "", "" });

        for (sites.items[0..@min(20, sites.items.len)]) |site| {
            try writer.print("  {s:<50} {d:>10} {d:>12} {d:>12}\n", .{
                site.location,
                site.count,
                site.total_bytes,
                site.current_bytes,
            });
        }

        try writer.print("\n", .{});
    }
};

/// Tracking allocator wrapper for automatic profiling
pub fn TrackingAllocator(comptime BaseAllocator: type) type {
    return struct {
        base: BaseAllocator,
        profiler: *MemoryProfiler,

        const Self = @This();

        pub fn init(base: BaseAllocator, profiler: *MemoryProfiler) Self {
            return .{
                .base = base,
                .profiler = profiler,
            };
        }

        pub fn allocator(self: *Self) std.mem.Allocator {
            return .{
                .ptr = self,
                .vtable = &.{
                    .alloc = alloc,
                    .resize = resize,
                    .free = free,
                },
            };
        }

        fn alloc(ctx: *anyopaque, len: usize, ptr_align: u8, ret_addr: usize) ?[*]u8 {
            const self: *Self = @ptrCast(@alignCast(ctx));
            const result = self.base.rawAlloc(len, ptr_align, ret_addr);

            if (result) |ptr| {
                const address = @intFromPtr(ptr);
                self.profiler.recordAllocation(
                    address,
                    len,
                    "tracked_allocation",
                ) catch {};
            }

            return result;
        }

        fn resize(
            ctx: *anyopaque,
            buf: []u8,
            buf_align: u8,
            new_len: usize,
            ret_addr: usize,
        ) bool {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return self.base.rawResize(buf, buf_align, new_len, ret_addr);
        }

        fn free(ctx: *anyopaque, buf: []u8, buf_align: u8, ret_addr: usize) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            const address = @intFromPtr(buf.ptr);

            self.profiler.recordFree(address) catch {};
            self.base.rawFree(buf, buf_align, ret_addr);
        }
    };
}

/// Memory usage timeline for visualization
pub const MemoryTimeline = struct {
    allocator: std.mem.Allocator,
    samples: std.ArrayList(Sample),
    sample_interval_ms: i64,
    last_sample_time: i64,

    pub const Sample = struct {
        timestamp: i64,
        current_memory: usize,
        allocation_count: usize,
    };

    pub fn init(allocator: std.mem.Allocator, sample_interval_ms: i64) MemoryTimeline {
        return .{
            .allocator = allocator,
            .samples = std.ArrayList(Sample).init(allocator),
            .sample_interval_ms = sample_interval_ms,
            .last_sample_time = 0,
        };
    }

    pub fn deinit(self: *MemoryTimeline) void {
        self.samples.deinit();
    }

    pub fn record(self: *MemoryTimeline, snapshot: MemoryProfiler.MemorySnapshot) !void {
        const now = std.time.milliTimestamp();

        if (now - self.last_sample_time >= self.sample_interval_ms) {
            try self.samples.append(.{
                .timestamp = snapshot.timestamp,
                .current_memory = snapshot.current_memory,
                .allocation_count = snapshot.allocation_count,
            });
            self.last_sample_time = now;
        }
    }

    pub fn exportCSV(self: *MemoryTimeline) ![]const u8 {
        var buffer = std.ArrayList(u8).init(self.allocator);
        const writer = buffer.writer();

        try writer.writeAll("timestamp,memory_bytes,allocation_count\n");

        for (self.samples.items) |sample| {
            try writer.print("{},{},{}\n", .{
                sample.timestamp,
                sample.current_memory,
                sample.allocation_count,
            });
        }

        return try buffer.toOwnedSlice();
    }
};
