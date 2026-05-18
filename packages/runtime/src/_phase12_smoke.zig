// Temporary verification driver — pulls each newly-copied file into the
// home_rt module so `zig build-obj` exercises their tests. This file is
// not part of the home_rt public surface and will be removed once the
// aggregator is updated to import each new leaf.

test {
    _ = @import("options_types/GlobalCache.zig");
    _ = @import("options_types/BundleEnums.zig");
    _ = @import("options_types/CommandTag.zig");
    _ = @import("install/ExternalSlice.zig");
    _ = @import("install/padding_checker.zig");
}
