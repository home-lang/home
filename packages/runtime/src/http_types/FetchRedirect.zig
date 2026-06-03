// Copied from bun/src/http_types/FetchRedirect.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
// Imports rewritten: @import("bun") → @import("home"). The JSC-bridge
// `toJS` re-export is omitted — it re-lands under `src/http_jsc/` in
// Phase 12.2.

pub const FetchRedirect = enum(u2) {
    follow,
    manual,
    @"error",

    pub const Map = home_rt.ComptimeStringMap(FetchRedirect, .{
        .{ "follow", .follow },
        .{ "manual", .manual },
        .{ "error", .@"error" },
    });

    pub fn toJS(this: FetchRedirect, globalThis: *home_rt.jsc.JSGlobalObject) home_rt.jsc.JSValue {
        return home_rt.jsc.ZigString.init(@tagName(this)).toJS(globalThis);
    }
};

const home_rt = @import("home");
