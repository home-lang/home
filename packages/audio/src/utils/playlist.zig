// Home Audio Library - Playlist Parsing
// Support for M3U, M3U8, and PLS playlist formats

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Playlist entry
pub const PlaylistEntry = struct {
    path: []const u8, // File path or URL
    title: ?[]const u8, // Optional title
    duration: ?i32, // Duration in seconds (-1 for unknown)
    artist: ?[]const u8, // Optional artist
    album: ?[]const u8, // Optional album

    pub fn deinit(self: *PlaylistEntry, allocator: Allocator) void {
        allocator.free(self.path);
        if (self.title) |t| allocator.free(t);
        if (self.artist) |a| allocator.free(a);
        if (self.album) |al| allocator.free(al);
    }
};

/// Playlist format
pub const PlaylistFormat = enum {
    m3u, // Standard M3U
    m3u8, // Extended M3U (UTF-8)
    pls, // PLS format

    pub fn fromExtension(ext: []const u8) ?PlaylistFormat {
        if (std.ascii.eqlIgnoreCase(ext, ".m3u")) return .m3u;
        if (std.ascii.eqlIgnoreCase(ext, ".m3u8")) return .m3u8;
        if (std.ascii.eqlIgnoreCase(ext, ".pls")) return .pls;
        return null;
    }
};

/// Playlist
pub const Playlist = struct {
    allocator: Allocator,
    entries: std.ArrayList(PlaylistEntry),
    title: ?[]const u8,
    format: PlaylistFormat,

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return Self{
            .allocator = allocator,
            .entries = .{},
            .title = null,
            .format = .m3u,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.entries.items) |*entry| {
            entry.deinit(self.allocator);
        }
        self.entries.deinit(self.allocator);
        if (self.title) |t| self.allocator.free(t);
    }

    /// Add entry to playlist
    pub fn addEntry(self: *Self, path: []const u8, title: ?[]const u8, duration: ?i32) !void {
        try self.entries.append(self.allocator, PlaylistEntry{
            .path = try self.allocator.dupe(u8, path),
            .title = if (title) |t| try self.allocator.dupe(u8, t) else null,
            .duration = duration,
            .artist = null,
            .album = null,
        });
    }

    /// Get entry count
    pub fn count(self: *Self) usize {
        return self.entries.items.len;
    }

    /// Get entry by index
    pub fn getEntry(self: *Self, index: usize) ?*PlaylistEntry {
        if (index >= self.entries.items.len) return null;
        return &self.entries.items[index];
    }

    /// Remove entry by index
    pub fn removeEntry(self: *Self, index: usize) void {
        if (index >= self.entries.items.len) return;
        self.entries.items[index].deinit(self.allocator);
        _ = self.entries.orderedRemove(index);
    }

    /// Clear all entries
    pub fn clear(self: *Self) void {
        for (self.entries.items) |*entry| {
            entry.deinit(self.allocator);
        }
        self.entries.clearRetainingCapacity();
    }
};

/// M3U/M3U8 parser
pub const M3uParser = struct {
    allocator: Allocator,

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return Self{ .allocator = allocator };
    }

    /// Parse M3U content
    pub fn parse(self: *Self, content: []const u8) !Playlist {
        var playlist = Playlist.init(self.allocator);
        errdefer playlist.deinit();

        // Check for extended M3U header
        const is_extended = std.mem.startsWith(u8, content, "#EXTM3U");
        playlist.format = if (is_extended) .m3u8 else .m3u;

        var pending_info: ?struct {
            duration: i32,
            title: []const u8,
        } = null;

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, &[_]u8{ '\r', ' ', '\t' });
            if (line.len == 0) continue;

            if (std.mem.startsWith(u8, line, "#EXTINF:")) {
                // Parse EXTINF line: #EXTINF:duration,title
                const info_part = line[8..];
                if (std.mem.indexOf(u8, info_part, ",")) |comma_idx| {
                    const duration_str = info_part[0..comma_idx];
                    const title = info_part[comma_idx + 1 ..];

                    const duration = std.fmt.parseInt(i32, duration_str, 10) catch -1;

                    pending_info = .{
                        .duration = duration,
                        .title = title,
                    };
                }
            } else if (std.mem.startsWith(u8, line, "#PLAYLIST:")) {
                // Playlist title
                playlist.title = try self.allocator.dupe(u8, line[10..]);
            } else if (!std.mem.startsWith(u8, line, "#")) {
                // This is a file path or URL
                const duration = if (pending_info) |info| info.duration else null;
                const title = if (pending_info) |info| info.title else null;

                try playlist.addEntry(line, title, duration);
                pending_info = null;
            }
        }

        return playlist;
    }

    /// Parse from file
    pub fn parseFile(self: *Self, path: []const u8) !Playlist {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 10 * 1024 * 1024);
        defer self.allocator.free(content);

        return self.parse(content);
    }
};

