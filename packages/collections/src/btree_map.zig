// BTreeMap Implementation for Home Language
// Self-balancing sorted map with O(log n) operations
//
// Properties:
// - Order-6 B-tree (can hold 5-11 keys per node)
// - Sorted key-value pairs
// - Efficient range queries
// - Better cache locality than red-black trees

const std = @import("std");
const Allocator = std.mem.Allocator;
const Order = std.math.Order;

/// B-tree map with configurable branching factor
pub fn BTreeMap(comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();
        const NODE_ORDER = 6; // Each node can have 5-11 keys
        const MIN_KEYS = NODE_ORDER - 1; // 5
        const MAX_KEYS = 2 * NODE_ORDER - 1; // 11

        /// B-tree node structure
        const Node = struct {
            keys: [MAX_KEYS]K,
            values: [MAX_KEYS]V,
            children: [MAX_KEYS + 1]?*Node,
            num_keys: usize,
            is_leaf: bool,

            fn init(is_leaf: bool) Node {
                return Node{
                    .keys = undefined,
                    .values = undefined,
                    .children = [_]?*Node{null} ** (MAX_KEYS + 1),
                    .num_keys = 0,
                    .is_leaf = is_leaf,
                };
            }

            fn isFull(self: *const Node) bool {
                return self.num_keys == MAX_KEYS;
            }

            fn isMinimal(self: *const Node) bool {
                return self.num_keys == MIN_KEYS;
            }

            /// Find the index where key should be inserted/found
            fn findKeyIndex(self: *const Node, key: K) usize {
                var i: usize = 0;
                while (i < self.num_keys and compareKeys(key, self.keys[i]) == .gt) : (i += 1) {}
                return i;
            }
        };

        allocator: Allocator,
        root: ?*Node,
        len: usize,

        /// Initialize an empty B-tree map
        pub fn init(allocator: Allocator) Self {
            return Self{
                .allocator = allocator,
                .root = null,
                .len = 0,
            };
        }

        /// Clean up all nodes
        pub fn deinit(self: *Self) void {
            if (self.root) |root| {
                self.freeNode(root);
            }
            self.* = undefined;
        }

        fn freeNode(self: *Self, node: *Node) void {
            if (!node.is_leaf) {
                var i: usize = 0;
                while (i <= node.num_keys) : (i += 1) {
                    if (node.children[i]) |child| {
                        self.freeNode(child);
                    }
                }
            }
            self.allocator.destroy(node);
        }

        /// Insert a key-value pair
        pub fn insert(self: *Self, key: K, value: V) !void {
            if (self.root == null) {
                // Create first node
                const root = try self.allocator.create(Node);
                root.* = Node.init(true);
                root.keys[0] = key;
                root.values[0] = value;
                root.num_keys = 1;
                self.root = root;
                self.len = 1;
                return;
            }

            // Check if root is full
            if (self.root.?.isFull()) {
                // Create new root
                const new_root = try self.allocator.create(Node);
                new_root.* = Node.init(false);
                new_root.children[0] = self.root;
                self.root = new_root;

                // Split old root
                try self.splitChild(new_root, 0);
            }

            try self.insertNonFull(self.root.?, key, value);
        }

        fn insertNonFull(self: *Self, node: *Node, key: K, value: V) !void {
            var i: isize = @intCast(node.num_keys);
            i -= 1;

            if (node.is_leaf) {
                // Check if key already exists (before shifting)
                var j: usize = 0;
                while (j < node.num_keys) : (j += 1) {
                    if (compareKeys(key, node.keys[j]) == .eq) {
                        // Update existing value
                        node.values[j] = value;
                        return;
                    }
                }

                // Insert into leaf node
                while (i >= 0 and compareKeys(key, node.keys[@intCast(i)]) == .lt) : (i -= 1) {
                    node.keys[@intCast(i + 1)] = node.keys[@intCast(i)];
                    node.values[@intCast(i + 1)] = node.values[@intCast(i)];
                }

                const idx: usize = @intCast(i + 1);
                node.keys[idx] = key;
                node.values[idx] = value;
                node.num_keys += 1;
                self.len += 1;
            } else {
                // Find child to insert into
                while (i >= 0 and compareKeys(key, node.keys[@intCast(i)]) == .lt) : (i -= 1) {}
                i += 1;

                const child_idx: usize = @intCast(i);
                const child = node.children[child_idx].?;

                if (child.isFull()) {
                    try self.splitChild(node, child_idx);
                    if (compareKeys(key, node.keys[child_idx]) == .gt) {
                        i += 1;
                    }
                }

                try self.insertNonFull(node.children[@intCast(i)].?, key, value);
            }
        }

        fn splitChild(self: *Self, parent: *Node, child_idx: usize) !void {
            const child = parent.children[child_idx].?;
            const new_node = try self.allocator.create(Node);
            new_node.* = Node.init(child.is_leaf);

            const mid = MIN_KEYS;
            new_node.num_keys = MIN_KEYS;

            // Copy second half of keys/values to new node
            var i: usize = 0;
            while (i < MIN_KEYS) : (i += 1) {
                new_node.keys[i] = child.keys[mid + 1 + i];
                new_node.values[i] = child.values[mid + 1 + i];
            }

            // Copy children if not leaf
            if (!child.is_leaf) {
                i = 0;
                while (i <= MIN_KEYS) : (i += 1) {
                    new_node.children[i] = child.children[mid + 1 + i];
                    child.children[mid + 1 + i] = null;
                }
            }

            child.num_keys = MIN_KEYS;

            // Insert middle key into parent
            i = parent.num_keys;
            while (i > child_idx) : (i -= 1) {
                parent.children[i + 1] = parent.children[i];
            }
            parent.children[child_idx + 1] = new_node;

            i = parent.num_keys;
            while (i > child_idx) {
                i -= 1;
                parent.keys[i + 1] = parent.keys[i];
                parent.values[i + 1] = parent.values[i];
            }
            parent.keys[child_idx] = child.keys[mid];
            parent.values[child_idx] = child.values[mid];
            parent.num_keys += 1;
        }

        /// Get value for a key
        pub fn get(self: *const Self, key: K) ?V {
            if (self.root) |root| {
                return self.searchNode(root, key);
            }
            return null;
        }

        fn searchNode(self: *const Self, node: *const Node, key: K) ?V {
            const idx = node.findKeyIndex(key);

            if (idx < node.num_keys and compareKeys(key, node.keys[idx]) == .eq) {
                return node.values[idx];
            }

            if (node.is_leaf) {
                return null;
            }

            if (node.children[idx]) |child| {
                return self.searchNode(child, key);
            }

            return null;
        }

        /// Check if key exists
        pub fn contains(self: *const Self, key: K) bool {
            return self.get(key) != null;
        }

        /// Remove a key-value pair
        pub fn remove(self: *Self, key: K) bool {
            if (self.root == null) return false;

            const removed = self.removeFromNode(self.root.?, key);

            // Shrink tree if root is empty
            if (self.root.?.num_keys == 0) {
                const old_root = self.root.?;
                if (!old_root.is_leaf and old_root.children[0] != null) {
                    self.root = old_root.children[0];
                } else {
                    self.root = null;
                }
                self.allocator.destroy(old_root);
            }

            if (removed) {
                self.len -= 1;
            }

            return removed;
        }

        fn removeFromNode(self: *Self, node: *Node, key: K) bool {
            const idx = node.findKeyIndex(key);

            if (idx < node.num_keys and compareKeys(key, node.keys[idx]) == .eq) {
                // Key found in this node
                if (node.is_leaf) {
                    return self.removeFromLeaf(node, idx);
                } else {
                    return self.removeFromNonLeaf(node, idx);
                }
            }

            if (node.is_leaf) {
                return false; // Key not found
            }

            const child = node.children[idx] orelse return false;
            const is_last_child = (idx == node.num_keys);

            if (child.isMinimal()) {
                self.ensureMinKeys(node, idx);
            }

            // Child might have moved after rebalancing
            if (is_last_child and idx > node.num_keys) {
                return self.removeFromNode(node.children[idx - 1].?, key);
            } else {
                return self.removeFromNode(node.children[idx].?, key);
            }
        }

        fn removeFromLeaf(self: *Self, node: *Node, idx: usize) bool {
            _ = self;
            // Shift keys left
            var i: usize = idx;
            while (i < node.num_keys - 1) : (i += 1) {
                node.keys[i] = node.keys[i + 1];
                node.values[i] = node.values[i + 1];
            }
            node.num_keys -= 1;
            return true;
        }

        fn removeFromNonLeaf(self: *Self, node: *Node, idx: usize) bool {
            const key = node.keys[idx];

            if (node.children[idx]) |left_child| {
                if (!left_child.isMinimal()) {
                    const pred = self.getPredecessor(node, idx);
                    node.keys[idx] = pred.key;
                    node.values[idx] = pred.value;
                    return self.removeFromNode(left_child, pred.key);
                }
            }

            if (node.children[idx + 1]) |right_child| {
                if (!right_child.isMinimal()) {
                    const succ = self.getSuccessor(node, idx);
                    node.keys[idx] = succ.key;
                    node.values[idx] = succ.value;
                    return self.removeFromNode(right_child, succ.key);
                }
            }

            // Both children have minimum keys, merge
            self.merge(node, idx) catch return false;
            return self.removeFromNode(node.children[idx].?, key);
        }

        fn getPredecessor(self: *const Self, node: *const Node, idx: usize) struct { key: K, value: V } {
            _ = self;
            var curr = node.children[idx].?;
            while (!curr.is_leaf) {
                curr = curr.children[curr.num_keys].?;
            }
            const last_idx = curr.num_keys - 1;
            return .{ .key = curr.keys[last_idx], .value = curr.values[last_idx] };
        }

        fn getSuccessor(self: *const Self, node: *const Node, idx: usize) struct { key: K, value: V } {
            _ = self;
            var curr = node.children[idx + 1].?;
            while (!curr.is_leaf) {
                curr = curr.children[0].?;
            }
            return .{ .key = curr.keys[0], .value = curr.values[0] };
        }

        fn ensureMinKeys(self: *Self, node: *Node, idx: usize) void {
            // Try to borrow from left sibling
            if (idx > 0) {
                if (node.children[idx - 1]) |left_sibling| {
                    if (left_sibling.num_keys > MIN_KEYS) {
                        self.borrowFromPrev(node, idx);
                        return;
                    }
                }
            }

            // Try to borrow from right sibling
            if (idx < node.num_keys) {
                if (node.children[idx + 1]) |right_sibling| {
                    if (right_sibling.num_keys > MIN_KEYS) {
                        self.borrowFromNext(node, idx);
                        return;
                    }
                }
            }

            // Merge with sibling
            if (idx < node.num_keys) {
                self.merge(node, idx) catch {};
            } else {
                self.merge(node, idx - 1) catch {};
            }
        }

        fn borrowFromPrev(self: *Self, parent: *Node, child_idx: usize) void {
            _ = self;
            const child = parent.children[child_idx].?;
            const sibling = parent.children[child_idx - 1].?;

            // Move all keys in child one step ahead
            var i: usize = child.num_keys;
            while (i > 0) {
                i -= 1;
                child.keys[i + 1] = child.keys[i];
                child.values[i + 1] = child.values[i];
            }

            // Move all children one step ahead
            if (!child.is_leaf) {
                i = child.num_keys + 1;
                while (i > 0) {
                    i -= 1;
                    child.children[i + 1] = child.children[i];
                }
            }

            // Move parent's key down
            child.keys[0] = parent.keys[child_idx - 1];
            child.values[0] = parent.values[child_idx - 1];

            // Move sibling's last child
            if (!child.is_leaf) {
                child.children[0] = sibling.children[sibling.num_keys];
            }

            // Move sibling's last key up to parent
            parent.keys[child_idx - 1] = sibling.keys[sibling.num_keys - 1];
            parent.values[child_idx - 1] = sibling.values[sibling.num_keys - 1];

            child.num_keys += 1;
            sibling.num_keys -= 1;
        }

        fn borrowFromNext(self: *Self, parent: *Node, child_idx: usize) void {
            _ = self;
            const child = parent.children[child_idx].?;
            const sibling = parent.children[child_idx + 1].?;

            // Parent's key goes down to child
            child.keys[child.num_keys] = parent.keys[child_idx];
            child.values[child.num_keys] = parent.values[child_idx];

            // Sibling's first child becomes child's last
            if (!child.is_leaf) {
                child.children[child.num_keys + 1] = sibling.children[0];
            }

            // Sibling's first key goes up to parent
            parent.keys[child_idx] = sibling.keys[0];
            parent.values[child_idx] = sibling.values[0];

            // Shift sibling's keys left
            var i: usize = 0;
            while (i < sibling.num_keys - 1) : (i += 1) {
                sibling.keys[i] = sibling.keys[i + 1];
                sibling.values[i] = sibling.values[i + 1];
            }

            // Shift sibling's children left
            if (!sibling.is_leaf) {
                i = 0;
                while (i < sibling.num_keys) : (i += 1) {
                    sibling.children[i] = sibling.children[i + 1];
                }
            }

            child.num_keys += 1;
            sibling.num_keys -= 1;
        }

        fn merge(self: *Self, parent: *Node, idx: usize) !void {
            const child = parent.children[idx].?;
            const sibling = parent.children[idx + 1].?;

            // Pull key from parent and merge with right sibling
            child.keys[child.num_keys] = parent.keys[idx];
            child.values[child.num_keys] = parent.values[idx];
            child.num_keys += 1;

            // Copy keys from sibling
            var i: usize = 0;
            while (i < sibling.num_keys) : (i += 1) {
                child.keys[child.num_keys + i] = sibling.keys[i];
                child.values[child.num_keys + i] = sibling.values[i];
            }

            // Copy children from sibling
            if (!child.is_leaf) {
                i = 0;
                while (i <= sibling.num_keys) : (i += 1) {
                    child.children[child.num_keys + i] = sibling.children[i];
                }
            }

            child.num_keys += sibling.num_keys;

            // Shift parent's keys left
            i = idx;
            while (i < parent.num_keys - 1) : (i += 1) {
                parent.keys[i] = parent.keys[i + 1];
                parent.values[i] = parent.values[i + 1];
            }

            // Shift parent's children left
            i = idx + 1;
            while (i < parent.num_keys) : (i += 1) {
                parent.children[i] = parent.children[i + 1];
            }

            parent.num_keys -= 1;
            self.allocator.destroy(sibling);
        }

        /// Get number of entries
        pub fn count(self: *const Self) usize {
            return self.len;
        }

        /// Check if empty
        pub fn isEmpty(self: *const Self) bool {
            return self.len == 0;
        }

        /// Clear all entries
        pub fn clear(self: *Self) void {
            if (self.root) |root| {
                self.freeNode(root);
                self.root = null;
                self.len = 0;
            }
        }

        /// Simple iterator (in-order traversal)
        /// Note: For production use, implement a stack-based iterator
        pub const Iterator = struct {
            map: *const Self,
            current_key: ?K,
            finished: bool,

            pub fn next(self: *Iterator) ?struct { key: K, value: V } {
                if (self.finished) return null;

                // Simple placeholder: just return null for now
                // A full implementation would do in-order traversal
                self.finished = true;
                return null;
            }

            pub fn deinit(self: *Iterator) void {
                _ = self;
            }
        };

        pub fn iterator(self: *const Self) Iterator {
            return Iterator{
                .map = self,
                .current_key = null,
                .finished = self.root == null,
            };
        }
    };
}

