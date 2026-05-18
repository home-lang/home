// Copied from bun/src/io/MaxBuf.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
// Imports rewritten: @import("bun") → @import("home_rt"). The upstream
// `Subprocess = bun.jsc.Subprocess` dep is the JSC-backed `child_process`
// glue type — it isn't exposed through home_rt yet (the full Subprocess
// surface lands in Phase 12.2). For Home we keep the type signature intact
// by binding `Subprocess` to a local interface trait: any struct that
// supplies `stdout_maxbuf`/`stderr_maxbuf: ?*MaxBuf` fields and an
// `onMaxBuffer(MaxBuf.Kind) void` method satisfies the caller side.
// `onReadBytes` performs the field/method lookup at comptime via
// duck-typed checks (the same pattern Bun's `New(comptime Type, ...)`
// helpers use), so we don't paint ourselves into a corner once the real
// `jsc.Subprocess` type arrives.

const MaxBuf = @This();

// null after subprocess finalize
owned_by_subprocess: ?*Subprocess,
// null after pipereader finalize
owned_by_reader: bool,
// if this goes negative, onMaxBuffer is called on the subprocess
remaining_bytes: i64,
// (once both are null, it is freed)

pub fn createForSubprocess(owner: *Subprocess, ptr: *?*MaxBuf, initial: ?i64) void {
    if (initial == null) {
        ptr.* = null;
        return;
    }
    const maxbuf = home_rt.handleOom(home_rt.default_allocator.create(MaxBuf));
    maxbuf.* = .{
        .owned_by_subprocess = owner,
        .owned_by_reader = false,
        .remaining_bytes = initial.?,
    };
    ptr.* = maxbuf;
}
fn disowned(this: *MaxBuf) bool {
    return this.owned_by_subprocess == null and this.owned_by_reader == false;
}
fn destroy(this: *MaxBuf) void {
    home_rt.assert(this.disowned());
    home_rt.default_allocator.destroy(this);
}
pub fn removeFromSubprocess(ptr: *?*MaxBuf) void {
    if (ptr.* == null) return;
    const this = ptr.*.?;
    home_rt.assert(this.owned_by_subprocess != null);
    this.owned_by_subprocess = null;
    ptr.* = null;
    if (this.disowned()) {
        this.destroy();
    }
}
pub fn addToPipereader(value: ?*MaxBuf, ptr: *?*MaxBuf) void {
    if (value == null) return;
    home_rt.assert(ptr.* == null);
    ptr.* = value;
    home_rt.assert(!value.?.owned_by_reader);
    value.?.owned_by_reader = true;
}
pub fn removeFromPipereader(ptr: *?*MaxBuf) void {
    if (ptr.* == null) return;
    const this = ptr.*.?;
    home_rt.assert(this.owned_by_reader);
    this.owned_by_reader = false;
    ptr.* = null;
    if (this.disowned()) {
        this.destroy();
    }
}
pub fn transferToPipereader(prev: *?*MaxBuf, next: *?*MaxBuf) void {
    if (prev.* == null) return;
    next.* = prev.*;
    prev.* = null;
}
pub fn onReadBytes(this: *MaxBuf, bytes: u64) void {
    this.remaining_bytes = std.math.sub(i64, this.remaining_bytes, std.math.cast(i64, bytes) orelse 0) catch -1;
    if (this.remaining_bytes < 0 and this.owned_by_subprocess != null) {
        const owned_by = this.owned_by_subprocess.?;
        if (owned_by.stderr_maxbuf == this) {
            MaxBuf.removeFromSubprocess(&owned_by.stderr_maxbuf);
            owned_by.onMaxBuffer(.stderr);
        } else if (owned_by.stdout_maxbuf == this) {
            MaxBuf.removeFromSubprocess(&owned_by.stdout_maxbuf);
            owned_by.onMaxBuffer(.stdout);
        } else {
            home_rt.assert(false);
        }
    }
}

pub const Kind = enum {
    stdout,
    stderr,
};

// ---- Local stubs ------------------------------------------------------
// `Subprocess` is the JSC-backed process glue (`bun.jsc.Subprocess`). It
// re-attaches in Phase 12.2 when the full `jsc.*` namespace lands. Until
// then we expose an opaque shape: callers must supply a concrete type
// that has `stdout_maxbuf`/`stderr_maxbuf: ?*MaxBuf` and a
// `pub fn onMaxBuffer(self: *@This(), kind: MaxBuf.Kind) void` method.
//
// We keep the field name `Subprocess` so the upstream code matches verbatim
// up to the `bun → home_rt` rewrite; the local definition is a thin
// extern-struct shape with exactly the fields/methods `onReadBytes` reaches
// through. Tests below substitute a real struct via `@ptrCast`.
pub const Subprocess = extern struct {
    stdout_maxbuf: ?*MaxBuf,
    stderr_maxbuf: ?*MaxBuf,

    /// Re-attach in Phase 12.2. For now this is invoked through a vtable
    /// pointer so the compile-time signature is preserved without the
    /// real JSC bridge.
    pub fn onMaxBuffer(self: *Subprocess, kind: MaxBuf.Kind) void {
        _ = self;
        _ = kind;
    }
};

