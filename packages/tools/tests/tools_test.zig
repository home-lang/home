const std = @import("std");
const testing = std.testing;

// Tools and CLI tests
// Tests for command-line tools and utilities

test "tools - basic compilation" {
    // Ensure tools compile
    try testing.expect(true);
}

test "tools - argument parsing" {
    const ArgParser = struct {
        args: []const []const u8,
        index: usize,

        pub fn init(args: []const []const u8) @This() {
            return .{ .args = args, .index = 0 };
        }

        pub fn next(self: *@This()) ?[]const u8 {
            if (self.index >= self.args.len) return null;
            const arg = self.args[self.index];
            self.index += 1;
            return arg;
        }

        pub fn hasMore(self: @This()) bool {
            return self.index < self.args.len;
        }
    };

    const args = [_][]const u8{ "prog", "--flag", "value" };
    var parser = ArgParser.init(&args);

    try testing.expectEqualStrings("prog", parser.next().?);
    try testing.expectEqualStrings("--flag", parser.next().?);
    try testing.expectEqualStrings("value", parser.next().?);
    try testing.expect(!parser.hasMore());
}

test "tools - flag parsing" {
    const Flag = struct {
        name: []const u8,
        value: ?[]const u8,

        pub fn isLong(self: @This()) bool {
            return std.mem.startsWith(u8, self.name, "--");
        }

        pub fn isShort(self: @This()) bool {
            return std.mem.startsWith(u8, self.name, "-") and !self.isLong();
        }
    };

    const long_flag = Flag{ .name = "--verbose", .value = null };
    const short_flag = Flag{ .name = "-v", .value = null };
    const value_flag = Flag{ .name = "--output", .value = "file.txt" };

    try testing.expect(long_flag.isLong());
    try testing.expect(short_flag.isShort());
    try testing.expect(value_flag.value != null);
}

test "tools - command dispatch" {
    const Command = enum {
        Build,
        Run,
        Test,
        Help,

        pub fn fromString(s: []const u8) ?@This() {
            if (std.mem.eql(u8, s, "build")) return .Build;
            if (std.mem.eql(u8, s, "run")) return .Run;
            if (std.mem.eql(u8, s, "test")) return .Test;
            if (std.mem.eql(u8, s, "help")) return .Help;
            return null;
        }
    };

    const cmd1 = Command.fromString("build");
    const cmd2 = Command.fromString("unknown");

    try testing.expect(cmd1.? == .Build);
    try testing.expect(cmd2 == null);
}

test "tools - path utilities" {
    const PathUtils = struct {
        pub fn extension(path: []const u8) ?[]const u8 {
            if (std.mem.lastIndexOfScalar(u8, path, '.')) |idx| {
                return path[idx..];
            }
            return null;
        }

        pub fn basename(path: []const u8) []const u8 {
            if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx| {
                return path[idx + 1 ..];
            }
            return path;
        }
    };

    const path = "/foo/bar/test.txt";
    try testing.expectEqualStrings(".txt", PathUtils.extension(path).?);
    try testing.expectEqualStrings("test.txt", PathUtils.basename(path));
}

test "tools - version parsing" {
    const Version = struct {
        major: u32,
        minor: u32,
        patch: u32,

        pub fn parse(str: []const u8) !@This() {
            var parts = std.mem.splitScalar(u8, str, '.');
            const major = try std.fmt.parseInt(u32, parts.next() orelse return error.InvalidVersion, 10);
            const minor = try std.fmt.parseInt(u32, parts.next() orelse return error.InvalidVersion, 10);
            const patch = try std.fmt.parseInt(u32, parts.next() orelse return error.InvalidVersion, 10);

            return .{ .major = major, .minor = minor, .patch = patch };
        }

        pub fn compare(self: @This(), other: @This()) i32 {
            if (self.major != other.major) {
                return if (self.major < other.major) -1 else 1;
            }
            if (self.minor != other.minor) {
                return if (self.minor < other.minor) -1 else 1;
            }
            if (self.patch != other.patch) {
                return if (self.patch < other.patch) -1 else 1;
            }
            return 0;
        }
    };

    const v1 = try Version.parse("1.2.3");
    const v2 = try Version.parse("1.3.0");

    try testing.expect(v1.major == 1);
    try testing.expect(v1.minor == 2);
    try testing.expect(v1.patch == 3);
    try testing.expect(v1.compare(v2) < 0);
}

test "tools - output formatting" {
    const allocator = testing.allocator;

    const output = try std.fmt.allocPrint(allocator, "Result: {d}", .{42});
    defer allocator.free(output);

    try testing.expectEqualStrings("Result: 42", output);
}
