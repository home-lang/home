const std = @import("std");
const testing = @import("../src/modern_test.zig");
const t = testing.t;
const ConstGenerics = @import("../../types/src/const_generics.zig").ConstGenerics;
const Examples = @import("../../types/src/const_generics.zig").Examples;
const Constraints = @import("../../types/src/const_generics.zig").Constraints;

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
    try t.describe("Const Generics - Basic Functionality", testBasicFunctionality);
    try t.describe("Const Generics - Array Example", testArrayExample);
    try t.describe("Const Generics - Vector Example", testVectorExample);
    try t.describe("Const Generics - Matrix Example", testMatrixExample);
    try t.describe("Const Generics - Bounded Example", testBoundedExample);
    try t.describe("Const Generics - Constraints", testConstraints);
    try t.describe("Const Generics - Instantiation", testInstantiation);

    try runner.run();
}

fn testBasicFunctionality() !void {
    try t.it("should initialize const generics system", testInit);
    try t.it("should register const parameters", testRegisterParam);
    try t.it("should handle different parameter kinds", testParameterKinds);
}

fn testInit(expect: *testing.ModernTest.Expect) !void {
    var cg = ConstGenerics.init(expect.allocator);
    defer cg.deinit();

    const count = cg.const_params.count();
    expect.* = t.expect(expect.allocator, count, expect.failures);
    try expect.toBe(@as(u32, 0));
}

fn testRegisterParam(expect: *testing.ModernTest.Expect) !void {
    var cg = ConstGenerics.init(expect.allocator);
    defer cg.deinit();

    try cg.registerConstParam("N", .integer, null);

    const has_param = cg.const_params.contains("N");
    expect.* = t.expect(expect.allocator, has_param, expect.failures);
    try expect.toBe(true);
}

fn testParameterKinds(expect: *testing.ModernTest.Expect) !void {
    var cg = ConstGenerics.init(expect.allocator);
    defer cg.deinit();

    try cg.registerConstParam("size", .integer, null);
    try cg.registerConstParam("enabled", .boolean, null);
    try cg.registerConstParam("name", .string, null);
    try cg.registerConstParam("type", .type_ref, null);

    const count = cg.const_params.count();
    expect.* = t.expect(expect.allocator, count, expect.failures);
    try expect.toBe(@as(u32, 4));
}

fn testArrayExample() !void {
    try t.it("should create fixed-size array", testArrayCreate);
    try t.it("should get array length", testArrayLength);
    try t.it("should get/set array elements", testArrayGetSet);
    try t.it("should handle bounds checking", testArrayBounds);
}

fn testArrayCreate(expect: *testing.ModernTest.Expect) !void {
    const Array5 = Examples.ArrayExample.create(i32, 5);
    var arr = Array5.init();

    const len = arr.len();
    expect.* = t.expect(expect.allocator, len, expect.failures);
    try expect.toBe(@as(usize, 5));
}

fn testArrayLength(expect: *testing.ModernTest.Expect) !void {
    const Array10 = Examples.ArrayExample.create(u32, 10);
    var arr = Array10.init();

    const len = arr.len();
    expect.* = t.expect(expect.allocator, len, expect.failures);
    try expect.toBe(@as(usize, 10));
}

fn testArrayGetSet(expect: *testing.ModernTest.Expect) !void {
    const Array3 = Examples.ArrayExample.create(i32, 3);
    var arr = Array3.init();

    try arr.set(0, 10);
    try arr.set(1, 20);
    try arr.set(2, 30);

    const val0 = arr.get(0);
    const val1 = arr.get(1);
    const val2 = arr.get(2);

    expect.* = t.expect(expect.allocator, val0.?, expect.failures);
    try expect.toBe(10);

    expect.* = t.expect(expect.allocator, val1.?, expect.failures);
    try expect.toBe(20);

    expect.* = t.expect(expect.allocator, val2.?, expect.failures);
    try expect.toBe(30);
}

fn testArrayBounds(expect: *testing.ModernTest.Expect) !void {
    const Array3 = Examples.ArrayExample.create(i32, 3);
    var arr = Array3.init();

    const result = arr.set(5, 100);

    expect.* = t.expect(expect.allocator, result, expect.failures);
    try expect.toEqual(error.IndexOutOfBounds);
}

fn testVectorExample() !void {
    try t.it("should create vector with dimensions", testVectorCreate);
    try t.it("should compute dot product", testVectorDot);
    try t.it("should compute magnitude", testVectorMagnitude);
}

