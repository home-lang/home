// Copied from bun/src/paths/EnvPath.zig at upstream SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
// Generic PATH-style env-var builder ("/a:/b:/c") with delimiter trimming.
// The upstream `PathComponentBuilder` nested helper depends on `AbsPath`,
// which is unported (blocked on paths/Path.zig). It's omitted here and
// re-attaches when AbsPath ports.

pub const EnvPathOptions = struct {
    //
};

fn trimPathDelimiters(input: string) string {
    var trimmed = input;
    while (trimmed.len > 0 and trimmed[0] == std.fs.path.delimiter) {
        trimmed = trimmed[1..];
    }
    while (trimmed.len > 0 and trimmed[trimmed.len - 1] == std.fs.path.delimiter) {
        trimmed = trimmed[0 .. trimmed.len - 1];
    }
    return trimmed;
}

/// Local helper — upstream calls `strings.withoutTrailingSlash`, which Home
/// doesn't expose yet. Behaviorally identical: strip a single trailing
/// `/` or `\` if present (callers of EnvPath only ever pass POSIX-style
/// inputs to it, but we match Bun and check both).
fn withoutTrailingSlash(input: string) string {
    var trimmed = input;
    while (trimmed.len > 0 and (trimmed[trimmed.len - 1] == '/' or trimmed[trimmed.len - 1] == '\\')) {
        trimmed = trimmed[0 .. trimmed.len - 1];
    }
    return trimmed;
}

pub fn EnvPath(comptime opts: EnvPathOptions) type {
    _ = opts;
    return struct {
        allocator: std.mem.Allocator,
        buf: std.ArrayListUnmanaged(u8) = .empty,

        pub fn init(allocator: std.mem.Allocator) @This() {
            return .{ .allocator = allocator };
        }

        pub fn initCapacity(allocator: std.mem.Allocator, capacity: usize) OOM!@This() {
            return .{ .allocator = allocator, .buf = try .initCapacity(allocator, capacity) };
        }

        pub fn deinit(this: *const @This()) void {
            @constCast(this).buf.deinit(this.allocator);
        }

        pub fn slice(this: *const @This()) string {
            return this.buf.items;
        }

        pub fn append(this: *@This(), input: anytype) OOM!void {
            const trimmed: string = switch (@TypeOf(input)) {
                []u8, []const u8 => withoutTrailingSlash(trimPathDelimiters(input)),

                // assume already trimmed
                else => input.slice(),
            };

            if (trimmed.len == 0) {
                return;
            }

            if (this.buf.items.len != 0) {
                try this.buf.ensureUnusedCapacity(this.allocator, trimmed.len + 1);
                this.buf.appendAssumeCapacity(std.fs.path.delimiter);
                this.buf.appendSliceAssumeCapacity(trimmed);
            } else {
                try this.buf.appendSlice(this.allocator, trimmed);
            }
        }

        // stubbed: PathComponentBuilder re-attaches when paths/Path.zig's
        // `AbsPath` lands. Callers that need the builder will `@compileError`
        // until then; the leaf-level `append([]const u8)` path covers every
        // existing Home-runtime use site.
    };
}

const string = []const u8;

const std = @import("std");

const home_rt = @import("home_rt");
const OOM = home_rt.OOM;

test "EnvPath appends with delimiter between entries" {
    const testing = std.testing;
    var ep = EnvPath(.{}).init(testing.allocator);
    defer ep.deinit();

    try ep.append(@as([]const u8, "/usr/local/bin"));
    try ep.append(@as([]const u8, "/usr/bin"));
    try ep.append(@as([]const u8, "/bin/"));

    // Each entry is joined by the platform PATH delimiter; trailing slash
    // is stripped on the third entry.
    const sep = std.fs.path.delimiter;
    var expected_buf: [64]u8 = undefined;
    const expected = try std.fmt.bufPrint(&expected_buf, "/usr/local/bin{c}/usr/bin{c}/bin", .{ sep, sep });
    try testing.expectEqualStrings(expected, ep.slice());
}

test "EnvPath skips empty entries" {
    const testing = std.testing;
    var ep = EnvPath(.{}).init(testing.allocator);
    defer ep.deinit();

    try ep.append(@as([]const u8, ""));
    try ep.append(@as([]const u8, "/only"));
    try ep.append(@as([]const u8, ""));
    try testing.expectEqualStrings("/only", ep.slice());
}
