const std = @import("std");
const builtin = @import("builtin");

pub fn currentArchitecture() []const u8 {
    return switch (builtin.cpu.arch) {
        .x86_64 => "x64",
        .aarch64 => "arm64",
        .x86 => "ia32",
        .arm => "arm",
        .riscv64 => "riscv64",
        .powerpc64le, .powerpc64 => "ppc64",
        else => @tagName(builtin.cpu.arch),
    };
}

pub fn currentOperatingSystem() []const u8 {
    return switch (builtin.os.tag) {
        .macos => "darwin",
        .linux => "linux",
        .windows => "win32",
        .freebsd => "freebsd",
        .openbsd => "openbsd",
        .netbsd => "netbsd",
        .illumos => "sunos",
        else => @tagName(builtin.os.tag),
    };
}

pub fn isArchitectureMatch(list: []const []const u8, current: []const u8) bool {
    return isPlatformListMatch(list, current);
}

pub fn isOperatingSystemMatch(list: []const []const u8, current: []const u8) bool {
    return isPlatformListMatch(list, current);
}

pub fn isCurrentArchitectureMatch(list: []const []const u8) bool {
    return isArchitectureMatch(list, currentArchitecture());
}

pub fn isCurrentOperatingSystemMatch(list: []const []const u8) bool {
    return isOperatingSystemMatch(list, currentOperatingSystem());
}

fn isPlatformListMatch(list: []const []const u8, current: []const u8) bool {
    if (list.len == 0) return true;

    for (list) |entry| {
        if (entry.len > 1 and entry[0] == '!' and std.mem.eql(u8, entry[1..], current)) return false;
    }

    for (list) |entry| {
        if (std.mem.eql(u8, entry, "any")) return true;
        if (std.mem.eql(u8, entry, current)) return true;
        if (entry.len > 0 and entry[0] == '!') return true;
    }

    return false;
}

test "architecture match mirrors Bun install helper tables" {
    const current = currentArchitecture();
    const neg_current = try std.fmt.allocPrint(std.testing.allocator, "!{s}", .{current});
    defer std.testing.allocator.free(neg_current);

    const trues = [_][]const []const u8{
        &.{ "wombo.com", "any" },
        &.{ "wombo.com", current },
        &.{},
        &.{"any"},
        &.{ "any", current },
        &.{current},
        &.{"!ia32"},
        &.{ "!ia32", current },
        &.{ "ia32", current },
        &.{ "!mips", "!ia32" },
    };
    const falses = [_][]const []const u8{
        &.{"wombo.com"},
        &.{"ia32"},
        &.{ "any", neg_current },
        &.{neg_current},
        &.{ "!ia32", neg_current },
        &.{ neg_current, current },
    };

    for (trues) |items| try std.testing.expect(isArchitectureMatch(items, current));
    for (falses) |items| try std.testing.expect(!isArchitectureMatch(items, current));
}

test "operating system match mirrors Bun install helper tables" {
    const current = currentOperatingSystem();
    const neg_current = try std.fmt.allocPrint(std.testing.allocator, "!{s}", .{current});
    defer std.testing.allocator.free(neg_current);

    const trues = [_][]const []const u8{
        &.{},
        &.{"any"},
        &.{ "any", current },
        &.{current},
        &.{"!sunos"},
        &.{ "!sunos", current },
        &.{ "sunos", current },
        &.{ "!aix", "!sunos" },
        &.{ "wombo.com", "!aix" },
    };
    const falses = [_][]const []const u8{
        &.{"aix"},
        &.{ "any", neg_current },
        &.{neg_current},
        &.{ "!sunos", neg_current },
        &.{ neg_current, current },
    };

    for (trues) |items| try std.testing.expect(isOperatingSystemMatch(items, current));
    for (falses) |items| try std.testing.expect(!isOperatingSystemMatch(items, current));
}
