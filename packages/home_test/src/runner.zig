const std = @import("std");

const result = @import("result.zig");

pub const Adapter = enum {
    jsc_bootstrap,

    pub fn label(self: Adapter) []const u8 {
        return switch (self) {
            .jsc_bootstrap => "jsc-bootstrap",
        };
    }
};

pub const FileSpec = struct {
    path: []const u8,
    source: []const u8,
    allow_no_tests: bool = false,
};

pub const PreparedFile = struct {
    path: []const u8,
    source: []u8,
    unsupported_reason: ?[]const u8 = null,
    allow_no_tests: bool = false,

    pub fn fileSpec(self: PreparedFile) FileSpec {
        return .{
            .path = self.path,
            .source = self.source,
            .allow_no_tests = self.allow_no_tests,
        };
    }

    pub fn deinit(self: *PreparedFile, allocator: std.mem.Allocator) void {
        allocator.free(self.source);
        self.source = &.{};
        self.unsupported_reason = null;
    }
};

pub const RunOptions = struct {
    adapter: Adapter = .jsc_bootstrap,
};

pub const FileRun = struct {
    result: result.FileResult,
    first_failure_message_owned: bool = false,

    pub fn deinit(self: *FileRun, allocator: std.mem.Allocator) void {
        if (self.first_failure_message_owned) {
            allocator.free(self.result.first_failure_message);
        }
        self.result.first_failure_message = "";
        self.first_failure_message_owned = false;
    }

    pub fn failBorrowed(path: []const u8, message: []const u8) FileRun {
        return .{
            .result = .{
                .path = path,
                .failed = 1,
                .first_failure_message = message,
            },
        };
    }

    pub fn unsupportedBorrowed(path: []const u8, message: []const u8) FileRun {
        return .{
            .result = .{
                .path = path,
                .unsupported = 1,
                .first_failure_message = message,
            },
        };
    }

    pub fn failOwned(allocator: std.mem.Allocator, path: []const u8, message: ?[]const u8) !FileRun {
        const copied = try allocator.dupe(u8, message orelse "JSEvaluateScript returned null without an exception");
        return .{
            .result = .{
                .path = path,
                .failed = 1,
                .first_failure_message = copied,
            },
            .first_failure_message_owned = true,
        };
    }

    pub fn unsupportedOwned(allocator: std.mem.Allocator, path: []const u8, message: []const u8) !FileRun {
        return unsupportedCountOwned(allocator, path, message, 1);
    }

    pub fn unsupportedCountOwned(allocator: std.mem.Allocator, path: []const u8, message: []const u8, count: usize) !FileRun {
        const copied = try allocator.dupe(u8, message);
        return .{
            .result = .{
                .path = path,
                .unsupported = count,
                .first_failure_message = copied,
            },
            .first_failure_message_owned = true,
        };
    }
};

test "runner adapter labels are stable" {
    try std.testing.expectEqualStrings("jsc-bootstrap", Adapter.jsc_bootstrap.label());
}

test "prepared file exposes executable file spec" {
    const source = try std.testing.allocator.dupe(u8, "test(\"x\", () => {});");
    var prepared = PreparedFile{
        .path = "sample.test.ts",
        .source = source,
    };
    defer prepared.deinit(std.testing.allocator);

    const spec = prepared.fileSpec();
    try std.testing.expectEqualStrings("sample.test.ts", spec.path);
    try std.testing.expectEqualStrings("test(\"x\", () => {});", spec.source);
}

test "file run owns copied failure messages" {
    var file_run = try FileRun.failOwned(std.testing.allocator, "sample.test.ts", "boom");
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(result.TestStatus.failed, file_run.result.status());
    try std.testing.expectEqualStrings("boom", file_run.result.first_failure_message);
    try std.testing.expect(file_run.first_failure_message_owned);
}

test "file run can report borrowed unsupported reasons" {
    var file_run = FileRun.unsupportedBorrowed("sample.test.ts", "no tests");
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(result.TestStatus.unsupported, file_run.result.status());
    try std.testing.expectEqualStrings("no tests", file_run.result.first_failure_message);
    try std.testing.expect(!file_run.first_failure_message_owned);
}

test "file run owns copied unsupported reasons" {
    var file_run = try FileRun.unsupportedOwned(std.testing.allocator, "sample.test.ts", "not implemented");
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(result.TestStatus.unsupported, file_run.result.status());
    try std.testing.expectEqualStrings("not implemented", file_run.result.first_failure_message);
    try std.testing.expect(file_run.first_failure_message_owned);
}

test "file run can report multiple unsupported registrations" {
    var file_run = try FileRun.unsupportedCountOwned(std.testing.allocator, "sample.test.ts", "not implemented", 3);
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(result.TestStatus.unsupported, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 3), file_run.result.unsupported);
}
