// Copied from bun/src/http/HeaderBuilder.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// Imports rewritten: `@import("bun")` → `@import("home")`. Two ancillary
// rewrites:
//
//   * `StringBuilder = bun.StringBuilder` (i.e. `bun.string.StringBuilder`, a
//     pure-Zig `{len, cap, ptr}` buffer) → `home_rt.core.string.StringBuilder`,
//     ported as a sibling leaf at `src/core/string/StringBuilder.zig`. The
//     other `home_rt.jsc.StringBuilder` (the WTF C++ wrapper) is a different
//     type and is NOT what this file wants.
//   * `Headers = bun.http.Headers` and `api = bun.schema.api` are kept as the
//     canonical header-list/string-pointer identities so AsyncHTTP can take a
//     HeaderBuilder-built list without an adapter.
//
// `apply(client: *HTTPClient)` is the only method that touches the full
// HTTPClient state; upstream's `HTTPClient` lives in `bun/src/http/http.zig`
// (the big request orchestrator). That file is not yet ported, so we type
// the parameter as `anytype` and access only the two fields HTTPClient
// exposes here (`header_entries` and `header_buf`). This stays
// structurally identical to upstream — when http.zig lands, the `anytype`
// will resolve to `*HTTPClient` without any source change.

const std = @import("std");

const home_rt = @import("home");
const StringBuilder = @import("../core/string/StringBuilder.zig");
const Headers = @import("./Headers.zig");
const api = home_rt.schema.api;

const string = []const u8;

const HeaderBuilder = @This();

pub const StringPointer = api.StringPointer;

pub const Entry = Headers.Entry;

content: StringBuilder = .{},
header_count: u64 = 0,
entries: Entry.List = .empty,

pub fn count(this: *HeaderBuilder, name: string, value: string) void {
    this.header_count += 1;
    this.content.count(name);
    this.content.count(value);
}

pub fn allocate(this: *HeaderBuilder, allocator: std.mem.Allocator) !void {
    try this.content.allocate(allocator);
    try this.entries.ensureTotalCapacity(allocator, this.header_count);
}
pub fn append(this: *HeaderBuilder, name: string, value: string) void {
    const name_ptr = StringPointer{
        .offset = @as(u32, @truncate(this.content.len)),
        .length = @as(u32, @truncate(name.len)),
    };

    _ = this.content.append(name);

    const value_ptr = StringPointer{
        .offset = @as(u32, @truncate(this.content.len)),
        .length = @as(u32, @truncate(value.len)),
    };
    _ = this.content.append(value);
    this.entries.appendAssumeCapacity(.{ .name = name_ptr, .value = value_ptr });
}

pub fn appendFmt(this: *HeaderBuilder, name: string, comptime fmt: string, args: anytype) void {
    const name_ptr = StringPointer{
        .offset = @as(u32, @truncate(this.content.len)),
        .length = @as(u32, @truncate(name.len)),
    };

    _ = this.content.append(name);

    const value = this.content.fmt(fmt, args);

    const value_ptr = StringPointer{
        .offset = @as(u32, @truncate(this.content.len - value.len)),
        .length = @as(u32, @truncate(value.len)),
    };

    this.entries.appendAssumeCapacity(.{ .name = name_ptr, .value = value_ptr });
}

/// `client` is upstream `*HTTPClient` from `bun/src/http/http.zig`.
/// HTTPClient hasn't been ported yet (full HTTP/1.1 orchestrator); the
/// `anytype` keeps this leaf usable today and resolves identically when
/// http.zig lands.
pub fn apply(this: *HeaderBuilder, client: anytype) void {
    client.header_entries = this.entries;
    client.header_buf = this.content.ptr.?[0..this.content.len];
}

// Silence unused-const warnings for `home_rt` in the smoke-build path
// (the import stays so future expansions — e.g. handleOom — can reach it
// without a re-add).
comptime {
    _ = home_rt;
}

test "HeaderBuilder counts then appends two headers into a shared buffer" {
    var b = HeaderBuilder{};
    b.count("Content-Type", "application/json");
    b.count("X-Trace-Id", "abc123");
    try std.testing.expectEqual(@as(u64, 2), b.header_count);

    try b.allocate(std.testing.allocator);
    defer {
        b.content.deinit(std.testing.allocator);
        b.entries.deinit(std.testing.allocator);
    }

    b.append("Content-Type", "application/json");
    b.append("X-Trace-Id", "abc123");

    try std.testing.expectEqual(@as(usize, 2), b.entries.len);

    const sliced = b.entries.slice();
    const names = sliced.items(.name);
    const values = sliced.items(.value);

    const buf = b.content.ptr.?[0..b.content.len];
    try std.testing.expectEqualStrings("Content-Type", buf[names[0].offset..][0..names[0].length]);
    try std.testing.expectEqualStrings("application/json", buf[values[0].offset..][0..values[0].length]);
    try std.testing.expectEqualStrings("X-Trace-Id", buf[names[1].offset..][0..names[1].length]);
    try std.testing.expectEqualStrings("abc123", buf[values[1].offset..][0..values[1].length]);
}

test "HeaderBuilder.appendFmt formats the value in place" {
    var b = HeaderBuilder{};
    b.count("Content-Length", "");
    b.content.cap += std.fmt.count("{d}", .{4096});

    try b.allocate(std.testing.allocator);
    defer {
        b.content.deinit(std.testing.allocator);
        b.entries.deinit(std.testing.allocator);
    }

    b.appendFmt("Content-Length", "{d}", .{4096});
    try std.testing.expectEqual(@as(usize, 1), b.entries.len);

    const sliced = b.entries.slice();
    const names = sliced.items(.name);
    const values = sliced.items(.value);
    const buf = b.content.ptr.?[0..b.content.len];
    try std.testing.expectEqualStrings("Content-Length", buf[names[0].offset..][0..names[0].length]);
    try std.testing.expectEqualStrings("4096", buf[values[0].offset..][0..values[0].length]);
}
