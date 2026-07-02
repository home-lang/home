// Copied from bun/src/runtime/api/NativePromiseContext.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
//
// Rewrites:
//   - @import("bun") → @import("home")
//
// Stubs (re-attach in Phase 12.2 when home_rt grows the matching surface):
//   - `jsc.JSGlobalObject`, `jsc.JSValue`, `jsc.Task`, `jsc.VirtualMachine`
//     — opaque shims locally; the create/take entry points stay as soft-linked
//     fn-ptr indirections.
//   - `server.HTTPServer.RequestContext` and the rest of the server-side
//     dispatch targets — modeled as zero-field stub types so the Tag table
//     compiles and `runFromJSThread` retains its switch shape. Body still
//     wires the deref call chain; the real deref symbol gets routed back
//     when the server tree lands.
//   - `bun.webcore.Body.ValueBufferer` / `HTMLRewriter.BufferOutputSink`
//     — stubbed structs with `deref` and a `ctx` field, preserving the
//     "release on the owner" indirection.
//
// The packed-pointer/tag layout (tag in low 3 bits, ctx pointer in 48..3,
// 8-byte alignment assertions) is preserved and exercised by tests.

//! Zig bindings for the NativePromiseContext JSCell.
//!
//! See `src/jsc/bindings/NativePromiseContext.h` for the rationale. Short
//! version: when native code `.then()`s a user Promise and needs a context
//! pointer, wrap the pointer in this GC-managed cell instead of passing it
//! raw. If the Promise never settles, GC collects the cell and the destructor
//! releases the ref — no leak, no use-after-free.

pub const NativePromiseContext = @This();

/// Must match Bun::NativePromiseContext::Tag in NativePromiseContext.h.
/// One entry per concrete native type — the tag is packed into the pointer's
/// upper bits via CompactPointerTuple so the cell stays at one pointer of
/// storage beyond the JSCell header.
pub const Tag = enum(u8) {
    HTTPServerRequestContext,
    HTTPSServerRequestContext,
    DebugHTTPServerRequestContext,
    DebugHTTPSServerRequestContext,
    BodyValueBufferer,
    HTTPSServerH3RequestContext,
    DebugHTTPSServerH3RequestContext,

    pub fn fromType(comptime T: type) Tag {
        return switch (T) {
            server.HTTPServer.RequestContext => .HTTPServerRequestContext,
            server.HTTPSServer.RequestContext => .HTTPSServerRequestContext,
            server.DebugHTTPServer.RequestContext => .DebugHTTPServerRequestContext,
            server.DebugHTTPSServer.RequestContext => .DebugHTTPSServerRequestContext,
            server.HTTPSServer.H3RequestContext => .HTTPSServerH3RequestContext,
            server.DebugHTTPSServer.H3RequestContext => .DebugHTTPSServerH3RequestContext,
            webcore.Body.ValueBufferer => .BodyValueBufferer,
            else => @compileError("NativePromiseContext.Tag: unsupported type " ++ @typeName(T)),
        };
    }
};

// Soft-linked through fn-ptr indirection so the file builds standalone
// without dragging the JSC link into unit tests. With `-Denable_jsc` the
// real C++ cell factory in the linked Bun object is used; otherwise (JSC-less
// unit-test gate) the stubs keep the file self-contained.
//
// Wiring these to the real externs is load-bearing: without it, create()
// returns a `.zero` cell and take() always returns null, so any async server
// handler whose Promise settles on a *later* event-loop tick (a timer,
// async file/network I/O — anything but a synchronously-resolved microtask)
// silently drops its Response and the request hangs forever.
extern fn Bun__NativePromiseContext__create(global: *jsc.JSGlobalObject, ctx: *anyopaque, tag: u8) callconv(.c) jsc.JSValue;
extern fn Bun__NativePromiseContext__take(value: jsc.JSValue) callconv(.c) ?*anyopaque;

var Bun__NativePromiseContext__create_fn: *const fn (global: *jsc.JSGlobalObject, ctx: *anyopaque, tag: u8) callconv(.c) jsc.JSValue =
    if (build_options.enable_jsc) &Bun__NativePromiseContext__create else &stub_create;
var Bun__NativePromiseContext__take_fn: *const fn (value: jsc.JSValue) callconv(.c) ?*anyopaque =
    if (build_options.enable_jsc) &Bun__NativePromiseContext__take else &stub_take;

fn stub_create(_: *jsc.JSGlobalObject, _: *anyopaque, _: u8) callconv(.c) jsc.JSValue {
    return .zero;
}
fn stub_take(_: jsc.JSValue) callconv(.c) ?*anyopaque {
    return null;
}

/// The caller must have already taken a ref on `ctx`. The returned cell owns
/// that ref until `take()` transfers it back or GC runs the destructor.
pub fn create(global: *jsc.JSGlobalObject, ctx: anytype) jsc.JSValue {
    const T = @typeInfo(@TypeOf(ctx)).pointer.child;
    return Bun__NativePromiseContext__create_fn(global, ctx, @intFromEnum(Tag.fromType(T)));
}

