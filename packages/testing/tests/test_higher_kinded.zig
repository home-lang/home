const std = @import("std");
const testing = @import("../src/modern_test.zig");
const t = testing.t;
const HKT = @import("../../types/src/higher_kinded.zig");

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
    try t.describe("Higher-Kinded Types - Option", testOption);
    try t.describe("Higher-Kinded Types - Result", testResult);
    try t.describe("Higher-Kinded Types - List", testList);
    try t.describe("Higher-Kinded Types - Type Level", testTypeLevel);

    try runner.run();
}

fn testOption() !void {
    try t.it("should create Some value", testOptionSome);
    try t.it("should create None value", testOptionNone);
    try t.it("should check isSome/isNone", testOptionChecks);
    try t.it("should map over Option", testOptionMap);
    try t.it("should flatMap Option", testOptionFlatMap);
    try t.it("should fold Option", testOptionFold);
}

fn testOptionSome(expect: *testing.ModernTest.Expect) !void {
    const IntOption = HKT.Option(i32);
    const opt = IntOption.init(42);

    const is_some = opt.isSome();
    expect.* = t.expect(expect.allocator, is_some, expect.failures);
    try expect.toBe(true);

    const value = try opt.unwrap();
    expect.* = t.expect(expect.allocator, value, expect.failures);
    try expect.toBe(42);
}

fn testOptionNone(expect: *testing.ModernTest.Expect) !void {
    const IntOption = HKT.Option(i32);
    const opt = IntOption.none_value();

    const is_none = opt.isNone();
    expect.* = t.expect(expect.allocator, is_none, expect.failures);
    try expect.toBe(true);

    const result = opt.unwrap();
    expect.* = t.expect(expect.allocator, result, expect.failures);
    try expect.toEqual(error.NoneValue);
}

fn testOptionChecks(expect: *testing.ModernTest.Expect) !void {
    const IntOption = HKT.Option(i32);
    const some = IntOption.init(10);
    const none = IntOption.none_value();

    expect.* = t.expect(expect.allocator, some.isSome(), expect.failures);
    try expect.toBe(true);

    expect.* = t.expect(expect.allocator, some.isNone(), expect.failures);
    try expect.toBe(false);

    expect.* = t.expect(expect.allocator, none.isSome(), expect.failures);
    try expect.toBe(false);

    expect.* = t.expect(expect.allocator, none.isNone(), expect.failures);
    try expect.toBe(true);
}

fn testOptionMap(expect: *testing.ModernTest.Expect) !void {
    const IntOption = HKT.Option(i32);
    const opt = IntOption.init(10);

    const double = struct {
        fn f(x: i32) i32 {
            return x * 2;
        }
    }.f;

    const mapped = opt.map(i32, double);
    const value = try mapped.unwrap();

    expect.* = t.expect(expect.allocator, value, expect.failures);
    try expect.toBe(20);
}

fn testOptionFlatMap(expect: *testing.ModernTest.Expect) !void {
    const IntOption = HKT.Option(i32);
    const opt = IntOption.init(5);

    const safe_divide = struct {
        fn f(x: i32) HKT.Option(i32) {
            if (x == 0) return HKT.Option(i32).none_value();
            return HKT.Option(i32).init(@divFloor(100, x));
        }
    }.f;

    const result = opt.flatMap(i32, safe_divide);
    const value = try result.unwrap();

    expect.* = t.expect(expect.allocator, value, expect.failures);
    try expect.toBe(20);
}

fn testOptionFold(expect: *testing.ModernTest.Expect) !void {
    const IntOption = HKT.Option(i32);
    const some = IntOption.init(10);
    const none = IntOption.none_value();

    const add = struct {
        fn f(acc: i32, x: i32) i32 {
            return acc + x;
        }
    }.f;

    const result1 = some.foldLeft(i32, 0, add);
    const result2 = none.foldLeft(i32, 0, add);

    expect.* = t.expect(expect.allocator, result1, expect.failures);
    try expect.toBe(10);

    expect.* = t.expect(expect.allocator, result2, expect.failures);
    try expect.toBe(0);
}

fn testResult() !void {
    try t.it("should create Ok value", testResultOk);
    try t.it("should create Err value", testResultErr);
    try t.it("should check isOk/isErr", testResultChecks);
    try t.it("should map over Result", testResultMap);
    try t.it("should flatMap Result", testResultFlatMap);
    try t.it("should mapErr", testResultMapErr);
}

fn testResultOk(expect: *testing.ModernTest.Expect) !void {
    const IntResult = HKT.Result(i32, []const u8);
    const result = IntResult.ok_value(42);

    const is_ok = result.isOk();
    expect.* = t.expect(expect.allocator, is_ok, expect.failures);
    try expect.toBe(true);

    const value = try result.unwrap();
    expect.* = t.expect(expect.allocator, value, expect.failures);
    try expect.toBe(42);
}

fn testResultErr(expect: *testing.ModernTest.Expect) !void {
    const IntResult = HKT.Result(i32, []const u8);
    const result = IntResult.err_value("error occurred");

    const is_err = result.isErr();
    expect.* = t.expect(expect.allocator, is_err, expect.failures);
    try expect.toBe(true);

    const unwrap_result = result.unwrap();
    expect.* = t.expect(expect.allocator, unwrap_result, expect.failures);
    try expect.toEqual(error.ResultError);
}

