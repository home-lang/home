pub fn toHaveBeenCalledTimes(this: *Expect, globalThis: *JSGlobalObject, callframe: *CallFrame) home_rt.JSError!JSValue {
    jsc.markBinding(@src());

    const thisValue = callframe.this();
    const arguments_ = callframe.arguments_old(1);
    const arguments: []const JSValue = arguments_.slice();
    defer this.postMatch(globalThis);
    const value: JSValue = try this.getValue(globalThis, thisValue, "toHaveBeenCalledTimes", "<green>expected<r>");

    this.incrementExpectCallCounter();

    const calls = try home_rt.cpp.JSMockFunction__getCalls(globalThis, value);
    if (!calls.jsType().isArray()) {
        var formatter = jsc.ConsoleObject.Formatter{ .globalThis = globalThis, .quote_strings = true };
        defer formatter.deinit();
        return globalThis.throw("Expected value must be a mock function: {f}", .{value.toFmt(&formatter)});
    }

    if (arguments.len < 1 or !arguments[0].isUInt32AsAnyInt()) {
        return globalThis.throwInvalidArguments("toHaveBeenCalledTimes() requires 1 non-negative integer argument", .{});
    }

    const times = arguments[0].toInt64();

    var pass = @as(i64, @intCast(try calls.getLength(globalThis))) == times;

    const not = this.flags.not;
    if (not) pass = !pass;
    if (pass) return .js_undefined;

    // handle failure
    if (not) {
        const signature = comptime getSignature("toHaveBeenCalledTimes", "<green>expected<r>", true);
        return this.throw(globalThis, signature, "\n\n" ++ "Expected number of calls: not <green>{d}<r>\n" ++ "Received number of calls: <red>{d}<r>\n", .{ times, try calls.getLength(globalThis) });
    }

    const signature = comptime getSignature("toHaveBeenCalledTimes", "<green>expected<r>", false);
    return this.throw(globalThis, signature, "\n\n" ++ "Expected number of calls: <green>{d}<r>\n" ++ "Received number of calls: <red>{d}<r>\n", .{ times, try calls.getLength(globalThis) });
}

const home_rt = @import("home");

const jsc = home_rt.jsc;
const CallFrame = home_rt.jsc.CallFrame;
const JSGlobalObject = home_rt.jsc.JSGlobalObject;
const JSValue = home_rt.jsc.JSValue;

const Expect = home_rt.jsc.Expect.Expect;
const getSignature = Expect.getSignature;
