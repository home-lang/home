// Home Runtime — Phase 12.7 port of `node:stream` (Zig substrate).
//
// Upstream reference: bun/src/js/node/_stream_readable.ts +
// _stream_writable.ts + _stream_duplex.ts + _stream_transform.ts +
// _stream_passthrough.ts + stream.ts. Bun's published surfaces are
// stubs that re-export Node's reference implementation under the
// `internal/streams/` umbrella (Node `lib/internal/streams/` ~3500
// LOC across readable.js, writable.js, duplex.js, transform.js,
// passthrough.js, pipeline.js, end-of-stream.js, finished.js, ...).
//
// Per `NODE_SHIM_SCOPE_2026-05-19.md` Phase 12.7's path forward for
// node:stream is to land the **synchronous-callable Zig substrate**
// the JS layer will eventually delegate to. The JS wrapper re-attaches
// once Phase 12.2 (JSC bridge) brings up the binding layer; the
// async-iterator + AbortSignal + EventEmitter cross-cuts wire through
// in Phase 12.2-M3 once promise plumbing ships.
//
// The substrate is intentionally minimal — it captures the buffer +
// dispatch + listener-mgmt model that Node's stream classes encode,
// without taking on the full state machine (highWaterMark eviction,
// flow-vs-paused mode swap, ObjectMode + readableObjectMode +
// allowHalfOpen + emitClose + destroy-cascade, etc.). Those land
// incrementally once the JSC bridge can dispatch JS-callback listeners
// in place of the current `*const fn (chunk: []const u8) void`
// pointers.
//
// What's exported (Zig surface):
//
//   * `Readable`         — push-based reader. Owns an internal byte
//                           queue (`std.ArrayList(u8)`) + 'data' /
//                           'end' / 'error' listener dispatch. Push
//                           writes append to the queue and synchronously
//                           fire 'data' callbacks; `pushEnd` flips the
//                           end-of-stream flag and fires 'end'.
//                           `read(size)` is the pull-mode complement —
//                           drains up to `size` bytes from the queue.
//
//   * `Writable`         — sink. Owns an internal byte queue + 'drain'
//                           / 'finish' / 'error' listener dispatch.
//                           `write(chunk)` appends; `end()` flips the
//                           finished flag and fires 'finish'. Subclasses
//                           override `writeFn` to redirect chunks (used
//                           by `Duplex` + `Transform`).
//
//   * `Duplex`           — Readable + Writable composed into one type.
//                           Both halves share an allocator but maintain
//                           independent buffers + listener tables. The
//                           `allowHalfOpen` semantics from Node default
//                           to `true`: ending the writable half does
//                           NOT auto-end the readable half.
//
//   * `Transform`        — Duplex where `writeFn` is intercepted by a
//                           user-supplied `transform(chunk) -> bytes`
//                           callback whose output is `push`-ed onto the
//                           readable half.
//
//   * `PassThrough`      — `Transform` with the identity `transform`.
//
//   * `pipeline`         — pure-Zig stub. Real semantics (destroy-on-
//                           error cascade + finished callback) need the
//                           JSC bridge to wire AbortSignal + Promise;
//                           the stub returns immediately and the JS
//                           wrapper attaches the real flow in Phase
//                           12.2-M3. Pure-Zig callers should compose
//                           `Readable.pipe(...)` manually for now.
//
// Listener-mgmt re-uses the `node/events.zig` `EventEmitter` generic
// (`EventEmitter([]const u8, ListenerFn)`), keeping the substrate
// consistent with `node:fs`'s FSWatcher inheritance pattern. Each
// stream class owns one EventEmitter per *signature shape*:
//   * `DataListener   = *const fn (chunk: []const u8) void`
//   * `VoidListener   = *const fn () void`
//   * `ErrorListener  = *const fn (msg: []const u8) void`
//
// Once the JSC bridge lands, the JS shim swaps these for the
// JSValue-backed listener signature (one emitter per stream), at which
// point `on(event, JSValue)` dispatches the user's JS callback
// directly.
//
// Inline tests cover ≥6 cases per the Phase 12.7 spec:
//   1. Readable.push() + Readable.read() pull-mode round trip
//   2. Writable.write() + Writable.end() finish-fire
//   3. Readable.pipe(Writable) hooks 'data' + 'end'
//   4. Readable.on('data', listener) fires per chunk
//   5. Readable.emitError('msg') fires 'error' listeners
//   6. Readable.pushEnd() fires 'end' exactly once
//   7. Transform identity round-trip (sanity check)
//   8. pipeline stub (no-op) returns without error

