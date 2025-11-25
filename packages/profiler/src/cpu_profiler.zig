const std = @import("std");
const builtin = @import("builtin");

/// CPU Profiler with sampling-based profiling
///
/// Features:
/// - Statistical sampling of call stacks
/// - Low overhead profiling
/// - Multi-threaded support
/// - Configurable sample rate
/// - Call stack unwinding
/// - Flame graph data generation
pub const CPUProfiler = struct {
    allocator: std.mem.Allocator,
    samples: std.ArrayList(Sample),
    thread_samples: std.AutoHashMap(std.Thread.Id, std.ArrayList(Sample)),
    config: Config,
    running: std.atomic.Value(bool),
    sample_thread: ?std.Thread,
    start_time: i64,
    total_samples: usize,

    pub const Config = struct {
        /// Sample frequency in Hz (samples per second)
        sample_rate: u32 = 1000,
        /// Maximum stack depth to capture
        max_stack_depth: usize = 64,
        /// Enable per-thread profiling
        per_thread: bool = true,
        /// Buffer size for samples
        buffer_size: usize = 10000,
    };

    pub const Sample = struct {
        timestamp: i64,
        thread_id: std.Thread.Id,
        stack: []usize,
        count: usize = 1,

        pub fn deinit(self: *Sample, allocator: std.mem.Allocator) void {
            allocator.free(self.stack);
        }
    };

    pub const ProfileResult = struct {
        allocator: std.mem.Allocator,
        total_samples: usize,
        duration_ms: i64,
        samples_per_second: f64,
        functions: std.StringHashMap(FunctionProfile),

        pub const FunctionProfile = struct {
            name: []const u8,
            self_time: usize,
            total_time: usize,
            call_count: usize,
            percentage: f64,
        };

        pub fn deinit(self: *ProfileResult) void {
            var it = self.functions.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
            }
            self.functions.deinit();
        }

        pub fn print(self: *ProfileResult, writer: anytype) !void {
            try writer.print("\n=== CPU Profile Results ===\n\n", .{});
            try writer.print("Duration:          {}ms\n", .{self.duration_ms});
            try writer.print("Total samples:     {}\n", .{self.total_samples});
            try writer.print("Sample rate:       {d:.1} samples/sec\n\n", .{self.samples_per_second});

            // Sort functions by self_time
            var functions = std.ArrayList(FunctionProfile).init(self.allocator);
            defer functions.deinit();

            var it = self.functions.valueIterator();
            while (it.next()) |func| {
                try functions.append(func.*);
            }

            std.mem.sort(FunctionProfile, functions.items, {}, struct {
                fn lessThan(_: void, a: FunctionProfile, b: FunctionProfile) bool {
                    return a.self_time > b.self_time;
                }
            }.lessThan);

            try writer.print("Top Functions by Self Time:\n", .{});
            try writer.print("  {s:<40} {s:>10} {s:>10} {s:>8}\n", .{ "Function", "Self", "Total", "%" });
            try writer.print("  {s:-<40} {s:->10} {s:->10} {s:->8}\n", .{ "", "", "", "" });

            for (functions.items[0..@min(20, functions.items.len)]) |func| {
                try writer.print("  {s:<40} {d:>10} {d:>10} {d:>6.2}%\n", .{
                    func.name,
                    func.self_time,
                    func.total_time,
                    func.percentage,
                });
            }

            try writer.print("\n", .{});
        }
    };

    pub fn init(allocator: std.mem.Allocator, config: Config) CPUProfiler {
        return .{
            .allocator = allocator,
            .samples = std.ArrayList(Sample).init(allocator),
            .thread_samples = std.AutoHashMap(std.Thread.Id, std.ArrayList(Sample)).init(allocator),
            .config = config,
            .running = std.atomic.Value(bool).init(false),
            .sample_thread = null,
            .start_time = 0,
            .total_samples = 0,
        };
    }

    pub fn deinit(self: *CPUProfiler) void {
        self.stop() catch {};

        for (self.samples.items) |*sample| {
            sample.deinit(self.allocator);
        }
        self.samples.deinit();

        var it = self.thread_samples.valueIterator();
        while (it.next()) |thread_samples| {
            for (thread_samples.items) |*sample| {
                sample.deinit(self.allocator);
            }
            thread_samples.deinit();
        }
        self.thread_samples.deinit();
    }

    /// Start profiling
    pub fn start(self: *CPUProfiler) !void {
        if (self.running.load(.acquire)) return error.AlreadyRunning;

        self.running.store(true, .release);
        self.start_time = std.time.milliTimestamp();
        self.total_samples = 0;

        // Start sampling thread
        self.sample_thread = try std.Thread.spawn(.{}, sampleLoop, .{self});
    }

    /// Stop profiling and return results
    pub fn stop(self: *CPUProfiler) !ProfileResult {
        if (!self.running.load(.acquire)) return error.NotRunning;

        self.running.store(false, .release);

        if (self.sample_thread) |thread| {
            thread.join();
            self.sample_thread = null;
        }

        const end_time = std.time.milliTimestamp();
        const duration = end_time - self.start_time;

        return try self.analyze(duration);
    }

    fn sampleLoop(self: *CPUProfiler) !void {
        const sleep_ns = (1000 * 1000 * 1000) / self.config.sample_rate;

        while (self.running.load(.acquire)) {
            try self.takeSample();
            std.time.sleep(sleep_ns);
        }
    }

    fn takeSample(self: *CPUProfiler) !void {
        var stack_buffer: [64]usize = undefined;
        const stack_trace = try self.captureStackTrace(&stack_buffer);

        const sample = Sample{
            .timestamp = std.time.milliTimestamp(),
            .thread_id = std.Thread.getCurrentId(),
            .stack = try self.allocator.dupe(usize, stack_trace),
        };

        try self.samples.append(sample);
        self.total_samples += 1;

        // Per-thread samples
        if (self.config.per_thread) {
            const entry = try self.thread_samples.getOrPut(sample.thread_id);
            if (!entry.found_existing) {
                entry.value_ptr.* = std.ArrayList(Sample).init(self.allocator);
            }
            try entry.value_ptr.append(sample);
        }
    }

    fn captureStackTrace(self: *CPUProfiler, buffer: []usize) ![]usize {
        _ = self;

        var stack_trace = std.builtin.StackTrace{
            .instruction_addresses = buffer,
            .index = 0,
        };

        std.debug.captureStackTrace(@returnAddress(), &stack_trace);

        return buffer[0..stack_trace.index];
    }

    fn analyze(self: *CPUProfiler, duration_ms: i64) !ProfileResult {
        var result = ProfileResult{
            .allocator = self.allocator,
            .total_samples = self.total_samples,
            .duration_ms = duration_ms,
            .samples_per_second = @as(f64, @floatFromInt(self.total_samples)) /
                                   (@as(f64, @floatFromInt(duration_ms)) / 1000.0),
            .functions = std.StringHashMap(ProfileResult.FunctionProfile).init(self.allocator),
        };

        // Analyze samples and build function profiles
        for (self.samples.items) |sample| {
            for (sample.stack) |address| {
                const func_name = try self.getSymbolName(address);

                const entry = try result.functions.getOrPut(func_name);
                if (!entry.found_existing) {
                    entry.value_ptr.* = .{
                        .name = func_name,
                        .self_time = 0,
                        .total_time = 0,
                        .call_count = 0,
                        .percentage = 0.0,
                    };
                }

                entry.value_ptr.self_time += 1;
                entry.value_ptr.total_time += 1;
                entry.value_ptr.call_count += 1;
            }
        }

        // Calculate percentages
        var it = result.functions.valueIterator();
        while (it.next()) |func| {
            func.percentage = @as(f64, @floatFromInt(func.self_time)) /
                             @as(f64, @floatFromInt(self.total_samples)) * 100.0;
        }

        return result;
    }

    fn getSymbolName(self: *CPUProfiler, address: usize) ![]const u8 {
        // In a real implementation, this would use debug info to resolve symbols
        // For now, return hex address
        return try std.fmt.allocPrint(self.allocator, "0x{x}", .{address});
    }

    /// Generate flame graph data
    pub fn generateFlameGraph(self: *CPUProfiler) ![]const u8 {
        var buffer = std.ArrayList(u8).init(self.allocator);
        const writer = buffer.writer();

        // Generate folded stack format for flame graphs
        for (self.samples.items) |sample| {
            var first = true;
            for (sample.stack) |address| {
                if (!first) {
                    try writer.writeByte(';');
                }
                const symbol = try self.getSymbolName(address);
                defer self.allocator.free(symbol);
                try writer.writeAll(symbol);
                first = false;
            }
            try writer.print(" {d}\n", .{sample.count});
        }

        return try buffer.toOwnedSlice();
    }
};