fn testVectorCreate(expect: *testing.ModernTest.Expect) !void {
    const Vec3 = Examples.VectorExample.create(i32, 3);
    const vec = Vec3.init([_]i32{ 1, 2, 3 });

    const val = vec.components[0];
    expect.* = t.expect(expect.allocator, val, expect.failures);
    try expect.toBe(1);
}

fn testVectorDot(expect: *testing.ModernTest.Expect) !void {
    const Vec3 = Examples.VectorExample.create(i32, 3);
    const v1 = Vec3.init([_]i32{ 1, 2, 3 });
    const v2 = Vec3.init([_]i32{ 4, 5, 6 });

    const dot = v1.dot(&v2);
    // 1*4 + 2*5 + 3*6 = 4 + 10 + 18 = 32
    expect.* = t.expect(expect.allocator, dot, expect.failures);
    try expect.toBe(32);
}

fn testVectorMagnitude(expect: *testing.ModernTest.Expect) !void {
    const Vec3 = Examples.VectorExample.create(i32, 3);
    const v = Vec3.init([_]i32{ 3, 4, 0 });

    const mag = v.magnitude();
    // sqrt(3^2 + 4^2 + 0^2) = sqrt(9 + 16) = sqrt(25) = 5
    expect.* = t.expect(expect.allocator, mag, expect.failures);
    try expect.toBeCloseTo(5.0, 1);
}

fn testMatrixExample() !void {
    try t.it("should create matrix with dimensions", testMatrixCreate);
    try t.it("should get matrix dimensions", testMatrixDimensions);
    try t.it("should get/set matrix elements", testMatrixGetSet);
}

fn testMatrixCreate(expect: *testing.ModernTest.Expect) !void {
    const Matrix2x3 = Examples.MatrixExample.create(i32, 2, 3);
    var mat = Matrix2x3.init();

    const rows = mat.rows();
    const cols = mat.cols();

    expect.* = t.expect(expect.allocator, rows, expect.failures);
    try expect.toBe(@as(usize, 2));

    expect.* = t.expect(expect.allocator, cols, expect.failures);
    try expect.toBe(@as(usize, 3));
}

fn testMatrixDimensions(expect: *testing.ModernTest.Expect) !void {
    const Matrix4x5 = Examples.MatrixExample.create(f32, 4, 5);
    var mat = Matrix4x5.init();

    const rows = mat.rows();
    const cols = mat.cols();

    expect.* = t.expect(expect.allocator, rows, expect.failures);
    try expect.toBe(@as(usize, 4));

    expect.* = t.expect(expect.allocator, cols, expect.failures);
    try expect.toBe(@as(usize, 5));
}

fn testMatrixGetSet(expect: *testing.ModernTest.Expect) !void {
    const Matrix2x2 = Examples.MatrixExample.create(i32, 2, 2);
    var mat = Matrix2x2.init();

    try mat.set(0, 0, 1);
    try mat.set(0, 1, 2);
    try mat.set(1, 0, 3);
    try mat.set(1, 1, 4);

    const val00 = try mat.get(0, 0);
    const val01 = try mat.get(0, 1);
    const val10 = try mat.get(1, 0);
    const val11 = try mat.get(1, 1);

    expect.* = t.expect(expect.allocator, val00, expect.failures);
    try expect.toBe(1);

    expect.* = t.expect(expect.allocator, val01, expect.failures);
    try expect.toBe(2);

    expect.* = t.expect(expect.allocator, val10, expect.failures);
    try expect.toBe(3);

    expect.* = t.expect(expect.allocator, val11, expect.failures);
    try expect.toBe(4);
}

fn testBoundedExample() !void {
    try t.it("should create bounded integer", testBoundedCreate);
    try t.it("should enforce minimum bound", testBoundedMin);
    try t.it("should enforce maximum bound", testBoundedMax);
    try t.it("should get min/max values", testBoundedMinMax);
}

fn testBoundedCreate(expect: *testing.ModernTest.Expect) !void {
    const Percent = Examples.BoundedExample.create(i32, 0, 100);
    const val = try Percent.init(50);

    const result = val.get();
    expect.* = t.expect(expect.allocator, result, expect.failures);
    try expect.toBe(50);
}

fn testBoundedMin(expect: *testing.ModernTest.Expect) !void {
    const Percent = Examples.BoundedExample.create(i32, 0, 100);
    const result = Percent.init(-1);

    expect.* = t.expect(expect.allocator, result, expect.failures);
    try expect.toEqual(error.OutOfBounds);
}

fn testBoundedMax(expect: *testing.ModernTest.Expect) !void {
    const Percent = Examples.BoundedExample.create(i32, 0, 100);
    const result = Percent.init(101);

    expect.* = t.expect(expect.allocator, result, expect.failures);
    try expect.toEqual(error.OutOfBounds);
}

