const std = @import("std");
const home_rt = @import("home_rt");
const runner = @import("../runner.zig");

pub const Runtime = struct {
    engine: home_rt.jsc.engine.Engine,

    pub fn init(allocator: std.mem.Allocator, harness_source: []const u8) !Runtime {
        var self = Runtime{
            .engine = try home_rt.jsc.engine.Engine.init(allocator),
        };
        errdefer self.deinit();

        try self.installHarness(allocator, harness_source);
        return self;
    }

    pub fn deinit(self: *Runtime) void {
        self.engine.deinit();
    }

    fn installHarness(self: *Runtime, allocator: std.mem.Allocator, harness_source: []const u8) !void {
        const evaluation = try home_rt.jsc.evaluate.evaluateUtf8Detailed(
            allocator,
            self.engine.currentContext(),
            harness_source,
            "home:corpus-harness",
            1,
        );
        defer evaluation.deinit(allocator);

        if (evaluation.exception != null or evaluation.value == null) {
            return error.CorpusHarnessInstallFailed;
        }
    }

    fn resetFileState(self: *Runtime, allocator: std.mem.Allocator) !void {
        const evaluation = try home_rt.jsc.evaluate.evaluateUtf8Detailed(
            allocator,
            self.engine.currentContext(),
            "globalThis.__home_reset_tests();",
            "home:corpus-reset",
            1,
        );
        defer evaluation.deinit(allocator);

        if (evaluation.exception != null or evaluation.value == null) {
            return error.CorpusHarnessResetFailed;
        }
    }

    fn readCounters(self: *Runtime, allocator: std.mem.Allocator) !Counters {
        return .{
            .passed = try readCounter(allocator, &self.engine, "__home_bun_tests.passed"),
            .failed = try readCounter(allocator, &self.engine, "__home_bun_tests.failed"),
            .todo = try readCounter(allocator, &self.engine, "__home_bun_tests.todo"),
        };
    }

    pub fn runFile(self: *Runtime, allocator: std.mem.Allocator, spec: runner.FileSpec) !runner.FileRun {
        self.resetFileState(allocator) catch |err| {
            return runner.FileRun.failBorrowed(spec.path, @errorName(err));
        };

        const evaluation = try home_rt.jsc.evaluate.evaluateUtf8Detailed(
            allocator,
            self.engine.currentContext(),
            spec.source,
            spec.path,
            1,
        );
        defer evaluation.deinit(allocator);

        if (evaluation.exception != null) {
            if (unsupportedExceptionReason(evaluation.exception_message)) |reason| {
                return runner.FileRun.unsupportedOwned(allocator, spec.path, reason);
            }
            return runner.FileRun.failOwned(allocator, spec.path, evaluation.exception_message);
        }
        if (evaluation.value == null) {
            return runner.FileRun.failOwned(allocator, spec.path, null);
        }

        const finish_evaluation = try home_rt.jsc.evaluate.evaluateUtf8Detailed(
            allocator,
            self.engine.currentContext(),
            "globalThis.__home_finish_tests();",
            "home:corpus-finish",
            1,
        );
        defer finish_evaluation.deinit(allocator);

        if (finish_evaluation.exception != null) {
            if (unsupportedExceptionReason(finish_evaluation.exception_message)) |reason| {
                return runner.FileRun.unsupportedOwned(allocator, spec.path, reason);
            }
            return runner.FileRun.failOwned(allocator, spec.path, finish_evaluation.exception_message);
        }
        if (finish_evaluation.value == null) {
            return runner.FileRun.failOwned(allocator, spec.path, null);
        }

        const counters = self.readCounters(allocator) catch |err| {
            return runner.FileRun.failBorrowed(spec.path, @errorName(err));
        };
        if (counters.passed + counters.failed + counters.todo == 0) {
            if (spec.allow_no_tests) {
                return .{
                    .result = .{
                        .path = spec.path,
                    },
                };
            }
            return runner.FileRun.unsupportedBorrowed(spec.path, "no bun:test tests registered by corpus file");
        }

        return .{
            .result = .{
                .path = spec.path,
                .passed = counters.passed,
                .failed = counters.failed,
                .todo = counters.todo,
            },
        };
    }
};

const Counters = struct {
    passed: usize,
    failed: usize,
    todo: usize,
};

fn readCounter(allocator: std.mem.Allocator, engine: *home_rt.jsc.engine.Engine, expr: []const u8) !usize {
    const value = (try home_rt.jsc.evaluate.evaluateUtf8(
        allocator,
        engine.currentContext(),
        expr,
        "home:corpus-counter",
        1,
        null,
    )) orelse return error.CounterEvaluateFailed;

    const number = home_rt.jsc.extern_fns.JSValueToNumber(engine.currentContext(), value, null);
    if (!std.math.isFinite(number) or number < 0 or @floor(number) != number) {
        return error.InvalidCorpusCounter;
    }
    return @intFromFloat(number);
}

const unsupported_error_name = "HomeUnsupportedError";
const unsupported_error_marker = "__home_unsupported__:";

fn unsupportedExceptionReason(message: ?[]const u8) ?[]const u8 {
    const text = message orelse return null;
    if (std.mem.indexOf(u8, text, unsupported_error_name) == null) return null;
    const marker_index = std.mem.indexOf(u8, text, unsupported_error_marker) orelse return null;
    return text[marker_index + unsupported_error_marker.len ..];
}

test "adapter label is stable" {
    try std.testing.expectEqualStrings("jsc-bootstrap", runner.Adapter.jsc_bootstrap.label());
}

test "adapter recognizes HomeUnsupported exceptions" {
    try std.testing.expectEqualStrings("Async tests are not supported", unsupportedExceptionReason("HomeUnsupportedError: __home_unsupported__:Async tests are not supported").?);
    try std.testing.expectEqualStrings("Only Buffer.from is supported", unsupportedExceptionReason("Exception: HomeUnsupportedError: __home_unsupported__:Only Buffer.from is supported").?);
    try std.testing.expect(unsupportedExceptionReason("HomeUnsupportedError: assertion failed") == null);
    try std.testing.expect(unsupportedExceptionReason("Error: __home_unsupported__:assertion failed") == null);
    try std.testing.expect(unsupportedExceptionReason("Error: assertion failed") == null);
}
