// These are all extern so they can't be top-level structs.
pub const String = @import("./SemverString.zig").String;
pub const ExternalString = @import("./ExternalString.zig").ExternalString;
pub const Version = @import("./Version.zig").Version;
pub const VersionType = @import("./Version.zig").VersionType;

pub const SlicedString = @import("./SlicedString.zig");
pub const Range = @import("./SemverRange.zig");
pub const Query = @import("./SemverQuery.zig");
// The real JSC host-function bridge for `Bun.semver.{satisfies,order}`.
// Re-attached 2026-06-23: home_rt now exposes the JSFunction/ArgumentsSlice
// surface the bridge needs, so import it instead of the .zero-returning stub
// (a .zero lazy-prop value segfaulted JSC on `Bun.semver` access). Matches
// upstream semver.zig's `@import("../semver_jsc/SemverObject.zig")`.
pub const SemverObject = @import("../semver_jsc/SemverObject.zig");
