// Copied/adapted from Bun (https://github.com/oven-sh/bun) — MIT-licensed.
// Original: src/runtime/bake/DevServer/RouteBundle.zig
// See LICENSE.bun.md for full license text.
//
// Lifetime-only subset: Bun's RouteBundle carries compiled route assets,
// manifests, source maps, and HMR state. Home keeps the fields HmrSocket
// deinit needs: stable index, active-viewer refcount, and source-map id.

const std = @import("std");

pub const RouteBundle = struct {
    pub const Index = enum(u32) {
        _,

        pub fn fromInt(value: u32) Index {
            return @enumFromInt(value);
        }

        pub fn asInt(this: Index) u32 {
            return @intFromEnum(this);
        }
    };

    active_viewers: usize = 0,
    source_map_id: ?u32 = null,
};

test "RouteBundle.Index round-trips integer ids" {
    const index = RouteBundle.Index.fromInt(42);
    try std.testing.expectEqual(@as(u32, 42), index.asInt());
}
