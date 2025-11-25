const std = @import("std");

/// Performance metrics and instrumentation framework
///
/// Features:
/// - Counter, gauge, and histogram metrics
/// - Labels and dimensions
/// - Metric aggregation
/// - Time series data
/// - Export to various formats (Prometheus, StatsD, JSON)
pub const Metrics = struct {
    allocator: std.mem.Allocator,
    counters: std.StringHashMap(Counter),
    gauges: std.StringHashMap(Gauge),
    histograms: std.StringHashMap(Histogram),
    timers: std.StringHashMap(Timer),
    mutex: std.Thread.Mutex,

    pub const Counter = struct {
        value: std.atomic.Value(u64),
        labels: ?std.StringHashMap([]const u8),

        pub fn init() Counter {
            return .{
                .value = std.atomic.Value(u64).init(0),
                .labels = null,
            };
        }

        pub fn increment(self: *Counter) void {
            _ = self.value.fetchAdd(1, .monotonic);
        }

        pub fn add(self: *Counter, delta: u64) void {
            _ = self.value.fetchAdd(delta, .monotonic);
        }

        pub fn get(self: *Counter) u64 {
            return self.value.load(.monotonic);
        }

        pub fn reset(self: *Counter) void {
            self.value.store(0, .monotonic);
        }
    };

    pub const Gauge = struct {
        value: std.atomic.Value(i64),
        labels: ?std.StringHashMap([]const u8),

        pub fn init() Gauge {
            return .{
                .value = std.atomic.Value(i64).init(0),
                .labels = null,
            };
        }

        pub fn set(self: *Gauge, value: i64) void {
            self.value.store(value, .monotonic);
        }

        pub fn increment(self: *Gauge) void {
            _ = self.value.fetchAdd(1, .monotonic);
        }

        pub fn decrement(self: *Gauge) void {
            _ = self.value.fetchSub(1, .monotonic);
        }

        pub fn add(self: *Gauge, delta: i64) void {
            _ = self.value.fetchAdd(delta, .monotonic);
        }

        pub fn get(self: *Gauge) i64 {
            return self.value.load(.monotonic);
        }
    };

    pub const Histogram = struct {
        allocator: std.mem.Allocator,
        buckets: []Bucket,
        count: std.atomic.Value(u64),
        sum: std.atomic.Value(f64),
        labels: ?std.StringHashMap([]const u8),

        pub const Bucket = struct {
            upper_bound: f64,
            count: std.atomic.Value(u64),
        };

        pub fn init(allocator: std.mem.Allocator, buckets: []const f64) !Histogram {
            var bucket_list = try allocator.alloc(Bucket, buckets.len);

            for (buckets, 0..) |upper_bound, i| {
                bucket_list[i] = .{
                    .upper_bound = upper_bound,
                    .count = std.atomic.Value(u64).init(0),
                };
            }

            return .{
                .allocator = allocator,
                .buckets = bucket_list,
                .count = std.atomic.Value(u64).init(0),
                .sum = std.atomic.Value(f64).init(0.0),
                .labels = null,
            };
        }

        pub fn deinit(self: *Histogram) void {
            self.allocator.free(self.buckets);
        }

        pub fn observe(self: *Histogram, value: f64) void {
            _ = self.count.fetchAdd(1, .monotonic);

            // Atomic float addition is tricky, use CAS loop
            while (true) {
                const current = self.sum.load(.monotonic);
                const new_sum = current + value;
                if (self.sum.cmpxchgWeak(current, new_sum, .monotonic, .monotonic)) |_| {
                    continue;
                } else {
                    break;
                }
            }

            // Update buckets
            for (self.buckets) |*bucket| {
                if (value <= bucket.upper_bound) {
                    _ = bucket.count.fetchAdd(1, .monotonic);
                }
            }
        }

        pub fn getCount(self: *Histogram) u64 {
            return self.count.load(.monotonic);
        }

        pub fn getSum(self: *Histogram) f64 {
            return self.sum.load(.monotonic);
        }

        pub fn getMean(self: *Histogram) f64 {
            const count = self.getCount();
            if (count == 0) return 0.0;
            return self.getSum() / @as(f64, @floatFromInt(count));
        }
    };

    pub const Timer = struct {
        histogram: Histogram,

        pub fn time(self: *Timer) TimerHandle {
            return TimerHandle{
                .timer = self,
                .start_time = std.time.nanoTimestamp(),
            };
        }

        pub const TimerHandle = struct {
            timer: *Timer,
            start_time: i64,

            pub fn stop(self: *TimerHandle) void {
                const end_time = std.time.nanoTimestamp();
                const duration_ns = end_time - self.start_time;
                const duration_ms = @as(f64, @floatFromInt(duration_ns)) / 1_000_000.0;
                self.timer.histogram.observe(duration_ms);
            }
        };
    };

    pub fn init(allocator: std.mem.Allocator) Metrics {
        return .{
            .allocator = allocator,
            .counters = std.StringHashMap(Counter).init(allocator),
            .gauges = std.StringHashMap(Gauge).init(allocator),
            .histograms = std.StringHashMap(Histogram).init(allocator),
            .timers = std.StringHashMap(Timer).init(allocator),
            .mutex = std.Thread.Mutex{},
        };
    }

    pub fn deinit(self: *Metrics) void {
        var hist_it = self.histograms.valueIterator();
        while (hist_it.next()) |hist| {
            hist.deinit();
        }

        self.counters.deinit();
        self.gauges.deinit();
        self.histograms.deinit();
        self.timers.deinit();
    }

    /// Get or create a counter
    pub fn counter(self: *Metrics, name: []const u8) !*Counter {
        self.mutex.lock();
        defer self.mutex.unlock();

        const entry = try self.counters.getOrPut(name);
        if (!entry.found_existing) {
            entry.value_ptr.* = Counter.init();
        }
        return entry.value_ptr;
    }

    /// Get or create a gauge
    pub fn gauge(self: *Metrics, name: []const u8) !*Gauge {
        self.mutex.lock();
        defer self.mutex.unlock();

        const entry = try self.gauges.getOrPut(name);
        if (!entry.found_existing) {
            entry.value_ptr.* = Gauge.init();
        }
        return entry.value_ptr;
    }

    /// Get or create a histogram
    pub fn histogram(self: *Metrics, name: []const u8, buckets: []const f64) !*Histogram {
        self.mutex.lock();
        defer self.mutex.unlock();

        const entry = try self.histograms.getOrPut(name);
        if (!entry.found_existing) {
            entry.value_ptr.* = try Histogram.init(self.allocator, buckets);
        }
        return entry.value_ptr;
    }

    /// Get or create a timer
    pub fn timer(self: *Metrics, name: []const u8) !*Timer {
        self.mutex.lock();
        defer self.mutex.unlock();

        const entry = try self.timers.getOrPut(name);
        if (!entry.found_existing) {
            const default_buckets = [_]f64{ 1, 5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000 };
            entry.value_ptr.* = .{
                .histogram = try Histogram.init(self.allocator, &default_buckets),
            };
        }
        return entry.value_ptr;
    }

    /// Export metrics in Prometheus format
    pub fn exportPrometheus(self: *Metrics) ![]const u8 {
        var buffer = std.ArrayList(u8).init(self.allocator);
        const writer = buffer.writer();

        // Counters
        var counter_it = self.counters.iterator();
        while (counter_it.next()) |entry| {
            const name = entry.key_ptr.*;
            const cnt = entry.value_ptr.*;

            try writer.print("# TYPE {s} counter\n", .{name});
            try writer.print("{s} {d}\n\n", .{ name, cnt.get() });
        }

        // Gauges
        var gauge_it = self.gauges.iterator();
        while (gauge_it.next()) |entry| {
            const name = entry.key_ptr.*;
            const gage = entry.value_ptr.*;

            try writer.print("# TYPE {s} gauge\n", .{name});
            try writer.print("{s} {d}\n\n", .{ name, gage.get() });
        }

        // Histograms
        var hist_it = self.histograms.iterator();
        while (hist_it.next()) |entry| {
            const name = entry.key_ptr.*;
            const hist = entry.value_ptr.*;

            try writer.print("# TYPE {s} histogram\n", .{name});

            for (hist.buckets) |bucket| {
                try writer.print("{s}_bucket{{le=\"{d:.2}\"}} {d}\n", .{
                    name,
                    bucket.upper_bound,
                    bucket.count.load(.monotonic),
                });
            }

            try writer.print("{s}_bucket{{le=\"+Inf\"}} {d}\n", .{ name, hist.getCount() });
            try writer.print("{s}_sum {d:.2}\n", .{ name, hist.getSum() });
            try writer.print("{s}_count {d}\n\n", .{ name, hist.getCount() });
        }

        return try buffer.toOwnedSlice();
    }

    /// Export metrics in JSON format
    pub fn exportJSON(self: *Metrics) ![]const u8 {
        var buffer = std.ArrayList(u8).init(self.allocator);
        const writer = buffer.writer();

        try writer.writeAll("{\n");

        // Counters
        try writer.writeAll("  \"counters\": {\n");
        var counter_it = self.counters.iterator();
        var first = true;
        while (counter_it.next()) |entry| {
            if (!first) try writer.writeAll(",\n");
            try writer.print("    \"{s}\": {d}", .{ entry.key_ptr.*, entry.value_ptr.get() });
            first = false;
        }
        try writer.writeAll("\n  },\n");

        // Gauges
        try writer.writeAll("  \"gauges\": {\n");
        var gauge_it = self.gauges.iterator();
        first = true;
        while (gauge_it.next()) |entry| {
            if (!first) try writer.writeAll(",\n");
            try writer.print("    \"{s}\": {d}", .{ entry.key_ptr.*, entry.value_ptr.get() });
            first = false;
        }
        try writer.writeAll("\n  },\n");

        // Histograms
        try writer.writeAll("  \"histograms\": {\n");
        var hist_it = self.histograms.iterator();
        first = true;
        while (hist_it.next()) |entry| {
            if (!first) try writer.writeAll(",\n");
            const hist = entry.value_ptr.*;

            try writer.print("    \"{s}\": {{\n", .{entry.key_ptr.*});
            try writer.print("      \"count\": {d},\n", .{hist.getCount()});
            try writer.print("      \"sum\": {d:.2},\n", .{hist.getSum()});
            try writer.print("      \"mean\": {d:.2}\n", .{hist.getMean()});
            try writer.writeAll("    }");
            first = false;
        }
        try writer.writeAll("\n  }\n");

        try writer.writeAll("}\n");

        return try buffer.toOwnedSlice();
    }

    /// Print summary report
    pub fn printReport(self: *Metrics, writer: anytype) !void {
        try writer.writeAll("\n=== Performance Metrics ===\n\n");

        // Counters
        if (self.counters.count() > 0) {
            try writer.writeAll("Counters:\n");
            var counter_it = self.counters.iterator();
            while (counter_it.next()) |entry| {
                try writer.print("  {s:<40} {d}\n", .{ entry.key_ptr.*, entry.value_ptr.get() });
            }
            try writer.writeAll("\n");
        }

        // Gauges
        if (self.gauges.count() > 0) {
            try writer.writeAll("Gauges:\n");
            var gauge_it = self.gauges.iterator();
            while (gauge_it.next()) |entry| {
                try writer.print("  {s:<40} {d}\n", .{ entry.key_ptr.*, entry.value_ptr.get() });
            }
            try writer.writeAll("\n");
        }

        // Histograms
        if (self.histograms.count() > 0) {
            try writer.writeAll("Histograms:\n");
            var hist_it = self.histograms.iterator();
            while (hist_it.next()) |entry| {
                const hist = entry.value_ptr.*;
                try writer.print("  {s}:\n", .{entry.key_ptr.*});
                try writer.print("    Count: {d}\n", .{hist.getCount()});
                try writer.print("    Sum:   {d:.2}\n", .{hist.getSum()});
                try writer.print("    Mean:  {d:.2}\n", .{hist.getMean()});
            }
            try writer.writeAll("\n");
        }
    }
};

