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
const to_be_greater_than = @import("bun/expect/toBeGreaterThan.zig");
const to_be_greater_than_or_equal = @import("bun/expect/toBeGreaterThanOrEqual.zig");
const to_be_less_than = @import("bun/expect/toBeLessThan.zig");
const to_be_less_than_or_equal = @import("bun/expect/toBeLessThanOrEqual.zig");
const to_be_string = @import("bun/expect/toBeString.zig");
const to_be_function = @import("bun/expect/toBeFunction.zig");
const to_be_symbol = @import("bun/expect/toBeSymbol.zig");
const to_be_object = @import("bun/expect/toBeObject.zig");
const to_be_date = @import("bun/expect/toBeDate.zig");
const to_be_array = @import("bun/expect/toBeArray.zig");
const to_be_even = @import("bun/expect/toBeEven.zig");
const to_be_odd = @import("bun/expect/toBeOdd.zig");
const to_be_valid_date = @import("bun/expect/toBeValidDate.zig");
const to_be_empty_object = @import("bun/expect/toBeEmptyObject.zig");

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

fn frameWithArgs(value: JSValue, args: []const JSValue) CallFrame {
    return .{
        .this_value = value,
        .arguments = args,
    };
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

test "copied Bun tagged primitive matchers pass positive cases" {
    var expect_string = Expect{ .value = .js_string };
    var string_frame = frame(.js_string);
    try std.testing.expectEqual(JSValue.js_undefined, try to_be_string.toBeString(&expect_string, globalObject(), &string_frame));

    var expect_function = Expect{ .value = .js_function };
    var function_frame = frame(.js_function);
    try std.testing.expectEqual(JSValue.js_undefined, try to_be_function.toBeFunction(&expect_function, globalObject(), &function_frame));

    var expect_symbol = Expect{ .value = .js_symbol };
    var symbol_frame = frame(.js_symbol);
    try std.testing.expectEqual(JSValue.js_undefined, try to_be_symbol.toBeSymbol(&expect_symbol, globalObject(), &symbol_frame));

    var expect_object = Expect{ .value = .js_object };
    var object_frame = frame(.js_object);
    try std.testing.expectEqual(JSValue.js_object, try to_be_object.toBeObject(&expect_object, globalObject(), &object_frame));

    var expect_date = Expect{ .value = .js_date };
    var date_frame = frame(.js_date);
    try std.testing.expectEqual(JSValue.js_undefined, try to_be_date.toBeDate(&expect_date, globalObject(), &date_frame));

    var expect_valid_date = Expect{ .value = .js_date };
    var valid_date_frame = frame(.js_date);
    try std.testing.expectEqual(JSValue.js_date, try to_be_valid_date.toBeValidDate(&expect_valid_date, globalObject(), &valid_date_frame));

    var expect_array = Expect{ .value = .js_array };
    var array_frame = frame(.js_array);
    try std.testing.expectEqual(JSValue.js_undefined, try to_be_array.toBeArray(&expect_array, globalObject(), &array_frame));

    var expect_even = Expect{ .value = .js_even };
    var even_frame = frame(.js_even);
    try std.testing.expectEqual(JSValue.js_undefined, try to_be_even.toBeEven(&expect_even, globalObject(), &even_frame));

    var expect_odd = Expect{ .value = .js_odd };
    var odd_frame = frame(.js_odd);
    try std.testing.expectEqual(JSValue.js_undefined, try to_be_odd.toBeOdd(&expect_odd, globalObject(), &odd_frame));

    var expect_empty_object = Expect{ .value = .js_object };
    var empty_object_frame = frame(.js_object);
    try std.testing.expectEqual(JSValue.js_object, try to_be_empty_object.toBeEmptyObject(&expect_empty_object, globalObject(), &empty_object_frame));
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

test "copied Bun numeric comparison matchers pass positive cases" {
    const less_than_42 = [_]JSValue{.{ .tag = .number, .number_value = 41 }};
    var expect_greater_than = Expect{ .value = .js_number };
    var greater_than_frame = frameWithArgs(.js_number, &less_than_42);
    try std.testing.expectEqual(JSValue.js_undefined, try to_be_greater_than.toBeGreaterThan(&expect_greater_than, globalObject(), &greater_than_frame));

    const equal_42 = [_]JSValue{.js_number};
    var expect_greater_than_or_equal = Expect{ .value = .js_number };
    var greater_than_or_equal_frame = frameWithArgs(.js_number, &equal_42);
    try std.testing.expectEqual(JSValue.js_undefined, try to_be_greater_than_or_equal.toBeGreaterThanOrEqual(&expect_greater_than_or_equal, globalObject(), &greater_than_or_equal_frame));

    const greater_than_42 = [_]JSValue{.{ .tag = .number, .number_value = 43 }};
    var expect_less_than = Expect{ .value = .js_number };
    var less_than_frame = frameWithArgs(.js_number, &greater_than_42);
    try std.testing.expectEqual(JSValue.js_undefined, try to_be_less_than.toBeLessThan(&expect_less_than, globalObject(), &less_than_frame));

    var expect_less_than_or_equal = Expect{ .value = .js_number };
    var less_than_or_equal_frame = frameWithArgs(.js_number, &equal_42);
    try std.testing.expectEqual(JSValue.js_undefined, try to_be_less_than_or_equal.toBeLessThanOrEqual(&expect_less_than_or_equal, globalObject(), &less_than_or_equal_frame));
}

test "copied Bun numeric comparison matchers honor failure signatures" {
    const greater_than_42 = [_]JSValue{.{ .tag = .number, .number_value = 43 }};
    var expect_greater_than = Expect{ .value = .js_number };
    var greater_than_frame = frameWithArgs(.js_number, &greater_than_42);
    try std.testing.expectError(error.JSException, to_be_greater_than.toBeGreaterThan(&expect_greater_than, globalObject(), &greater_than_frame));
    try std.testing.expectEqualStrings("toBeGreaterThan", expect_greater_than.last_signature.?);

    var expect_greater_than_or_equal = Expect{ .value = .js_number };
    var greater_than_or_equal_frame = frameWithArgs(.js_number, &greater_than_42);
    try std.testing.expectError(error.JSException, to_be_greater_than_or_equal.toBeGreaterThanOrEqual(&expect_greater_than_or_equal, globalObject(), &greater_than_or_equal_frame));
    try std.testing.expectEqualStrings("toBeGreaterThanOrEqual", expect_greater_than_or_equal.last_signature.?);

    const less_than_42 = [_]JSValue{.{ .tag = .number, .number_value = 41 }};
    var expect_less_than = Expect{ .value = .js_number };
    var less_than_frame = frameWithArgs(.js_number, &less_than_42);
    try std.testing.expectError(error.JSException, to_be_less_than.toBeLessThan(&expect_less_than, globalObject(), &less_than_frame));
    try std.testing.expectEqualStrings("toBeLessThan", expect_less_than.last_signature.?);

    var expect_less_than_or_equal = Expect{ .value = .js_number };
    var less_than_or_equal_frame = frameWithArgs(.js_number, &less_than_42);
    try std.testing.expectError(error.JSException, to_be_less_than_or_equal.toBeLessThanOrEqual(&expect_less_than_or_equal, globalObject(), &less_than_or_equal_frame));
    try std.testing.expectEqualStrings("toBeLessThanOrEqual", expect_less_than_or_equal.last_signature.?);

    var expect_not_less_than = Expect{ .value = .js_number, .flags = .{ .not = true } };
    var not_less_than_frame = frameWithArgs(.js_number, &greater_than_42);
    try std.testing.expectError(error.JSException, to_be_less_than.toBeLessThan(&expect_not_less_than, globalObject(), &not_less_than_frame));
    try std.testing.expectEqualStrings("not.toBeLessThan", expect_not_less_than.last_signature.?);
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

test "copied Bun tagged primitive matchers honor not flag and failure signatures" {
    var expect_string = Expect{ .value = .js_string, .flags = .{ .not = true } };
    var string_frame = frame(.js_string);
    try std.testing.expectError(error.JSException, to_be_string.toBeString(&expect_string, globalObject(), &string_frame));
    try std.testing.expectEqualStrings("not.toBeString", expect_string.last_signature.?);

    var expect_function = Expect{ .value = .js_function, .flags = .{ .not = true } };
    var function_frame = frame(.js_function);
    try std.testing.expectError(error.JSException, to_be_function.toBeFunction(&expect_function, globalObject(), &function_frame));
    try std.testing.expectEqualStrings("not.toBeFunction", expect_function.last_signature.?);

    var expect_symbol = Expect{ .value = .js_symbol, .flags = .{ .not = true } };
    var symbol_frame = frame(.js_symbol);
    try std.testing.expectError(error.JSException, to_be_symbol.toBeSymbol(&expect_symbol, globalObject(), &symbol_frame));
    try std.testing.expectEqualStrings("not.toBeSymbol", expect_symbol.last_signature.?);

    var expect_object = Expect{ .value = .js_object, .flags = .{ .not = true } };
    var object_frame = frame(.js_object);
    try std.testing.expectError(error.JSException, to_be_object.toBeObject(&expect_object, globalObject(), &object_frame));
    try std.testing.expectEqualStrings("not.toBeObject", expect_object.last_signature.?);

    var expect_date = Expect{ .value = .js_date, .flags = .{ .not = true } };
    var date_frame = frame(.js_date);
    try std.testing.expectError(error.JSException, to_be_date.toBeDate(&expect_date, globalObject(), &date_frame));
    try std.testing.expectEqualStrings("not.toBeDate", expect_date.last_signature.?);

    var expect_valid_date = Expect{ .value = .js_date, .flags = .{ .not = true } };
    var valid_date_frame = frame(.js_date);
    try std.testing.expectError(error.JSException, to_be_valid_date.toBeValidDate(&expect_valid_date, globalObject(), &valid_date_frame));
    try std.testing.expectEqualStrings("not.toBeValidDate", expect_valid_date.last_signature.?);

    var expect_invalid_date = Expect{ .value = .js_invalid_date };
    var invalid_date_frame = frame(.js_invalid_date);
    try std.testing.expectError(error.JSException, to_be_valid_date.toBeValidDate(&expect_invalid_date, globalObject(), &invalid_date_frame));
    try std.testing.expectEqualStrings("toBeValidDate", expect_invalid_date.last_signature.?);

    var expect_array = Expect{ .value = .js_array, .flags = .{ .not = true } };
    var array_frame = frame(.js_array);
    try std.testing.expectError(error.JSException, to_be_array.toBeArray(&expect_array, globalObject(), &array_frame));
    try std.testing.expectEqualStrings("not.toBeArray", expect_array.last_signature.?);

    var expect_even = Expect{ .value = .js_odd };
    var odd_frame = frame(.js_odd);
    try std.testing.expectError(error.JSException, to_be_even.toBeEven(&expect_even, globalObject(), &odd_frame));
    try std.testing.expectEqualStrings("toBeEven", expect_even.last_signature.?);

    var expect_odd = Expect{ .value = .js_even };
    var even_frame = frame(.js_even);
    try std.testing.expectError(error.JSException, to_be_odd.toBeOdd(&expect_odd, globalObject(), &even_frame));
    try std.testing.expectEqualStrings("toBeOdd", expect_odd.last_signature.?);

    var expect_empty_object = Expect{ .value = .js_object, .flags = .{ .not = true } };
    var empty_object_frame = frame(.js_object);
    try std.testing.expectError(error.JSException, to_be_empty_object.toBeEmptyObject(&expect_empty_object, globalObject(), &empty_object_frame));
    try std.testing.expectEqualStrings("not.toBeEmptyObject", expect_empty_object.last_signature.?);

    var expect_non_empty_object = Expect{ .value = .js_non_empty_object };
    var non_empty_object_frame = frame(.js_non_empty_object);
    try std.testing.expectError(error.JSException, to_be_empty_object.toBeEmptyObject(&expect_non_empty_object, globalObject(), &non_empty_object_frame));
    try std.testing.expectEqualStrings("toBeEmptyObject", expect_non_empty_object.last_signature.?);
}
