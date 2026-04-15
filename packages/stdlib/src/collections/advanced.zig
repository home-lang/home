const std = @import("std");

/// Advanced collection data structures for the Home standard library

/// Persistent Vector (inspired by Clojure)
/// Provides efficient immutable operations
pub fn PersistentVector(comptime T: type) type {
    return struct {
        const Self = @This();
        const BRANCH_FACTOR = 32;
        const SHIFT = 5;

        allocator: std.mem.Allocator,
        root: ?*Node,
        tail: []T,
        len: usize,
        shift: u6,

        const Node = struct {
            children: [BRANCH_FACTOR]?*Node,
        };

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .root = null,
                .tail = &[_]T{},
                .len = 0,
                .shift = SHIFT,
            };
        }

        pub fn deinit(self: *Self) void {
            if (self.root) |root| {
                self.freeNode(root, self.shift);
            }
            if (self.tail.len > 0) {
                self.allocator.free(self.tail);
            }
        }

        fn freeNode(self: *Self, node: *Node, shift: u6) void {
            if (shift > 0) {
                for (node.children) |maybe_child| {
                    if (maybe_child) |child| {
                        self.freeNode(child, shift - SHIFT);
                    }
                }
            }
            self.allocator.destroy(node);
        }

        pub fn push(self: *Self, value: T) !Self {
            var new = Self{
                .allocator = self.allocator,
                .root = self.root,
                .tail = undefined,
                .len = self.len + 1,
                .shift = self.shift,
            };

            if (self.tail.len < BRANCH_FACTOR) {
                // Tail has room — copy the tail and append the new element,
                // sharing the existing trie nodes with the original.
                var new_tail = try self.allocator.alloc(T, self.tail.len + 1);
                @memcpy(new_tail[0..self.tail.len], self.tail);
                new_tail[self.tail.len] = value;
                new.tail = new_tail;
            } else {
                // Tail is full — push the current tail into the trie as a new
                // leaf node and start a fresh tail with just the new value.
                const leaf = try self.allocator.create(Node);
                leaf.* = .{ .children = [_]?*Node{null} ** BRANCH_FACTOR };

                new.root = try self.pushTail(self.shift, self.root, leaf);

                // If the tree overflowed its current depth, add a new root level.
                if (self.treeSize() > (@as(usize, 1) << @intCast(self.shift + SHIFT))) {
                    const new_root = try self.allocator.create(Node);
                    new_root.* = .{ .children = [_]?*Node{null} ** BRANCH_FACTOR };
                    new_root.children[0] = new.root;
                    new_root.children[1] = try self.newPath(self.shift, leaf);
                    new.root = new_root;
                    new.shift = self.shift + SHIFT;
                }

                var new_tail = try self.allocator.alloc(T, 1);
                new_tail[0] = value;
                new.tail = new_tail;
            }

            return new;
        }

        fn treeSize(self: *Self) usize {
            if (self.len <= BRANCH_FACTOR) return 0;
            return self.len - self.tail.len;
        }

        fn pushTail(self: *Self, level: u6, parent: ?*Node, tail_node: *Node) !*Node {
            const new_node = try self.allocator.create(Node);
            // Destroy the newly-allocated node if the recursive pushTail
            // below fails — otherwise it leaks.
            errdefer self.allocator.destroy(new_node);
            if (parent) |p| {
                new_node.* = p.*;
            } else {
                new_node.* = .{ .children = [_]?*Node{null} ** BRANCH_FACTOR };
            }
            const subidx = ((self.len - 1) >> @intCast(level)) & (BRANCH_FACTOR - 1);
            if (level == SHIFT) {
                new_node.children[subidx] = tail_node;
            } else {
                const child = new_node.children[subidx];
                new_node.children[subidx] = try self.pushTail(level - SHIFT, child, tail_node);
            }
            return new_node;
        }

        fn newPath(self: *Self, level: u6, node: *Node) !*Node {
            if (level == 0) return node;
            const new_node = try self.allocator.create(Node);
            errdefer self.allocator.destroy(new_node);
            new_node.* = .{ .children = [_]?*Node{null} ** BRANCH_FACTOR };
            new_node.children[0] = try self.newPath(level - SHIFT, node);
            return new_node;
        }

        pub fn get(self: *Self, index: usize) ?T {
            if (index >= self.len) return null;
            // If index is in the tail section, read directly.
            const tail_offset = self.len - self.tail.len;
            if (index >= tail_offset) {
                return self.tail[index - tail_offset];
            }
            // Traverse the trie from the root.
            var node = self.root orelse return null;
            var level = self.shift;
            while (level > 0) : (level -= SHIFT) {
                const subidx = (index >> @intCast(level)) & (BRANCH_FACTOR - 1);
                node = node.children[subidx] orelse return null;
            }
            // At the leaf level, the children array is re-purposed — not yet
            // used for leaf values in this representation, so fall back to null.
            // Full implementation would store T values in a separate leaf array.
            _ = node;
            return null;
        }
    };
}