/// Global metrics registry
var global_metrics: ?*Metrics = null;
var global_metrics_mutex: std.Thread.Mutex = .{};

pub fn getGlobalMetrics() !*Metrics {
    global_metrics_mutex.lock();
    defer global_metrics_mutex.unlock();

    if (global_metrics == null) {
        const allocator = std.heap.page_allocator;
        const metrics = try allocator.create(Metrics);
        metrics.* = Metrics.init(allocator);
        global_metrics = metrics;
    }

    return global_metrics.?;
}

/// Convenience macros for instrumentation
pub fn incrementCounter(name: []const u8) !void {
    const metrics = try getGlobalMetrics();
    const cnt = try metrics.counter(name);
    cnt.increment();
}

pub fn setGauge(name: []const u8, value: i64) !void {
    const metrics = try getGlobalMetrics();
    const gage = try metrics.gauge(name);
    gage.set(value);
}

pub fn observeHistogram(name: []const u8, value: f64) !void {
    const metrics = try getGlobalMetrics();
    const default_buckets = [_]f64{ 1, 5, 10, 25, 50, 100, 250, 500, 1000 };
    const hist = try metrics.histogram(name, &default_buckets);
    hist.observe(value);
}

pub fn timeOperation(name: []const u8) !Metrics.Timer.TimerHandle {
    const metrics = try getGlobalMetrics();
    const tmr = try metrics.timer(name);
    return tmr.time();
}
