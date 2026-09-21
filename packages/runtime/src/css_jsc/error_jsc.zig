//! JSC bridge for `home_rt.css.Err(T)`. Keeps `src/css/` free of JSC types.

/// `this` is `*const css.Err(T)` for any `T`; only `.kind` is accessed.
pub fn toErrorInstance(this: anytype, globalThis: *home_rt.jsc.JSGlobalObject) !home_rt.jsc.JSValue {
    var str = try home_rt.String.createFormat("{f}", .{this.kind});
    // String.toErrorInstance consumes this reference. Releasing it here as
    // well over-releases the Error message's StringImpl and corrupts JSC's
    // string-uniquing table when GC runs between repeated CSS errors.
    return str.toErrorInstance(globalThis);
}

const home_rt = @import("home");
