pub fn toBeNull(this: *Expect, globalThis: *JSGlobalObject, callFrame: *CallFrame) home_rt.JSError!JSValue {
    defer this.postMatch(globalThis);

    const thisValue = callFrame.this();
    const value: JSValue = try this.getValue(globalThis, thisValue, "toBeNull", "");

    this.incrementExpectCallCounter();

    const not = this.flags.not;
    var pass = value.isNull();
    if (not) pass = !pass;
    if (pass) return .js_undefined;

    // handle failure
    var formatter = jsc.ConsoleObject.Formatter{ .globalThis = globalThis, .quote_strings = true };
    defer formatter.deinit();
    const value_fmt = value.toFmt(&formatter);
    if (not) {
        const received_line = "Received: <red>{f}<r>\n";
        const signature = comptime getSignature("toBeNull", "", true);
        return this.throw(globalThis, signature, "\n\n" ++ received_line, .{value_fmt});
    }

    const received_line = "Received: <red>{f}<r>\n";
    const signature = comptime getSignature("toBeNull", "", false);
    return this.throw(globalThis, signature, "\n\n" ++ received_line, .{value_fmt});
}

const home_rt = @import("home");

const jsc = home_rt.jsc;
const CallFrame = home_rt.jsc.CallFrame;
const JSGlobalObject = home_rt.jsc.JSGlobalObject;
const JSValue = home_rt.jsc.JSValue;

const Expect = home_rt.jsc.Expect.Expect;
const getSignature = Expect.getSignature;
