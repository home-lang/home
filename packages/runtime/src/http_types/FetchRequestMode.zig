// Copied from bun/src/http_types/FetchRequestMode.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
// JSC-bridge `toJS` omitted (Phase 12.2 follow-up).

/// https://developer.mozilla.org/en-US/docs/Web/API/Request/mode
pub const FetchRequestMode = enum(u2) {
    @"same-origin",
    @"no-cors",
    cors,
    navigate,

    pub const Map = home_rt.ComptimeStringMap(FetchRequestMode, .{
        .{ "same-origin", .@"same-origin" },
        .{ "no-cors", .@"no-cors" },
        .{ "cors", .cors },
        .{ "navigate", .navigate },
    });

    pub fn toJS(this: FetchRequestMode, globalThis: *home_rt.jsc.JSGlobalObject) home_rt.jsc.JSValue {
        return home_rt.jsc.ZigString.init(@tagName(this)).toJS(globalThis);
    }
};

const home_rt = @import("home");
