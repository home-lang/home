//! Pinned crash-report retrieval and Linux core-file processing.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const platform = @import("corpus_platform.zig");

pub const Diagnostics = struct {
    text: []u8 = &.{},
    traces: usize = 0,
    core_files: usize = 0,
    fetch_failed: bool = false,

    pub fn deinit(self: *Diagnostics, allocator: Allocator) void {
        if (self.text.len != 0) allocator.free(self.text);
        self.* = undefined;
    }
};

fn jsonTruthy(value: std.json.Value) bool {
    return switch (value) {
        .null => false,
        .bool => |item| item,
        .integer => |item| item != 0,
        .float => |item| item != 0,
        .number_string => |item| blk: {
            const number = std.fmt.parseFloat(f64, item) catch break :blk true;
            break :blk number != 0;
        },
        .string => |item| item.len != 0,
        .array, .object => true,
    };
}

pub fn parseRemapTraces(allocator: Allocator, source: []const u8) !Diagnostics {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, source, .{});
    defer parsed.deinit();
    const traces = switch (parsed.value) {
        .array => |items| items.items,
        else => return error.InvalidRemapTraceResponse,
    };
    var output = std.Io.Writer.Allocating.init(allocator);
    errdefer output.deinit();
    if (traces.len != 0) try output.writer.print("{d} crashes reported during this test\n", .{traces.len});
    for (traces) |trace| {
        const object = switch (trace) {
            .object => |value| value,
            else => return error.InvalidRemapTrace,
        };
        if (object.get("failed_parse")) |failed| if (jsonTruthy(failed)) switch (failed) {
            .string => |message| {
                try output.writer.writeAll("Trace string failed to parse:\n");
                try output.writer.print("{s}\n", .{message});
                continue;
            },
            else => return error.InvalidRemapTrace,
        };
        if (object.get("failed_remap")) |failed| if (jsonTruthy(failed)) {
            const pretty = try std.json.Stringify.valueAlloc(allocator, failed, .{ .whitespace = .indent_2 });
            defer allocator.free(pretty);
            try output.writer.writeAll("Parsed trace failed to remap:\n");
            try output.writer.print("{s}\n", .{pretty});
            continue;
        };
        const remap = object.get("remap") orelse return error.InvalidRemapTrace;
        switch (remap) {
            .string => |message| try output.writer.print("================\n{s}\n", .{message}),
            else => return error.InvalidRemapTrace,
        }
    }
    return .{ .text = try output.toOwnedSlice(), .traces = traces.len };
}

pub fn fetchRemapTraces(allocator: Allocator, io: Io, port: u16) !Diagnostics {
    if (port == 0) return error.InvalidRemapPort;
    // Bun waits for the crash uploader to reach the server before /traces.
    try Io.sleep(io, .fromMilliseconds(500), .awake);
    const url = try std.fmt.allocPrint(allocator, "http://localhost:{d}/traces", .{port});
    defer allocator.free(url);
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();
    var body = std.Io.Writer.Allocating.init(allocator);
    defer body.deinit();
    const response = try client.fetch(.{ .location = .{ .url = url }, .response_writer = &body.writer });
    if (response.status != .ok) return error.RemapServerStatus;
    return parseRemapTraces(allocator, body.written());
}

pub const ToolResult = struct {
    term: std.process.Child.Term,
    timed_out: bool,
    output_complete: bool,
    stdout: []u8,
    stderr: []u8,

    pub fn deinit(self: *ToolResult, allocator: Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
        self.* = undefined;
    }
};

pub const ToolRunner = *const fn (Allocator, Io, []const []const u8, []const u8, i64) anyerror!ToolResult;

pub fn coreDumpsApplicable(host: platform.Host, buildkite: bool) bool {
    return buildkite and std.mem.eql(u8, host.os, "linux");
}