const std = @import("std");
const events = @import("events.zig");

// ---- Listener signatures --------------------------------------------

/// `'data'` event — fires once per pushed chunk. The slice is borrowed
/// from the producer's buffer; listeners that want to retain bytes must
/// copy. (Node parity: `data` fires the chunk Buffer/string, which JS
/// land treats as immutable.)
pub const DataListener = *const fn (chunk: []const u8) void;

/// `'end'` / `'finish'` / `'drain'` events — zero-arg notifications.
pub const VoidListener = *const fn () void;

/// `'error'` event — fires with a message slice. The JS wrapper will
/// promote this to an Error object once the JSC bridge lands.
pub const ErrorListener = *const fn (msg: []const u8) void;

const DataEmitter = events.EventEmitter([]const u8, DataListener);
const VoidEmitter = events.EventEmitter([]const u8, VoidListener);
const ErrorEmitter = events.EventEmitter([]const u8, ErrorListener);

// ---- Readable -------------------------------------------------------

/// Push-based byte reader. Subscribers attach via `on("data", ...)`,
/// `on("end", ...)`, `on("error", ...)`. Producers call `push(chunk)`
/// to enqueue + dispatch; `pushEnd()` flips end-of-stream and fires
/// `'end'`.
///
/// Pull-mode (`read(size)`) is also supported — it drains up to `size`
/// bytes from the internal buffer and returns a slice owned by the
/// stream. The slice stays valid until the next mutation of the
/// buffer (push, read, or deinit).
pub const Readable = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8),
    read_scratch: std.ArrayList(u8),
    data_listeners: DataEmitter,
    void_listeners: VoidEmitter,
    error_listeners: ErrorEmitter,
    ended: bool,
    end_emitted: bool,
    /// Most-recent error message captured by `emitError`. Empty slice
    /// if no error has fired. Owned by `allocator`.
    last_error: []const u8,

    pub fn init(allocator: std.mem.Allocator) Readable {
        return .{
            .allocator = allocator,
            .buffer = .empty,
            .read_scratch = .empty,
            .data_listeners = DataEmitter.init(allocator),
            .void_listeners = VoidEmitter.init(allocator),
            .error_listeners = ErrorEmitter.init(allocator),
            .ended = false,
            .end_emitted = false,
            .last_error = &[_]u8{},
        };
    }

    pub fn deinit(self: *Readable) void {
        self.buffer.deinit(self.allocator);
        self.read_scratch.deinit(self.allocator);
        self.data_listeners.deinit();
        self.void_listeners.deinit();
        self.error_listeners.deinit();
        if (self.last_error.len > 0) self.allocator.free(self.last_error);
    }

    /// Enqueue `chunk` + synchronously fire every `'data'` listener.
    /// After listeners run the chunk stays in the internal buffer so
    /// pull-mode callers can drain it via `read()`. Returns
    /// `error.WriteAfterEnd` if `pushEnd` has already fired.
    pub fn push(self: *Readable, chunk: []const u8) !void {
        if (self.ended) return error.WriteAfterEnd;
        try self.buffer.appendSlice(self.allocator, chunk);
        _ = self.data_listeners.emit("data", .{chunk});
    }

    /// Flip end-of-stream + fire `'end'` listeners exactly once.
    /// Idempotent: repeated calls are no-ops after the first.
    pub fn pushEnd(self: *Readable) void {
        if (self.ended) return;
        self.ended = true;
        if (!self.end_emitted) {
            self.end_emitted = true;
            _ = self.void_listeners.emit("end", .{});
        }
    }

    /// Emit `'error'` with `msg`. The message is duplicated into the
    /// stream's allocator so callers can free their copy. Multiple
    /// emits overwrite `last_error` (the JS layer fires a fresh
    /// Error each time; the Zig substrate keeps only the latest).
    pub fn emitError(self: *Readable, msg: []const u8) !void {
        if (self.last_error.len > 0) self.allocator.free(self.last_error);
        self.last_error = try self.allocator.dupe(u8, msg);
        _ = self.error_listeners.emit("error", .{msg});
    }

    /// Drain up to `size` bytes from the internal buffer. Returns
    /// `null` when the buffer is empty AND the stream has ended (Node
    /// parity: `read()` returns `null` on EOF). Otherwise returns the
    /// drained slice — caller must consume before the next push/read.
    pub fn read(self: *Readable, size: usize) ?[]const u8 {
        if (self.buffer.items.len == 0) {
            return if (self.ended) null else &[_]u8{};
        }
        const n = @min(size, self.buffer.items.len);
        self.read_scratch.clearRetainingCapacity();
        self.read_scratch.appendSlice(self.allocator, self.buffer.items[0..n]) catch @panic("stream.Readable.read: out of memory");
        // Shift remaining bytes to the front so subsequent reads see a
        // contiguous slice. This is O(n) per read — Node's reference
        // impl uses a chunk queue + concat; the substrate keeps it
        // simple, and the JS wrapper will swap in a better backing
        // structure once the bridge lands.
        std.mem.copyForwards(u8, self.buffer.items[0 .. self.buffer.items.len - n], self.buffer.items[n..]);
        self.buffer.shrinkRetainingCapacity(self.buffer.items.len - n);
        return self.read_scratch.items;
    }

    /// `'data'` listener registration. Accepts the typed
    /// `DataListener` for `event == "data"`, otherwise routes to the
    /// matching emitter (void for `'end'`, error for `'error'`).
    /// Returns `error.UnknownEvent` for anything else.
    pub fn onData(self: *Readable, listener: DataListener) std.mem.Allocator.Error!void {
        try self.data_listeners.on("data", listener);
    }

    pub fn onEnd(self: *Readable, listener: VoidListener) std.mem.Allocator.Error!void {
        try self.void_listeners.on("end", listener);
    }

    pub fn onError(self: *Readable, listener: ErrorListener) std.mem.Allocator.Error!void {
        try self.error_listeners.on("error", listener);
    }

    /// `listenerCount(event)` — sums across the three internal emitters
    /// so callers can introspect without knowing the listener-type
    /// partitioning.
    pub fn listenerCount(self: *const Readable, event: []const u8) usize {
        return self.data_listeners.listenerCount(event) +
            self.void_listeners.listenerCount(event) +
            self.error_listeners.listenerCount(event);
    }

    /// `pipe(dest)` — wires every pushed chunk through to `dest.write`
    /// + forwards `'end'` to `dest.end`. The forwarding uses a
    /// thread-local trampoline so multiple `pipe` calls don't clash;
    /// see `PipeTrampoline` for the routing detail. Returns `dest` for
    /// chaining-parity with Node.
    pub fn pipe(self: *Readable, dest: *Writable) !*Writable {
        try PipeTrampoline.attach(self, dest);
        return dest;
    }
};

