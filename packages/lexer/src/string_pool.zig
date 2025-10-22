const std = @import("std");

/// String interning pool for deduplicating string literals
/// Reduces memory usage by storing each unique string only once
pub const StringPool = struct {
    allocator: std.mem.Allocator,
    strings: std.StringHashMap(u32), // string -> ID mapping
    interned: std.ArrayList([]const u8), // ID -> string mapping

    pub fn init(allocator: std.mem.Allocator) StringPool {
        return .{
            .allocator = allocator,
            .strings = std.StringHashMap(u32).init(allocator),
            .interned = std.ArrayList([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *StringPool) void {
        // Free all interned strings
        for (self.interned.items) |str| {
            self.allocator.free(str);
        }
        self.interned.deinit();
        self.strings.deinit();
    }

    /// Intern a string and return its ID
    /// If the string is already interned, returns existing ID
    pub fn intern(self: *StringPool, str: []const u8) !u32 {
        // Check if already interned
        if (self.strings.get(str)) |id| {
            return id;
        }

        // Allocate new string
        const owned = try self.allocator.dupe(u8, str);
        errdefer self.allocator.free(owned);

        // Assign new ID
        const id = @as(u32, @intCast(self.interned.items.len));
        try self.interned.append(owned);
        try self.strings.put(owned, id);

        return id;
    }

    /// Get string by ID
    pub fn getString(self: *const StringPool, id: u32) []const u8 {
        return self.interned.items[id];
    }

    /// Get number of unique strings
    pub fn count(self: *const StringPool) usize {
        return self.interned.items.len;
    }
};

test "string pool: basic interning" {
    const testing = std.testing;
    var pool = StringPool.init(testing.allocator);
    defer pool.deinit();

    const id1 = try pool.intern("hello");
    const id2 = try pool.intern("world");
    const id3 = try pool.intern("hello"); // duplicate

    try testing.expectEqual(id1, id3); // same string, same ID
    try testing.expect(id1 != id2); // different strings, different IDs
    try testing.expectEqual(@as(usize, 2), pool.count()); // only 2 unique strings

    try testing.expectEqualStrings("hello", pool.getString(id1));
    try testing.expectEqualStrings("world", pool.getString(id2));
}

test "string pool: many duplicates" {
    const testing = std.testing;
    var pool = StringPool.init(testing.allocator);
    defer pool.deinit();

    // Intern same string 100 times
    var i: usize = 0;
    var first_id: u32 = 0;
    while (i < 100) : (i += 1) {
        const id = try pool.intern("duplicate");
        if (i == 0) first_id = id;
        try testing.expectEqual(first_id, id);
    }

    // Only one unique string stored
    try testing.expectEqual(@as(usize, 1), pool.count());
}
