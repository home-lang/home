// Copied from bun/src/collections/pool.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
// Imports rewritten: @import("bun") → @import("home_rt").
// Rewrites:
//   * `bun.assert` → `home_rt.assert`.
//   * `bun.memory.deinit(&node.data)` and the `Type != bun.ByteList`
//     special-case in `destroyNode` are replaced with a thin pattern
//     that mirrors the upstream contract: if the pooled type defines
//     a `deinit` method, call it; otherwise the value is destroyed via
//     its owning allocator. `bun.ByteList` doesn't exist in Home yet —
//     when it lands the special-case can be restored verbatim.
//   * The Environment-gated assert in `push` is rewritten to read
//     `home_rt.Environment.allow_assert` directly so we don't have to
//     reach into Bun's bun_core/env.zig path.

fn SinglyLinkedList(comptime T: type, comptime Parent: type) type {
    return struct {
        const Self = @This();

        /// Node inside the linked list wrapping the actual data.
        pub const Node = struct {
            next: ?*Node = null,
            allocator: std.mem.Allocator,
            data: T,

            pub const Data = T;

            /// Insert a new node after the current one.
            ///
            /// Arguments:
            ///     new_node: Pointer to the new node to insert.
            pub fn insertAfter(node: *Node, new_node: *Node) void {
                new_node.next = node.next;
                node.next = new_node;
            }

            /// Remove a node from the list.
            ///
            /// Arguments:
            ///     node: Pointer to the node to be removed.
            /// Returns:
            ///     node removed
            pub fn removeNext(node: *Node) ?*Node {
                const next_node = node.next orelse return null;
                node.next = next_node.next;
                return next_node;
            }

            /// Iterate over the singly-linked list from this node, until the final node is found.
            /// This operation is O(N).
            pub fn findLast(node: *Node) *Node {
                var it = node;
                while (true) {
                    it = it.next orelse return it;
                }
            }

            /// Iterate over each next node, returning the count of all nodes except the starting one.
            /// This operation is O(N).
            pub fn countChildren(node: *const Node) usize {
                var count: usize = 0;
                var it: ?*const Node = node.next;
                while (it) |n| : (it = n.next) {
                    count += 1;
                }
                return count;
            }

            pub inline fn release(node: *Node) void {
                Parent.release(node);
            }
        };

        first: ?*Node = null,

        /// Insert a new node at the head.
        ///
        /// Arguments:
        ///     new_node: Pointer to the new node to insert.
        pub fn prepend(list: *Self, new_node: *Node) void {
            new_node.next = list.first;
            list.first = new_node;
        }

        /// Remove a node from the list.
        ///
        /// Arguments:
        ///     node: Pointer to the node to be removed.
        pub fn remove(list: *Self, node: *Node) void {
            if (list.first == node) {
                list.first = node.next;
            } else {
                var current_elm = list.first.?;
                while (current_elm.next != node) {
                    current_elm = current_elm.next.?;
                }
                current_elm.next = node.next;
            }
        }

        /// Remove and return the first node in the list.
        ///
        /// Returns:
        ///     A pointer to the first node in the list.
        pub fn popFirst(list: *Self) ?*Node {
            const first = list.first orelse return null;
            list.first = first.next;
            return first;
        }

        /// Iterate over all nodes, returning the count.
        /// This operation is O(N).
        pub fn len(list: Self) usize {
            if (list.first) |n| {
                return 1 + n.countChildren();
            } else {
                return 0;
            }
        }
    };
}

const log_allocations = false;

