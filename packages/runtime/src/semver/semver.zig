// These are all extern so they can't be top-level structs.
pub const String = @import("./SemverString.zig").String;
pub const ExternalString = @import("./ExternalString.zig").ExternalString;
pub const Version = @import("./Version.zig").Version;
pub const VersionType = @import("./Version.zig").VersionType;

pub const SlicedString = @import("./SlicedString.zig");
pub const Range = @import("./SemverRange.zig");
pub const Query = @import("./SemverQuery.zig");
// Bun imports ../semver_jsc/SemverObject.zig here. Home does not have the
// semver_jsc/JSC host-function bridge yet, so keep the name unavailable
// instead of exposing a partial `Bun.semver` object.
pub const SemverObject = struct {
    comptime {
        @compileError("SemverObject requires Bun's semver_jsc/JSC host-function bridge");
    }
};
