const std = @import("std");
const bun = @import("bun");

const to_be_true = @import("bun/expect/toBeTrue.zig");
const to_be_false = @import("bun/expect/toBeFalse.zig");
const to_be_defined = @import("bun/expect/toBeDefined.zig");
const to_be_undefined = @import("bun/expect/toBeUndefined.zig");
const to_be_null = @import("bun/expect/toBeNull.zig");
const to_be_truthy = @import("bun/expect/toBeTruthy.zig");
const to_be_falsy = @import("bun/expect/toBeFalsy.zig");
const to_be_boolean = @import("bun/expect/toBeBoolean.zig");
const to_be_nil = @import("bun/expect/toBeNil.zig");
const to_be_number = @import("bun/expect/toBeNumber.zig");
const to_be_integer = @import("bun/expect/toBeInteger.zig");
const to_be_nan = @import("bun/expect/toBeNaN.zig");
const to_be_finite = @import("bun/expect/toBeFinite.zig");
const to_be_positive = @import("bun/expect/toBePositive.zig");
const to_be_negative = @import("bun/expect/toBeNegative.zig");

const Expect = bun.jsc.Expect.Expect;
const JSValue = bun.jsc.JSValue;
const JSGlobalObject = bun.jsc.JSGlobalObject;
const CallFrame = bun.jsc.CallFrame;

fn globalObject() *JSGlobalObject {
    return @ptrFromInt(0x1);
}

fn frame(value: JSValue) CallFrame {
    return .{ .this_value = value };
}

test "copied Bun primitive truthiness matchers pass positive cases" {
    var expect_true = Expect{ .value = .js_true };
    var true_frame = frame(.js_true);
    try std.testing.expectEqual(JSValue.js_undefined, try to_be_true.toBeTrue(&expect_true, globalObject(), &true_frame));
    try std.testing.expectEqual(@as(usize, 1), expect_true.call_count);
    try std.testing.expectEqual(@as(usize, 1), expect_true.post_count);

    var expect_false = Expect{ .value = .js_false };
    var false_frame = frame(.js_false);
    try std.testing.expectEqual(JSValue.js_undefined, try to_be_false.toBeFalse(&expect_false, globalObject(), &false_frame));
    try std.testing.expectEqual(@as(usize, 1), expect_false.call_count);
    try std.testing.expectEqual(@as(usize, 1), expect_false.post_count);
}

test "copied Bun defined undefined and null matchers pass positive cases" {
    var expect_defined = Expect{ .value = .js_null };
    var null_frame = frame(.js_null);
    try std.testing.expectEqual(JSValue.js_undefined, try to_be_defined.toBeDefined(&expect_defined, globalObject(), &null_frame));

    var expect_undefined = Expect{ .value = .js_undefined };
    var undefined_frame = frame(.js_undefined);
    try std.testing.expectEqual(JSValue.js_undefined, try to_be_undefined.toBeUndefined(&expect_undefined, globalObject(), &undefined_frame));

    var expect_null = Expect{ .value = .js_null };
    var null_frame_again = frame(.js_null);
    try std.testing.expectEqual(JSValue.js_undefined, try to_be_null.toBeNull(&expect_null, globalObject(), &null_frame_again));
}

test "copied Bun primitive matchers honor not flag and failure signatures" {
    var expect_true = Expect{ .value = .js_true, .flags = .{ .not = true } };
    var true_frame = frame(.js_true);
    try std.testing.expectError(error.JSException, to_be_true.toBeTrue(&expect_true, globalObject(), &true_frame));
    try std.testing.expectEqualStrings("not.toBeTrue", expect_true.last_signature.?);
    try std.testing.expectEqual(@as(usize, 1), expect_true.post_count);

    var expect_null = Expect{ .value = .js_other };
    var other_frame = frame(.js_other);
    try std.testing.expectError(error.JSException, to_be_null.toBeNull(&expect_null, globalObject(), &other_frame));
    try std.testing.expectEqualStrings("toBeNull", expect_null.last_signature.?);
}