/// PLS parser
pub const PlsParser = struct {
    allocator: Allocator,

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return Self{ .allocator = allocator };
    }

    /// Parse PLS content
    pub fn parse(self: *Self, content: []const u8) !Playlist {
        var playlist = Playlist.init(self.allocator);
        playlist.format = .pls;
        errdefer playlist.deinit();

        // Temporary storage for entries
        var entries_map = std.AutoHashMap(usize, struct {
            path: ?[]const u8,
            title: ?[]const u8,
            duration: ?i32,
        }).init(self.allocator);
        defer entries_map.deinit();

        var num_entries: usize = 0;

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, &[_]u8{ '\r', ' ', '\t' });
            if (line.len == 0) continue;

            // Parse key=value
            if (std.mem.indexOf(u8, line, "=")) |eq_idx| {
                const key = std.mem.trim(u8, line[0..eq_idx], " ");
                const value = std.mem.trim(u8, line[eq_idx + 1 ..], " ");

                if (std.ascii.eqlIgnoreCase(key, "NumberOfEntries")) {
                    num_entries = std.fmt.parseInt(usize, value, 10) catch 0;
                } else if (std.mem.startsWith(u8, key, "File")) {
                    const idx_str = key[4..];
                    const idx = (std.fmt.parseInt(usize, idx_str, 10) catch 1) - 1;

                    const gop = try entries_map.getOrPut(idx);
                    if (!gop.found_existing) {
                        gop.value_ptr.* = .{ .path = null, .title = null, .duration = null };
                    }
                    gop.value_ptr.path = value;
                } else if (std.mem.startsWith(u8, key, "Title")) {
                    const idx_str = key[5..];
                    const idx = (std.fmt.parseInt(usize, idx_str, 10) catch 1) - 1;

                    const gop = try entries_map.getOrPut(idx);
                    if (!gop.found_existing) {
                        gop.value_ptr.* = .{ .path = null, .title = null, .duration = null };
                    }
                    gop.value_ptr.title = value;
                } else if (std.mem.startsWith(u8, key, "Length")) {
                    const idx_str = key[6..];
                    const idx = (std.fmt.parseInt(usize, idx_str, 10) catch 1) - 1;

                    const gop = try entries_map.getOrPut(idx);
                    if (!gop.found_existing) {
                        gop.value_ptr.* = .{ .path = null, .title = null, .duration = null };
                    }
                    gop.value_ptr.duration = std.fmt.parseInt(i32, value, 10) catch -1;
                }
            }
        }

        // Add entries in order
        for (0..@max(num_entries, entries_map.count())) |i| {
            if (entries_map.get(i)) |entry| {
                if (entry.path) |path| {
                    try playlist.addEntry(path, entry.title, entry.duration);
                }
            }
        }

        return playlist;
    }

    /// Parse from file
    pub fn parseFile(self: *Self, path: []const u8) !Playlist {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 10 * 1024 * 1024);
        defer self.allocator.free(content);

        return self.parse(content);
    }
};

/// M3U writer
pub const M3uWriter = struct {
    allocator: Allocator,
    extended: bool,

    const Self = @This();

    pub fn init(allocator: Allocator, extended: bool) Self {
        return Self{
            .allocator = allocator,
            .extended = extended,
        };
    }

    /// Generate M3U content
    pub fn generate(self: *Self, playlist: *const Playlist) ![]u8 {
        var output: std.ArrayList(u8) = .{};
        errdefer output.deinit(self.allocator);

        // Header
        if (self.extended) {
            try output.appendSlice(self.allocator, "#EXTM3U\n");

            if (playlist.title) |title| {
                try output.appendSlice(self.allocator, "#PLAYLIST:");
                try output.appendSlice(self.allocator, title);
                try output.append(self.allocator, '\n');
            }
        }

        // Entries
        for (playlist.entries.items) |entry| {
            if (self.extended) {
                const duration = entry.duration orelse -1;
                const title = entry.title orelse entry.path;
                // Write #EXTINF:duration,title
                try output.appendSlice(self.allocator, "#EXTINF:");
                // Simple duration formatting
                if (duration >= 0) {
                    var buf: [16]u8 = undefined;
                    const dur_str = std.fmt.bufPrint(&buf, "{d}", .{duration}) catch "0";
                    try output.appendSlice(self.allocator, dur_str);
                } else {
                    try output.appendSlice(self.allocator, "-1");
                }
                try output.append(self.allocator, ',');
                try output.appendSlice(self.allocator, title);
                try output.append(self.allocator, '\n');
            }
            try output.appendSlice(self.allocator, entry.path);
            try output.append(self.allocator, '\n');
        }

        return output.toOwnedSlice(self.allocator);
    }

    /// Write to file
    pub fn writeFile(self: *Self, playlist: *const Playlist, path: []const u8) !void {
        const content = try self.generate(playlist);
        defer self.allocator.free(content);

        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        try file.writeAll(content);
    }
};