/// Bloom Filter for probabilistic set membership
pub fn BloomFilter(comptime max_items: usize) type {
    return struct {
        const Self = @This();
        const BITS_PER_ITEM = 10;
        const SIZE = max_items * BITS_PER_ITEM;
        const NUM_HASHES = 7;

        bits: std.bit_set.DynamicBitSet,
        count: usize,

        pub fn init(allocator: std.mem.Allocator) !Self {
            return .{
                .bits = try std.bit_set.DynamicBitSet.initEmpty(allocator, SIZE),
                .count = 0,
            };
        }

        pub fn deinit(self: *Self) void {
            self.bits.deinit();
        }

        pub fn insert(self: *Self, item: []const u8) void {
            var i: usize = 0;
            while (i < NUM_HASHES) : (i += 1) {
                const hash = self.hashItem(item, i);
                self.bits.set(hash % SIZE);
            }
            self.count += 1;
        }

        pub fn contains(self: *Self, item: []const u8) bool {
            var i: usize = 0;
            while (i < NUM_HASHES) : (i += 1) {
                const hash = self.hashItem(item, i);
                if (!self.bits.isSet(hash % SIZE)) {
                    return false;
                }
            }
            return true;
        }

        fn hashItem(self: *Self, item: []const u8, seed: usize) u64 {
            _ = self;
            var hasher = std.hash.Wyhash.init(seed);
            hasher.update(item);
            return hasher.final();
        }

        pub fn estimatedFalsePositiveRate(self: *Self) f64 {
            const k = @as(f64, @floatFromInt(NUM_HASHES));
            const m = @as(f64, @floatFromInt(SIZE));
            const n = @as(f64, @floatFromInt(self.count));
            return std.math.pow(f64, 1.0 - std.math.exp(-k * n / m), k);
        }
    };
}

