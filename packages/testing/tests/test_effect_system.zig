const std = @import("std");
const testing = @import("../src/modern_test.zig");
const t = testing.t;
const Effects = @import("../../types/src/effect_system.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = testing.ModernTest.Config{
        .reporter = .pretty,
        .timeout_ms = 5000,
    };

    const runner = try testing.ModernTest.Runner.init(allocator, config);
    defer runner.deinit();

    // Run all test suites
    try t.describe("Effect System - IO Effect", testIO);
    try t.describe("Effect System - State Effect", testState);
    try t.describe("Effect System - Reader Effect", testReader);
    try t.describe("Effect System - Writer Effect", testWriter);
    try t.describe("Effect System - Exceptional", testExceptional);
    try t.describe("Effect System - Effect Registration", testRegistration);

    try runner.run();
}

fn testIO() !void {
    try t.it("should create IO effect", testIOCreate);
    try t.it("should run IO effect", testIORun);
    try t.it("should map over IO", testIOMap);
    try t.it("should flatMap IO", testIOFlatMap);
}

fn testIOCreate(expect: *testing.ModernTest.Expect) !void {
    const comp = struct {
        fn f() i32 {
            return 42;
        }
    }.f;

    const io = Effects.IO.of(i32).init(comp);
    const result = io.run();

    expect.* = t.expect(expect.allocator, result, expect.failures);
    try expect.toBe(42);
}

fn testIORun(expect: *testing.ModernTest.Expect) !void {
    const comp = struct {
        fn f() i32 {
            return 10 + 20;
        }
    }.f;

    const io = Effects.IO.of(i32).init(comp);
    const result = io.run();

    expect.* = t.expect(expect.allocator, result, expect.failures);
    try expect.toBe(30);
}

fn testIOMap(expect: *testing.ModernTest.Expect) !void {
    const comp = struct {
        fn f() i32 {
            return 5;
        }
    }.f;

    const double = struct {
        fn f(x: i32) i32 {
            return x * 2;
        }
    }.f;

    const io = Effects.IO.of(i32).init(comp);
    const mapped = io.map(i32, double);
    const result = mapped.run();

    expect.* = t.expect(expect.allocator, result, expect.failures);
    try expect.toBe(10);
}

fn testIOFlatMap(expect: *testing.ModernTest.Expect) !void {
    const comp = struct {
        fn f() i32 {
            return 10;
        }
    }.f;

    const toIO = struct {
        fn f(x: i32) Effects.IO.of(i32) {
            const inner = struct {
                fn g() i32 {
                    return x + 5;
                }
            }.g;
            return Effects.IO.of(i32).init(inner);
        }
    }.f;

    const io = Effects.IO.of(i32).init(comp);
    const flat = io.flatMap(i32, toIO);
    const result = flat.run();

    expect.* = t.expect(expect.allocator, result, expect.failures);
    try expect.toBe(15);
}

fn testState() !void {
    try t.it("should create State effect", testStateCreate);
    try t.it("should run State effect", testStateRun);
    try t.it("should map over State", testStateMap);
    try t.it("should flatMap State", testStateFlatMap);
}

fn testStateCreate(expect: *testing.ModernTest.Expect) !void {
    const run_fn = struct {
        fn f(s: i32) struct { value: i32, state: i32 } {
            return .{ .value = s * 2, .state = s + 1 };
        }
    }.f;

    const state = Effects.State(i32, i32).init(run_fn);
    const result = state.run(5);

    expect.* = t.expect(expect.allocator, result.value, expect.failures);
    try expect.toBe(10);

    expect.* = t.expect(expect.allocator, result.state, expect.failures);
    try expect.toBe(6);
}

fn testStateRun(expect: *testing.ModernTest.Expect) !void {
    const run_fn = struct {
        fn f(s: i32) struct { value: []const u8, state: i32 } {
            return .{ .value = "result", .state = s + 10 };
        }
    }.f;

    const state = Effects.State(i32, []const u8).init(run_fn);
    const result = state.run(0);

    const equal = std.mem.eql(u8, result.value, "result");
    expect.* = t.expect(expect.allocator, equal, expect.failures);
    try expect.toBe(true);

    expect.* = t.expect(expect.allocator, result.state, expect.failures);
    try expect.toBe(10);
}

fn testStateMap(expect: *testing.ModernTest.Expect) !void {
    const run_fn = struct {
        fn f(s: i32) struct { value: i32, state: i32 } {
            return .{ .value = s, .state = s };
        }
    }.f;

    const double = struct {
        fn f(x: i32) i32 {
            return x * 2;
        }
    }.f;

    const state = Effects.State(i32, i32).init(run_fn);
    const mapped = state.map(i32, double);
    const result = mapped.run(5);

    expect.* = t.expect(expect.allocator, result.value, expect.failures);
    try expect.toBe(10);

    expect.* = t.expect(expect.allocator, result.state, expect.failures);
    try expect.toBe(5);
}

