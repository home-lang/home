const std = @import("std");
const posix = std.posix;
const session = @import("../session.zig");

/// Helper to get current timestamp
fn getTimestamp() i64 {
    const ts = posix.clock_gettime(.REALTIME) catch return 0;
    return ts.sec;
}

/// File-based session driver
pub const FileDriver = struct {
    allocator: std.mem.Allocator,
    path: []const u8,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, path: []const u8) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .path = try allocator.dupe(u8, path),
        };

        // Ensure directory exists
        std.fs.makeDirAbsolute(path) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.path);
        self.allocator.destroy(self);
    }

    pub fn driver(self: *Self) session.SessionDriver {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    fn getFilePath(self: *Self, id: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.allocator, "{s}/sess_{s}", .{ self.path, id });
    }

    fn read(ptr: *anyopaque, id: []const u8) anyerror!?session.SessionData {
        const self: *Self = @ptrCast(@alignCast(ptr));

        const file_path = try self.getFilePath(id);
        defer self.allocator.free(file_path);

        const file = std.fs.openFileAbsolute(file_path, .{}) catch |err| {
            if (err == error.FileNotFound) return null;
            return err;
        };
        defer file.close();

        // Read file contents
        const stat = try file.stat();
        if (stat.size == 0) return null;

        const contents = try self.allocator.alloc(u8, stat.size);
        defer self.allocator.free(contents);

        _ = try file.preadAll(contents, 0);

        // Parse session data (simple format: key=value lines)
        var data = session.SessionData.init(self.allocator);
        errdefer data.deinit();

        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;

            // Check for metadata
            if (std.mem.startsWith(u8, line, "__created_at=")) {
                data.created_at = std.fmt.parseInt(i64, line[13..], 10) catch 0;
                continue;
            }
            if (std.mem.startsWith(u8, line, "__last_activity=")) {
                data.last_activity = std.fmt.parseInt(i64, line[16..], 10) catch 0;
                continue;
            }

            // Parse key=type:value
            const eq_pos = std.mem.indexOf(u8, line, "=") orelse continue;
            const key = line[0..eq_pos];
            const rest = line[eq_pos + 1 ..];

            const colon_pos = std.mem.indexOf(u8, rest, ":") orelse continue;
            const type_str = rest[0..colon_pos];
            const value_str = rest[colon_pos + 1 ..];

            const key_copy = try self.allocator.dupe(u8, key);
            errdefer self.allocator.free(key_copy);

            const value: session.SessionData.Value = if (std.mem.eql(u8, type_str, "s")) blk: {
                break :blk .{ .string = try self.allocator.dupe(u8, value_str) };
            } else if (std.mem.eql(u8, type_str, "i")) blk: {
                break :blk .{ .int = std.fmt.parseInt(i64, value_str, 10) catch 0 };
            } else if (std.mem.eql(u8, type_str, "b")) blk: {
                break :blk .{ .bool = std.mem.eql(u8, value_str, "true") };
            } else blk: {
                break :blk .null;
            };

            try data.data.put(key_copy, value);
        }

        return data;
    }

    fn write(ptr: *anyopaque, id: []const u8, data: session.SessionData) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));

        const file_path = try self.getFilePath(id);
        defer self.allocator.free(file_path);

        const file = try std.fs.createFileAbsolute(file_path, .{ .truncate = true });
        defer file.close();

        // Write metadata
        var meta_buf: [128]u8 = undefined;
        const created = try std.fmt.bufPrint(&meta_buf, "__created_at={d}\n", .{data.created_at});
        try file.writeAll(created);

        const activity = try std.fmt.bufPrint(&meta_buf, "__last_activity={d}\n", .{data.last_activity});
        try file.writeAll(activity);

        // Write data
        var iter = data.data.iterator();
        while (iter.next()) |entry| {
            var line_buf: [4096]u8 = undefined;

            const line = switch (entry.value_ptr.*) {
                .string => |s| try std.fmt.bufPrint(&line_buf, "{s}=s:{s}\n", .{ entry.key_ptr.*, s }),
                .int => |i| try std.fmt.bufPrint(&line_buf, "{s}=i:{d}\n", .{ entry.key_ptr.*, i }),
                .bool => |b| try std.fmt.bufPrint(&line_buf, "{s}=b:{s}\n", .{ entry.key_ptr.*, if (b) "true" else "false" }),
                .float => |f| try std.fmt.bufPrint(&line_buf, "{s}=f:{d}\n", .{ entry.key_ptr.*, f }),
                .null => try std.fmt.bufPrint(&line_buf, "{s}=n:\n", .{entry.key_ptr.*}),
            };

            try file.writeAll(line);
        }
    }

    fn destroy(ptr: *anyopaque, id: []const u8) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));

        const file_path = try self.getFilePath(id);
        defer self.allocator.free(file_path);

        std.fs.deleteFileAbsolute(file_path) catch |err| {
            if (err != error.FileNotFound) return err;
        };
    }

    fn gc(ptr: *anyopaque, max_lifetime: i64) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const now = getTimestamp();
        const cutoff = now - max_lifetime;

        var dir = std.fs.openDirAbsolute(self.path, .{ .iterate = true }) catch return;
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (!std.mem.startsWith(u8, entry.name, "sess_")) continue;

            const file_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.path, entry.name });
            defer self.allocator.free(file_path);

            const file = std.fs.openFileAbsolute(file_path, .{}) catch continue;
            defer file.close();

            const stat = file.stat() catch continue;
            const mtime = stat.mtime.sec;

            if (mtime < cutoff) {
                std.fs.deleteFileAbsolute(file_path) catch {};
            }
        }
    }

    fn deinitFn(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.deinit();
    }

    const vtable = session.SessionDriver.VTable{
        .read = read,
        .write = write,
        .destroy = destroy,
        .gc = gc,
        .deinit = deinitFn,
    };
};

// Tests
test "file driver init" {
    const allocator = std.testing.allocator;

    const drv = try FileDriver.init(allocator, "/tmp/test-sessions");
    defer drv.deinit();

    try std.testing.expectEqualStrings("/tmp/test-sessions", drv.path);
}
