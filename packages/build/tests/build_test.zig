const std = @import("std");
const testing = std.testing;

// Build system tests
// Tests for build configuration and compilation

test "build - basic compilation" {
    // Ensure build system compiles
    try testing.expect(true);
}

test "build - target configuration" {
    const Target = struct {
        arch: []const u8,
        os: []const u8,
        abi: []const u8,

        pub fn triple(self: @This(), allocator: std.mem.Allocator) ![]const u8 {
            return try std.fmt.allocPrint(allocator, "{s}-{s}-{s}", .{ self.arch, self.os, self.abi });
        }
    };

    const target = Target{
        .arch = "x86_64",
        .os = "linux",
        .abi = "gnu",
    };

    const triple = try target.triple(testing.allocator);
    defer testing.allocator.free(triple);

    try testing.expectEqualStrings("x86_64-linux-gnu", triple);
}

test "build - optimization levels" {
    const OptLevel = enum {
        Debug,
        ReleaseSafe,
        ReleaseFast,
        ReleaseSmall,

        pub fn description(self: @This()) []const u8 {
            return switch (self) {
                .Debug => "No optimization, safety checks enabled",
                .ReleaseSafe => "Optimize for speed, safety checks enabled",
                .ReleaseFast => "Optimize for speed, safety checks disabled",
                .ReleaseSmall => "Optimize for size",
            };
        }
    };

    const opt: OptLevel = .ReleaseSafe;
    const desc = opt.description();

    try testing.expect(desc.len > 0);
}

test "build - build mode flags" {
    const BuildMode = struct {
        optimize: bool,
        debug_info: bool,
        safety: bool,

        pub fn forDebug() @This() {
            return .{ .optimize = false, .debug_info = true, .safety = true };
        }

        pub fn forRelease() @This() {
            return .{ .optimize = true, .debug_info = false, .safety = false };
        }
    };

    const debug = BuildMode.forDebug();
    const release = BuildMode.forRelease();

    try testing.expect(!debug.optimize);
    try testing.expect(debug.debug_info);
    try testing.expect(release.optimize);
    try testing.expect(!release.safety);
}

test "build - dependency graph" {
    const allocator = testing.allocator;

    const Package = struct {
        name: []const u8,
        dependencies: []const []const u8,
    };

    const pkg1 = Package{ .name = "foo", .dependencies = &[_][]const u8{} };
    const pkg2 = Package{ .name = "bar", .dependencies = &[_][]const u8{"foo"} };

    var dep_map = std.StringHashMap([]const []const u8).init(allocator);
    defer dep_map.deinit();

    try dep_map.put(pkg1.name, pkg1.dependencies);
    try dep_map.put(pkg2.name, pkg2.dependencies);

    const bar_deps = dep_map.get("bar").?;
    try testing.expect(bar_deps.len == 1);
    try testing.expectEqualStrings("foo", bar_deps[0]);
}

test "build - incremental build tracking" {
    const FileState = struct {
        path: []const u8,
        hash: u64,
        timestamp: i64,

        pub fn needsRebuild(self: @This(), current_hash: u64) bool {
            return self.hash != current_hash;
        }
    };

    const file = FileState{
        .path = "src/main.zig",
        .hash = 12345,
        .timestamp = 1000000,
    };

    try testing.expect(!file.needsRebuild(12345));
    try testing.expect(file.needsRebuild(67890));
}

test "build - compiler flags" {
    const Flags = struct {
        flags: std.ArrayList([]const u8),

        pub fn init(allocator: std.mem.Allocator) @This() {
            return .{ .flags = std.ArrayList([]const u8).init(allocator) };
        }

        pub fn deinit(self: *@This()) void {
            self.flags.deinit();
        }

        pub fn add(self: *@This(), flag: []const u8) !void {
            try self.flags.append(flag);
        }

        pub fn count(self: @This()) usize {
            return self.flags.items.len;
        }
    };

    var flags = Flags.init(testing.allocator);
    defer flags.deinit();

    try flags.add("-O2");
    try flags.add("-Wall");

    try testing.expect(flags.count() == 2);
}

test "build - cache key generation" {
    const CacheKey = struct {
        pub fn generate(allocator: std.mem.Allocator, inputs: []const []const u8) ![]const u8 {
            // Simple hash-based cache key
            var hasher = std.hash.Wyhash.init(0);
            for (inputs) |input| {
                hasher.update(input);
            }
            const hash = hasher.final();
            return try std.fmt.allocPrint(allocator, "{x}", .{hash});
        }
    };

    const inputs = [_][]const u8{ "src/main.zig", "src/lib.zig" };
    const key1 = try CacheKey.generate(testing.allocator, &inputs);
    defer testing.allocator.free(key1);

    const key2 = try CacheKey.generate(testing.allocator, &inputs);
    defer testing.allocator.free(key2);

    // Same inputs should generate same key
    try testing.expectEqualStrings(key1, key2);
}
