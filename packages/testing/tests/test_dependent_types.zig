const std = @import("std");
const testing = @import("../src/modern_test.zig");
const t = testing.t;
const DT = @import("../../types/src/dependent_types.zig");

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
    try t.describe("Dependent Types - Vec", testVec);
    try t.describe("Dependent Types - Bounded", testBounded);
    try t.describe("Dependent Types - Matrix", testMatrix);
    try t.describe("Dependent Types - NonEmptyList", testNonEmptyList);
    try t.describe("Dependent Types - SortedList", testSortedList);
    try t.describe("Dependent Types - Refinement", testRefinement);
    try t.describe("Dependent Types - Proofs", testProofs);

    try runner.run();
}

fn testVec() !void {
    try t.it("should create fixed-length vector", testVecCreate);
    try t.it("should preserve length through operations", testVecLength);
    try t.it("should append element", testVecAppend);
    try t.it("should take elements", testVecTake);
    try t.it("should concatenate vectors", testVecConcat);
    try t.it("should map over vector", testVecMap);
    try t.it("should zip vectors", testVecZip);
}

fn testVecCreate(expect: *testing.ModernTest.Expect) !void {
    const Vec3 = DT.Vec(i32, 3);
    const vec = Vec3.fromArray([_]i32{ 1, 2, 3 });

    const len = vec.len();
    expect.* = t.expect(expect.allocator, len, expect.failures);
    try expect.toBe(@as(usize, 3));
}

fn testVecLength(expect: *testing.ModernTest.Expect) !void {
    const Vec5 = DT.Vec(i32, 5);
    var vec = Vec5.init();

    const len = vec.len();
    expect.* = t.expect(expect.allocator, len, expect.failures);
    try expect.toBe(@as(usize, 5));
}

fn testVecAppend(expect: *testing.ModernTest.Expect) !void {
    const Vec2 = DT.Vec(i32, 2);
    const vec = Vec2.fromArray([_]i32{ 1, 2 });

    const vec3 = vec.append(3);
    const len = vec3.len();

    expect.* = t.expect(expect.allocator, len, expect.failures);
    try expect.toBe(@as(usize, 3));

    const val0 = try vec3.get(0);
    const val1 = try vec3.get(1);
    const val2 = try vec3.get(2);

    expect.* = t.expect(expect.allocator, val0, expect.failures);
    try expect.toBe(1);

    expect.* = t.expect(expect.allocator, val1, expect.failures);
    try expect.toBe(2);

    expect.* = t.expect(expect.allocator, val2, expect.failures);
    try expect.toBe(3);
}

fn testVecTake(expect: *testing.ModernTest.Expect) !void {
    const Vec5 = DT.Vec(i32, 5);
    const vec = Vec5.fromArray([_]i32{ 1, 2, 3, 4, 5 });

    const vec3 = vec.take(3);
    const len = vec3.len();

    expect.* = t.expect(expect.allocator, len, expect.failures);
    try expect.toBe(@as(usize, 3));

    const val0 = try vec3.get(0);
    const val1 = try vec3.get(1);
    const val2 = try vec3.get(2);

    expect.* = t.expect(expect.allocator, val0, expect.failures);
    try expect.toBe(1);

    expect.* = t.expect(expect.allocator, val1, expect.failures);
    try expect.toBe(2);

    expect.* = t.expect(expect.allocator, val2, expect.failures);
    try expect.toBe(3);
}

fn testVecConcat(expect: *testing.ModernTest.Expect) !void {
    const Vec2 = DT.Vec(i32, 2);
    const Vec3 = DT.Vec(i32, 3);

    const vec1 = Vec2.fromArray([_]i32{ 1, 2 });
    const vec2 = Vec3.fromArray([_]i32{ 3, 4, 5 });

    const vec5 = vec1.concat(3, vec2);
    const len = vec5.len();

    expect.* = t.expect(expect.allocator, len, expect.failures);
    try expect.toBe(@as(usize, 5));

    const val4 = try vec5.get(4);
    expect.* = t.expect(expect.allocator, val4, expect.failures);
    try expect.toBe(5);
}

fn testVecMap(expect: *testing.ModernTest.Expect) !void {
    const Vec3 = DT.Vec(i32, 3);
    const vec = Vec3.fromArray([_]i32{ 1, 2, 3 });

    const double = struct {
        fn f(x: i32) i32 {
            return x * 2;
        }
    }.f;

    const mapped = vec.map(i32, double);

    const val0 = try mapped.get(0);
    const val1 = try mapped.get(1);
    const val2 = try mapped.get(2);

    expect.* = t.expect(expect.allocator, val0, expect.failures);
    try expect.toBe(2);

    expect.* = t.expect(expect.allocator, val1, expect.failures);
    try expect.toBe(4);

    expect.* = t.expect(expect.allocator, val2, expect.failures);
    try expect.toBe(6);
}

