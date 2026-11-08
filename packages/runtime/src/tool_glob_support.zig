//! Pure leaves used by Home's owned glob matcher in the public-C tool host.
const std = @import("std");
pub const BoundedArray = @import("core/bounded_array.zig").BoundedArray;
pub const assert = std.debug.assert;
pub const debugAssert = std.debug.assert;
pub const Environment = struct {
    pub const allow_assert = true;
};
pub const strings = struct {
    const unicode = @import("string/immutable/unicode.zig");
    pub const u3_fast = u8;
    pub const wtf8ByteSequenceLength = unicode.wtf8ByteSequenceLength;
    pub const decodeWTF8RuneT = unicode.decodeWTF8RuneT;
};