/// Skip List for O(log n) operations
pub fn SkipList(comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();
        const MAX_LEVEL = 16;

        allocator: std.mem.Allocator,
        head: *Node,
        level: usize,
        len: usize,
        rng: std.Random.DefaultPrng,

        const Node = struct {
            key: K,
            value: V,
            forward: [MAX_LEVEL]?*Node,
        };

        pub fn init(allocator: std.mem.Allocator) !Self {
            const head = try allocator.create(Node);
            head.* = .{
                .key = undefined,
                .value = undefined,
                .forward = [_]?*Node{null} ** MAX_LEVEL,
            };

            return .{
                .allocator = allocator,
                .head = head,
                .level = 0,
                .len = 0,
                .rng = std.Random.DefaultPrng.init(0),
            };
        }

        pub fn deinit(self: *Self) void {
            var current = self.head.forward[0];
            while (current) |node| {
                const next = node.forward[0];
                self.allocator.destroy(node);
                current = next;
            }
            self.allocator.destroy(self.head);
        }

        pub fn insert(self: *Self, key: K, value: V) !void {
            var update: [MAX_LEVEL]?*Node = [_]?*Node{null} ** MAX_LEVEL;
            var current = self.head;

            var i = self.level;
            while (i > 0) : (i -= 1) {
                while (current.forward[i - 1]) |next| {
                    if (std.math.order(next.key, key) == .lt) {
                        current = next;
                    } else {
                        break;
                    }
                }
                update[i - 1] = current;
            }

            current = current.forward[0] orelse self.head;

            const new_level = self.randomLevel();
            const new_node = try self.allocator.create(Node);
            new_node.* = .{
                .key = key,
                .value = value,
                .forward = [_]?*Node{null} ** MAX_LEVEL,
            };

            if (new_level > self.level) {
                var j = self.level;
                while (j < new_level) : (j += 1) {
                    update[j] = self.head;
                }
                self.level = new_level;
            }

            var k: usize = 0;
            while (k < new_level) : (k += 1) {
                if (update[k]) |prev| {
                    new_node.forward[k] = prev.forward[k];
                    prev.forward[k] = new_node;
                }
            }

            self.len += 1;
        }

        pub fn get(self: *Self, key: K) ?V {
            var current = self.head;

            var i = self.level;
            while (i > 0) : (i -= 1) {
                while (current.forward[i - 1]) |next| {
                    if (std.math.order(next.key, key) == .lt) {
                        current = next;
                    } else {
                        break;
                    }
                }
            }

            current = current.forward[0] orelse return null;

            if (std.math.order(current.key, key) == .eq) {
                return current.value;
            }

            return null;
        }

        fn randomLevel(self: *Self) usize {
            var level: usize = 1;
            while (self.rng.random().int(u32) & 1 == 0 and level < MAX_LEVEL) {
                level += 1;
            }
            return level;
        }
    };
}

/// Trie for efficient string operations
pub const Trie = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    root: *Node,
    count: usize,

    const Node = struct {
        children: std.AutoHashMap(u8, *Node),
        is_end: bool,
        value: ?*anyopaque,

        fn init(allocator: std.mem.Allocator) !*Node {
            const node = try allocator.create(Node);
            node.* = .{
                .children = std.AutoHashMap(u8, *Node).init(allocator),
                .is_end = false,
                .value = null,
            };
            return node;
        }

        fn deinit(self: *Node, allocator: std.mem.Allocator) void {
            var it = self.children.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.*.deinit(allocator);
                allocator.destroy(entry.value_ptr.*);
            }
            self.children.deinit();
        }
    };

    pub fn init(allocator: std.mem.Allocator) !Self {
        return .{
            .allocator = allocator,
            .root = try Node.init(allocator),
            .count = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        self.root.deinit(self.allocator);
        self.allocator.destroy(self.root);
    }

    pub fn insert(self: *Self, key: []const u8) !void {
        var current = self.root;

        for (key) |char| {
            const entry = try current.children.getOrPut(char);
            if (!entry.found_existing) {
                // If Node.init fails, back the entry out of the map —
                // otherwise we'd leave an undefined value_ptr that the
                // later traversal / deinit would dereference.
                entry.value_ptr.* = Node.init(self.allocator) catch |err| {
                    _ = current.children.remove(char);
                    return err;
                };
            }
            current = entry.value_ptr.*;
        }

        if (!current.is_end) {
            current.is_end = true;
            self.count += 1;
        }
    }

    pub fn contains(self: *Self, key: []const u8) bool {
        var current = self.root;

        for (key) |char| {
            if (current.children.get(char)) |next| {
                current = next;
            } else {
                return false;
            }
        }

        return current.is_end;
    }

    pub fn startsWith(self: *Self, prefix: []const u8) bool {
        var current = self.root;

        for (prefix) |char| {
            if (current.children.get(char)) |next| {
                current = next;
            } else {
                return false;
            }
        }

        return true;
    }

    pub fn findWithPrefix(self: *Self, prefix: []const u8, results: *std.ArrayList([]const u8)) !void {
        var current = self.root;

        for (prefix) |char| {
            if (current.children.get(char)) |next| {
                current = next;
            } else {
                return;
            }
        }

        try self.collectWords(current, prefix, results);
    }

    fn collectWords(self: *Self, node: *Node, prefix: []const u8, results: *std.ArrayList([]const u8)) !void {
        if (node.is_end) {
            const word = try self.allocator.dupe(u8, prefix);
            errdefer self.allocator.free(word);
            try results.append(word);
        }

        var it = node.children.iterator();
        while (it.next()) |entry| {
            const new_prefix = try std.mem.concat(self.allocator, u8, &[_][]const u8{ prefix, &[_]u8{entry.key_ptr.*} });
            defer self.allocator.free(new_prefix);
            try self.collectWords(entry.value_ptr.*, new_prefix, results);
        }
    }
};

