// Copied from bun/src/http_types/FetchCacheMode.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
// JSC-bridge `toJS` omitted (Phase 12.2 follow-up).

/// https://developer.mozilla.org/en-US/docs/Web/API/Request/cache
pub const FetchCacheMode = enum(u3) {
    default,
    @"no-store",
    reload,
    @"no-cache",
    @"force-cache",
    @"only-if-cached",

    pub const Map = home_rt.ComptimeStringMap(FetchCacheMode, .{
        .{ "default", .default },
        .{ "no-store", .@"no-store" },
        .{ "reload", .reload },
        .{ "no-cache", .@"no-cache" },
        .{ "force-cache", .@"force-cache" },
        .{ "only-if-cached", .@"only-if-cached" },
    });
};

const home_rt = @import("home");
