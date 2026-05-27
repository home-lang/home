//! Faithful re-implementation of the pre-0.17 `std.SinglyLinkedList(T)`
//! node-embedding shape, which the stdlib dropped in the Zig 0.15+/0.17
//! container rework. Bun's `parsers/json.zig` `HashMapPool` recycles
//! duplicate-key hash maps through this exact API (`prepend` / `popFirst`
//! over `Node`s that embed their `data`), so the resolver/macro/PM cone needs
//! it under `bun.deprecated.SinglyLinkedList`.
//!
//! Kept in its own module (rather than alongside the other `bun.deprecated`
//! helpers) so importers don't eagerly parse `bun_core/deprecated.zig`, whose
//! RapidHash test body still trips the pinned Zig 0.17.0-dev.263 `**`
//! tokenizer bug.

/// A singly-linked list is headed by a single forward pointer. The elements
/// are singly-linked for minimum space and pointer manipulation overhead at
/// the expense of O(n) removal for arbitrary elements. New elements can be
/// added to the list after an existing element or at the head of the list.
/// A singly-linked list may only be traversed in the forward direction.
pub fn SinglyLinkedList(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Node inside the linked list wrapping the actual data.
        pub const Node = struct {
            next: ?*Node = null,
            data: T,

            pub const Data = T;

            /// Insert a new node after the current one.
            pub fn insertAfter(self: *Node, new_node: *Node) void {
                new_node.next = self.next;
                self.next = new_node;
            }

            /// Remove the node after this one, returning it (or null).
            pub fn removeNext(self: *Node) ?*Node {
                const next_node = self.next orelse return null;
                self.next = next_node.next;
                return next_node;
            }

            /// Iterate forward until the final node is found. O(N).
            pub fn findLast(self: *Node) *Node {
                var it = self;
                while (true) {
                    it = it.next orelse return it;
                }
            }

            /// Count all nodes after this one (excluding self). O(N).
            pub fn countChildren(self: *const Node) usize {
                var count: usize = 0;
                var it: ?*const Node = self.next;
                while (it) |n| : (it = n.next) {
                    count += 1;
                }
                return count;
            }

            /// Reverse the list starting from this node in-place. O(N).
            pub fn reverse(indirect: *?*Node) void {
                if (indirect.* == null) {
                    return;
                }
                var current: *Node = indirect.*.?;
                while (current.next) |next| {
                    current.next = next.next;
                    next.next = indirect.*;
                    indirect.* = next;
                }
            }
        };

        first: ?*Node = null,

        /// Insert a new node at the head.
        pub fn prepend(list: *Self, new_node: *Node) void {
            new_node.next = list.first;
            list.first = new_node;
        }

        /// Remove a node from the list. O(N).
        pub fn remove(list: *Self, target: *Node) void {
            if (list.first == target) {
                list.first = target.next;
            } else {
                var current_elm = list.first.?;
                while (current_elm.next != target) {
                    current_elm = current_elm.next.?;
                }
                current_elm.next = target.next;
            }
        }

        /// Remove and return the first node in the list.
        pub fn popFirst(list: *Self) ?*Node {
            const first = list.first orelse return null;
            list.first = first.next;
            return first;
        }

        /// Count all nodes in the list. O(N).
        pub fn len(list: Self) usize {
            if (list.first) |n| {
                return 1 + n.countChildren();
            } else {
                return 0;
            }
        }
    };
}

const std = @import("std");
const testing = std.testing;

test "SinglyLinkedList basic operations" {
    const L = SinglyLinkedList(u32);
    var list = L{};

    try testing.expectEqual(@as(usize, 0), list.len());

    var one = L.Node{ .data = 1 };
    var two = L.Node{ .data = 2 };
    var three = L.Node{ .data = 3 };
    var four = L.Node{ .data = 4 };
    var five = L.Node{ .data = 5 };

    list.prepend(&two); // {2}
    two.insertAfter(&five); // {2, 5}
    list.prepend(&one); // {1, 2, 5}
    two.insertAfter(&three); // {1, 2, 3, 5}
    three.insertAfter(&four); // {1, 2, 3, 4, 5}

    try testing.expectEqual(@as(usize, 5), list.len());

    // Traverse forwards verifying order.
    {
        var it = list.first;
        var index: u32 = 1;
        while (it) |node| : (it = node.next) {
            try testing.expectEqual(index, node.data);
            index += 1;
        }
    }

    try testing.expectEqual(@as(u32, 5), list.first.?.findLast().data);
    try testing.expectEqual(@as(usize, 4), list.first.?.countChildren());

    _ = list.popFirst(); // {2, 3, 4, 5}
    list.remove(&five); // {2, 3, 4}
    _ = two.removeNext(); // {2, 4}

    try testing.expectEqual(@as(u32, 2), list.first.?.data);
    try testing.expectEqual(@as(u32, 4), list.first.?.next.?.data);
    try testing.expect(list.first.?.next.?.next == null);

    L.Node.reverse(&list.first);

    try testing.expectEqual(@as(u32, 4), list.first.?.data);
    try testing.expectEqual(@as(u32, 2), list.first.?.next.?.data);
    try testing.expect(list.first.?.next.?.next == null);
}

test "SinglyLinkedList matches the HashMapPool LIFO recycle pattern" {
    // Mirrors how parsers/json.zig recycles duplicate-key hash maps: a LIFO
    // free list keyed on `Node.data`.
    const Counter = struct { hits: u32 = 0 };
    const L = SinglyLinkedList(Counter);
    var pool = L{};

    var a = L.Node{ .data = .{ .hits = 10 } };
    var b = L.Node{ .data = .{ .hits = 20 } };

    pool.prepend(&a);
    pool.prepend(&b);

    // popFirst returns the most-recently prepended node (LIFO).
    const first = pool.popFirst().?;
    try testing.expectEqual(@as(u32, 20), first.data.hits);
    const second = pool.popFirst().?;
    try testing.expectEqual(@as(u32, 10), second.data.hits);
    try testing.expect(pool.popFirst() == null);
}

test "SinglyLinkedList.remove on head and interior nodes" {
    const L = SinglyLinkedList(u8);
    var list = L{};

    var a = L.Node{ .data = 'a' };
    var b = L.Node{ .data = 'b' };
    var c = L.Node{ .data = 'c' };

    list.prepend(&c);
    list.prepend(&b);
    list.prepend(&a); // {a, b, c}

    list.remove(&a); // head removal -> {b, c}
    try testing.expectEqual(@as(u8, 'b'), list.first.?.data);

    list.remove(&c); // tail removal -> {b}
    try testing.expectEqual(@as(u8, 'b'), list.first.?.data);
    try testing.expect(list.first.?.next == null);

    list.remove(&b); // last node -> {}
    try testing.expect(list.first == null);
    try testing.expectEqual(@as(usize, 0), list.len());
}