test "copied Bun truthiness and boolean matchers pass positive cases" {
    var expect_truthy = Expect{ .value = .js_true };
    var true_frame = frame(.js_true);
    try std.testing.expectEqual(JSValue.js_undefined, try to_be_truthy.toBeTruthy(&expect_truthy, globalObject(), &true_frame));

    var expect_falsy = Expect{ .value = .js_false };
    var false_frame = frame(.js_false);
    try std.testing.expectEqual(JSValue.js_undefined, try to_be_falsy.toBeFalsy(&expect_falsy, globalObject(), &false_frame));

    var expect_boolean = Expect{ .value = .js_false };
    var boolean_frame = frame(.js_false);
    try std.testing.expectEqual(JSValue.js_undefined, try to_be_boolean.toBeBoolean(&expect_boolean, globalObject(), &boolean_frame));

    var expect_nil = Expect{ .value = .js_undefined };
    var nil_frame = frame(.js_undefined);
    try std.testing.expectEqual(JSValue.js_undefined, try to_be_nil.toBeNil(&expect_nil, globalObject(), &nil_frame));

    var expect_number = Expect{ .value = .js_number };
    var number_frame = frame(.js_number);
    try std.testing.expectEqual(JSValue.js_undefined, try to_be_number.toBeNumber(&expect_number, globalObject(), &number_frame));

    var expect_integer = Expect{ .value = .js_number };
    var integer_frame = frame(.js_number);
    try std.testing.expectEqual(JSValue.js_undefined, try to_be_integer.toBeInteger(&expect_integer, globalObject(), &integer_frame));

    var expect_nan = Expect{ .value = .js_nan };
    var nan_frame = frame(.js_nan);
    try std.testing.expectEqual(JSValue.js_undefined, try to_be_nan.toBeNaN(&expect_nan, globalObject(), &nan_frame));

    var expect_finite = Expect{ .value = .js_number };
    var finite_frame = frame(.js_number);
    try std.testing.expectEqual(JSValue.js_undefined, try to_be_finite.toBeFinite(&expect_finite, globalObject(), &finite_frame));

    var expect_positive = Expect{ .value = .js_number };
    var positive_frame = frame(.js_number);
    try std.testing.expectEqual(JSValue.js_undefined, try to_be_positive.toBePositive(&expect_positive, globalObject(), &positive_frame));

    var expect_negative = Expect{ .value = .js_negative };
    var negative_frame = frame(.js_negative);
    try std.testing.expectEqual(JSValue.js_undefined, try to_be_negative.toBeNegative(&expect_negative, globalObject(), &negative_frame));
}

test "copied Bun numeric matchers honor failure signatures" {
    var expect_integer = Expect{ .value = .js_fraction };
    var fraction_frame = frame(.js_fraction);
    try std.testing.expectError(error.JSException, to_be_integer.toBeInteger(&expect_integer, globalObject(), &fraction_frame));
    try std.testing.expectEqualStrings("toBeInteger", expect_integer.last_signature.?);

    var expect_nan = Expect{ .value = .js_number };
    var number_frame = frame(.js_number);
    try std.testing.expectError(error.JSException, to_be_nan.toBeNaN(&expect_nan, globalObject(), &number_frame));
    try std.testing.expectEqualStrings("toBeNaN", expect_nan.last_signature.?);

    var expect_finite = Expect{ .value = .js_inf };
    var inf_frame = frame(.js_inf);
    try std.testing.expectError(error.JSException, to_be_finite.toBeFinite(&expect_finite, globalObject(), &inf_frame));
    try std.testing.expectEqualStrings("toBeFinite", expect_finite.last_signature.?);

    var expect_positive = Expect{ .value = .js_negative };
    var negative_frame = frame(.js_negative);
    try std.testing.expectError(error.JSException, to_be_positive.toBePositive(&expect_positive, globalObject(), &negative_frame));
    try std.testing.expectEqualStrings("toBePositive", expect_positive.last_signature.?);

    var expect_negative = Expect{ .value = .js_number };
    var positive_frame = frame(.js_number);
    try std.testing.expectError(error.JSException, to_be_negative.toBeNegative(&expect_negative, globalObject(), &positive_frame));
    try std.testing.expectEqualStrings("toBeNegative", expect_negative.last_signature.?);
}

test "copied Bun truthiness nil and number matchers honor not flag and failure signatures" {
    var expect_truthy = Expect{ .value = .js_true, .flags = .{ .not = true } };
    var true_frame = frame(.js_true);
    try std.testing.expectError(error.JSException, to_be_truthy.toBeTruthy(&expect_truthy, globalObject(), &true_frame));
    try std.testing.expectEqualStrings("not.toBeTruthy", expect_truthy.last_signature.?);

    var expect_nil = Expect{ .value = .js_null, .flags = .{ .not = true } };
    var null_frame = frame(.js_null);
    try std.testing.expectError(error.JSException, to_be_nil.toBeNil(&expect_nil, globalObject(), &null_frame));
    try std.testing.expectEqualStrings("not.toBeNil", expect_nil.last_signature.?);

    var expect_number = Expect{ .value = .js_number, .flags = .{ .not = true } };
    var number_frame = frame(.js_number);
    try std.testing.expectError(error.JSException, to_be_number.toBeNumber(&expect_number, globalObject(), &number_frame));
    try std.testing.expectEqualStrings("not.toBeNumber", expect_number.last_signature.?);

    var expect_integer = Expect{ .value = .js_number, .flags = .{ .not = true } };
    var integer_frame = frame(.js_number);
    try std.testing.expectError(error.JSException, to_be_integer.toBeInteger(&expect_integer, globalObject(), &integer_frame));
    try std.testing.expectEqualStrings("not.toBeInteger", expect_integer.last_signature.?);

    var expect_finite = Expect{ .value = .js_number, .flags = .{ .not = true } };
    var finite_frame = frame(.js_number);
    try std.testing.expectError(error.JSException, to_be_finite.toBeFinite(&expect_finite, globalObject(), &finite_frame));
    try std.testing.expectEqualStrings("not.toBeFinite", expect_finite.last_signature.?);
}
