// Copied from bun/src/threading/guarded.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
// Imports rewritten: @import("bun") → @import("home").
// Rewrites:
//   * `bun.threading.Mutex` → local `@import("./Mutex.zig")`.
//   * `bun.safety.ThreadLock` → `home_rt.safety.ThreadLock`.
//   * `bun.memory.initDefault(T)` / `bun.memory.deinit(*T)` are stubbed
//     locally because `home_rt` does not yet expose `home_rt.memory`.
//     - `initDefault` returns `.{}` for default-initializable structs
//       (the only kind upstream uses with this helper).
//     - `deinit` calls `T.deinit(*T)` when present, otherwise does
//       nothing.
//     Re-attach to `home_rt.memory.*` once the memory namespace lands.
//   * Upstream uses `#mutex` (private field syntax). Home is on
//     Zig 0.17.0-dev.263 which still rejects `#`-prefixed identifiers as
//     fields, so we rename to plain `mtx`.
//
// Guarded is a tiny Mutex+Value wrapper. The lock-shape comes directly
// from kprotty's gist (see `unbounded_queue.zig` for the same notice).

/// A wrapper around a mutex, and a value protected by the mutex.
/// This type uses Home's Mutex internally.
pub fn Guarded(comptime Value: type) type {
    return GuardedBy(Value, Mutex);
}

/// A wrapper around a mutex, and a value protected by the mutex.
/// `MutexType` should have `lock` and `unlock` methods.
pub fn GuardedBy(comptime Value: type, comptime MutexType: type) type {
    return struct {
        const Self = @This();

        /// The raw value. Don't use this if there might be concurrent accesses.
        unsynchronized_value: Value,
        mtx: MutexType,

        /// Creates a guarded value with a default-initialized mutex.
        pub fn init(value: Value) Self {
            return .initWithMutex(value, memInitDefault(MutexType));
        }

        /// Creates a guarded value with the given mutex.
        pub fn initWithMutex(value: Value, mutex: MutexType) Self {
            return .{
                .unsynchronized_value = value,
                .mtx = mutex,
            };
        }

        /// Locks the mutex and returns a pointer to the value. Remember to call `unlock`!
        pub fn lock(self: *Self) *Value {
            self.mtx.lock();
            return &self.unsynchronized_value;
        }

        /// Unlocks the mutex. Don't use any pointers returned by `lock` after calling this method!
        pub fn unlock(self: *Self) void {
            self.mtx.unlock();
        }

        /// Returns the inner unprotected value.
        ///
        /// You must ensure that no other threads could be concurrently using `self`. This method
        /// invalidates `self`, so you must ensure `self` is not used on any thread after calling
        /// this method.
        pub fn intoUnprotected(self: *Self) Value {
            defer self.* = undefined;
            memDeinit(&self.mtx);
            return self.unsynchronized_value;
        }

        /// Deinitializes the inner value and mutex.
        ///
        /// You must ensure that no other threads could be concurrently using `self`. This method
        /// invalidates `self`.
        pub fn deinit(self: *Self) void {
            memDeinit(&self.unsynchronized_value);
            memDeinit(&self.mtx);
            self.* = undefined;
        }
    };
}

/// Uses `home_rt.safety.ThreadLock`.
pub fn Debug(comptime Value: type) type {
    return GuardedBy(Value, home_rt.safety.ThreadLock);
}

/// Stub for `bun.memory.initDefault`. Returns `T{}` for structs with all
/// fields defaulted (the only shape upstream needs here — `Mutex{}` and
/// `ThreadLock{}` both work).
inline fn memInitDefault(comptime T: type) T {
    return T{};
}

/// Stub for `bun.memory.deinit`. Calls `T.deinit(*T)` when present.
inline fn memDeinit(ptr: anytype) void {
    const T = @typeInfo(@TypeOf(ptr)).pointer.child;
    if (@hasDecl(T, "deinit")) {
        const D = @TypeOf(T.deinit);
        // Some upstream types declare `pub const deinit = void;` — skip those.
        if (@typeInfo(D) == .@"fn") {
            T.deinit(ptr);
        }
    }
}

test "Guarded: lock + unlock around plain u32" {
    var g: Guarded(u32) = .init(0);
    const ptr = g.lock();
    ptr.* = 7;
    g.unlock();
    try std.testing.expectEqual(@as(u32, 7), g.unsynchronized_value);
}

test "Guarded: intoUnprotected hands the value back" {
    var g: Guarded(u32) = .init(42);
    const v = g.intoUnprotected();
    try std.testing.expectEqual(@as(u32, 42), v);
}

test "GuardedBy: deinit dispatches to inner T.deinit when present" {
    const Inner = struct {
        ran: *bool,
        pub fn deinit(self: *@This()) void {
            self.ran.* = true;
        }
    };
    var did_run = false;
    var g: GuardedBy(Inner, Mutex) = .init(.{ .ran = &did_run });
    g.deinit();
    try std.testing.expect(did_run);
}

const home_rt = @import("home");
const Mutex = @import("./Mutex.zig");
const std = @import("std");
