// LinkedList Implementation for Home Language
// Doubly-linked list with safe node reference handling

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Generic doubly-linked list implementation
pub fn LinkedList(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Node in the linked list
        pub const Node = struct {
            data: T,
            prev: ?*Node,
            next: ?*Node,
        };

        allocator: Allocator,
        head: ?*Node,
        tail: ?*Node,
        len: usize,

        /// Initialize an empty linked list
        pub fn init(allocator: Allocator) Self {
            return Self{
                .allocator = allocator,
                .head = null,
                .tail = null,
                .len = 0,
            };
        }

        /// Clean up all nodes
        pub fn deinit(self: *Self) void {
            var current = self.head;
            while (current) |node| {
                const next = node.next;
                self.allocator.destroy(node);
                current = next;
            }
            self.* = undefined;
        }

        /// Add element to the front
        pub fn pushFront(self: *Self, value: T) !void {
            const node = try self.allocator.create(Node);
            node.* = Node{
                .data = value,
                .prev = null,
                .next = self.head,
            };

            if (self.head) |head| {
                head.prev = node;
            } else {
                self.tail = node;
            }

            self.head = node;
            self.len += 1;
        }

        /// Add element to the back
        pub fn pushBack(self: *Self, value: T) !void {
            const node = try self.allocator.create(Node);
            node.* = Node{
                .data = value,
                .prev = self.tail,
                .next = null,
            };

            if (self.tail) |tail| {
                tail.next = node;
            } else {
                self.head = node;
            }

            self.tail = node;
            self.len += 1;
        }

        /// Remove and return element from the front
        pub fn popFront(self: *Self) ?T {
            const head = self.head orelse return null;
            const value = head.data;

            self.head = head.next;
            if (self.head) |new_head| {
                new_head.prev = null;
            } else {
                self.tail = null;
            }

            self.allocator.destroy(head);
            self.len -= 1;
            return value;
        }

        /// Remove and return element from the back
        pub fn popBack(self: *Self) ?T {
            const tail = self.tail orelse return null;
            const value = tail.data;

            self.tail = tail.prev;
            if (self.tail) |new_tail| {
                new_tail.next = null;
            } else {
                self.head = null;
            }

            self.allocator.destroy(tail);
            self.len -= 1;
            return value;
        }

        /// Get first element without removing
        pub fn peekFront(self: *const Self) ?T {
            if (self.head) |head| {
                return head.data;
            }
            return null;
        }

        /// Get last element without removing
        pub fn peekBack(self: *const Self) ?T {
            if (self.tail) |tail| {
                return tail.data;
            }
            return null;
        }

        /// Insert after a given node
        pub fn insertAfter(self: *Self, node: *Node, value: T) !void {
            const new_node = try self.allocator.create(Node);
            new_node.* = Node{
                .data = value,
                .prev = node,
                .next = node.next,
            };

            if (node.next) |next| {
                next.prev = new_node;
            } else {
                self.tail = new_node;
            }

            node.next = new_node;
            self.len += 1;
        }

        /// Insert before a given node
        pub fn insertBefore(self: *Self, node: *Node, value: T) !void {
            const new_node = try self.allocator.create(Node);
            new_node.* = Node{
                .data = value,
                .prev = node.prev,
                .next = node,
            };

            if (node.prev) |prev| {
                prev.next = new_node;
            } else {
                self.head = new_node;
            }

            node.prev = new_node;
            self.len += 1;
        }

        /// Remove a specific node
        pub fn remove(self: *Self, node: *Node) void {
            if (node.prev) |prev| {
                prev.next = node.next;
            } else {
                self.head = node.next;
            }

            if (node.next) |next| {
                next.prev = node.prev;
            } else {
                self.tail = node.prev;
            }

            self.allocator.destroy(node);
            self.len -= 1;
        }

        /// Get the number of elements
        pub fn length(self: *const Self) usize {
            return self.len;
        }

        /// Check if the list is empty
        pub fn isEmpty(self: *const Self) bool {
            return self.len == 0;
        }

        /// Clear all elements
        pub fn clear(self: *Self) void {
            var current = self.head;
            while (current) |node| {
                const next = node.next;
                self.allocator.destroy(node);
                current = next;
            }
            self.head = null;
            self.tail = null;
            self.len = 0;
        }

        /// Forward iterator
        pub const Iterator = struct {
            current: ?*Node,

            pub fn next(it: *Iterator) ?T {
                if (it.current) |node| {
                    const value = node.data;
                    it.current = node.next;
                    return value;
                }
                return null;
            }
        };

        /// Get forward iterator
        pub fn iterator(self: *const Self) Iterator {
            return Iterator{ .current = self.head };
        }

        /// Backward iterator
        pub const ReverseIterator = struct {
            current: ?*Node,

            pub fn next(it: *ReverseIterator) ?T {
                if (it.current) |node| {
                    const value = node.data;
                    it.current = node.prev;
                    return value;
                }
                return null;
            }
        };

        /// Get backward iterator
        pub fn reverseIterator(self: *const Self) ReverseIterator {
            return ReverseIterator{ .current = self.tail };
        }
    };
}

// =================================================================================
//                                    TESTS
// =================================================================================

test "LinkedList - init and deinit" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var list = LinkedList(i32).init(allocator);
    defer list.deinit();

    try testing.expectEqual(@as(usize, 0), list.length());
    try testing.expect(list.isEmpty());
}