fn testVecZip(expect: *testing.ModernTest.Expect) !void {
    const Vec3 = DT.Vec(i32, 3);
    const vec1 = Vec3.fromArray([_]i32{ 1, 2, 3 });
    const vec2 = Vec3.fromArray([_]i32{ 4, 5, 6 });

    const zipped = vec1.zip(i32, vec2);

    const pair0 = try zipped.get(0);
    const pair1 = try zipped.get(1);
    const pair2 = try zipped.get(2);

    expect.* = t.expect(expect.allocator, pair0[0], expect.failures);
    try expect.toBe(1);

    expect.* = t.expect(expect.allocator, pair0[1], expect.failures);
    try expect.toBe(4);

    expect.* = t.expect(expect.allocator, pair1[0], expect.failures);
    try expect.toBe(2);

    expect.* = t.expect(expect.allocator, pair1[1], expect.failures);
    try expect.toBe(5);

    expect.* = t.expect(expect.allocator, pair2[0], expect.failures);
    try expect.toBe(3);

    expect.* = t.expect(expect.allocator, pair2[1], expect.failures);
    try expect.toBe(6);
}

fn testBounded() !void {
    try t.it("should create bounded value in range", testBoundedCreate);
    try t.it("should reject value below min", testBoundedMin);
    try t.it("should reject value above max", testBoundedMax);
    try t.it("should add bounded values", testBoundedAdd);
    try t.it("should subtract bounded values", testBoundedSub);
}

fn testBoundedCreate(expect: *testing.ModernTest.Expect) !void {
    const Percent = DT.Bounded(0, 100);
    const val = try Percent.init(50);

    const result = val.get();
    expect.* = t.expect(expect.allocator, result, expect.failures);
    try expect.toBe(50);
}

fn testBoundedMin(expect: *testing.ModernTest.Expect) !void {
    const Percent = DT.Bounded(0, 100);
    const result = Percent.init(-1);

    expect.* = t.expect(expect.allocator, result, expect.failures);
    try expect.toEqual(error.OutOfBounds);
}

fn testBoundedMax(expect: *testing.ModernTest.Expect) !void {
    const Percent = DT.Bounded(0, 100);
    const result = Percent.init(101);

    expect.* = t.expect(expect.allocator, result, expect.failures);
    try expect.toEqual(error.OutOfBounds);
}

fn testBoundedAdd(expect: *testing.ModernTest.Expect) !void {
    const Small = DT.Bounded(0, 10);
    const a = try Small.init(3);
    const b = try Small.init(4);

    const sum = try a.add(b);
    const result = sum.get();

    expect.* = t.expect(expect.allocator, result, expect.failures);
    try expect.toBe(7);
}

fn testBoundedSub(expect: *testing.ModernTest.Expect) !void {
    const Small = DT.Bounded(0, 10);
    const a = try Small.init(7);
    const b = try Small.init(3);

    const diff = try a.sub(b);
    const result = diff.get();

    expect.* = t.expect(expect.allocator, result, expect.failures);
    try expect.toBe(4);
}

fn testMatrix() !void {
    try t.it("should create matrix with dimensions", testMatrixCreate);
    try t.it("should get/set matrix elements", testMatrixGetSet);
    try t.it("should multiply matrices", testMatrixMultiply);
    try t.it("should transpose matrix", testMatrixTranspose);
}

fn testMatrixCreate(expect: *testing.ModernTest.Expect) !void {
    const Mat2x3 = DT.Matrix(i32, 2, 3);
    const mat = Mat2x3.init();

    const rows = mat.rows_count();
    const cols = mat.cols_count();

    expect.* = t.expect(expect.allocator, rows, expect.failures);
    try expect.toBe(@as(usize, 2));

    expect.* = t.expect(expect.allocator, cols, expect.failures);
    try expect.toBe(@as(usize, 3));
}

