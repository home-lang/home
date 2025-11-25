// Home Video Library - Metadata Operations
// Read, write, merge, and convert metadata

const std = @import("std");
const metadata = @import("metadata.zig");

pub const Metadata = metadata.Metadata;

// Metadata operations
pub const MetadataOperations = struct {
    pub fn merge(allocator: std.mem.Allocator, base: Metadata, overlay: Metadata) !Metadata {
        var result = base;
        if (overlay.title) |v| result.title = try allocator.dupe(u8, v);
        if (overlay.artist) |v| result.artist = try allocator.dupe(u8, v);
        if (overlay.album) |v| result.album = try allocator.dupe(u8, v);
        if (overlay.genre) |v| result.genre = try allocator.dupe(u8, v);
        if (overlay.year) |v| result.year = try allocator.dupe(u8, v);
        if (overlay.comment) |v| result.comment = try allocator.dupe(u8, v);
        if (overlay.track_number) |v| result.track_number = v;
        if (overlay.disc_number) |v| result.disc_number = v;
        return result;
    }

    pub fn clear(meta: *Metadata, allocator: std.mem.Allocator) void {
        _ = allocator;
        meta.* = .{};
    }

    pub fn copy(allocator: std.mem.Allocator, source: *const Metadata) !Metadata {
        var result: Metadata = .{};
        if (source.title) |v| result.title = try allocator.dupe(u8, v);
        if (source.artist) |v| result.artist = try allocator.dupe(u8, v);
        if (source.album) |v| result.album = try allocator.dupe(u8, v);
        if (source.genre) |v| result.genre = try allocator.dupe(u8, v);
        if (source.year) |v| result.year = try allocator.dupe(u8, v);
        if (source.comment) |v| result.comment = try allocator.dupe(u8, v);
        result.track_number = source.track_number;
        result.disc_number = source.disc_number;
        return result;
    }

    pub fn equals(a: *const Metadata, b: *const Metadata) bool {
        return std.mem.eql(u8, a.title orelse "", b.title orelse "") and
            std.mem.eql(u8, a.artist orelse "", b.artist orelse "") and
            std.mem.eql(u8, a.album orelse "", b.album orelse "");
    }
};
