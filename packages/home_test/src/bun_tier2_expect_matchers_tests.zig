const std = @import("std");
const bun = @import("bun");

const to_be_true = @import("bun/expect/toBeTrue.zig");
const to_be_false = @import("bun/expect/toBeFalse.zig");
const to_be_defined = @import("bun/expect/toBeDefined.zig");
const to_be_undefined = @import("bun/expect/toBeUndefined.zig");
const to_be_null = @import("bun/expect/toBeNull.zig");

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
