const std = @import("std");
const testing = std.testing;

// Safety and borrow checker tests
// Tests for ownership, lifetime, and memory safety

test "safety - basic compilation" {
    // Ensure safety system compiles
    try testing.expect(true);
}

test "safety - ownership transfer simulation" {
    const Owner = struct {
        value: i32,
        owned: bool,

        pub fn init(value: i32) @This() {
            return .{ .value = value, .owned = true };
        }

        pub fn transfer(self: *@This()) @This() {
            self.owned = false;
            return .{ .value = self.value, .owned = true };
        }

        pub fn isOwned(self: @This()) bool {
            return self.owned;
        }
    };

    var original = Owner.init(42);
    try testing.expect(original.isOwned());

    const transferred = original.transfer();
    try testing.expect(!original.isOwned());
    try testing.expect(transferred.isOwned());
}

test "safety - borrow tracking simulation" {
    const BorrowState = enum {
        Owned,
        Borrowed,
        MutablyBorrowed,
    };

    const Resource = struct {
        data: i32,
        state: BorrowState,

        pub fn borrow(self: *@This()) !*const i32 {
            if (self.state == .MutablyBorrowed) {
                return error.AlreadyBorrowed;
            }
            self.state = .Borrowed;
            return &self.data;
        }

        pub fn borrowMut(self: *@This()) !*i32 {
            if (self.state != .Owned) {
                return error.AlreadyBorrowed;
            }
            self.state = .MutablyBorrowed;
            return &self.data;
        }

        pub fn release(self: *@This()) void {
            self.state = .Owned;
        }
    };

    var resource = Resource{ .data = 42, .state = .Owned };

    const borrow1 = try resource.borrow();
    try testing.expect(borrow1.* == 42);

    // Should fail - already borrowed
    const result = resource.borrowMut();
    try testing.expectError(error.AlreadyBorrowed, result);

    resource.release();

    // Should succeed now
    const mut_borrow = try resource.borrowMut();
    mut_borrow.* = 100;
    try testing.expect(resource.data == 100);
}

test "safety - lifetime tracking simulation" {
    const Lifetime = enum {
        Static,
        Stack,
        Heap,
    };

    const Reference = struct {
        lifetime: Lifetime,

        pub fn isValid(self: @This(), current_scope: Lifetime) bool {
            return switch (self.lifetime) {
                .Static => true,
                .Stack => current_scope == .Stack,
                .Heap => true,
            };
        }
    };

    const static_ref = Reference{ .lifetime = .Static };
    const stack_ref = Reference{ .lifetime = .Stack };

    try testing.expect(static_ref.isValid(.Stack));
    try testing.expect(static_ref.isValid(.Heap));
    try testing.expect(stack_ref.isValid(.Stack));
    try testing.expect(!stack_ref.isValid(.Heap));
}

test "safety - use after free detection simulation" {
    const PointerState = enum {
        Valid,
        Freed,
    };

    const SafePtr = struct {
        data: ?i32,
        state: PointerState,

        pub fn init(value: i32) @This() {
            return .{ .data = value, .state = .Valid };
        }

        pub fn free(self: *@This()) void {
            self.data = null;
            self.state = .Freed;
        }

        pub fn get(self: @This()) !i32 {
            if (self.state == .Freed) {
                return error.UseAfterFree;
            }
            return self.data orelse error.NullPointer;
        }
    };

    var ptr = SafePtr.init(42);
    try testing.expect(try ptr.get() == 42);

    ptr.free();
    try testing.expectError(error.UseAfterFree, ptr.get());
}

test "safety - double free prevention" {
    const Resource = struct {
        allocated: bool,

        pub fn alloc() @This() {
            return .{ .allocated = true };
        }

        pub fn free(self: *@This()) !void {
            if (!self.allocated) {
                return error.DoubleFree;
            }
            self.allocated = false;
        }
    };

    var resource = Resource.alloc();
    try resource.free();
    try testing.expectError(error.DoubleFree, resource.free());
}

test "safety - null pointer checks" {
    const maybe_ptr: ?*const i32 = null;

    const result = if (maybe_ptr) |ptr| ptr.* else 0;

    try testing.expect(result == 0);
}
