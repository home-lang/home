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
};

test "runner adapter labels are stable" {
    try std.testing.expectEqualStrings("jsc-bootstrap", Adapter.jsc_bootstrap.label());
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