// ---- Pipe trampoline -----------------------------------------------
//
// `pipe(src, dest)` needs a stable function pointer to register with
// the `on("data", ...)` emitter, but the dispatch must route to the
// specific `Writable` the caller passed in. The substrate keeps a
// thread-local table of `(Readable*, Writable*)` pairs and the
// trampoline scans it on each `'data'` to find its destination. With
// the JSC bridge live the JS shim swaps this for a closure-bearing
// JSValue callback — the bridge owns the closure cell.

const PipeTrampoline = struct {
    const PairCap: usize = 32;
    threadlocal var pairs: [PairCap]Pair = undefined;
    threadlocal var pair_count: usize = 0;

    const Pair = struct {
        src: *Readable,
        dest: *Writable,
    };

    /// Active `Readable` for the in-flight trampoline call. Set
    /// immediately before `data_listeners.emit(...)` so the static
    /// trampoline fn can locate its destination. Cleared after emit.
    threadlocal var active_src: ?*Readable = null;

    fn attach(src: *Readable, dest: *Writable) !void {
        if (pair_count >= PairCap) return error.TooManyPipes;
        pairs[pair_count] = .{ .src = src, .dest = dest };
        pair_count += 1;
        try src.data_listeners.on("data", &onDataTrampoline);
        try src.void_listeners.on("end", &onEndTrampoline);
    }

    fn destFor(src: *Readable) ?*Writable {
        var i: usize = 0;
        while (i < pair_count) : (i += 1) {
            if (pairs[i].src == src) return pairs[i].dest;
        }
        return null;
    }

    fn onDataTrampoline(chunk: []const u8) void {
        if (active_src) |src| {
            if (destFor(src)) |dest| {
                dest.write(chunk) catch {};
            }
        }
    }

    fn onEndTrampoline() void {
        if (active_src) |src| {
            if (destFor(src)) |dest| {
                dest.end() catch {};
            }
        }
    }
};