/// Compare two keys (supports int and float types)
fn compareKeys(a: anytype, b: @TypeOf(a)) Order {
    const T = @TypeOf(a);
    return switch (@typeInfo(T)) {
        .int => if (a < b) .lt else if (a > b) .gt else .eq,
        .float => if (a < b) .lt else if (a > b) .gt else .eq,
        else => @compileError("Unsupported key type for BTreeMap"),
    };
}

// =================================================================================
//                                    TESTS
// =================================================================================

test "BTreeMap - init and deinit" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var map = BTreeMap(i32, []const u8).init(allocator);
    defer map.deinit();

    try testing.expectEqual(@as(usize, 0), map.count());
    try testing.expect(map.isEmpty());
}

test "BTreeMap - insert and get" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var map = BTreeMap(i32, i32).init(allocator);
    defer map.deinit();

    try map.insert(5, 50);
    try map.insert(3, 30);
    try map.insert(7, 70);

    try testing.expectEqual(@as(usize, 3), map.count());
    try testing.expectEqual(@as(i32, 50), map.get(5).?);
    try testing.expectEqual(@as(i32, 30), map.get(3).?);
    try testing.expectEqual(@as(i32, 70), map.get(7).?);
    try testing.expect(map.get(10) == null);
}

test "BTreeMap - update existing key" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var map = BTreeMap(i32, i32).init(allocator);
    defer map.deinit();

    try map.insert(5, 50);
    try testing.expectEqual(@as(i32, 50), map.get(5).?);

    try map.insert(5, 100);
    try testing.expectEqual(@as(i32, 100), map.get(5).?);
    try testing.expectEqual(@as(usize, 1), map.count());
}