fn testStateFlatMap(expect: *testing.ModernTest.Expect) !void {
    const run_fn = struct {
        fn f(s: i32) struct { value: i32, state: i32 } {
            return .{ .value = s * 2, .state = s + 1 };
        }
    }.f;

    const toState = struct {
        fn f(x: i32) Effects.State(i32, i32) {
            const inner = struct {
                fn g(s: i32) struct { value: i32, state: i32 } {
                    return .{ .value = x + s, .state = s + 1 };
                }
            }.g;
            return Effects.State(i32, i32).init(inner);
        }
    }.f;

    const state = Effects.State(i32, i32).init(run_fn);
    const flat = state.flatMap(i32, toState);
    const result = flat.run(5);

    // First: value = 10, state = 6
    // Second: value = 10 + 6 = 16, state = 7
    expect.* = t.expect(expect.allocator, result.value, expect.failures);
    try expect.toBe(16);

    expect.* = t.expect(expect.allocator, result.state, expect.failures);
    try expect.toBe(7);
}

fn testReader() !void {
    try t.it("should create Reader effect", testReaderCreate);
    try t.it("should run Reader effect", testReaderRun);
    try t.it("should map over Reader", testReaderMap);
    try t.it("should ask for environment", testReaderAsk);
}

fn testReaderCreate(expect: *testing.ModernTest.Expect) !void {
    const run_fn = struct {
        fn f(r: i32) i32 {
            return r * 2;
        }
    }.f;

    const reader = Effects.Reader(i32, i32).init(run_fn);
    const result = reader.run(10);

    expect.* = t.expect(expect.allocator, result, expect.failures);
    try expect.toBe(20);
}

fn testReaderRun(expect: *testing.ModernTest.Expect) !void {
    const Config = struct {
        multiplier: i32,
    };

    const run_fn = struct {
        fn f(cfg: Config) i32 {
            return cfg.multiplier * 5;
        }
    }.f;

    const reader = Effects.Reader(Config, i32).init(run_fn);
    const result = reader.run(.{ .multiplier = 3 });

    expect.* = t.expect(expect.allocator, result, expect.failures);
    try expect.toBe(15);
}

fn testReaderMap(expect: *testing.ModernTest.Expect) !void {
    const run_fn = struct {
        fn f(r: i32) i32 {
            return r + 10;
        }
    }.f;

    const double = struct {
        fn f(x: i32) i32 {
            return x * 2;
        }
    }.f;

    const reader = Effects.Reader(i32, i32).init(run_fn);
    const mapped = reader.map(i32, double);
    const result = mapped.run(5);

    expect.* = t.expect(expect.allocator, result, expect.failures);
    try expect.toBe(30);
}

fn testReaderAsk(expect: *testing.ModernTest.Expect) !void {
    const reader = Effects.Reader(i32, i32).ask();
    const result = reader.run(42);

    expect.* = t.expect(expect.allocator, result, expect.failures);
    try expect.toBe(42);
}

fn testWriter() !void {
    try t.it("should create Writer effect", testWriterCreate);
    try t.it("should run Writer effect", testWriterRun);
    try t.it("should map over Writer", testWriterMap);
    try t.it("should tell log", testWriterTell);
}

fn testWriterCreate(expect: *testing.ModernTest.Expect) !void {
    const writer = Effects.Writer([]const u8, i32).init(42, "log message");
    const result = writer.run();

    expect.* = t.expect(expect.allocator, result.value, expect.failures);
    try expect.toBe(42);

    const equal = std.mem.eql(u8, result.log, "log message");
    expect.* = t.expect(expect.allocator, equal, expect.failures);
    try expect.toBe(true);
}

fn testWriterRun(expect: *testing.ModernTest.Expect) !void {
    const writer = Effects.Writer(i32, i32).init(10, 100);
    const result = writer.run();

    expect.* = t.expect(expect.allocator, result.value, expect.failures);
    try expect.toBe(10);

    expect.* = t.expect(expect.allocator, result.log, expect.failures);
    try expect.toBe(100);
}

fn testWriterMap(expect: *testing.ModernTest.Expect) !void {
    const writer = Effects.Writer([]const u8, i32).init(5, "log");

    const double = struct {
        fn f(x: i32) i32 {
            return x * 2;
        }
    }.f;

    const mapped = writer.map(i32, double);
    const result = mapped.run();

    expect.* = t.expect(expect.allocator, result.value, expect.failures);
    try expect.toBe(10);

    const equal = std.mem.eql(u8, result.log, "log");
    expect.* = t.expect(expect.allocator, equal, expect.failures);
    try expect.toBe(true);
}

fn testWriterTell(expect: *testing.ModernTest.Expect) !void {
    const writer = Effects.Writer([]const u8, void).tell("message");
    const result = writer.run();

    const equal = std.mem.eql(u8, result.log, "message");
    expect.* = t.expect(expect.allocator, equal, expect.failures);
    try expect.toBe(true);
}