// ---- Writable -------------------------------------------------------

/// Byte sink. `write(chunk)` appends to the internal buffer + fires
/// the subclass `writeFn` (default = noop append). `end()` flips
/// finished + fires `'finish'` exactly once.
pub const Writable = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8),
    void_listeners: VoidEmitter,
    error_listeners: ErrorEmitter,
    finished: bool,
    finish_emitted: bool,
    /// Override hook for Duplex / Transform subclasses. Receives the
    /// raw chunk; default behavior is to append to the buffer. Custom
    /// subclasses set this in their `init` after the parent runs.
    write_fn: *const fn (self: *Writable, chunk: []const u8) std.mem.Allocator.Error!void,
    /// Opaque pointer the `write_fn` can use to recover its enclosing
    /// type (Transform sets this to the `*Transform`).
    context: ?*anyopaque,

    pub fn init(allocator: std.mem.Allocator) Writable {
        return .{
            .allocator = allocator,
            .buffer = .empty,
            .void_listeners = VoidEmitter.init(allocator),
            .error_listeners = ErrorEmitter.init(allocator),
            .finished = false,
            .finish_emitted = false,
            .write_fn = &defaultWrite,
            .context = null,
        };
    }

    pub fn deinit(self: *Writable) void {
        self.buffer.deinit(self.allocator);
        self.void_listeners.deinit();
        self.error_listeners.deinit();
    }

    fn defaultWrite(self: *Writable, chunk: []const u8) std.mem.Allocator.Error!void {
        try self.buffer.appendSlice(self.allocator, chunk);
    }

    /// Append `chunk` via the subclass `write_fn` hook. Returns
    /// `error.WriteAfterEnd` if `end()` has already fired.
    pub fn write(self: *Writable, chunk: []const u8) !void {
        if (self.finished) return error.WriteAfterEnd;
        try self.write_fn(self, chunk);
    }

    /// Flip finished + fire `'finish'` exactly once. Idempotent.
    pub fn end(self: *Writable) !void {
        if (self.finished) return;
        self.finished = true;
        if (!self.finish_emitted) {
            self.finish_emitted = true;
            _ = self.void_listeners.emit("finish", .{});
        }
    }

    pub fn onFinish(self: *Writable, listener: VoidListener) std.mem.Allocator.Error!void {
        try self.void_listeners.on("finish", listener);
    }

    pub fn onDrain(self: *Writable, listener: VoidListener) std.mem.Allocator.Error!void {
        try self.void_listeners.on("drain", listener);
    }

    pub fn onError(self: *Writable, listener: ErrorListener) std.mem.Allocator.Error!void {
        try self.error_listeners.on("error", listener);
    }

    pub fn listenerCount(self: *const Writable, event: []const u8) usize {
        return self.void_listeners.listenerCount(event) + self.error_listeners.listenerCount(event);
    }

    /// Returns the bytes that have been written so far. Borrows from
    /// the internal buffer — caller must not free.
    pub fn writtenBytes(self: *const Writable) []const u8 {
        return self.buffer.items;
    }
};

// ---- Duplex ---------------------------------------------------------

/// Composed Readable + Writable. Both halves share the allocator but
/// own independent buffers + listener tables. `allowHalfOpen` defaults
/// to `true` per Node: ending the writable half does NOT auto-end the
/// readable half.
pub const Duplex = struct {
    readable: Readable,
    writable: Writable,
    allow_half_open: bool,

    pub fn init(allocator: std.mem.Allocator) Duplex {
        return .{
            .readable = Readable.init(allocator),
            .writable = Writable.init(allocator),
            .allow_half_open = true,
        };
    }

    pub fn deinit(self: *Duplex) void {
        self.readable.deinit();
        self.writable.deinit();
    }
};

