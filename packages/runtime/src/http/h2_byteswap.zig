// Per-field byte-swap for the HTTP/2 wire packed structs.
//
// `std.mem.byteSwapAllFields` (both Zig 0.16-dev and 0.17-dev, which Home
// builds with) takes a fast-path for packed structs with a backing integer:
// it byte-reverses the ENTIRE backing integer as one unit rather than
// swapping each field individually. For the oversized-backing H2 wire
// structs — FrameHeader (packed struct(u72)), SettingsPayloadUnit (u48),
// StreamPriority (u40), FullSettingsPayload (u336) — that reverses the whole
// 9/6/5/42-byte header instead of producing RFC 7540 big-endian per-field
// layout, corrupting every frame Home encodes and decodes. The corruption is
// symmetric between two Home peers (so home↔home framing round-trips and
// masks it) but breaks interop with any RFC-correct peer.
//
// Bun's pinned (older) Zig had no backing-integer fast-path and always swapped
// per-field, so the pin's identical `std.mem.byteSwapAllFields` calls emit
// correct wire bytes. This helper restores that per-field behavior. All the H2
// wire structs have byte-aligned integer fields, so per-field swap is exactly
// the RFC big-endian layout.
const std = @import("std");

pub fn byteSwapAllFields(comptime S: type, ptr: *S) void {
    inline for (std.meta.fields(S)) |f| {
        switch (@typeInfo(f.type)) {
            .@"struct" => byteSwapAllFields(f.type, &@field(ptr, f.name)),
            .@"enum" => {
                @field(ptr, f.name) = @enumFromInt(@byteSwap(@intFromEnum(@field(ptr, f.name))));
            },
            .bool => {},
            else => {
                @field(ptr, f.name) = @byteSwap(@field(ptr, f.name));
            },
        }
    }
}
