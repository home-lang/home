const std = @import("std");

pub const TestStatus = enum {
    passed,
    failed,
    todo,
    unsupported,
};

pub const FileResult = struct {
    path: []const u8,
    passed: usize = 0,
    failed: usize = 0,
    todo: usize = 0,
    unsupported: usize = 0,
    first_failure_message: []const u8 = "",

    pub fn status(self: FileResult) TestStatus {
        if (self.unsupported != 0) return .unsupported;
        if (self.failed != 0) return .failed;
        if (self.todo != 0 and self.passed == 0) return .todo;
        return .passed;
    }
};

pub const RunSummary = struct {
    files: usize = 0,
    passed: usize = 0,
    failed: usize = 0,
    todo: usize = 0,
    unsupported: usize = 0,

    pub fn addFile(self: *RunSummary, file: FileResult) void {
        self.files += 1;
        self.passed += file.passed;
        self.failed += file.failed;
        self.todo += file.todo;
        self.unsupported += file.unsupported;
    }
};

test "run summary aggregates file results" {
    var summary = RunSummary{};
    summary.addFile(.{
        .path = "a.test.js",
        .passed = 2,
        .todo = 1,
    });
    summary.addFile(.{
        .path = "b.test.js",
        .failed = 1,
        .unsupported = 1,
    });

    try std.testing.expectEqual(@as(usize, 2), summary.files);
    try std.testing.expectEqual(@as(usize, 2), summary.passed);
    try std.testing.expectEqual(@as(usize, 1), summary.failed);
    try std.testing.expectEqual(@as(usize, 1), summary.todo);
    try std.testing.expectEqual(@as(usize, 1), summary.unsupported);
}

test "file result status prefers blockers" {
    try std.testing.expectEqual(TestStatus.unsupported, (FileResult{ .path = "x", .unsupported = 1 }).status());
    try std.testing.expectEqual(TestStatus.failed, (FileResult{ .path = "x", .failed = 1 }).status());
    try std.testing.expectEqual(TestStatus.todo, (FileResult{ .path = "x", .todo = 1 }).status());
    try std.testing.expectEqual(TestStatus.passed, (FileResult{ .path = "x", .passed = 1 }).status());
}
