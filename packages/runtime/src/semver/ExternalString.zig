pub const ExternalString = extern struct {
    value: String = String{},
    hash: u64 = 0,

    pub inline fn fmt(this: *const ExternalString, buf: string) String.Formatter {
        return this.value.fmt(buf);
    }

    pub fn order(lhs: *const ExternalString, rhs: *const ExternalString, lhs_buf: string, rhs_buf: string) std.math.Order {
        if (lhs.hash == rhs.hash and lhs.hash > 0) return .eq;
        return lhs.value.order(&rhs.value, lhs_buf, rhs_buf);
    }

    pub inline fn from(in: string) ExternalString {
        return .{
            .value = String.init(in, in),
            .hash = String.stringHash(in),
        };
    }

    pub inline fn isInline(this: ExternalString) bool {
        return this.value.isInline();
    }

    pub inline fn isEmpty(this: ExternalString) bool {
        return this.value.isEmpty();
    }

    pub inline fn len(this: ExternalString) u32 {
        return @intCast(this.value.len());
    }

    pub inline fn init(buf: string, in: string, hash: u64) ExternalString {
        return .{
            .value = String.init(buf, in),
            .hash = hash,
        };
    }

    pub inline fn slice(this: *const ExternalString, buf: string) string {
        return this.value.slice(buf);
    }
};

const string = []const u8;

const std = @import("std");
const String = @import("SemverString.zig").String;

