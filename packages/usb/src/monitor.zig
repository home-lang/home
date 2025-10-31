// USB Activity Monitoring
// Tracks device connections, data transfers, and suspicious activity

const std = @import("std");
const usb = @import("usb.zig");

/// USB event type
pub const EventType = enum {
    device_connected,
    device_disconnected,
    device_authorized,
    device_denied,
    data_transfer_started,
    data_transfer_completed,
    suspicious_activity,
    policy_violation,
};

/// USB event
pub const Event = struct {
    event_type: EventType,
    device_id: usb.DeviceID,
    timestamp: i64,
    port_number: u8,
    details: [512]u8,
    details_len: usize,
    bytes_transferred: u64,

    pub fn init(
        event_type: EventType,
        device_id: usb.DeviceID,
        port_number: u8,
        details: []const u8,
    ) Event {
        var event: Event = undefined;
        event.event_type = event_type;
        event.device_id = device_id;
        event.timestamp = std.time.timestamp();
        event.port_number = port_number;
        event.bytes_transferred = 0;

        @memset(&event.details, 0);
        @memcpy(event.details[0..details.len], details);
        event.details_len = details.len;

        return event;
    }

    pub fn getDetails(self: *const Event) []const u8 {
        return self.details[0..self.details_len];
    }
};

/// Transfer statistics
pub const TransferStats = struct {
    bytes_read: std.atomic.Value(u64),
    bytes_written: std.atomic.Value(u64),
    read_operations: std.atomic.Value(u64),
    write_operations: std.atomic.Value(u64),
    last_activity: std.atomic.Value(i64),

    pub fn init() TransferStats {
        return .{
            .bytes_read = std.atomic.Value(u64).init(0),
            .bytes_written = std.atomic.Value(u64).init(0),
            .read_operations = std.atomic.Value(u64).init(0),
            .write_operations = std.atomic.Value(u64).init(0),
            .last_activity = std.atomic.Value(i64).init(0),
        };
    }

    pub fn recordRead(self: *TransferStats, bytes: u64) void {
        _ = self.bytes_read.fetchAdd(bytes, .monotonic);
        _ = self.read_operations.fetchAdd(1, .monotonic);
        self.last_activity.store(std.time.timestamp(), .release);
    }

    pub fn recordWrite(self: *TransferStats, bytes: u64) void {
        _ = self.bytes_written.fetchAdd(bytes, .monotonic);
        _ = self.write_operations.fetchAdd(1, .monotonic);
        self.last_activity.store(std.time.timestamp(), .release);
    }

    pub fn getTotalBytes(self: *const TransferStats) u64 {
        return self.bytes_read.load(.monotonic) + self.bytes_written.load(.monotonic);
    }

    pub fn getTotalOperations(self: *const TransferStats) u64 {
        return self.read_operations.load(.monotonic) + self.write_operations.load(.monotonic);
    }

    pub fn getReadThroughput(self: *const TransferStats) f64 {
        const ops = self.read_operations.load(.monotonic);
        if (ops == 0) return 0.0;
        const bytes = self.bytes_read.load(.monotonic);
        return @as(f64, @floatFromInt(bytes)) / @as(f64, @floatFromInt(ops));
    }
};

/// Device monitoring session
pub const MonitorSession = struct {
    device_id: usb.DeviceID,
    start_time: i64,
    stats: TransferStats,
    suspicious_count: u32,

    pub fn init(device_id: usb.DeviceID) MonitorSession {
        return .{
            .device_id = device_id,
            .start_time = std.time.timestamp(),
            .stats = TransferStats.init(),
            .suspicious_count = 0,
        };
    }

    pub fn recordSuspiciousActivity(self: *MonitorSession) void {
        self.suspicious_count += 1;
    }

    pub fn getDuration(self: *const MonitorSession) i64 {
        return std.time.timestamp() - self.start_time;
    }

    pub fn isSuspicious(self: *const MonitorSession) bool {
        return self.suspicious_count > 0;
    }
};