fn testExceptional() !void {
    try t.it("should create success value", testExceptionalOk);
    try t.it("should create failure value", testExceptionalErr);
    try t.it("should check isOk", testExceptionalIsOk);
    try t.it("should map over Exceptional", testExceptionalMap);
    try t.it("should flatMap Exceptional", testExceptionalFlatMap);
    try t.it("should catch errors", testExceptionalCatch);
}

fn testExceptionalOk(expect: *testing.ModernTest.Expect) !void {
    const exc = Effects.Exceptional([]const u8, i32).ok(42);

    const is_ok = exc.isOk();
    expect.* = t.expect(expect.allocator, is_ok, expect.failures);
    try expect.toBe(true);
}

fn testExceptionalErr(expect: *testing.ModernTest.Expect) !void {
    const exc = Effects.Exceptional([]const u8, i32).err("error");

    const is_ok = exc.isOk();
    expect.* = t.expect(expect.allocator, is_ok, expect.failures);
    try expect.toBe(false);
}

fn testExceptionalIsOk(expect: *testing.ModernTest.Expect) !void {
    const ok = Effects.Exceptional([]const u8, i32).ok(10);
    const err = Effects.Exceptional([]const u8, i32).err("fail");

    expect.* = t.expect(expect.allocator, ok.isOk(), expect.failures);
    try expect.toBe(true);

    expect.* = t.expect(expect.allocator, err.isOk(), expect.failures);
    try expect.toBe(false);
}

fn testExceptionalMap(expect: *testing.ModernTest.Expect) !void {
    const exc = Effects.Exceptional([]const u8, i32).ok(5);

    const double = struct {
        fn f(x: i32) i32 {
            return x * 2;
        }
    }.f;

    const mapped = exc.map(i32, double);

    expect.* = t.expect(expect.allocator, mapped.isOk(), expect.failures);
    try expect.toBe(true);
}

fn testExceptionalFlatMap(expect: *testing.ModernTest.Expect) !void {
    const exc = Effects.Exceptional([]const u8, i32).ok(10);

    const half = struct {
        fn f(x: i32) Effects.Exceptional([]const u8, i32) {
            if (@mod(x, 2) != 0) {
                return Effects.Exceptional([]const u8, i32).err("not even");
            }
            return Effects.Exceptional([]const u8, i32).ok(@divFloor(x, 2));
        }
    }.f;

    const result = exc.flatMap(i32, half);

    expect.* = t.expect(expect.allocator, result.isOk(), expect.failures);
    try expect.toBe(true);
}

fn testExceptionalCatch(expect: *testing.ModernTest.Expect) !void {
    const exc = Effects.Exceptional([]const u8, i32).err("error");

    const handler = struct {
        fn f(msg: []const u8) i32 {
            _ = msg;
            return -1;
        }
    }.f;

    const result = exc.catch_error(handler);

    expect.* = t.expect(expect.allocator, result, expect.failures);
    try expect.toBe(-1);
}

fn testRegistration() !void {
    try t.it("should register effect definition", testRegisterEffect);
    try t.it("should register effect handler", testRegisterHandler);
    try t.it("should perform effect operation", testPerformEffect);
}

fn testRegisterEffect(expect: *testing.ModernTest.Expect) !void {
    var system = Effects.EffectSystem.init(expect.allocator);
    defer system.deinit();

    const ops = [_]Effects.EffectSystem.EffectDef.Operation{
        .{
            .name = "read",
            .params = &.{},
            .return_type = "String",
        },
    };

    try system.registerEffect("IO", .io, &ops);

    const has_effect = system.effects.contains("IO");
    expect.* = t.expect(expect.allocator, has_effect, expect.failures);
    try expect.toBe(true);
}

fn testRegisterHandler(expect: *testing.ModernTest.Expect) !void {
    var system = Effects.EffectSystem.init(expect.allocator);
    defer system.deinit();

    const handler = struct {
        fn f(op: []const u8, args: []const ?*anyopaque) anyerror!?*anyopaque {
            _ = op;
            _ = args;
            return null;
        }
    }.f;

    try system.registerHandler("IO", handler);

    const has_handler = system.handlers.contains("IO");
    expect.* = t.expect(expect.allocator, has_handler, expect.failures);
    try expect.toBe(true);
}

fn testPerformEffect(expect: *testing.ModernTest.Expect) !void {
    var system = Effects.EffectSystem.init(expect.allocator);
    defer system.deinit();

    const value: i32 = 42;
    const handler = struct {
        fn f(op: []const u8, args: []const ?*anyopaque) anyerror!?*anyopaque {
            _ = op;
            _ = args;
            const val: i32 = 42;
            return @constCast(@ptrCast(&val));
        }
    }.f;

    try system.registerHandler("Test", handler);

    const result = try system.perform("Test", "operation", &.{});

    expect.* = t.expect(expect.allocator, result != null, expect.failures);
    try expect.toBe(true);
}