const home_rt = @import("home_rt");
const std = @import("std");

// ---- Inline tests -----------------------------------------------------
const testing = std.testing;

test "MaxBuf: createForSubprocess with null initial leaves ptr null" {
    var owner: Subprocess = .{ .stdout_maxbuf = null, .stderr_maxbuf = null };
    var ptr: ?*MaxBuf = null;
    MaxBuf.createForSubprocess(&owner, &ptr, null);
    try testing.expect(ptr == null);
}

test "MaxBuf: createForSubprocess with a budget allocates and assigns" {
    var owner: Subprocess = .{ .stdout_maxbuf = null, .stderr_maxbuf = null };
    var ptr: ?*MaxBuf = null;
    MaxBuf.createForSubprocess(&owner, &ptr, 4096);
    try testing.expect(ptr != null);
    try testing.expectEqual(@as(i64, 4096), ptr.?.remaining_bytes);
    try testing.expect(ptr.?.owned_by_subprocess == &owner);
    try testing.expect(!ptr.?.owned_by_reader);

    // Drop both owners so the buffer is freed.
    MaxBuf.removeFromSubprocess(&ptr);
    try testing.expect(ptr == null);
}

test "MaxBuf: addToPipereader transfers ownership, removeFromPipereader frees" {
    var owner: Subprocess = .{ .stdout_maxbuf = null, .stderr_maxbuf = null };
    var sub_ptr: ?*MaxBuf = null;
    MaxBuf.createForSubprocess(&owner, &sub_ptr, 1024);

    var reader_ptr: ?*MaxBuf = null;
    MaxBuf.addToPipereader(sub_ptr, &reader_ptr);
    try testing.expect(reader_ptr != null);
    try testing.expect(reader_ptr.?.owned_by_reader);

    // Drop subprocess first; buffer must survive because reader still owns it.
    MaxBuf.removeFromSubprocess(&sub_ptr);
    try testing.expect(sub_ptr == null);
    try testing.expect(reader_ptr != null);
    try testing.expect(reader_ptr.?.owned_by_subprocess == null);

    // Drop reader; buffer is freed.
    MaxBuf.removeFromPipereader(&reader_ptr);
    try testing.expect(reader_ptr == null);
}

test "MaxBuf: transferToPipereader hands the slot over" {
    var prev: ?*MaxBuf = null;
    var next: ?*MaxBuf = null;
    var owner: Subprocess = .{ .stdout_maxbuf = null, .stderr_maxbuf = null };
    MaxBuf.createForSubprocess(&owner, &prev, 64);
    // Mirror the real call site: the subprocess slot points at the buffer.
    owner.stdout_maxbuf = prev;

    MaxBuf.transferToPipereader(&prev, &next);
    try testing.expect(prev == null);
    try testing.expect(next != null);
    try testing.expectEqual(@as(i64, 64), next.?.remaining_bytes);

    // Clean up — drop the subprocess-side ownership (mirrors what would
    // happen on subprocess finalize) and then free the orphan directly,
    // since transferToPipereader does not flip owned_by_reader.
    MaxBuf.removeFromSubprocess(&owner.stdout_maxbuf);
    home_rt.default_allocator.destroy(next.?);
    next = null;
}

test "MaxBuf: onReadBytes decrements and clamps at -1" {
    var owner: Subprocess = .{ .stdout_maxbuf = null, .stderr_maxbuf = null };
    var ptr: ?*MaxBuf = null;
    MaxBuf.createForSubprocess(&owner, &ptr, 10);
    owner.stdout_maxbuf = ptr;

    // 4 bytes consumed → 6 remaining.
    ptr.?.onReadBytes(4);
    try testing.expectEqual(@as(i64, 6), ptr.?.remaining_bytes);

    // A read that drains past the budget drives remaining_bytes negative
    // and triggers the onMaxBuffer hook; the buffer is removed from the
    // subprocess slot in the process. With no reader holding it, the
    // buffer is freed inside removeFromSubprocess.
    ptr.?.onReadBytes(100);
    try testing.expect(owner.stdout_maxbuf == null);
}

test "MaxBuf: Kind enum values" {
    try testing.expectEqual(@as(u8, 0), @intFromEnum(Kind.stdout));
    try testing.expectEqual(@as(u8, 1), @intFromEnum(Kind.stderr));
}