fn testBoundedMinMax(expect: *testing.ModernTest.Expect) !void {
    const Bounded10to20 = Examples.BoundedExample.create(i32, 10, 20);

    const min = Bounded10to20.min();
    const max = Bounded10to20.max();

    expect.* = t.expect(expect.allocator, min, expect.failures);
    try expect.toBe(10);

    expect.* = t.expect(expect.allocator, max, expect.failures);
    try expect.toBe(20);
}

fn testConstraints() !void {
    try t.it("should validate range constraint", testRangeConstraint);
    try t.it("should validate power of two constraint", testPowerOfTwoConstraint);
}

fn testRangeConstraint(expect: *testing.ModernTest.Expect) !void {
    const Range = Constraints.RangeConstraint(0, 100);

    const valid = Range.validate(50);
    const invalid_low = Range.validate(-1);
    const invalid_high = Range.validate(101);

    expect.* = t.expect(expect.allocator, valid, expect.failures);
    try expect.toBe(true);

    expect.* = t.expect(expect.allocator, invalid_low, expect.failures);
    try expect.toBe(false);

    expect.* = t.expect(expect.allocator, invalid_high, expect.failures);
    try expect.toBe(false);
}

fn testPowerOfTwoConstraint(expect: *testing.ModernTest.Expect) !void {
    const PowerOfTwo = Constraints.PowerOfTwoConstraint();

    const valid1 = PowerOfTwo.validate(1);
    const valid2 = PowerOfTwo.validate(2);
    const valid4 = PowerOfTwo.validate(4);
    const valid8 = PowerOfTwo.validate(8);
    const valid16 = PowerOfTwo.validate(16);
    const invalid3 = PowerOfTwo.validate(3);
    const invalid5 = PowerOfTwo.validate(5);
    const invalid0 = PowerOfTwo.validate(0);

    expect.* = t.expect(expect.allocator, valid1, expect.failures);
    try expect.toBe(true);

    expect.* = t.expect(expect.allocator, valid2, expect.failures);
    try expect.toBe(true);

    expect.* = t.expect(expect.allocator, valid4, expect.failures);
    try expect.toBe(true);

    expect.* = t.expect(expect.allocator, valid8, expect.failures);
    try expect.toBe(true);

    expect.* = t.expect(expect.allocator, valid16, expect.failures);
    try expect.toBe(true);

    expect.* = t.expect(expect.allocator, invalid3, expect.failures);
    try expect.toBe(false);

    expect.* = t.expect(expect.allocator, invalid5, expect.failures);
    try expect.toBe(false);

    expect.* = t.expect(expect.allocator, invalid0, expect.failures);
    try expect.toBe(false);
}

fn testInstantiation() !void {
    try t.it("should instantiate with const args", testInstantiateBasic);
    try t.it("should reuse existing instantiation", testInstantiateReuse);
    try t.it("should generate mangled names", testMangledNames);
}

fn testInstantiateBasic(expect: *testing.ModernTest.Expect) !void {
    var cg = ConstGenerics.init(expect.allocator);
    defer cg.deinit();

    const args = [_]ConstGenerics.ConstParam.Value{
        .{ .integer = 5 },
    };

    const name = try cg.instantiate("Array", &args);

    const contains = std.mem.indexOf(u8, name, "Array_5");
    expect.* = t.expect(expect.allocator, contains != null, expect.failures);
    try expect.toBe(true);
}

fn testInstantiateReuse(expect: *testing.ModernTest.Expect) !void {
    var cg = ConstGenerics.init(expect.allocator);
    defer cg.deinit();

    const args = [_]ConstGenerics.ConstParam.Value{
        .{ .integer = 10 },
    };

    const name1 = try cg.instantiate("Vector", &args);
    const name2 = try cg.instantiate("Vector", &args);

    const equal = std.mem.eql(u8, name1, name2);
    expect.* = t.expect(expect.allocator, equal, expect.failures);
    try expect.toBe(true);
}

fn testMangledNames(expect: *testing.ModernTest.Expect) !void {
    var cg = ConstGenerics.init(expect.allocator);
    defer cg.deinit();

    const args = [_]ConstGenerics.ConstParam.Value{
        .{ .integer = 2 },
        .{ .integer = 3 },
    };

    const name = try cg.instantiate("Matrix", &args);

    const contains = std.mem.indexOf(u8, name, "Matrix_2_3");
    expect.* = t.expect(expect.allocator, contains != null, expect.failures);
    try expect.toBe(true);
}