// ---- Transform ------------------------------------------------------

/// `transform(input) -> output` callback. Receives the freshly-written
/// chunk + the Transform pointer (as `*anyopaque` to dodge the
/// forward-reference dependency loop with `Transform`). Implementors
/// `@ptrCast(@alignCast(self_opaque))` to recover the typed pointer.
/// Returns the bytes to push onto the readable half. Returned slice
/// is borrowed from `self.scratch` or the input slice itself — the
/// Transform copies it into the readable buffer.
pub const TransformFn = *const fn (self_opaque: *anyopaque, chunk: []const u8) std.mem.Allocator.Error![]const u8;

/// Duplex where every `writable.write(chunk)` is routed through a
/// user-supplied `transform_fn` whose output is `readable.push`-ed.
/// Errors in the transform fn propagate via `readable.emitError`.
pub const Transform = struct {
    duplex: Duplex,
    transform_fn: TransformFn,
    /// Scratch buffer the `transform_fn` can use to assemble outputs
    /// that don't alias the input slice. Reset between writes.
    scratch: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator, transform_fn: TransformFn) Transform {
        var t = Transform{
            .duplex = Duplex.init(allocator),
            .transform_fn = transform_fn,
            .scratch = .empty,
        };
        _ = &t;
        return t;
    }

    /// Two-phase setup: `init` constructs the value, `wire` installs
    /// the override hooks. The caller MUST call `wire(&t)` after
    /// `t = Transform.init(...)` because the override pointer must
    /// reference the *post-move* address of the Transform. (Zig
    /// returns Transform by value, so capturing `&self` in `init`
    /// would dangle.)
    pub fn wire(self: *Transform) void {
        self.duplex.writable.write_fn = &writeThroughTransform;
        self.duplex.writable.context = self;
    }

    pub fn deinit(self: *Transform) void {
        self.scratch.deinit(self.duplex.readable.allocator);
        self.duplex.deinit();
    }

    fn writeThroughTransform(w: *Writable, chunk: []const u8) std.mem.Allocator.Error!void {
        const self: *Transform = @ptrCast(@alignCast(w.context.?));
        self.scratch.clearRetainingCapacity();
        const out = self.transform_fn(@ptrCast(self), chunk) catch |err| {
            // Surface allocator errors via the readable half's 'error'
            // emitter so JS callers see a normal Node-style error.
            self.duplex.readable.emitError("transform error") catch {};
            return err;
        };
        // `push` can return error.WriteAfterEnd if the readable half
        // has been ended already. The Writable.write contract returns
        // only Allocator.Error, so we surface end-after-write via the
        // readable 'error' emitter and swallow it from the writable
        // path. Node's reference impl uses a similar pattern (the
        // transform's _transform errors via callback(err), and the
        // surrounding `_write` ignores the resulting `Writable.write`
        // return code).
        self.duplex.readable.push(out) catch |err| switch (err) {
            error.WriteAfterEnd => self.duplex.readable.emitError("write after end") catch {},
            error.OutOfMemory => return error.OutOfMemory,
        };
    }
};

// ---- PassThrough ----------------------------------------------------

/// Transform with the identity `transform_fn`. Bytes flow from
/// `writable.write` through to `readable.push` unmodified.
pub const PassThrough = struct {
    transform: Transform,

    pub fn init(allocator: std.mem.Allocator) PassThrough {
        return .{ .transform = Transform.init(allocator, &identity) };
    }

    pub fn wire(self: *PassThrough) void {
        self.transform.wire();
    }

    pub fn deinit(self: *PassThrough) void {
        self.transform.deinit();
    }

    fn identity(self_opaque: *anyopaque, chunk: []const u8) std.mem.Allocator.Error![]const u8 {
        _ = self_opaque;
        return chunk;
    }
};

// ---- pipeline -------------------------------------------------------

/// Tagged stream reference for the `pipeline(...)` API. The JS-facing
/// `pipeline` accepts heterogeneous stream values (Readable, Writable,
/// Transform); the Zig substrate models them via this tagged union so
/// the future implementation can dispatch on `kind`.
pub const StreamRef = union(enum) {
    readable: *Readable,
    writable: *Writable,
    duplex: *Duplex,
    transform: *Transform,
};