fn testMatrixGetSet(expect: *testing.ModernTest.Expect) !void {
    const Mat2x2 = DT.Matrix(i32, 2, 2);
    var mat = Mat2x2.init();

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

fn testMatrixMultiply(expect: *testing.ModernTest.Expect) !void {
    const Mat2x2 = DT.Matrix(i32, 2, 2);
    var a = Mat2x2.init();
    var b = Mat2x2.init();

    // A = [1 2]    B = [5 6]
    //     [3 4]        [7 8]
    try a.set(0, 0, 1);
    try a.set(0, 1, 2);
    try a.set(1, 0, 3);
    try a.set(1, 1, 4);

    try b.set(0, 0, 5);
    try b.set(0, 1, 6);
    try b.set(1, 0, 7);
    try b.set(1, 1, 8);

    const c = a.multiply(2, b);

    // C = [19 22]
    //     [43 50]
    const val00 = try c.get(0, 0);
    const val01 = try c.get(0, 1);
    const val10 = try c.get(1, 0);
    const val11 = try c.get(1, 1);

    expect.* = t.expect(expect.allocator, val00, expect.failures);
    try expect.toBe(19);

    expect.* = t.expect(expect.allocator, val01, expect.failures);
    try expect.toBe(22);

    expect.* = t.expect(expect.allocator, val10, expect.failures);
    try expect.toBe(43);

    expect.* = t.expect(expect.allocator, val11, expect.failures);
    try expect.toBe(50);
}

fn testMatrixTranspose(expect: *testing.ModernTest.Expect) !void {
    const Mat2x3 = DT.Matrix(i32, 2, 3);
    var mat = Mat2x3.init();

    // [1 2 3]
    // [4 5 6]
    try mat.set(0, 0, 1);
    try mat.set(0, 1, 2);
    try mat.set(0, 2, 3);
    try mat.set(1, 0, 4);
    try mat.set(1, 1, 5);
    try mat.set(1, 2, 6);

    const transposed = mat.transpose();

    // [1 4]
    // [2 5]
    // [3 6]
    const val00 = try transposed.get(0, 0);
    const val01 = try transposed.get(0, 1);
    const val10 = try transposed.get(1, 0);
    const val11 = try transposed.get(1, 1);
    const val20 = try transposed.get(2, 0);
    const val21 = try transposed.get(2, 1);

    expect.* = t.expect(expect.allocator, val00, expect.failures);
    try expect.toBe(1);

    expect.* = t.expect(expect.allocator, val01, expect.failures);
    try expect.toBe(4);

    expect.* = t.expect(expect.allocator, val10, expect.failures);
    try expect.toBe(2);

    expect.* = t.expect(expect.allocator, val11, expect.failures);
    try expect.toBe(5);

    expect.* = t.expect(expect.allocator, val20, expect.failures);
    try expect.toBe(3);

    expect.* = t.expect(expect.allocator, val21, expect.failures);
    try expect.toBe(6);
}

fn testNonEmptyList() !void {
    try t.it("should create non-empty list", testNonEmptyCreate);
    try t.it("should get first element", testNonEmptyFirst);
    try t.it("should append elements", testNonEmptyAppend);
    try t.it("should map over list", testNonEmptyMap);
}

fn testNonEmptyCreate(expect: *testing.ModernTest.Expect) !void {
    const NEList = DT.NonEmptyList(i32);
    var list = NEList.init(expect.allocator, 42);
    defer list.deinit();

    const len = list.length();
    expect.* = t.expect(expect.allocator, len, expect.failures);
    try expect.toBe(@as(usize, 1));
}

fn testNonEmptyFirst(expect: *testing.ModernTest.Expect) !void {
    const NEList = DT.NonEmptyList(i32);
    var list = NEList.init(expect.allocator, 100);
    defer list.deinit();

    const first = list.first();
    expect.* = t.expect(expect.allocator, first, expect.failures);
    try expect.toBe(100);
}

fn testNonEmptyAppend(expect: *testing.ModernTest.Expect) !void {
    const NEList = DT.NonEmptyList(i32);
    var list = NEList.init(expect.allocator, 1);
    defer list.deinit();

    try list.append(2);
    try list.append(3);

    const len = list.length();
    expect.* = t.expect(expect.allocator, len, expect.failures);
    try expect.toBe(@as(usize, 3));

    const first = list.first();
    expect.* = t.expect(expect.allocator, first, expect.failures);
    try expect.toBe(1);
}

fn testNonEmptyMap(expect: *testing.ModernTest.Expect) !void {
    const NEList = DT.NonEmptyList(i32);
    var list = NEList.init(expect.allocator, 1);
    defer list.deinit();

    try list.append(2);
    try list.append(3);

    const double = struct {
        fn f(x: i32) i32 {
            return x * 2;
        }
    }.f;

    var mapped = try list.map(i32, double);
    defer mapped.deinit();

    const first = mapped.first();
    expect.* = t.expect(expect.allocator, first, expect.failures);
    try expect.toBe(2);

    const len = mapped.length();
    expect.* = t.expect(expect.allocator, len, expect.failures);
    try expect.toBe(@as(usize, 3));
}

fn testSortedList() !void {
    try t.it("should create empty sorted list", testSortedCreate);
    try t.it("should insert in sorted order", testSortedInsert);
    try t.it("should binary search", testSortedSearch);
}

fn testSortedCreate(expect: *testing.ModernTest.Expect) !void {
    const lessThan = struct {
        fn f(a: i32, b: i32) bool {
            return a < b;
        }
    }.f;

    const Sorted = DT.SortedList(i32, lessThan);
    var list = Sorted.init(expect.allocator);
    defer list.deinit();

    const len = list.length();
    expect.* = t.expect(expect.allocator, len, expect.failures);
    try expect.toBe(@as(usize, 0));
}

fn testSortedInsert(expect: *testing.ModernTest.Expect) !void {
    const lessThan = struct {
        fn f(a: i32, b: i32) bool {
            return a < b;
        }
    }.f;

    const Sorted = DT.SortedList(i32, lessThan);
    var list = Sorted.init(expect.allocator);
    defer list.deinit();

    try list.insert(5);
    try list.insert(2);
    try list.insert(8);
    try list.insert(1);
    try list.insert(9);

    const len = list.length();
    expect.* = t.expect(expect.allocator, len, expect.failures);
    try expect.toBe(@as(usize, 5));

    // Should be sorted: [1, 2, 5, 8, 9]
    const val0 = try list.get(0);
    const val1 = try list.get(1);
    const val2 = try list.get(2);
    const val3 = try list.get(3);
    const val4 = try list.get(4);

    expect.* = t.expect(expect.allocator, val0, expect.failures);
    try expect.toBe(1);

    expect.* = t.expect(expect.allocator, val1, expect.failures);
    try expect.toBe(2);

    expect.* = t.expect(expect.allocator, val2, expect.failures);
    try expect.toBe(5);

    expect.* = t.expect(expect.allocator, val3, expect.failures);
    try expect.toBe(8);

    expect.* = t.expect(expect.allocator, val4, expect.failures);
    try expect.toBe(9);
}

fn testSortedSearch(expect: *testing.ModernTest.Expect) !void {
    const lessThan = struct {
        fn f(a: i32, b: i32) bool {
            return a < b;
        }
    }.f;

    const Sorted = DT.SortedList(i32, lessThan);
    var list = Sorted.init(expect.allocator);
    defer list.deinit();

    try list.insert(1);
    try list.insert(3);
    try list.insert(5);
    try list.insert(7);
    try list.insert(9);

    const idx5 = list.binarySearch(5);
    const idx7 = list.binarySearch(7);
    const idx4 = list.binarySearch(4);

    expect.* = t.expect(expect.allocator, idx5.?, expect.failures);
    try expect.toBe(@as(usize, 2));

    expect.* = t.expect(expect.allocator, idx7.?, expect.failures);
    try expect.toBe(@as(usize, 3));

    expect.* = t.expect(expect.allocator, idx4 == null, expect.failures);
    try expect.toBe(true);
}

fn testRefinement() !void {
    try t.it("should create refined value", testRefinementCreate);
    try t.it("should reject invalid value", testRefinementReject);
}

fn testRefinementCreate(expect: *testing.ModernTest.Expect) !void {
    const isPositive = struct {
        fn f(x: i32) bool {
            return x > 0;
        }
    }.f;

    const Positive = DT.Refinement(i32, isPositive);
    const val = try Positive.init(42);

    const result = val.get();
    expect.* = t.expect(expect.allocator, result, expect.failures);
    try expect.toBe(42);
}

fn testRefinementReject(expect: *testing.ModernTest.Expect) !void {
    const isPositive = struct {
        fn f(x: i32) bool {
            return x > 0;
        }
    }.f;

    const Positive = DT.Refinement(i32, isPositive);
    const result = Positive.init(-5);

    expect.* = t.expect(expect.allocator, result, expect.failures);
    try expect.toEqual(error.PredicateFailed);
}

fn testProofs() !void {
    try t.it("should prove positive value at compile time", testProofPositive);
    try t.it("should prove even value at compile time", testProofEven);
    try t.it("should prove power of two at compile time", testProofPowerOfTwo);
}

fn testProofPositive(expect: *testing.ModernTest.Expect) !void {
    const Proof42 = DT.Proof.Positive(42);
    const val = Proof42.value;

    expect.* = t.expect(expect.allocator, val, expect.failures);
    try expect.toBe(42);
}

fn testProofEven(expect: *testing.ModernTest.Expect) !void {
    const Proof10 = DT.Proof.Even(10);
    const val = Proof10.value;

    expect.* = t.expect(expect.allocator, val, expect.failures);
    try expect.toBe(10);
}

fn testProofPowerOfTwo(expect: *testing.ModernTest.Expect) !void {
    const Proof16 = DT.Proof.PowerOfTwo(16);
    const val = Proof16.value;

    expect.* = t.expect(expect.allocator, val, expect.failures);
    try expect.toBe(16);
}
