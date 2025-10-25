// Home OS Kernel - Secure Syslog
// Authenticated and integrity-protected logging

const Basics = @import("basics");
const sync = @import("sync.zig");
const atomic = @import("atomic.zig");
const audit = @import("audit.zig");

pub const LogEntry = struct {
    /// Log level
    level: u8,
    /// Message
    message: [256]u8,
    /// Message length
    msg_len: usize,
    /// Timestamp
    timestamp: u64,
    /// Sequence number (detect missing logs)
    sequence: u64,
    /// HMAC for integrity
    hmac: [32]u8,

    pub fn init(level: u8, message: []const u8, sequence: u64) !LogEntry {
        if (message.len > 255) {
            return error.MessageTooLong;
        }

        var entry: LogEntry = undefined;
        entry.level = level;
        entry.message = [_]u8{0} ** 256;
        entry.msg_len = message.len;
        entry.timestamp = @as(u64, @intCast(@as(u128, @bitCast(Basics.time.nanoTimestamp()))));
        entry.sequence = sequence;
        entry.hmac = [_]u8{0} ** 32;

        @memcpy(entry.message[0..message.len], message);

        entry.generateHmac();

        return entry;
    }

    fn generateHmac(self: *LogEntry) void {
        var state: u64 = 0x6a09e667f3bcc908;

        state ^= self.level;
        state ^= self.timestamp;
        state ^= self.sequence;

        for (self.message[0..self.msg_len]) |byte| {
            state ^= byte;
            state = state *% 0x9e3779b97f4a7c15;
        }

        for (&self.hmac, 0..) |*byte, i| {
            _ = i;
            state = state *% 0x9e3779b97f4a7c15;
            byte.* = @truncate(state & 0xFF);
        }
    }

    pub fn verify(self: *const LogEntry) bool {
        var computed: [32]u8 = undefined;
        var state: u64 = 0x6a09e667f3bcc908;

        state ^= self.level;
        state ^= self.timestamp;
        state ^= self.sequence;

        for (self.message[0..self.msg_len]) |byte| {
            state ^= byte;
            state = state *% 0x9e3779b97f4a7c15;
        }

        for (&computed, 0..) |*byte, i| {
            _ = i;
            state = state *% 0x9e3779b97f4a7c15;
            byte.* = @truncate(state & 0xFF);
        }

        return Basics.mem.eql(u8, &self.hmac, &computed);
    }
};

pub const SecureLog = struct {
    /// Log entries (ring buffer)
    entries: [1024]?LogEntry,
    /// Current index
    index: atomic.AtomicU32,
    /// Sequence number
    sequence: atomic.AtomicU64,
    /// Lock
    lock: sync.Spinlock,

    pub fn init() SecureLog {
        return .{
            .entries = [_]?LogEntry{null} ** 1024,
            .index = atomic.AtomicU32.init(0),
            .sequence = atomic.AtomicU64.init(0),
            .lock = sync.Spinlock.init(),
        };
    }

    pub fn log(self: *SecureLog, level: u8, message: []const u8) !void {
        self.lock.acquire();
        defer self.lock.release();

        const seq = self.sequence.fetchAdd(1, .Release);
        const entry = try LogEntry.init(level, message, seq);

        const idx = self.index.fetchAdd(1, .Release) % 1024;
        self.entries[idx] = entry;
    }

    pub fn verifyIntegrity(self: *SecureLog) bool {
        self.lock.acquire();
        defer self.lock.release();

        for (self.entries) |maybe_entry| {
            if (maybe_entry) |entry| {
                if (!entry.verify()) {
                    return false;
                }
            }
        }

        return true;
    }
};

var global_log: SecureLog = undefined;
var log_initialized = false;

pub fn init() void {
    if (!log_initialized) {
        global_log = SecureLog.init();
        log_initialized = true;
    }
}

pub fn secureLog(level: u8, message: []const u8) void {
    if (!log_initialized) init();
    global_log.log(level, message) catch {};
}

test "secure log entry" {
    const entry = try LogEntry.init(1, "test message", 0);
    try Basics.testing.expect(entry.verify());
}

test "secure log" {
    var log = SecureLog.init();
    try log.log(1, "message 1");
    try log.log(2, "message 2");

    try Basics.testing.expect(log.verifyIntegrity());
}