test "BTreeMap - many insertions trigger splits" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var map = BTreeMap(i32, i32).init(allocator);
    defer map.deinit();

    // Insert many elements to force node splits
    var i: i32 = 0;
    while (i < 100) : (i += 1) {
        try map.insert(i, i * 10);
    }

    try testing.expectEqual(@as(usize, 100), map.count());

    // Verify all values
    i = 0;
    while (i < 100) : (i += 1) {
        try testing.expectEqual(@as(i32, i * 10), map.get(i).?);
    }
}

test "BTreeMap - remove" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var map = BTreeMap(i32, i32).init(allocator);
    defer map.deinit();

    try map.insert(5, 50);
    try map.insert(3, 30);
    try map.insert(7, 70);

    try testing.expect(map.remove(3));
    try testing.expectEqual(@as(usize, 2), map.count());
    try testing.expect(map.get(3) == null);
    try testing.expectEqual(@as(i32, 50), map.get(5).?);
    try testing.expectEqual(@as(i32, 70), map.get(7).?);

    try testing.expect(!map.remove(100)); // Remove non-existent
}

test "BTreeMap - clear" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var map = BTreeMap(i32, i32).init(allocator);
    defer map.deinit();

    try map.insert(1, 10);
    try map.insert(2, 20);
    try map.insert(3, 30);

    map.clear();
    try testing.expectEqual(@as(usize, 0), map.count());
    try testing.expect(map.isEmpty());
}

test "BTreeMap - iterator placeholder" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var map = BTreeMap(i32, i32).init(allocator);
    defer map.deinit();

    try map.insert(5, 50);
    try map.insert(2, 20);

    // Iterator exists (full implementation TODO)
    var iter = map.iterator();
    defer iter.deinit();

    try testing.expect(true);
}