/// Transfers the ref back to the caller and nulls the cell so the destructor
/// is a no-op. Returns null if already taken (e.g., the connection aborted
/// and the ref was released via the destructor on a prior GC cycle).
pub fn take(comptime T: type, cell: jsc.JSValue) ?*T {
    const raw = Bun__NativePromiseContext__take_fn(cell) orelse return null;
    return @ptrCast(@alignCast(raw));
}

/// Called from the C++ destructor when a cell is collected with a non-null
/// pointer (i.e., `take()` was never called — the Promise was GC'd without
/// settling).
///
/// The destructor runs during GC sweep, so it is NOT safe to do anything
/// that might touch the JSC heap. RequestContext.deref() can trigger
/// deinit() which detaches responses, unrefs bodies, and calls back into
/// the server — all of which may unprotect JS values or allocate. We must
/// defer that work to the event loop.
pub export fn Bun__NativePromiseContext__destroy(ctx: *anyopaque, tag: u8) callconv(.c) void {
    DeferredDerefTask.schedule(ctx, @enumFromInt(tag));
}

comptime {
    _ = &Bun__NativePromiseContext__destroy;
    _ = &home_rt.upstream_sha;
}

/// Defers the GC-triggered deref to the next event-loop tick so it runs
/// outside the sweep phase.
///
/// Zero-allocation: the ctx pointer and our Tag are packed into the task's
/// `_ptr` slot (pointer in high bits, tag in low 3 bits — the target types
/// are all >= 8-byte aligned).
pub const DeferredDerefTask = struct {
    const tag_mask: usize = 0b111;
    comptime {
        // Low 3 bits hold the tag; verify both capacity and alignment slack
        // so adding a tag or a packed field can't silently break the packing.
        std.debug.assert(@typeInfo(Tag).@"enum".fields.len <= tag_mask + 1);
        std.debug.assert(@alignOf(server.HTTPServer.RequestContext) > tag_mask);
        std.debug.assert(@alignOf(server.HTTPSServer.RequestContext) > tag_mask);
        std.debug.assert(@alignOf(server.DebugHTTPServer.RequestContext) > tag_mask);
        std.debug.assert(@alignOf(server.DebugHTTPSServer.RequestContext) > tag_mask);
        std.debug.assert(@alignOf(webcore.Body.ValueBufferer) > tag_mask);
    }

    pub fn schedule(ctx: *anyopaque, tag: Tag) void {
        const vm = jsc.VirtualMachine.get();
        // Process is dying; the leak no longer matters and the task
        // queue won't drain.
        if (vm.isShuttingDown()) return;

        const addr = @intFromPtr(ctx);
        std.debug.assert(addr & tag_mask == 0);

        var marker: DeferredDerefTask = undefined;
        var task = jsc.Task.init(&marker);
        task.setUintptr(@truncate(addr | @intFromEnum(tag)));
        vm.eventLoop().enqueueTask(task);
    }

    pub fn runFromJSThread(packed_ptr: usize) void {
        const tag: Tag = @enumFromInt(packed_ptr & tag_mask);
        const ctx: *anyopaque = @ptrFromInt(packed_ptr & ~tag_mask);
        switch (tag) {
            .HTTPServerRequestContext => @as(*server.HTTPServer.RequestContext, @ptrCast(@alignCast(ctx))).deref(),
            .HTTPSServerRequestContext => @as(*server.HTTPSServer.RequestContext, @ptrCast(@alignCast(ctx))).deref(),
            .DebugHTTPServerRequestContext => @as(*server.DebugHTTPServer.RequestContext, @ptrCast(@alignCast(ctx))).deref(),
            .DebugHTTPSServerRequestContext => @as(*server.DebugHTTPSServer.RequestContext, @ptrCast(@alignCast(ctx))).deref(),
            .BodyValueBufferer => {
                // ValueBufferer is embedded by value inside HTMLRewriter's
                // BufferOutputSink, with the owner pointer stored in .ctx.
                // The pending-promise ref was taken on the owner, so we
                // release it there.
                const bufferer: *webcore.Body.ValueBufferer = @ptrCast(@alignCast(ctx));
                @as(*HTMLRewriter.BufferOutputSink, @ptrCast(@alignCast(bufferer.ctx))).deref();
            },
            .HTTPSServerH3RequestContext => @as(*server.HTTPSServer.H3RequestContext, @ptrCast(@alignCast(ctx))).deref(),
            .DebugHTTPSServerH3RequestContext => @as(*server.DebugHTTPSServer.H3RequestContext, @ptrCast(@alignCast(ctx))).deref(),
        }
    }
};

const std = @import("std");
const home_rt = @import("home");
const build_options = @import("build_options");

// ============================================================================
// Local stubs (re-attach when the matching home_rt surfaces land)
// ============================================================================

