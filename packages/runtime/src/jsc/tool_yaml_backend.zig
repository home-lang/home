//! Arena-owned value storage for Home's shared native YAML parser.
//! Collection pointers retain alias identity. The allocator is scoped and
//! thread-local so independent callbacks never share parser storage.
const std = @import("std");

threadlocal var current_allocator: ?std.mem.Allocator = null;

pub const Scope = struct {
    previous: ?std.mem.Allocator,
    pub fn enter(allocator: std.mem.Allocator) Scope {
        const previous = current_allocator;
        current_allocator = allocator;
        return .{ .previous = previous };
    }
    pub fn deinit(self: Scope) void {
        current_allocator = self.previous;
    }
};

pub const OOM = std.mem.Allocator.Error;
pub const assert = std.debug.assert;
pub const logger = struct {
    pub const Loc = struct { start: i32 = 0 };
};
pub fn StringHashMap(comptime T: type) type {
    return std.StringHashMap(T);
}
pub fn throwStackOverflow() error{StackOverflow}!void {
    return error.StackOverflow;
}
pub const StackCheck = struct {
    base: usize,
    pub fn init() StackCheck {
        return .{ .base = @frameAddress() };
    }
    pub fn isSafeToRecurse(self: StackCheck) bool {
        const frame = @frameAddress();
        const distance = if (frame > self.base) frame - self.base else self.base - frame;
        return distance < 512 * 1024;
    }
};
pub const jsc = struct {
    // The shared parser's legacy numeric-decoder name; its backend here is
    // Zig's numeric parser and carries no engine value or ABI representation.
    pub const wtf = struct {
        pub fn parseDouble(input: []const u8) !f64 {
            return std.fmt.parseFloat(f64, input);
        }
    };
};

pub fn BabyList(comptime T: type) type {
    return struct {
        const Self = @This();
        storage: []T = &.{},
        len: usize = 0,
        pub fn initCapacity(allocator: std.mem.Allocator, capacity: usize) OOM!Self {
            return .{ .storage = try allocator.alloc(T, capacity) };
        }
        pub fn appendAssumeCapacity(self: *Self, item: T) void {
            self.storage[self.len] = item;
            self.len += 1;
        }
        pub fn slice(self: Self) []T {
            return self.storage[0..self.len];
        }
        pub fn moveFromList(list: anytype) Self {
            const raw = if (@hasField(@TypeOf(list.*), "inner")) &list.inner else list;
            const result: Self = .{ .storage = raw.items.ptr[0..raw.capacity], .len = raw.items.len };
            raw.items = &.{};
            raw.capacity = 0;
            return result;
        }
    };
}
pub const collections = struct {
    pub fn ArrayList(comptime T: type) type {
        return struct {
            const Self = @This();
            inner: std.array_list.Managed(T),
            pub fn initIn(allocator: std.mem.Allocator) Self {
                return .{ .inner = .init(allocator) };
            }
            pub fn items(self: *Self) []T {
                return self.inner.items;
            }
            pub fn append(self: *Self, item: T) OOM!void {
                try self.inner.append(item);
            }
            pub fn appendAssumeCapacity(self: *Self, item: T) void {
                self.inner.appendAssumeCapacity(item);
            }
            pub fn ensureUnusedCapacity(self: *Self, capacity: usize) OOM!void {
                try self.inner.ensureUnusedCapacity(capacity);
            }
        };
    }
};

pub const ast = struct {
    pub const E = struct {
        pub const Null = struct {};
        pub const Missing = struct {};
        pub const Boolean = struct { value: bool };
        pub const Number = struct { value: f64 };
        pub const String = struct {
            data: []const u8 = "",
            pub fn eql(self: *const String, comptime T: type, other: *const T) bool {
                return std.mem.eql(u8, self.data, other.data);
            }
            pub fn eqlComptime(self: *const String, comptime text: []const u8) bool {
                return std.mem.eql(u8, self.data, text);
            }
            pub fn hash(self: *const String) u64 {
                return std.hash.Wyhash.hash(0, self.data);
            }
        };
        pub const Array = struct { items: BabyList(Expr) = .{} };
        pub const Object = struct { properties: G.Property.List = .{} };
        pub fn ownKeyPropertyFlags(key: Expr) G.Property.Flags {
            return .{ .is_computed = key.data == .e_string and key.data.e_string.eqlComptime("__proto__") };
        }
    };
    pub const G = struct {
        pub const Property = struct {
            pub const List = BabyList(Property);
            pub const Flags = struct { is_computed: bool = false };
            key: ?Expr = null,
            value: ?Expr = null,
            flags: Flags = .{},
        };
    };
    pub const Expr = struct {
        loc: logger.Loc,
        data: union(enum) {
            e_null: E.Null,
            e_missing: E.Missing,
            e_boolean: E.Boolean,
            e_number: E.Number,
            e_string: *E.String,
            e_array: *E.Array,
            e_object: *E.Object,
        },
        pub fn init(comptime T: type, value: T, loc: logger.Loc) Expr {
            if (T == E.Null) return .{ .loc = loc, .data = .{ .e_null = value } };
            if (T == E.Boolean) return .{ .loc = loc, .data = .{ .e_boolean = value } };
            if (T == E.Number) return .{ .loc = loc, .data = .{ .e_number = value } };
            const allocator = current_allocator orelse @panic("YAML value allocation requires a parser scope");
            const pointer = allocator.create(T) catch @panic("Out of memory allocating YAML value");
            pointer.* = value;
            return .{ .loc = loc, .data = if (T == E.String) .{ .e_string = pointer } else if (T == E.Array) .{ .e_array = pointer } else if (T == E.Object) .{ .e_object = pointer } else @compileError("Unsupported YAML value kind") };
        }
    };
};
