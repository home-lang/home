// Copied from bun/src/jsc/EventType.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// Imports rewritten: `@import("bun")` → `@import("home_rt")` so
// `bun.ComptimeStringMap` is `home_rt.ComptimeStringMap`. No semantic edits.

pub const EventType = enum(u8) {
    Event,
    MessageEvent,
    CloseEvent,
    ErrorEvent,
    OpenEvent,
    unknown = 254,
    _,

    pub const map = home_rt.ComptimeStringMap(EventType, .{
        .{ EventType.Event.label(), EventType.Event },
        .{ EventType.MessageEvent.label(), EventType.MessageEvent },
        .{ EventType.CloseEvent.label(), EventType.CloseEvent },
        .{ EventType.ErrorEvent.label(), EventType.ErrorEvent },
        .{ EventType.OpenEvent.label(), EventType.OpenEvent },
    });

    pub fn label(this: EventType) string {
        return switch (this) {
            .Event => "event",
            .MessageEvent => "message",
            .CloseEvent => "close",
            .ErrorEvent => "error",
            .OpenEvent => "open",
            else => "event",
        };
    }
};

const string = []const u8;

const home_rt = @import("home_rt");

test "EventType.map round-trips canonical labels" {
    const std = @import("std");
    try std.testing.expectEqual(EventType.Event, EventType.map.get("event").?);
    try std.testing.expectEqual(EventType.MessageEvent, EventType.map.get("message").?);
    try std.testing.expectEqual(EventType.CloseEvent, EventType.map.get("close").?);
    try std.testing.expectEqual(EventType.ErrorEvent, EventType.map.get("error").?);
    try std.testing.expectEqual(EventType.OpenEvent, EventType.map.get("open").?);
    try std.testing.expect(EventType.map.get("nope") == null);
}

test "EventType.label falls back to 'event' for unknown" {
    const std = @import("std");
    try std.testing.expectEqualStrings("event", EventType.Event.label());
    try std.testing.expectEqualStrings("message", EventType.MessageEvent.label());
    try std.testing.expectEqualStrings("event", EventType.unknown.label());
}