test "LinkedList - pushFront and popFront" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var list = LinkedList(i32).init(allocator);
    defer list.deinit();

    try list.pushFront(1);
    try list.pushFront(2);
    try list.pushFront(3);

    try testing.expectEqual(@as(usize, 3), list.length());

    try testing.expectEqual(@as(?i32, 3), list.popFront());
    try testing.expectEqual(@as(?i32, 2), list.popFront());
    try testing.expectEqual(@as(?i32, 1), list.popFront());
    try testing.expectEqual(@as(?i32, null), list.popFront());
}

test "LinkedList - pushBack and popBack" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var list = LinkedList(i32).init(allocator);
    defer list.deinit();

    try list.pushBack(1);
    try list.pushBack(2);
    try list.pushBack(3);

    try testing.expectEqual(@as(usize, 3), list.length());

    try testing.expectEqual(@as(?i32, 3), list.popBack());
    try testing.expectEqual(@as(?i32, 2), list.popBack());
    try testing.expectEqual(@as(?i32, 1), list.popBack());
    try testing.expectEqual(@as(?i32, null), list.popBack());
}

test "LinkedList - peek operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var list = LinkedList(i32).init(allocator);
    defer list.deinit();

    try testing.expectEqual(@as(?i32, null), list.peekFront());
    try testing.expectEqual(@as(?i32, null), list.peekBack());

    try list.pushBack(1);
    try list.pushBack(2);
    try list.pushBack(3);

    try testing.expectEqual(@as(?i32, 1), list.peekFront());
    try testing.expectEqual(@as(?i32, 3), list.peekBack());

    // Ensure peek doesn't remove
    try testing.expectEqual(@as(usize, 3), list.length());
}

test "LinkedList - insertAfter" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var list = LinkedList(i32).init(allocator);
    defer list.deinit();

    try list.pushBack(1);
    try list.pushBack(3);

    // Insert 2 after first node
    if (list.head) |node| {
        try list.insertAfter(node, 2);
    }

    try testing.expectEqual(@as(usize, 3), list.length());
    try testing.expectEqual(@as(?i32, 1), list.popFront());
    try testing.expectEqual(@as(?i32, 2), list.popFront());
    try testing.expectEqual(@as(?i32, 3), list.popFront());
}

test "LinkedList - insertBefore" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var list = LinkedList(i32).init(allocator);
    defer list.deinit();

    try list.pushBack(1);
    try list.pushBack(3);

    // Insert 2 before last node
    if (list.tail) |node| {
        try list.insertBefore(node, 2);
    }

    try testing.expectEqual(@as(usize, 3), list.length());
    try testing.expectEqual(@as(?i32, 1), list.popFront());
    try testing.expectEqual(@as(?i32, 2), list.popFront());
    try testing.expectEqual(@as(?i32, 3), list.popFront());
}

test "LinkedList - remove" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var list = LinkedList(i32).init(allocator);
    defer list.deinit();

    try list.pushBack(1);
    try list.pushBack(2);
    try list.pushBack(3);

    // Remove middle element
    if (list.head) |head| {
        if (head.next) |middle| {
            list.remove(middle);
        }
    }

    try testing.expectEqual(@as(usize, 2), list.length());
    try testing.expectEqual(@as(?i32, 1), list.popFront());
    try testing.expectEqual(@as(?i32, 3), list.popFront());
}

test "LinkedList - clear" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var list = LinkedList(i32).init(allocator);
    defer list.deinit();

    try list.pushBack(1);
    try list.pushBack(2);
    try list.pushBack(3);

    list.clear();

    try testing.expectEqual(@as(usize, 0), list.length());
    try testing.expect(list.isEmpty());
}

test "LinkedList - forward iterator" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var list = LinkedList(i32).init(allocator);
    defer list.deinit();

    try list.pushBack(1);
    try list.pushBack(2);
    try list.pushBack(3);

    var iter = list.iterator();
    try testing.expectEqual(@as(?i32, 1), iter.next());
    try testing.expectEqual(@as(?i32, 2), iter.next());
    try testing.expectEqual(@as(?i32, 3), iter.next());
    try testing.expectEqual(@as(?i32, null), iter.next());
}

test "LinkedList - reverse iterator" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var list = LinkedList(i32).init(allocator);
    defer list.deinit();

    try list.pushBack(1);
    try list.pushBack(2);
    try list.pushBack(3);

    var iter = list.reverseIterator();
    try testing.expectEqual(@as(?i32, 3), iter.next());
    try testing.expectEqual(@as(?i32, 2), iter.next());
    try testing.expectEqual(@as(?i32, 1), iter.next());
    try testing.expectEqual(@as(?i32, null), iter.next());
}

test "LinkedList - mixed operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var list = LinkedList(i32).init(allocator);
    defer list.deinit();

    try list.pushFront(2);
    try list.pushBack(3);
    try list.pushFront(1);
    try list.pushBack(4);

    try testing.expectEqual(@as(usize, 4), list.length());
    try testing.expectEqual(@as(?i32, 1), list.peekFront());
    try testing.expectEqual(@as(?i32, 4), list.peekBack());

    _ = list.popFront();
    _ = list.popBack();

    try testing.expectEqual(@as(usize, 2), list.length());
    try testing.expectEqual(@as(?i32, 2), list.popFront());
    try testing.expectEqual(@as(?i32, 3), list.popFront());
}
