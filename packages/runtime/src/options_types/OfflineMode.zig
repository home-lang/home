// Copied from bun/src/options_types/OfflineMode.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
// Imports rewritten: @import("bun") → @import("home").

pub const OfflineMode = enum {
    online,
    latest,
    offline,
};

pub const Prefer = home_rt.ComptimeStringMap(OfflineMode, .{
    &.{ "offline", OfflineMode.offline },
    &.{ "latest", OfflineMode.latest },
    &.{ "online", OfflineMode.online },
});

const home_rt = @import("home");
