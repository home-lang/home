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
    // Ninth-wave port batch (2026-05-18):
    _ = @import("core/string/StringBuilder.zig");
    _ = @import("http/HeaderBuilder.zig");
    // Thirteenth-wave port batch (2026-05-18) — orphan-wave smoke check.
    // Mirrors the home_rt aggregator additions so the smoke driver
    // exercises each file even before the test-step runs.
    // TODO(phase-12-13): wire analytics/Features.zig — Zig-0.17
    // whitespace-around-`*` lint trips at line 110 of the copy.
    // TODO(phase-12-13): wire node/path.zig — Zig-0.17 pointless-discard
    // lint trips on `_ = T` in the `isSep*T` / `isWindowsDeviceRootT`
    // comptime helpers.
    _ = @import("jsc/generated_classes_list.zig");
    _ = @import("runtime/api/bun/Terminal.zig");
    _ = @import("runtime/api/bun/spawn.zig");
    _ = @import("runtime/api/glob.zig");
    _ = @import("runtime/webcore/Body.zig");
    _ = @import("runtime/webcore/FormData.zig");
    _ = @import("runtime/webcore/ObjectURLRegistry.zig");
    _ = @import("runtime/webcore/Sink.zig");
    _ = @import("safety/safety.zig");
}