/// Rope data structure for efficient string operations
pub const Rope = struct {
    const Self = @This();
    const SPLIT_LENGTH = 1000;
    const JOIN_LENGTH = 500;

    allocator: std.mem.Allocator,
    root: ?*Node,

    const Node = union(enum) {
        Leaf: []const u8,
        Branch: struct {
            left: *Node,
            right: *Node,
            weight: usize,
        },
    };

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .root = null,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.root) |root| {
            self.freeNode(root);
        }
    }

    fn freeNode(self: *Self, node: *Node) void {
        switch (node.*) {
            .Leaf => |data| self.allocator.free(data),
            .Branch => |branch| {
                self.freeNode(branch.left);
                self.freeNode(branch.right);
            },
        }
        self.allocator.destroy(node);
    }

    pub fn fromString(allocator: std.mem.Allocator, str: []const u8) !Self {
        var rope = Self.init(allocator);
        if (str.len > 0) {
            const leaf_data = try allocator.dupe(u8, str);
            errdefer allocator.free(leaf_data);
            const node = try allocator.create(Node);
            node.* = .{ .Leaf = leaf_data };
            rope.root = node;
        }
        return rope;
    }

    pub fn length(self: *Self) usize {
        return if (self.root) |root| self.nodeLength(root) else 0;
    }

    fn nodeLength(self: *Self, node: *Node) usize {
        return switch (node.*) {
            .Leaf => |data| data.len,
            .Branch => |branch| branch.weight + self.nodeLength(branch.right),
        };
    }

    pub fn concat(self: *Self, other: *Self) !Self {
        var new_rope = Self.init(self.allocator);

        if (self.root == null) {
            new_rope.root = other.root;
            return new_rope;
        }
        if (other.root == null) {
            new_rope.root = self.root;
            return new_rope;
        }

        const self_len = self.length();
        const other_len = other.length();

        // For short ropes, flatten into a single leaf to prevent degenerate
        // trees from repeated small concatenations.
        if (self_len + other_len <= JOIN_LENGTH) {
            var buffer = std.ArrayList(u8).init(self.allocator);
            errdefer buffer.deinit();
            try self.appendToBuffer(self.root.?, &buffer);
            try self.appendToBuffer(other.root.?, &buffer);
            const leaf_data = try buffer.toOwnedSlice();
            errdefer self.allocator.free(leaf_data);
            const leaf = try self.allocator.create(Node);
            leaf.* = .{ .Leaf = leaf_data };
            new_rope.root = leaf;
            return new_rope;
        }

        const branch_node = try self.allocator.create(Node);
        branch_node.* = .{
            .Branch = .{
                .left = self.root.?,
                .right = other.root.?,
                .weight = self_len,
            },
        };

        new_rope.root = branch_node;

        // Rebalance if the tree is significantly unbalanced.
        // A balanced rope of length N should have depth ~log2(N/SPLIT_LENGTH).
        const depth = new_rope.treeDepth(new_rope.root.?);
        const total_len = self_len + other_len;
        const max_depth: usize = if (total_len <= SPLIT_LENGTH) 1 else @as(usize, @intFromFloat(@log2(@as(f64, @floatFromInt(total_len / SPLIT_LENGTH + 1))))) + 3;
        if (depth > max_depth) {
            const flat = try new_rope.toString();
            new_rope.freeNode(new_rope.root.?);
            new_rope.root = try new_rope.buildBalanced(flat, 0, flat.len);
        }

        return new_rope;
    }

    fn treeDepth(self: *Self, node: *Node) usize {
        _ = self;
        return switch (node.*) {
            .Leaf => 0,
            .Branch => |b| 1 + @max(self.treeDepth(b.left), self.treeDepth(b.right)),
        };
    }

    fn buildBalanced(self: *Self, text: []const u8, start: usize, end: usize) !*Node {
        const len = end - start;
        if (len <= SPLIT_LENGTH) {
            // Dupe first so a failed alloc doesn't leave `leaf` dangling.
            const leaf_data = try self.allocator.dupe(u8, text[start..end]);
            errdefer self.allocator.free(leaf_data);
            const leaf = try self.allocator.create(Node);
            leaf.* = .{ .Leaf = leaf_data };
            return leaf;
        }
        const mid = start + len / 2;
        const left = try self.buildBalanced(text, start, mid);
        // Free the sub-tree we just built if the right half or the branch
        // node allocation fails.
        errdefer self.freeNode(left);
        const right = try self.buildBalanced(text, mid, end);
        errdefer self.freeNode(right);
        const branch = try self.allocator.create(Node);
        branch.* = .{
            .Branch = .{
                .left = left,
                .right = right,
                .weight = mid - start,
            },
        };
        return branch;
    }

    pub fn toString(self: *Self) ![]const u8 {
        if (self.root == null) {
            return try self.allocator.alloc(u8, 0);
        }

        var buffer = std.ArrayList(u8).init(self.allocator);
        errdefer buffer.deinit();
        try self.appendToBuffer(self.root.?, &buffer);
        return buffer.toOwnedSlice();
    }

    fn appendToBuffer(self: *Self, node: *Node, buffer: *std.ArrayList(u8)) !void {
        switch (node.*) {
            .Leaf => |data| try buffer.appendSlice(data),
            .Branch => |branch| {
                try self.appendToBuffer(branch.left, buffer);
                try self.appendToBuffer(branch.right, buffer);
            },
        }
    }
};

