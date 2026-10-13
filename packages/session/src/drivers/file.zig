const std = @import("std");
const session = @import("../session.zig");
const compat = @import("../compat.zig");

fn getTimestamp() i64 {
    return compat.timestamp();
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
        std.Io.Dir.createDirAbsolute(compat.io(), path, .default_dir) catch |err| {
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

        const io = compat.io();
        const file = std.Io.Dir.openFileAbsolute(io, file_path, .{}) catch |err| {
            if (err == error.FileNotFound) return null;
            return err;
        };
        defer file.close(io);

        // Read file contents
        const stat = try file.stat(io);
        if (stat.size == 0) return null;

        const size = std.math.cast(usize, stat.size) orelse return error.FileTooBig;
        const contents = try self.allocator.alloc(u8, size);
        defer self.allocator.free(contents);

        const bytes_read = try file.readPositionalAll(io, contents, 0);
        if (bytes_read != size) return error.UnexpectedEof;

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

        const io = compat.io();
        const file = try std.Io.Dir.createFileAbsolute(io, file_path, .{ .truncate = true });
        defer file.close(io);

        // Write metadata
        var meta_buf: [128]u8 = undefined;
        const created = try std.fmt.bufPrint(&meta_buf, "__created_at={d}\n", .{data.created_at});
        try file.writeStreamingAll(io, created);

        const activity = try std.fmt.bufPrint(&meta_buf, "__last_activity={d}\n", .{data.last_activity});
        try file.writeStreamingAll(io, activity);

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

            try file.writeStreamingAll(io, line);
        }
    }

    fn destroy(ptr: *anyopaque, id: []const u8) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));

        const file_path = try self.getFilePath(id);
        defer self.allocator.free(file_path);

        std.Io.Dir.deleteFileAbsolute(compat.io(), file_path) catch |err| {
            if (err != error.FileNotFound) return err;
        };
    }

    fn gc(ptr: *anyopaque, max_lifetime: i64) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const now = getTimestamp();
        const cutoff = now - max_lifetime;

        const io = compat.io();
        const dir = std.Io.Dir.openDirAbsolute(io, self.path, .{ .iterate = true }) catch return;
        defer dir.close(io);

        var iter = dir.iterate();
        while (try iter.next(io)) |entry| {
            if (!std.mem.startsWith(u8, entry.name, "sess_")) continue;

            const file_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.path, entry.name });
            defer self.allocator.free(file_path);

            const file = std.Io.Dir.openFileAbsolute(io, file_path, .{}) catch continue;
            defer file.close(io);

            const stat = file.stat(io) catch continue;
            const mtime = stat.mtime.toSeconds();

            if (mtime < cutoff) {
                std.Io.Dir.deleteFileAbsolute(io, file_path) catch {};
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
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(compat.io(), &path_buffer);
    const path = path_buffer[0..path_len];

    const drv = try FileDriver.init(allocator, path);
    defer drv.deinit();

    try std.testing.expectEqualStrings(path, drv.path);

    var data = session.SessionData.init(allocator);
    defer data.deinit();
    const key = try allocator.dupe(u8, "user_id");
    try data.data.put(key, .{ .int = 42 });

    var driver = drv.driver();
    try driver.write("round-trip", data);
    var loaded = (try driver.read("round-trip")).?;
    defer loaded.deinit();
    try std.testing.expectEqual(@as(i64, 42), loaded.data.get("user_id").?.asInt().?);

    try driver.destroy("round-trip");
    try std.testing.expect((try driver.read("round-trip")) == null);
}
