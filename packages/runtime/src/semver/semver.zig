// These are all extern so they can't be top-level structs.
pub const String = @import("./SemverString.zig").String;
pub const ExternalString = @import("./ExternalString.zig").ExternalString;
pub const Version = @import("./Version.zig").Version;
pub const VersionType = @import("./Version.zig").VersionType;

pub const SlicedString = @import("./SlicedString.zig");
pub const Range = @import("./SemverRange.zig");
pub const Query = @import("./SemverQuery.zig");
pub const SemverObject = struct {
    comptime {
        @compileError("SemverObject is JSC-bound and intentionally parked in Home's semver leaf port");
    }
};