/// Circular Buffer
pub fn CircularBuffer(comptime T: type) type {
    return struct {
        const Self = @This();

        buffer: []T,
        read_pos: usize,
        write_pos: usize,
        full: bool,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator, capacity: usize) !Self {
            return .{
                .buffer = try allocator.alloc(T, capacity),
                .read_pos = 0,
                .write_pos = 0,
                .full = false,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.buffer);
        }

        pub fn push(self: *Self, item: T) !void {
            self.buffer[self.write_pos] = item;
            self.write_pos = (self.write_pos + 1) % self.buffer.len;

            if (self.full) {
                self.read_pos = (self.read_pos + 1) % self.buffer.len;
            }

            self.full = self.write_pos == self.read_pos;
        }

        pub fn pop(self: *Self) ?T {
            if (self.isEmpty()) return null;

            const item = self.buffer[self.read_pos];
            self.read_pos = (self.read_pos + 1) % self.buffer.len;
            self.full = false;

            return item;
        }

        pub fn isEmpty(self: *Self) bool {
            return !self.full and self.read_pos == self.write_pos;
        }

        pub fn isFull(self: *Self) bool {
            return self.full;
        }

        pub fn len(self: *Self) usize {
            if (self.full) return self.buffer.len;
            if (self.write_pos >= self.read_pos) {
                return self.write_pos - self.read_pos;
            }
            return self.buffer.len - self.read_pos + self.write_pos;
        }
    };
}
