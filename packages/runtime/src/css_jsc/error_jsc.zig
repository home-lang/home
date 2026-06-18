//! JSC bridge for `home_rt.css.Err(T)`. Keeps `src/css/` free of JSC types.

/// `this` is `*const css.Err(T)` for any `T`; only `.kind` is accessed.
pub fn toErrorInstance(this: anytype, globalThis: *home_rt.jsc.JSGlobalObject) !home_rt.jsc.JSValue {
    var str = try home_rt.String.createFormat("{f}", .{this.kind});
    defer str.deref();
    return str.toErrorInstance(globalThis);
}

const home_rt = @import("home");