pub fn ObjectPool(
    comptime Type: type,
    comptime Init: (?fn (allocator: std.mem.Allocator) anyerror!Type),
    comptime threadsafe: bool,
    comptime max_count: comptime_int,
) type {
    return struct {
        const Pool = @This();
        const LinkedList = SinglyLinkedList(Type, Pool);
        pub const List = LinkedList;
        pub const Node = LinkedList.Node;
        const MaxCountInt = std.math.IntFittingRange(0, max_count);
        const DataStruct = struct {
            list: LinkedList = undefined,
            loaded: bool = false,
            count: MaxCountInt = 0,
        };

        // We want this to be global
        // but we don't want to create 3 global variables per pool
        // instead, we create one global variable per pool
        const DataStructNonThreadLocal = if (threadsafe) void else DataStruct;
        const DataStructThreadLocal = if (!threadsafe) void else DataStruct;
        threadlocal var data_threadlocal: DataStructThreadLocal = DataStructThreadLocal{};
        var data__: DataStructNonThreadLocal = DataStructNonThreadLocal{};
        inline fn data() *DataStruct {
            if (comptime threadsafe) {
                return &data_threadlocal;
            }

            if (comptime !threadsafe) {
                return &data__;
            }

            unreachable;
        }

        pub fn full() bool {
            if (comptime max_count == 0) return false;
            return data().loaded and data().count >= max_count;
        }

        pub fn has() bool {
            return data().loaded and data().list.first != null;
        }

        pub fn push(allocator: std.mem.Allocator, pooled: Type) void {
            if (comptime home_rt.Environment.allow_assert)
                home_rt.assert(!full());

            const new_node = allocator.create(LinkedList.Node) catch unreachable;
            new_node.* = LinkedList.Node{
                .allocator = allocator,
                .data = pooled,
            };
            release(new_node);
        }

        pub fn getIfExists() ?*LinkedList.Node {
            if (!data().loaded) {
                return null;
            }

            var node = data().list.popFirst() orelse return null;
            if (std.meta.hasFn(Type, "reset")) node.data.reset();
            if (comptime max_count > 0) data().count -|= 1;

            return node;
        }

        pub fn first(allocator: std.mem.Allocator) *Type {
            return &get(allocator).data;
        }

        pub fn get(allocator: std.mem.Allocator) *LinkedList.Node {
            if (data().loaded) {
                if (data().list.popFirst()) |node| {
                    if (comptime std.meta.hasFn(Type, "reset")) node.data.reset();
                    if (comptime max_count > 0) data().count -|= 1;
                    return node;
                }
            }

            if (comptime log_allocations) std.fs.File.stderr().writeAll(comptime std.fmt.comptimePrint("Allocate {s} - {d} bytes\n", .{ @typeName(Type), @sizeOf(Type) })) catch {};

            const new_node = allocator.create(LinkedList.Node) catch unreachable;
            new_node.* = LinkedList.Node{
                .allocator = allocator,
                .data = if (comptime Init) |init_|
                    (init_(
                        allocator,
                    ) catch unreachable)
                else
                    undefined,
            };

            return new_node;
        }

        pub fn releaseValue(value: *Type) void {
            @as(*LinkedList.Node, @fieldParentPtr("data", value)).release();
        }

        pub fn release(node: *LinkedList.Node) void {
            if (comptime max_count > 0) {
                if (data().count >= max_count) {
                    if (comptime log_allocations) std.fs.File.stderr().writeAll(comptime std.fmt.comptimePrint("Free {s} - {d} bytes\n", .{ @typeName(Type), @sizeOf(Type) })) catch {};
                    destroyNode(node);
                    return;
                }
            }

            if (comptime max_count > 0) data().count +|= 1;

            if (data().loaded) {
                data().list.prepend(node);
                return;
            }

            data().list = LinkedList{ .first = node };
            data().loaded = true;
        }

        pub fn deleteAll() void {
            var dat = data();
            if (!dat.loaded) {
                return;
            }
            dat.loaded = false;
            dat.count = 0;
            var next = dat.list.first;
            dat.list.first = null;
            while (next) |node| {
                next = node.next;
                destroyNode(node);
            }
        }

        fn destroyNode(node: *LinkedList.Node) void {
            // Upstream Bun has a `Type != bun.ByteList` carve-out here that
            // skips `bun.memory.deinit` for ByteListPool. Home doesn't have
            // a ByteList type yet, so the carve-out is moot — instead we
            // invoke `Type.deinit` directly when it exists, which mirrors
            // the recursive-deinit semantics of `bun.memory.deinit`.
            if (comptime std.meta.hasFn(Type, "deinit")) {
                node.data.deinit();
            }
            node.allocator.destroy(node);
        }
    };
}

test "ObjectPool reuses freed nodes" {
    const allocator = std.testing.allocator;
    const Pool = ObjectPool(u32, null, false, 16);

    Pool.deleteAll();
    defer Pool.deleteAll();

    const node_a = Pool.get(allocator);
    node_a.data = 42;
    const ptr_a = node_a;

    Pool.release(node_a);

    const node_b = Pool.get(allocator);
    // The pool should hand us back the same node we just released.
    try std.testing.expectEqual(ptr_a, node_b);

    Pool.release(node_b);
}

test "ObjectPool: getIfExists returns null on cold pool" {
    const Pool = ObjectPool(u8, null, false, 4);
    Pool.deleteAll();
    defer Pool.deleteAll();
    try std.testing.expect(Pool.getIfExists() == null);
    try std.testing.expect(!Pool.has());
}

test "ObjectPool: full() honours the comptime max_count cap" {
    const allocator = std.testing.allocator;
    const Pool = ObjectPool(u8, null, false, 2);
    Pool.deleteAll();
    defer Pool.deleteAll();

    try std.testing.expect(!Pool.full());
    const n1 = Pool.get(allocator);
    const n2 = Pool.get(allocator);
    Pool.release(n1);
    Pool.release(n2);
    try std.testing.expect(Pool.full());
}

const home_rt = @import("home_rt");
const std = @import("std");
