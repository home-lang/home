//! JSC bridge for `home_rt.Semver.String`. Keeps `src/semver/` free of JSC types.

pub fn toJS(this: *const String, buffer: []const u8, globalThis: *jsc.JSGlobalObject) home_rt.JSError!jsc.JSValue {
    return home_rt.String.createUTF8ForJS(globalThis, this.slice(buffer));
}

const home_rt = @import("home");
const jsc = home_rt.jsc;
const String = home_rt.Semver.String;