/// PLS writer
pub const PlsWriter = struct {
    allocator: Allocator,

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return Self{ .allocator = allocator };
    }

    /// Generate PLS content
    pub fn generate(self: *Self, playlist: *const Playlist) ![]u8 {
        var output: std.ArrayList(u8) = .{};
        errdefer output.deinit(self.allocator);

        try output.appendSlice(self.allocator, "[playlist]\n");

        for (playlist.entries.items, 0..) |entry, i| {
            const idx = i + 1;
            var buf: [32]u8 = undefined;

            // File entry
            try output.appendSlice(self.allocator, "File");
            const idx_str = std.fmt.bufPrint(&buf, "{d}", .{idx}) catch "0";
            try output.appendSlice(self.allocator, idx_str);
            try output.append(self.allocator, '=');
            try output.appendSlice(self.allocator, entry.path);
            try output.append(self.allocator, '\n');

            // Title entry
            if (entry.title) |title| {
                try output.appendSlice(self.allocator, "Title");
                try output.appendSlice(self.allocator, idx_str);
                try output.append(self.allocator, '=');
                try output.appendSlice(self.allocator, title);
                try output.append(self.allocator, '\n');
            }

            // Length entry
            if (entry.duration) |duration| {
                try output.appendSlice(self.allocator, "Length");
                try output.appendSlice(self.allocator, idx_str);
                try output.append(self.allocator, '=');
                const dur_str = std.fmt.bufPrint(&buf, "{d}", .{duration}) catch "0";
                try output.appendSlice(self.allocator, dur_str);
                try output.append(self.allocator, '\n');
            }
        }

        var buf: [32]u8 = undefined;
        try output.appendSlice(self.allocator, "NumberOfEntries=");
        const count_str = std.fmt.bufPrint(&buf, "{d}", .{playlist.entries.items.len}) catch "0";
        try output.appendSlice(self.allocator, count_str);
        try output.append(self.allocator, '\n');
        try output.appendSlice(self.allocator, "Version=2\n");

        return output.toOwnedSlice(self.allocator);
    }

    /// Write to file
    pub fn writeFile(self: *Self, playlist: *const Playlist, path: []const u8) !void {
        const content = try self.generate(playlist);
        defer self.allocator.free(content);

        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        try file.writeAll(content);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "M3uParser simple" {
    const allocator = std.testing.allocator;

    var parser = M3uParser.init(allocator);
    const content =
        \\#EXTM3U
        \\#EXTINF:180,Artist - Title
        \\/path/to/song1.mp3
        \\#EXTINF:-1,Another Song
        \\/path/to/song2.mp3
    ;

    var playlist = try parser.parse(content);
    defer playlist.deinit();

    try std.testing.expectEqual(@as(usize, 2), playlist.count());
    try std.testing.expectEqualSlices(u8, "/path/to/song1.mp3", playlist.entries.items[0].path);
}

test "PlsParser simple" {
    const allocator = std.testing.allocator;

    var parser = PlsParser.init(allocator);
    const content =
        \\[playlist]
        \\File1=/path/to/song1.mp3
        \\Title1=Song One
        \\Length1=180
        \\File2=/path/to/song2.mp3
        \\NumberOfEntries=2
        \\Version=2
    ;

    var playlist = try parser.parse(content);
    defer playlist.deinit();

    try std.testing.expectEqual(@as(usize, 2), playlist.count());
}

test "M3uWriter generate" {
    const allocator = std.testing.allocator;

    var playlist = Playlist.init(allocator);
    defer playlist.deinit();

    try playlist.addEntry("/path/to/song.mp3", "Test Song", 180);

    var writer = M3uWriter.init(allocator, true);
    const content = try writer.generate(&playlist);
    defer allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "#EXTM3U") != null);
}

test "Playlist operations" {
    const allocator = std.testing.allocator;

    var playlist = Playlist.init(allocator);
    defer playlist.deinit();

    try playlist.addEntry("song1.mp3", "Song 1", 120);
    try playlist.addEntry("song2.mp3", "Song 2", 180);

    try std.testing.expectEqual(@as(usize, 2), playlist.count());

    playlist.removeEntry(0);
    try std.testing.expectEqual(@as(usize, 1), playlist.count());
    try std.testing.expectEqualSlices(u8, "song2.mp3", playlist.entries.items[0].path);
}
