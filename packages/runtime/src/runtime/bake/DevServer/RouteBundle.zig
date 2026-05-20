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

        pub const Optional = enum(u32) {
            none = std.math.maxInt(u32),
            _,

            pub fn fromIndex(index: Index) Optional {
                return @enumFromInt(index.asInt());
            }

            pub fn unwrap(this: Optional) ?Index {
                if (this == .none) return null;
                return @enumFromInt(@intFromEnum(this));
            }
        };

        pub fn fromInt(value: u32) Index {
            return @enumFromInt(value);
        }

        pub fn asInt(this: Index) u32 {
            return @intFromEnum(this);
        }

        pub fn toOptional(this: Index) Optional {
            return Optional.fromIndex(this);
        }
    };

    active_viewers: usize = 0,
    source_map_id: ?u32 = null,
};

test "RouteBundle.Index round-trips integer ids" {
    const index = RouteBundle.Index.fromInt(42);
    try std.testing.expectEqual(@as(u32, 42), index.asInt());
}

test "RouteBundle.Index.Optional round-trips none and some ids" {
    try std.testing.expect(RouteBundle.Index.Optional.none.unwrap() == null);

    const index = RouteBundle.Index.fromInt(7);
    const optional = index.toOptional();
    try std.testing.expect(optional != .none);
    try std.testing.expectEqual(index, optional.unwrap().?);
}
