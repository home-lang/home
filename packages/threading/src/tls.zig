// Home Programming Language - Thread Local Storage
// Simple TLS wrapper

const std = @import("std");
const ThreadError = @import("errors.zig").ThreadError;

fn lockMutex(mutex: *std.atomic.Mutex) void {
    while (!mutex.tryLock()) {
        std.atomic.spinLoopHint();
    }
}

pub const TLS = struct {
    storage: std.AutoHashMap(std.Thread.Id, *anyopaque),
    mutex: std.atomic.Mutex,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ThreadError!TLS {
        return TLS{
            .storage = std.AutoHashMap(std.Thread.Id, *anyopaque).init(allocator),
            .mutex = .unlocked,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TLS) void {
        self.storage.deinit();
    }

    pub fn set(self: *TLS, value: ?*anyopaque) ThreadError!void {
        const id = std.Thread.getCurrentId();
        lockMutex(&self.mutex);
        defer self.mutex.unlock();

        if (value) |v| {
            self.storage.put(id, v) catch return ThreadError.SetFailed;
        } else {
            _ = self.storage.remove(id);
        }
    }

    pub fn get(self: *TLS) ?*anyopaque {
        const id = std.Thread.getCurrentId();
        lockMutex(&self.mutex);
        defer self.mutex.unlock();

        return self.storage.get(id);
    }
};

pub fn TypedTLS(comptime T: type) type {
    return struct {
        tls: TLS,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) ThreadError!Self {
            return Self{
                .tls = try TLS.init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.tls.deinit();
        }

        pub fn set(self: *Self, value: *T) ThreadError!void {
            try self.tls.set(@ptrCast(value));
        }

        pub fn get(self: *Self) ?*T {
            if (self.tls.get()) |ptr| {
                return @ptrCast(@alignCast(ptr));
            }
            return null;
        }
    };
}

test "tls init" {
    const allocator = std.testing.allocator;
    var tls = try TLS.init(allocator);
    defer tls.deinit();
}