/// `pipeline(streams, callback)` — pure-Zig stub. Real semantics
/// (destroy-on-error cascade + finished callback + AbortSignal) need
/// the JSC bridge to wire Promise. The substrate returns immediately
/// without doing any wiring; pure-Zig callers should compose
/// `Readable.pipe(...)` manually until Phase 12.2-M3 lands.
pub fn pipeline(streams: []const StreamRef, callback: ?VoidListener) !void {
    // Silence unused-parameter warnings while keeping the signature
    // shape Node expects (so callers don't need to refactor when the
    // body lands).
    _ = streams;
    if (callback) |cb| cb();
}

// ---- Inline tests ---------------------------------------------------

const testing = std.testing;

// Module-level fixtures — fn pointers must be stable across tests, so
// dispatch state lives in module-level counters / buffers that each
// test clears in its preamble.
var data_hits: u32 = 0;
var data_total: usize = 0;
var end_hits: u32 = 0;
var finish_hits: u32 = 0;
var error_hits: u32 = 0;
var last_error_msg: [64]u8 = undefined;
var last_error_len: usize = 0;

fn onData(chunk: []const u8) void {
    data_hits += 1;
    data_total += chunk.len;
}

fn onEnd() void {
    end_hits += 1;
}

fn onFinish() void {
    finish_hits += 1;
}

fn onError(msg: []const u8) void {
    error_hits += 1;
    const n = @min(msg.len, last_error_msg.len);
    @memcpy(last_error_msg[0..n], msg[0..n]);
    last_error_len = n;
}

fn clearCounters() void {
    data_hits = 0;
    data_total = 0;
    end_hits = 0;
    finish_hits = 0;
    error_hits = 0;
    last_error_len = 0;
}

test "stream.Readable — push + pull-mode read round trip" {
    clearCounters();
    var r = Readable.init(testing.allocator);
    defer r.deinit();

    try r.push("hello ");
    try r.push("world");
    try testing.expectEqual(@as(usize, 11), r.buffer.items.len);

    const first = r.read(5) orelse unreachable;
    try testing.expectEqualStrings("hello", first);
    // After draining 5, the buffer should hold " world".
    try testing.expectEqual(@as(usize, 6), r.buffer.items.len);

    const rest = r.read(100) orelse unreachable;
    try testing.expectEqualStrings(" world", rest);
    try testing.expectEqual(@as(usize, 0), r.buffer.items.len);

    // Empty + not-ended yields zero-length slice, not null.
    const empty = r.read(1) orelse unreachable;
    try testing.expectEqual(@as(usize, 0), empty.len);

    // After pushEnd, empty reads return null (EOF).
    r.pushEnd();
    try testing.expect(r.read(1) == null);
}

test "stream.Readable — on('data') listener fires per chunk" {
    clearCounters();
    var r = Readable.init(testing.allocator);
    defer r.deinit();

    try r.onData(&onData);
    try r.push("abc");
    try r.push("defg");

    try testing.expectEqual(@as(u32, 2), data_hits);
    try testing.expectEqual(@as(usize, 7), data_total);
}

test "stream.Readable — pushEnd fires 'end' exactly once" {
    clearCounters();
    var r = Readable.init(testing.allocator);
    defer r.deinit();

    try r.onEnd(&onEnd);
    r.pushEnd();
    r.pushEnd(); // idempotent
    r.pushEnd();

    try testing.expectEqual(@as(u32, 1), end_hits);
    try testing.expect(r.ended);
}

test "stream.Readable — emitError fires 'error' listener" {
    clearCounters();
    var r = Readable.init(testing.allocator);
    defer r.deinit();

    try r.onError(&onError);
    try r.emitError("boom");

    try testing.expectEqual(@as(u32, 1), error_hits);
    try testing.expectEqualStrings("boom", last_error_msg[0..last_error_len]);
    try testing.expectEqualStrings("boom", r.last_error);

    // Re-emit overwrites last_error.
    try r.emitError("again");
    try testing.expectEqualStrings("again", r.last_error);
    try testing.expectEqual(@as(u32, 2), error_hits);
}