/// Call graph profiler with exact timing
pub const CallGraphProfiler = struct {
    allocator: std.mem.Allocator,
    call_stack: std.ArrayList(CallFrame),
    call_graph: std.StringHashMap(FunctionStats),
    start_time: i64,
    enabled: bool,

    pub const CallFrame = struct {
        function_name: []const u8,
        start_time: i64,
        parent: ?*CallFrame,
    };

    pub const FunctionStats = struct {
        name: []const u8,
        call_count: usize,
        total_time: i64,
        self_time: i64,
        children: std.StringHashMap(usize),
    };

    pub fn init(allocator: std.mem.Allocator) CallGraphProfiler {
        return .{
            .allocator = allocator,
            .call_stack = std.ArrayList(CallFrame).init(allocator),
            .call_graph = std.StringHashMap(FunctionStats).init(allocator),
            .start_time = 0,
            .enabled = false,
        };
    }

    pub fn deinit(self: *CallGraphProfiler) void {
        self.call_stack.deinit();

        var it = self.call_graph.valueIterator();
        while (it.next()) |stats| {
            self.allocator.free(stats.name);
            stats.children.deinit();
        }
        self.call_graph.deinit();
    }

    pub fn enable(self: *CallGraphProfiler) void {
        self.enabled = true;
        self.start_time = std.time.nanoTimestamp();
    }

    pub fn disable(self: *CallGraphProfiler) void {
        self.enabled = false;
    }

    /// Enter a function
    pub fn enter(self: *CallGraphProfiler, function_name: []const u8) !void {
        if (!self.enabled) return;

        const frame = CallFrame{
            .function_name = function_name,
            .start_time = std.time.nanoTimestamp(),
            .parent = if (self.call_stack.items.len > 0) &self.call_stack.items[self.call_stack.items.len - 1] else null,
        };

        try self.call_stack.append(frame);
    }

    /// Exit a function
    pub fn exit(self: *CallGraphProfiler, function_name: []const u8) !void {
        if (!self.enabled) return;
        if (self.call_stack.items.len == 0) return;

        const frame = self.call_stack.pop();
        if (!std.mem.eql(u8, frame.function_name, function_name)) {
            return error.MismatchedFunctionExit;
        }

        const end_time = std.time.nanoTimestamp();
        const duration = end_time - frame.start_time;

        // Update statistics
        const entry = try self.call_graph.getOrPut(function_name);
        if (!entry.found_existing) {
            entry.value_ptr.* = .{
                .name = try self.allocator.dupe(u8, function_name),
                .call_count = 0,
                .total_time = 0,
                .self_time = 0,
                .children = std.StringHashMap(usize).init(self.allocator),
            };
        }

        entry.value_ptr.call_count += 1;
        entry.value_ptr.total_time += duration;
        entry.value_ptr.self_time += duration;
    }

    pub fn printReport(self: *CallGraphProfiler, writer: anytype) !void {
        try writer.print("\n=== Call Graph Profile ===\n\n", .{});
        try writer.print("{s:<40} {s:>12} {s:>15} {s:>15}\n", .{
            "Function",
            "Calls",
            "Total (ms)",
            "Self (ms)",
        });
        try writer.print("{s:-<40} {s:->12} {s:->15} {s:->15}\n", .{ "", "", "", "" });

        var it = self.call_graph.valueIterator();
        while (it.next()) |stats| {
            const total_ms = @as(f64, @floatFromInt(stats.total_time)) / 1_000_000.0;
            const self_ms = @as(f64, @floatFromInt(stats.self_time)) / 1_000_000.0;

            try writer.print("{s:<40} {d:>12} {d:>15.3} {d:>15.3}\n", .{
                stats.name,
                stats.call_count,
                total_ms,
                self_ms,
            });
        }

        try writer.print("\n", .{});
    }
};

/// Manual instrumentation points
pub const Instrumentation = struct {
    pub fn begin(comptime name: []const u8) void {
        _ = name;
        // Hook for instrumentation
    }

    pub fn end(comptime name: []const u8) void {
        _ = name;
        // Hook for instrumentation
    }

    pub fn mark(comptime name: []const u8) void {
        _ = name;
        // Hook for instrumentation
    }

    pub fn counter(comptime name: []const u8, value: i64) void {
        _ = name;
        _ = value;
        // Hook for instrumentation
    }
};

/// Scoped profiler for RAII-style profiling
pub fn ScopedProfile(comptime name: []const u8) type {
    return struct {
        start_time: i64,

        pub fn init() @This() {
            Instrumentation.begin(name);
            return .{
                .start_time = std.time.nanoTimestamp(),
            };
        }

        pub fn deinit(self: *@This()) void {
            _ = self;
            Instrumentation.end(name);
        }
    };
}