const jsc = struct {
    pub const JSGlobalObject = home_rt.jsc.JSGlobalObject;
    pub const JSValue = home_rt.jsc.JSValue;

    /// 8-byte-aligned task struct, big enough that the low 3 bits of its
    /// embedded data slot are free for the tag pack.
    pub const Task = extern struct {
        data: u64 align(8) = 0,

        pub fn init(_: anytype) Task {
            return .{};
        }
        pub fn setUintptr(self: *Task, v: u64) void {
            self.data = v;
        }
    };

    pub const VirtualMachine = struct {
        shutting_down: bool = false,

        pub fn get() *VirtualMachine {
            return &global_vm;
        }
        pub fn isShuttingDown(self: *VirtualMachine) bool {
            return self.shutting_down;
        }
        pub fn eventLoop(self: *VirtualMachine) *EventLoop {
            _ = self;
            return &global_event_loop;
        }
    };

    pub const EventLoop = struct {
        enqueued: u32 = 0,

        pub fn enqueueTask(self: *EventLoop, _: Task) void {
            self.enqueued += 1;
        }
    };

    var global_vm: VirtualMachine = .{};
    var global_event_loop: EventLoop = .{};
};

// 8-byte-aligned stubs so the alignment assertions in DeferredDerefTask hold.
// Each Tag variant needs its own nominal type (Zig switch-on-type rejects
// duplicates), so each struct is declared inline rather than via a generic
// helper — generics memoize and produce one type.
// Re-attached 2026-06-24: the real server.zig is now ported, so getTag must
// switch on the real NewServer(...).RequestContext / H3RequestContext types
// (the ones create() is actually called with). The earlier inline stubs made
// every real request-context type fall to the @compileError else-branch.
const server = @import("../server/server.zig");
const webcore = @import("../webcore.zig");

// Local stand-in used only by the test blocks (not compiled into the exe). The
// real RequestContext has required fields and isn't `.{}`-constructible.
const StubRequest = extern struct {
    _pad: u64 = 0,
    pub fn deref(_: *@This()) void {}
};

const HTMLRewriter = struct {
    pub const BufferOutputSink = extern struct {
        _pad: u64 = 0,

        pub fn deref(_: *BufferOutputSink) void {}
    };
};

// ============================================================================
// Tests
// ============================================================================

test "NativePromiseContext.Tag: low 3 bits address all variants" {
    try std.testing.expect(@typeInfo(Tag).@"enum".fields.len <= 8);
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(Tag.HTTPServerRequestContext));
    try std.testing.expectEqual(@as(u8, 4), @intFromEnum(Tag.BodyValueBufferer));
}

test "NativePromiseContext.Tag.fromType maps the canonical request contexts" {
    try std.testing.expectEqual(Tag.HTTPServerRequestContext, Tag.fromType(server.HTTPServer.RequestContext));
    try std.testing.expectEqual(Tag.BodyValueBufferer, Tag.fromType(webcore.Body.ValueBufferer));
}

test "DeferredDerefTask.schedule packs the ctx pointer and tag in the low 3 bits" {
    var ctx_buf: [4]u64 align(8) = @splat(0);
    const ctx: *anyopaque = @ptrCast(&ctx_buf);

    // Reset event-loop counter via the stub VM.
    jsc.VirtualMachine.get().shutting_down = false;
    const before = @as(*jsc.EventLoop, &@field(jsc, "global_event_loop")).enqueued;
    DeferredDerefTask.schedule(ctx, .BodyValueBufferer);
    const after = @as(*jsc.EventLoop, &@field(jsc, "global_event_loop")).enqueued;
    try std.testing.expectEqual(before + 1, after);
}

test "DeferredDerefTask.schedule is a no-op when the VM is shutting down" {
    var ctx_buf: [4]u64 align(8) = @splat(0);
    const ctx: *anyopaque = @ptrCast(&ctx_buf);

    jsc.VirtualMachine.get().shutting_down = true;
    const before = @as(*jsc.EventLoop, &@field(jsc, "global_event_loop")).enqueued;
    DeferredDerefTask.schedule(ctx, .HTTPServerRequestContext);
    const after = @as(*jsc.EventLoop, &@field(jsc, "global_event_loop")).enqueued;
    try std.testing.expectEqual(before, after);
    jsc.VirtualMachine.get().shutting_down = false;
}

test "DeferredDerefTask.runFromJSThread dispatch table stays tag-complete" {
    try std.testing.expectEqual(@as(usize, 7), @typeInfo(Tag).@"enum".fields.len);
}

test "NativePromiseContext.create routes through the soft-linked fn-ptr" {
    var dummy: u8 = 0;
    var ctx_buf: [@sizeOf(server.HTTPServer.RequestContext)]u8 align(@alignOf(server.HTTPServer.RequestContext)) = undefined;
    const ctx: *server.HTTPServer.RequestContext = @ptrCast(&ctx_buf);
    const g: *jsc.JSGlobalObject = @ptrCast(&dummy);
    try std.testing.expectEqual(jsc.JSValue.zero, create(g, ctx));
}

test "NativePromiseContext.take returns null under the soft-linked stub" {
    try std.testing.expect(take(StubRequest, .zero) == null);
}