/// USB monitor
pub const Monitor = struct {
    events: std.ArrayList(Event),
    sessions: std.AutoHashMap(usb.DeviceID, MonitorSession),
    max_events: usize,
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,

    // Thresholds for suspicious activity detection
    max_transfer_rate: u64, // bytes/sec
    max_operations_per_sec: u64,

    pub fn init(allocator: std.mem.Allocator, max_events: usize) Monitor {
        return .{
            .events = std.ArrayList(Event){},
            .sessions = std.AutoHashMap(usb.DeviceID, MonitorSession).init(allocator),
            .max_events = max_events,
            .allocator = allocator,
            .mutex = std.Thread.Mutex{},
            .max_transfer_rate = 100 * 1024 * 1024, // 100 MB/s
            .max_operations_per_sec = 10000,
        };
    }

    pub fn deinit(self: *Monitor) void {
        self.events.deinit(self.allocator);
        self.sessions.deinit();
    }

    pub fn logEvent(self: *Monitor, event: Event) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Rotate events if at capacity
        if (self.events.items.len >= self.max_events) {
            _ = self.events.orderedRemove(0);
        }

        try self.events.append(self.allocator, event);
    }

    pub fn startSession(self: *Monitor, device_id: usb.DeviceID) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const session = MonitorSession.init(device_id);
        try self.sessions.put(device_id, session);

        // Log connection event
        const event = Event.init(
            .device_connected,
            device_id,
            0,
            "Device monitoring session started",
        );

        if (self.events.items.len < self.max_events) {
            try self.events.append(self.allocator, event);
        }
    }

    pub fn endSession(self: *Monitor, device_id: *const usb.DeviceID) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.sessions.get(device_id.*)) |session| {
            // Log disconnection event
            const event = Event.init(
                .device_disconnected,
                device_id.*,
                0,
                "Device monitoring session ended",
            );

            if (self.events.items.len < self.max_events) {
                try self.events.append(self.allocator, event);
            }

            _ = session;
            _ = self.sessions.remove(device_id.*);
        }
    }

    pub fn recordTransfer(
        self: *Monitor,
        device_id: *const usb.DeviceID,
        is_read: bool,
        bytes: u64,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.sessions.getPtr(device_id.*)) |session| {
            if (is_read) {
                session.stats.recordRead(bytes);
            } else {
                session.stats.recordWrite(bytes);
            }

            // Check for suspicious activity
            const ops = session.stats.getTotalOperations();
            const duration = session.getDuration();
            if (duration > 0) {
                const ops_per_sec = ops / @as(u64, @intCast(duration));
                if (ops_per_sec > self.max_operations_per_sec) {
                    session.recordSuspiciousActivity();

                    const event = Event.init(
                        .suspicious_activity,
                        device_id.*,
                        0,
                        "High operation rate detected",
                    );

                    if (self.events.items.len < self.max_events) {
                        try self.events.append(self.allocator, event);
                    }
                }
            }
        }
    }

    pub fn getEventCount(self: *const Monitor) usize {
        return self.events.items.len;
    }

    pub fn getActiveSessionCount(self: *const Monitor) usize {
        return self.sessions.count();
    }

    pub fn getSuspiciousDeviceCount(self: *Monitor) usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        var count: usize = 0;
        var iter = self.sessions.valueIterator();
        while (iter.next()) |session| {
            if (session.isSuspicious()) {
                count += 1;
            }
        }
        return count;
    }
};

test "monitor events" {
    const testing = std.testing;

    var monitor = Monitor.init(testing.allocator, 100);
    defer monitor.deinit();

    const dev = usb.DeviceID.init(0x046D, 0xC52B, "12345", .hid, "Logitech", "Mouse");

    const event = Event.init(.device_connected, dev, 1, "Device plugged in");
    try monitor.logEvent(event);

    try testing.expectEqual(@as(usize, 1), monitor.getEventCount());
}

test "transfer stats" {
    const testing = std.testing;

    var stats = TransferStats.init();

    stats.recordRead(1024);
    stats.recordRead(2048);
    stats.recordWrite(4096);

    try testing.expectEqual(@as(u64, 3072), stats.bytes_read.load(.monotonic));
    try testing.expectEqual(@as(u64, 4096), stats.bytes_written.load(.monotonic));
    try testing.expectEqual(@as(u64, 7168), stats.getTotalBytes());
    try testing.expectEqual(@as(u64, 3), stats.getTotalOperations());
}

test "monitor session" {
    const testing = std.testing;

    var monitor = Monitor.init(testing.allocator, 100);
    defer monitor.deinit();

    const dev = usb.DeviceID.init(0x046D, 0xC52B, "12345", .hid, "Logitech", "Mouse");

    // Start session
    try monitor.startSession(dev);
    try testing.expectEqual(@as(usize, 1), monitor.getActiveSessionCount());

    // Record transfers
    try monitor.recordTransfer(&dev, true, 1024);
    try monitor.recordTransfer(&dev, false, 2048);

    // End session
    try monitor.endSession(&dev);
    try testing.expectEqual(@as(usize, 0), monitor.getActiveSessionCount());
}
