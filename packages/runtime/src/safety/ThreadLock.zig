// Copied verbatim from bun/src/safety/ThreadLock.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// Debug-mode single-thread-affinity check. `enabled` follows
// `Environment.allow_assert` (Bun spells this `ci_assert`). The trace-printing
// branch is wired through `traces_enabled`, which we force to `false` until
// `home_rt.crash_handler.StoredTrace` + `dumpStackTrace` land — that keeps
// every reference to `StoredTrace.capture` / `StoredTrace.trace` behind a
// comptime-dead branch. `bun.assertf` is folded to plain `assert` (no
// formatted message), matching the surface `home_rt` currently exports.

const Self = @This();

owning_thread: if (enabled) Thread.Id else void,
locked_at: if (traces_enabled) StoredTrace else void = if (traces_enabled) StoredTrace.empty,

pub fn initUnlocked() Self {
    return .{ .owning_thread = if (comptime enabled) invalid_thread_id };
}

pub fn initLocked() Self {
    var self = Self.initUnlocked();
    self.lock();
    return self;
}

pub fn initLockedIfNonComptime() Self {
    return if (@inComptime()) .initUnlocked() else .initLocked();
}

pub fn lock(self: *Self) void {
    if (comptime !enabled) return;
    const current = Thread.getCurrentId();
    if (self.owning_thread != invalid_thread_id) {
        // stubbed: trace dump re-attaches when crash_handler.dumpStackTrace lands.
        if (comptime traces_enabled) {}
        std.debug.panic(
            "tried to lock `ThreadLock` on thread {}, but was already locked by thread {}",
            .{ current, self.owning_thread },
        );
    }
    self.owning_thread = current;
    if (comptime traces_enabled) {
        self.locked_at = StoredTrace.capture(@returnAddress());
    }
}

pub fn unlock(self: *Self) void {
    if (comptime !enabled) return;
    self.assertLocked();
    self.* = .initUnlocked();
}

pub fn assertLocked(self: *const Self) void {
    if (comptime !enabled) return;
    home_rt.assert(self.owning_thread != invalid_thread_id);
    const current = Thread.getCurrentId();
    home_rt.assert(self.owning_thread == current);
}

/// Acquires the lock if not already locked; otherwise, asserts that the current thread holds the
/// lock.
pub fn lockOrAssert(self: *Self) void {
    if (comptime !enabled) return;
    if (self.owning_thread == invalid_thread_id) {
        self.lock();
    } else {
        self.assertLocked();
    }
}

pub const enabled = home_rt.Environment.allow_assert;

const home_rt = @import("home");
const invalid_thread_id = @import("./thread_id.zig").invalid;
/// stubbed: re-attaches when home_rt.crash_handler.StoredTrace lands.
const StoredTrace = void;
/// stubbed: re-attaches when home_rt.crash_handler.dumpStackTrace lands. Keeping
/// this `false` keeps every `StoredTrace.capture` / `StoredTrace.trace` call
/// behind a comptime-dead branch.
const traces_enabled = false;

const std = @import("std");
const Thread = std.Thread;

test "ThreadLock: initUnlocked + lock + unlock roundtrips on the calling thread" {
    var lk: Self = .initUnlocked();
    lk.lock();
    lk.assertLocked();
    lk.unlock();
}

test "ThreadLock: lockOrAssert acquires when unlocked and is a no-op when held" {
    var lk: Self = .initUnlocked();
    lk.lockOrAssert();
    lk.lockOrAssert();
    lk.unlock();
}