pub const Snapshot = struct {
    allocator: Allocator,
    names: std.ArrayList([]u8) = .empty,

    pub fn capture(allocator: Allocator, io: Io, directory: []const u8) !Snapshot {
        var result = Snapshot{ .allocator = allocator };
        errdefer result.deinit();
        var dir = try Io.Dir.cwd().openDir(io, directory, .{ .iterate = true });
        defer dir.close(io);
        var iterator = dir.iterate();
        while (try iterator.next(io)) |entry| {
            const name = try allocator.dupe(u8, entry.name);
            errdefer allocator.free(name);
            try result.names.append(allocator, name);
        }
        return result;
    }

    pub fn contains(self: *const Snapshot, name: []const u8) bool {
        for (self.names.items) |existing| if (std.mem.eql(u8, existing, name)) return true;
        return false;
    }

    pub fn deinit(self: *Snapshot) void {
        for (self.names.items) |name| self.allocator.free(name);
        self.names.deinit(self.allocator);
        self.* = undefined;
    }
};

pub const CoreTracker = struct {
    allocator: Allocator,
    io: Io,
    directory: []u8,
    executable: []u8,

    pub fn start(
        allocator: Allocator,
        io: Io,
        cwd: []const u8,
        executable: []const u8,
        run_tool: ToolRunner,
    ) !CoreTracker {
        if (builtin.os.tag != .linux) return error.CoreDumpTrackingNotApplicable;
        var result = try run_tool(allocator, io, &.{ "sysctl", "-n", "kernel.core_pattern" }, cwd, 5_000);
        defer result.deinit(allocator);
        if (!result.term.success() or result.timed_out or !result.output_complete) return error.CorePatternProbeFailed;
        const pattern = std.mem.trim(u8, result.stdout, " \t\r\n");
        if (pattern.len == 0) return error.EmptyCorePattern;
        if (pattern[0] == '|') return error.PipedCorePattern;
        if (!std.fs.path.isAbsolute(pattern)) return error.RelativeCorePattern;
        const directory = std.fs.path.dirname(pattern) orelse return error.InvalidCorePattern;
        const owned_directory = try allocator.dupe(u8, directory);
        errdefer allocator.free(owned_directory);
        return .{
            .allocator = allocator,
            .io = io,
            .directory = owned_directory,
            .executable = try allocator.dupe(u8, executable),
        };
    }

    pub fn snapshot(self: *const CoreTracker) !Snapshot {
        return Snapshot.capture(self.allocator, self.io, self.directory);
    }

    pub fn collect(
        self: *const CoreTracker,
        before: *const Snapshot,
        pid: std.process.Child.Id,
        term: std.process.Child.Term,
        run_tool: ToolRunner,
    ) !Diagnostics {
        var after = try Snapshot.capture(self.allocator, self.io, self.directory);
        defer after.deinit();
        var output = std.Io.Writer.Allocating.init(self.allocator);
        errdefer output.deinit();
        var new_count: usize = 0;
        var matching_main_core = false;
        var pid_buffer: [64]u8 = undefined;
        const pid_suffix = try std.fmt.bufPrint(&pid_buffer, "{d}.core", .{pid});
        for (after.names.items) |name| {
            if (before.contains(name)) continue;
            new_count += 1;
            if (std.mem.endsWith(u8, name, pid_suffix)) matching_main_core = true;
        }
        switch (term) {
            .signal => |signal| if (!matching_main_core) try output.writer.print("main process killed by SIG{s} but no core file found\n", .{@tagName(signal)}),
            else => {},
        }
        for (after.names.items) |name| {
            if (before.contains(name)) continue;
            const path = try std.fs.path.join(self.allocator, &.{ self.directory, name });
            defer self.allocator.free(path);
            var gdb = run_tool(self.allocator, self.io, &.{ "gdb", "-batch", "--eval-command=bt", "--core", path, self.executable }, self.directory, 240_000) catch |err| {
                try output.writer.print("failed to get backtrace from GDB: {s}\n", .{@errorName(err)});
                continue;
            };
            defer gdb.deinit(self.allocator);
            if (!gdb.term.success() or gdb.timed_out or !gdb.output_complete) {
                try output.writer.writeAll("failed to get backtrace from GDB: ");
                if (gdb.timed_out) {
                    try output.writer.writeAll("timed out\n");
                } else if (std.mem.trim(u8, gdb.stderr, " \t\r\n").len != 0) {
                    try output.writer.print("{s}\n", .{std.mem.trim(u8, gdb.stderr, " \t\r\n")});
                } else switch (gdb.term) {
                    .exited => |code| try output.writer.print("exited with code {d}\n", .{code}),
                    .signal => |signal| try output.writer.print("terminated by SIG{s}\n", .{@tagName(signal)}),
                    .stopped => |signal| try output.writer.print("stopped by SIG{s}\n", .{@tagName(signal)}),
                    .unknown => |code| try output.writer.print("unknown status {d}\n", .{code}),
                }
                continue;
            }
            try output.writer.print("======== Stack trace from GDB for {s}: ========\n", .{name});
            var lines = std.mem.splitScalar(u8, gdb.stdout, '\n');
            while (lines.next()) |line| if (std.mem.startsWith(u8, line, "Program terminated") or std.mem.startsWith(u8, line, "#") or std.mem.startsWith(u8, line, "[Current thread is")) try output.writer.print("{s}\n", .{line});
        }
        return .{ .text = try output.toOwnedSlice(), .core_files = new_count };
    }

    pub fn deinit(self: *CoreTracker) void {
        self.allocator.free(self.executable);
        self.allocator.free(self.directory);
        self.* = undefined;
    }
};

