pub fn toStrictEqual(this: *Expect, globalThis: *JSGlobalObject, callFrame: *CallFrame) home_rt.JSError!JSValue {
    defer this.postMatch(globalThis);

    const thisValue = callFrame.this();
    const _arguments = callFrame.arguments_old(1);
    const arguments: []const JSValue = _arguments.ptr[0.._arguments.len];

    if (arguments.len < 1) {
        return globalThis.throwInvalidArguments("toStrictEqual() requires 1 argument", .{});
    }

    this.incrementExpectCallCounter();

    const expected = arguments[0];
    const value: JSValue = try this.getValue(globalThis, thisValue, "toStrictEqual", "<green>expected<r>");

    const not = this.flags.not;
    var pass = try value.jestStrictDeepEquals(expected, globalThis);

    if (not) pass = !pass;
    if (pass) return .js_undefined;

    // handle failure
    const diff_formatter = DiffFormatter{ .received = value, .expected = expected, .globalThis = globalThis, .not = not };

    if (not) {
        const signature = comptime getSignature("toStrictEqual", "<green>expected<r>", true);
        return this.throw(globalThis, signature, "\n\n{f}\n", .{diff_formatter});
    }

    const signature = comptime getSignature("toStrictEqual", "<green>expected<r>", false);
    return this.throw(globalThis, signature, "\n\n{f}\n", .{diff_formatter});
}

const home_rt = @import("home");
const DiffFormatter = @import("../diff_format.zig").DiffFormatter;

const jsc = home_rt.jsc;
const CallFrame = home_rt.jsc.CallFrame;
const JSGlobalObject = home_rt.jsc.JSGlobalObject;
const JSValue = home_rt.jsc.JSValue;

const Expect = home_rt.jsc.Expect.Expect;
const getSignature = Expect.getSignature;