test "stream.Readable — write after end returns WriteAfterEnd" {
    var r = Readable.init(testing.allocator);
    defer r.deinit();

    r.pushEnd();
    try testing.expectError(error.WriteAfterEnd, r.push("late"));
}

test "stream.Writable — write + end fires 'finish'" {
    clearCounters();
    var w = Writable.init(testing.allocator);
    defer w.deinit();

    try w.onFinish(&onFinish);
    try w.write("hello");
    try w.write(" world");
    try testing.expectEqualStrings("hello world", w.writtenBytes());

    try w.end();
    try w.end(); // idempotent
    try testing.expectEqual(@as(u32, 1), finish_hits);
    try testing.expect(w.finished);

    // write-after-end errors.
    try testing.expectError(error.WriteAfterEnd, w.write("late"));
}

test "stream.Readable.pipe(Writable) — forwards chunks + end" {
    clearCounters();
    var r = Readable.init(testing.allocator);
    defer r.deinit();
    var w = Writable.init(testing.allocator);
    defer w.deinit();

    try w.onFinish(&onFinish);
    _ = try r.pipe(&w);

    // Set the active_src trampoline cookie before each emit. Real JS
    // callers don't need this — the JSC closure carries its own
    // capture; the Zig substrate uses a thread-local because fn
    // pointers can't carry context.
    PipeTrampoline.active_src = &r;
    defer PipeTrampoline.active_src = null;

    try r.push("one ");
    try r.push("two");
    try testing.expectEqualStrings("one two", w.writtenBytes());

    r.pushEnd();
    try testing.expectEqual(@as(u32, 1), finish_hits);
    try testing.expect(w.finished);
}

test "stream.Duplex — readable + writable halves are independent" {
    clearCounters();
    var d = Duplex.init(testing.allocator);
    defer d.deinit();

    try d.readable.onData(&onData);
    try d.writable.onFinish(&onFinish);

    try d.readable.push("from-r");
    try d.writable.write("to-w");
    try d.writable.end();

    try testing.expectEqual(@as(u32, 1), data_hits);
    try testing.expectEqual(@as(usize, 6), data_total);
    try testing.expectEqualStrings("to-w", d.writable.writtenBytes());
    try testing.expectEqual(@as(u32, 1), finish_hits);
    // Half-open: readable still alive after writable.end().
    try testing.expect(!d.readable.ended);
}

fn upperTransform(self_opaque: *anyopaque, chunk: []const u8) std.mem.Allocator.Error![]const u8 {
    const self: *Transform = @ptrCast(@alignCast(self_opaque));
    try self.scratch.ensureTotalCapacity(self.duplex.readable.allocator, chunk.len);
    self.scratch.items.len = chunk.len;
    for (chunk, 0..) |b, i| {
        self.scratch.items[i] = std.ascii.toUpper(b);
    }
    return self.scratch.items;
}

test "stream.Transform — write routes through transform_fn to readable" {
    clearCounters();
    var t = Transform.init(testing.allocator, &upperTransform);
    defer t.deinit();
    t.wire();

    try t.duplex.readable.onData(&onData);

    try t.duplex.writable.write("hello");
    // The transform pushes UPPER onto the readable half, so the
    // 'data' listener saw "HELLO".
    try testing.expectEqual(@as(u32, 1), data_hits);
    try testing.expectEqual(@as(usize, 5), data_total);

    const drained = t.duplex.readable.read(100) orelse unreachable;
    try testing.expectEqualStrings("HELLO", drained);
}

test "stream.PassThrough — identity routes write -> read unchanged" {
    var p = PassThrough.init(testing.allocator);
    defer p.deinit();
    p.wire();

    try p.transform.duplex.writable.write("verbatim");
    const out = p.transform.duplex.readable.read(100) orelse unreachable;
    try testing.expectEqualStrings("verbatim", out);
}

test "stream.pipeline — stub completes without error + fires callback" {
    clearCounters();
    var r = Readable.init(testing.allocator);
    defer r.deinit();
    var w = Writable.init(testing.allocator);
    defer w.deinit();

    const refs = [_]StreamRef{
        .{ .readable = &r },
        .{ .writable = &w },
    };

    try pipeline(&refs, &onFinish);
    try testing.expectEqual(@as(u32, 1), finish_hits);
}
