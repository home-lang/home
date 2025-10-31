// Core dump format utilities

const std = @import("std");
const coredump = @import("coredump.zig");
const encrypt = @import("encrypt.zig");
const decrypt = @import("decrypt.zig");

/// Display dump information
pub fn printDumpInfo(dump: *const encrypt.EncryptedDump, writer: anytype) !void {
    try writer.print("Encrypted Core Dump:\n", .{});
    try writer.print("  {}\n", .{dump.metadata});
    try writer.print("  Algorithm: {s}\n", .{dump.metadata.algorithm.name()});
    try writer.print("  Key ID: ", .{});
    for (dump.key_id) |byte| {
        try writer.print("{x:0>2}", .{byte});
    }
    try writer.print("\n", .{});
    try writer.print("  Data Size: {d} bytes\n", .{dump.encrypted_data.len});
}

/// Display dump analysis
pub fn printAnalysis(analysis: *const decrypt.DumpAnalysis, writer: anytype) !void {
    try writer.print("{}", .{analysis});
}

/// Get dump file extension
pub fn dumpExtension(encrypted: bool) []const u8 {
    return if (encrypted) ".ecore" else ".core";
}

/// Generate dump filename
pub fn generateDumpFilename(
    allocator: std.mem.Allocator,
    metadata: *const coredump.DumpMetadata,
    encrypted: bool,
) ![]u8 {
    const ext = dumpExtension(encrypted);

    return try std.fmt.allocPrint(
        allocator,
        "core.{s}.{d}.{d}{s}",
        .{
            metadata.getProcessName(),
            metadata.pid,
            metadata.timestamp,
            ext,
        },
    );
}

/// Dump statistics
pub const DumpStatistics = struct {
    total_dumps: usize,
    encrypted_dumps: usize,
    total_size: usize,
    oldest_timestamp: i64,
    newest_timestamp: i64,

    pub fn init() DumpStatistics {
        return .{
            .total_dumps = 0,
            .encrypted_dumps = 0,
            .total_size = 0,
            .oldest_timestamp = std.math.maxInt(i64),
            .newest_timestamp = 0,
        };
    }

    pub fn update(self: *DumpStatistics, metadata: *const coredump.DumpMetadata, size: usize, encrypted: bool) void {
        self.total_dumps += 1;
        if (encrypted) self.encrypted_dumps += 1;
        self.total_size += size;

        if (metadata.timestamp < self.oldest_timestamp) {
            self.oldest_timestamp = metadata.timestamp;
        }
        if (metadata.timestamp > self.newest_timestamp) {
            self.newest_timestamp = metadata.timestamp;
        }
    }

    pub fn format(
        self: DumpStatistics,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        try writer.print("Core Dump Statistics:\n", .{});
        try writer.print("  Total Dumps: {d}\n", .{self.total_dumps});
        try writer.print("  Encrypted: {d}\n", .{self.encrypted_dumps});
        try writer.print("  Total Size: {d} bytes\n", .{self.total_size});

        if (self.total_dumps > 0) {
            try writer.print("  Oldest: {d}\n", .{self.oldest_timestamp});
            try writer.print("  Newest: {d}\n", .{self.newest_timestamp});
        }
    }
};

/// Scan directory for dumps
pub fn scanDumpDirectory(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
) !std.ArrayList([]const u8) {
    var dumps = std.ArrayList([]const u8){};
    errdefer {
        for (dumps.items) |item| {
            allocator.free(item);
        }
        dumps.deinit(allocator);
    }

    var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;

        // Check for .core or .ecore extension
        if (std.mem.endsWith(u8, entry.name, ".core") or
            std.mem.endsWith(u8, entry.name, ".ecore"))
        {
            const path = try std.fs.path.join(allocator, &[_][]const u8{ dir_path, entry.name });
            try dumps.append(allocator, path);
        }
    }

    return dumps;
}

/// Verify dump integrity
pub fn verifyDumpIntegrity(path: []const u8) !bool {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    // Read magic
    var magic: [8]u8 = undefined;
    _ = try file.readAll(&magic);

    return std.mem.eql(u8, &magic, "HOMECORE");
}

/// Get dump size
pub fn getDumpSize(path: []const u8) !usize {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const stat = try file.stat();
    return stat.size;
}

test "generate dump filename" {
    const testing = std.testing;

    var metadata = try coredump.DumpMetadata.init(1234, "myapp", 11);

    const filename = try generateDumpFilename(testing.allocator, &metadata, true);
    defer testing.allocator.free(filename);

    try testing.expect(std.mem.indexOf(u8, filename, "myapp") != null);
    try testing.expect(std.mem.indexOf(u8, filename, "1234") != null);
    try testing.expect(std.mem.endsWith(u8, filename, ".ecore"));
}

test "dump statistics" {
    const testing = std.testing;

    var stats = DumpStatistics.init();

    var metadata1 = try coredump.DumpMetadata.init(100, "app1", 11);
    stats.update(&metadata1, 1024, true);

    var metadata2 = try coredump.DumpMetadata.init(200, "app2", 6);
    stats.update(&metadata2, 2048, false);

    try testing.expectEqual(@as(usize, 2), stats.total_dumps);
    try testing.expectEqual(@as(usize, 1), stats.encrypted_dumps);
    try testing.expectEqual(@as(usize, 3072), stats.total_size);
}
