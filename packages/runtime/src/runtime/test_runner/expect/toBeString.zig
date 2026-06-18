pub fn toBeString(this: *Expect, globalThis: *JSGlobalObject, callFrame: *CallFrame) home_rt.JSError!JSValue {
    defer this.postMatch(globalThis);

    const thisValue = callFrame.this();
    const value: JSValue = try this.getValue(globalThis, thisValue, "toBeString", "");

    this.incrementExpectCallCounter();

    const not = this.flags.not;
    const pass = value.isString() != not;

    if (pass) return .js_undefined;

    var formatter = jsc.ConsoleObject.Formatter{ .globalThis = globalThis, .quote_strings = true };
    defer formatter.deinit();
    const received = value.toFmt(&formatter);

    if (not) {
        const signature = comptime getSignature("toBeString", "", true);
        return this.throw(globalThis, signature, "\n\n" ++ "Received: <red>{f}<r>\n", .{received});
    }

    const signature = comptime getSignature("toBeString", "", false);
    return this.throw(globalThis, signature, "\n\n" ++ "Received: <red>{f}<r>\n", .{received});
}

const home_rt = @import("home");

const jsc = home_rt.jsc;
const CallFrame = home_rt.jsc.CallFrame;
const JSGlobalObject = home_rt.jsc.JSGlobalObject;
const JSValue = home_rt.jsc.JSValue;

const Expect = home_rt.jsc.Expect.Expect;
const getSignature = Expect.getSignature;