test "native corpus crash trace formatting preserves parse remap and mapped failures" {
    const allocator = std.testing.allocator;
    var result = try parseRemapTraces(allocator,
        \\[
        \\  {"failed_parse":"raw-trace"},
        \\  {"failed_remap":{"reason":"missing map"}},
        \\  {"remap":"frame-a\nframe-b"},
        \\  {"failed_parse":"","remap":"empty-parse-fell-through"},
        \\  {"failed_remap":null,"remap":"null-remap-fell-through"}
        \\]
    );
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 5), result.traces);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "5 crashes reported during this test") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "Trace string failed to parse:\nraw-trace") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "Parsed trace failed to remap:") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "================\nframe-a\nframe-b") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "empty-parse-fell-through") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "null-remap-fell-through") != null);
}

test "native corpus core applicability retains pinned Buildkite Linux default" {
    try std.testing.expect(coreDumpsApplicable(.{ .os = "linux", .arch = "x64" }, true));
    try std.testing.expect(!coreDumpsApplicable(.{ .os = "linux", .arch = "x64" }, false));
    try std.testing.expect(!coreDumpsApplicable(.{ .os = "darwin", .arch = "aarch64" }, true));
}

test "native corpus core processing retains new files and filtered bounded GDB output" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    var tracker = CoreTracker{
        .allocator = allocator,
        .io = io,
        .directory = try allocator.dupe(u8, root),
        .executable = try allocator.dupe(u8, "/private/home"),
    };
    defer tracker.deinit();
    var before = try tracker.snapshot();
    defer before.deinit();
    try tmp.dir.writeFile(io, .{ .sub_path = "home.42.core", .data = "core" });
    const Fake = struct {
        fn run(a: Allocator, _: Io, argv: []const []const u8, _: []const u8, timeout_ms: i64) !ToolResult {
            try std.testing.expectEqualStrings("gdb", argv[0]);
            try std.testing.expectEqualStrings("/private/home", argv[argv.len - 1]);
            try std.testing.expectEqual(@as(i64, 240_000), timeout_ms);
            return .{
                .term = .{ .exited = 0 },
                .timed_out = false,
                .output_complete = true,
                .stdout = try a.dupe(u8, "noise\nProgram terminated with signal SIGABRT\n#0 frame\n[Current thread is 1]\nignored\n"),
                .stderr = try a.dupe(u8, ""),
            };
        }
    };
    var result = try tracker.collect(&before, @as(std.process.Child.Id, @intCast(42)), .{ .exited = 0 }, Fake.run);
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), result.core_files);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "Stack trace from GDB for home.42.core") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "Program terminated with signal SIGABRT") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "#0 frame") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "noise") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "ignored") == null);
}