fn testResultChecks(expect: *testing.ModernTest.Expect) !void {
    const IntResult = HKT.Result(i32, []const u8);
    const ok = IntResult.ok_value(10);
    const err = IntResult.err_value("error");

    expect.* = t.expect(expect.allocator, ok.isOk(), expect.failures);
    try expect.toBe(true);

    expect.* = t.expect(expect.allocator, ok.isErr(), expect.failures);
    try expect.toBe(false);

    expect.* = t.expect(expect.allocator, err.isOk(), expect.failures);
    try expect.toBe(false);

    expect.* = t.expect(expect.allocator, err.isErr(), expect.failures);
    try expect.toBe(true);
}

fn testResultMap(expect: *testing.ModernTest.Expect) !void {
    const IntResult = HKT.Result(i32, []const u8);
    const result = IntResult.ok_value(10);

    const double = struct {
        fn f(x: i32) i32 {
            return x * 2;
        }
    }.f;

    const mapped = result.map(i32, double);
    const value = try mapped.unwrap();

    expect.* = t.expect(expect.allocator, value, expect.failures);
    try expect.toBe(20);
}

fn testResultFlatMap(expect: *testing.ModernTest.Expect) !void {
    const IntResult = HKT.Result(i32, []const u8);
    const result = IntResult.ok_value(5);

    const safe_divide = struct {
        fn f(x: i32) HKT.Result(i32, []const u8) {
            if (x == 0) return HKT.Result(i32, []const u8).err_value("division by zero");
            return HKT.Result(i32, []const u8).ok_value(@divFloor(100, x));
        }
    }.f;

    const divided = result.flatMap(i32, safe_divide);
    const value = try divided.unwrap();

    expect.* = t.expect(expect.allocator, value, expect.failures);
    try expect.toBe(20);
}

fn testResultMapErr(expect: *testing.ModernTest.Expect) !void {
    const IntResult = HKT.Result(i32, []const u8);
    const result = IntResult.err_value("original error");

    const transform_error = struct {
        fn f(msg: []const u8) i32 {
            _ = msg;
            return -1;
        }
    }.f;

    const mapped = result.mapErr(i32, transform_error);

    expect.* = t.expect(expect.allocator, mapped.isErr(), expect.failures);
    try expect.toBe(true);
}

fn testList() !void {
    try t.it("should create empty list", testListCreate);
    try t.it("should map over list", testListMap);
    try t.it("should fold list", testListFold);
}

fn testListCreate(expect: *testing.ModernTest.Expect) !void {
    var list = HKT.List(i32).init(expect.allocator);
    defer list.deinit();

    const len = list.items.len;
    expect.* = t.expect(expect.allocator, len, expect.failures);
    try expect.toBe(@as(usize, 0));
}

fn testListMap(expect: *testing.ModernTest.Expect) !void {
    var list = HKT.List(i32).init(expect.allocator);
    list.items = try expect.allocator.alloc(i32, 3);
    list.items[0] = 1;
    list.items[1] = 2;
    list.items[2] = 3;
    defer list.deinit();

    const double = struct {
        fn f(x: i32) i32 {
            return x * 2;
        }
    }.f;

    var mapped = try list.map(i32, double);
    defer mapped.deinit();

    expect.* = t.expect(expect.allocator, mapped.items[0], expect.failures);
    try expect.toBe(2);

    expect.* = t.expect(expect.allocator, mapped.items[1], expect.failures);
    try expect.toBe(4);

    expect.* = t.expect(expect.allocator, mapped.items[2], expect.failures);
    try expect.toBe(6);
}

fn testListFold(expect: *testing.ModernTest.Expect) !void {
    var list = HKT.List(i32).init(expect.allocator);
    list.items = try expect.allocator.alloc(i32, 4);
    list.items[0] = 1;
    list.items[1] = 2;
    list.items[2] = 3;
    list.items[3] = 4;
    defer list.deinit();

    const add = struct {
        fn f(acc: i32, x: i32) i32 {
            return acc + x;
        }
    }.f;

    const sum = list.foldLeft(i32, 0, add);

    expect.* = t.expect(expect.allocator, sum, expect.failures);
    try expect.toBe(10);
}

fn testTypeLevel() !void {
    try t.it("should apply type constructor", testTypeApply);
    try t.it("should compose type constructors", testTypeCompose);
}

fn testTypeApply(expect: *testing.ModernTest.Expect) !void {
    const Applied = HKT.TypeLevel.Apply(HKT.Option, i32);
    const opt = Applied.init(42);

    const value = try opt.unwrap();
    expect.* = t.expect(expect.allocator, value, expect.failures);
    try expect.toBe(42);
}

fn testTypeCompose(expect: *testing.ModernTest.Expect) !void {
    // Option<List<T>> composition
    const OptionList = HKT.TypeLevel.Compose(HKT.Option, HKT.List);
    const Applied = OptionList.apply(i32);

    const opt = Applied.init(HKT.List(i32).init(expect.allocator));
    const is_some = opt.isSome();

    expect.* = t.expect(expect.allocator, is_some, expect.failures);
    try expect.toBe(true);

    var list = try opt.unwrap();
    defer list.deinit();

    const len = list.items.len;
    expect.* = t.expect(expect.allocator, len, expect.failures);
    try expect.toBe(@as(usize, 0));
}
