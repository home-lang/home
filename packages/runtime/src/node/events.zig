// Home Runtime — Phase 12.7 port of `node:events` (Zig substrate).
//
// Upstream reference: bun/src/js/node/events.ts + Node.js
// `lib/events.js` (~865 LOC combined). Both surfaces depend on JSC
// primitives (`globalThis.process`, `Symbol.for(...)`, `Reflect.apply`,
// `AbortSignal`) which won't bind until Phase 12.2 brings up the JSC
// bridge. Per `NODE_SHIM_SCOPE_2026-05-19.md` the path forward in
// Phase 12.7 is to land the **Zig-callable substrate** the JS layer
// will eventually delegate to. The JS shim (events.ts) re-attaches
// once JSC is live, at which point listeners become JSValue callbacks
// rather than Zig fn pointers.
//
// EventEmitter is also the base class for `FSWatcher`, `net.Server`,
// `ChildProcess`, `Stream`, etc. — Phase 12.7's `node:fs` port
// depends on it directly (chained dependency), so this file is the
// gating port for the rest of the tier-2 Node shims.
//
// What's exported (Zig surface, comptime-generic over `EventName` and
// `Listener`):
//   * `on` / `addListener`                       — register listener
//   * `off` / `removeListener`                   — deregister listener
//   * `once`                                     — fire-and-remove
//   * `prependListener` / `prependOnceListener`  — register at head
//   * `emit`                                     — fire all listeners
//                                                 for `event` with args
//   * `listenerCount`                            — count for event
//   * `listeners`                                — slice for event
//   * `removeAllListeners`                       — drop all (per-event
//                                                 or globally)
//   * `setMaxListeners` / `getMaxListeners`      — overflow guard
//   * `eventNames`                               — registered events
//
// `EventEmitterDefault` is the typical-case alias used when the JS
// layer wires through: string event names, zero-arg listeners.
// Once the JSC bridge ships, JS callers parameterize with
// `(JSValue, JSValue)` so the dispatch table holds JS callbacks.
//
// Listener-mgmt semantics mirror Node verbatim:
//   * Listeners fire in insertion order.
//   * `once` listeners are removed *before* the callback runs, so a
//     callback can safely re-subscribe without recursion.
//   * `off` removes the first matching listener (by fn-pointer
//     equality); idempotent if no match.
//   * `setMaxListeners(n)` with `n <= 0` disables the warning entirely
//     (matches Node's `setMaxListeners(Infinity)` / 0 semantics).
//   * Default max is 10 (Node's `defaultMaxListeners`).
//   * Overflow emits a captured warning via `last_warning`; pure-Zig
//     callers read it with `lastWarning()`. The JS layer wraps this
//     into `process.emitWarning('MaxListenersExceededWarning', ...)`
//     once JSC is live.
//
// Inline tests cover: subscribe/emit, once fires-then-removes,
// off removes by identity, listenerCount, setMaxListeners + warn.

const std = @import("std");

// ---- Warning capture --------------------------------------------------

/// Maximum captured warning length. Mirrors Node's
/// `MaxListenersExceededWarning` formatter output.
pub const max_warning_bytes: usize = 256;

threadlocal var last_warning_buf: [max_warning_bytes]u8 = undefined;
threadlocal var last_warning_len: usize = 0;

/// Returns the most recent MaxListenersExceededWarning captured on
/// this thread. Empty slice if no warning has fired yet (or after
/// `clearLastWarning`).
pub fn lastWarning() []const u8 {
    return last_warning_buf[0..last_warning_len];
}

/// Clears the thread-local warning slot.
pub fn clearLastWarning() void {
    last_warning_len = 0;
}

fn captureWarning(msg: []const u8) void {
    const n = @min(msg.len, max_warning_bytes);
    @memcpy(last_warning_buf[0..n], msg[0..n]);
    last_warning_len = n;
}

// ---- defaults --------------------------------------------------------

/// Node's `EventEmitter.defaultMaxListeners` initial value.
pub const default_max_listeners: usize = 10;

// ---- Generic EventEmitter -------------------------------------------

/// `EventEmitter(EventName, Listener)` — Node's EventEmitter as a
/// Zig generic. `EventName` is typically `[]const u8`; `Listener` is
/// a callable type (fn pointer, fn-pointer struct, etc.). Listeners
/// are compared by `==` for `off` / `removeListener` — for fn
/// pointers that's reference equality, which matches Node's
/// `listener === otherListener` rule.
pub fn EventEmitter(comptime EventName: type, comptime Listener: type) type {
    return struct {
        const Self = @This();

        /// Per-event listener entry. `once` is the Node-spec flag that
        /// triggers removal-before-fire when the listener is invoked
        /// via `emit`.
        pub const Entry = struct {
            event: EventName,
            listener: Listener,
            once: bool,
        };

        entries: std.ArrayListUnmanaged(Entry) = .empty,
        allocator: std.mem.Allocator,
        max_listeners: usize = default_max_listeners,

        /// Constructs an empty emitter. Callers own the allocator
        /// lifetime; `deinit` must be called to release the entry
        /// list.
        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        /// Frees the entry list. Listeners themselves are caller-owned
        /// — the emitter never invokes `deinit` on them.
        pub fn deinit(self: *Self) void {
            self.entries.deinit(self.allocator);
        }

        // ---- Event-name equality -----------------------------------

        fn eventEql(a: EventName, b: EventName) bool {
            return switch (@typeInfo(EventName)) {
                .pointer => |p| if (p.size == .slice)
                    std.mem.eql(p.child, a, b)
                else
                    a == b,
                else => a == b,
            };
        }

        fn listenerEql(a: Listener, b: Listener) bool {
            return switch (@typeInfo(Listener)) {
                .pointer => a == b,
                .@"fn" => @compileError("Listener must be a pointer type — use *const fn (...) ... not fn (...) ..."),
                else => a == b,
            };
        }

        // ---- on / addListener / once / prepend ---------------------

        fn appendEntry(self: *Self, event: EventName, listener: Listener, once_flag: bool, at_head: bool) std.mem.Allocator.Error!void {
            // Overflow warning fires *after* the new listener is added
            // but only when transitioning across the threshold (Node's
            // `n.emit('newListener', ...)` flow). Capture once per
            // transition rather than every add.
            const prior_count = self.listenerCount(event);
            const will_warn = self.max_listeners > 0 and prior_count == self.max_listeners;

            const entry = Entry{ .event = event, .listener = listener, .once = once_flag };
            if (at_head) {
                try self.entries.insert(self.allocator, 0, entry);
            } else {
                try self.entries.append(self.allocator, entry);
            }

            if (will_warn) {
                var buf: [max_warning_bytes]u8 = undefined;
                const new_count = prior_count + 1;
                const msg = std.fmt.bufPrint(&buf, "MaxListenersExceededWarning: Possible EventEmitter memory leak detected. {d} listeners added. Use emitter.setMaxListeners() to increase limit", .{new_count}) catch buf[0..buf.len];
                captureWarning(msg);
            }
        }

        /// `emitter.on(event, listener)` — append listener for `event`.
        /// Returns an error only on OOM.
        pub fn on(self: *Self, event: EventName, listener: Listener) std.mem.Allocator.Error!void {
            try self.appendEntry(event, listener, false, false);
        }

        /// Alias of `on` — Node API parity.
        pub fn addListener(self: *Self, event: EventName, listener: Listener) std.mem.Allocator.Error!void {
            return self.on(event, listener);
        }

        /// `emitter.once(event, listener)` — append a single-shot
        /// listener. Removed *before* it fires so the callback can
        /// safely re-subscribe.
        pub fn once(self: *Self, event: EventName, listener: Listener) std.mem.Allocator.Error!void {
            try self.appendEntry(event, listener, true, false);
        }

        /// `emitter.prependListener(event, listener)` — insert at head.
        pub fn prependListener(self: *Self, event: EventName, listener: Listener) std.mem.Allocator.Error!void {
            try self.appendEntry(event, listener, false, true);
        }

        /// `emitter.prependOnceListener(event, listener)` — head-insert
        /// + single-shot.
        pub fn prependOnceListener(self: *Self, event: EventName, listener: Listener) std.mem.Allocator.Error!void {
            try self.appendEntry(event, listener, true, true);
        }

        // ---- off / removeListener ---------------------------------

        /// `emitter.off(event, listener)` — remove the *first* matching
        /// entry. Idempotent if no match.
        pub fn off(self: *Self, event: EventName, listener: Listener) void {
            var i: usize = 0;
            while (i < self.entries.items.len) : (i += 1) {
                const e = self.entries.items[i];
                if (eventEql(e.event, event) and listenerEql(e.listener, listener)) {
                    _ = self.entries.orderedRemove(i);
                    return;
                }
            }
        }

        /// Alias of `off`.
        pub fn removeListener(self: *Self, event: EventName, listener: Listener) void {
            self.off(event, listener);
        }

        /// `emitter.removeAllListeners(event)` — drops all listeners
        /// for `event`. Pass `null` to drop every listener across
        /// every event.
        pub fn removeAllListeners(self: *Self, event: ?EventName) void {
            if (event) |target| {
                var i: usize = 0;
                while (i < self.entries.items.len) {
                    if (eventEql(self.entries.items[i].event, target)) {
                        _ = self.entries.orderedRemove(i);
                    } else {
                        i += 1;
                    }
                }
            } else {
                self.entries.clearRetainingCapacity();
            }
        }

        // ---- emit -------------------------------------------------

        /// `emitter.emit(event, args)` — invokes every listener for
        /// `event` in insertion order with the supplied `args` tuple.
        /// Returns `true` if any listener fired (Node parity).
        ///
        /// `once` listeners are removed from the table *before* their
        /// callback runs. The snapshot is taken eagerly so a listener
        /// adding new listeners during emit does not see them fire on
        /// the in-flight dispatch (Node semantics).
        pub fn emit(self: *Self, event: EventName, args: anytype) bool {
            // Snapshot all entries that match this event. We collect
            // pointers-to-Entry rather than copies so the `once` flag
            // can be flipped before the callback runs.
            var matches: [64]Listener = undefined;
            var match_count: usize = 0;
            var fired_any = false;

            // First pass: snapshot listeners + drop `once` entries.
            // We iterate in reverse for the removal pass so indices
            // stay valid as we remove, then we reverse the snapshot
            // afterwards to restore insertion order.
            var i: usize = self.entries.items.len;
            while (i > 0) {
                i -= 1;
                const e = self.entries.items[i];
                if (eventEql(e.event, event)) {
                    if (match_count < matches.len) {
                        matches[match_count] = e.listener;
                        match_count += 1;
                    }
                    if (e.once) {
                        _ = self.entries.orderedRemove(i);
                    }
                }
            }

            // Reverse the snapshot so listeners fire in insertion
            // (forward) order.
            var lo: usize = 0;
            var hi: usize = match_count;
            while (lo + 1 < hi) {
                hi -= 1;
                const tmp = matches[lo];
                matches[lo] = matches[hi];
                matches[hi] = tmp;
                lo += 1;
            }

            // Second pass: invoke. `Listener` is a function pointer;
            // `@call` with the args tuple covers any arity.
            var k: usize = 0;
            while (k < match_count) : (k += 1) {
                _ = @call(.auto, matches[k], args);
                fired_any = true;
            }
            return fired_any;
        }

        // ---- introspection ----------------------------------------

        /// `emitter.listenerCount(event)` — number of listeners for
        /// `event`.
        pub fn listenerCount(self: *const Self, event: EventName) usize {
            var n: usize = 0;
            for (self.entries.items) |e| {
                if (eventEql(e.event, event)) n += 1;
            }
            return n;
        }

        /// `emitter.listeners(event)` — returns a freshly-allocated
        /// slice of listeners for `event`, in insertion order. Caller
        /// frees with the same allocator the emitter was constructed
        /// with.
        pub fn listeners(self: *const Self, allocator: std.mem.Allocator, event: EventName) std.mem.Allocator.Error![]Listener {
            const n = self.listenerCount(event);
            const out = try allocator.alloc(Listener, n);
            var w: usize = 0;
            for (self.entries.items) |e| {
                if (eventEql(e.event, event)) {
                    out[w] = e.listener;
                    w += 1;
                }
            }
            return out;
        }

        /// `emitter.eventNames()` — returns each distinct event name
        /// that has at least one registered listener. Caller frees.
        pub fn eventNames(self: *const Self, allocator: std.mem.Allocator) std.mem.Allocator.Error![]EventName {
            var out = std.ArrayListUnmanaged(EventName).empty;
            errdefer out.deinit(allocator);
            for (self.entries.items) |e| {
                var seen = false;
                for (out.items) |existing| {
                    if (eventEql(existing, e.event)) {
                        seen = true;
                        break;
                    }
                }
                if (!seen) try out.append(allocator, e.event);
            }
            return out.toOwnedSlice(allocator);
        }

        // ---- max listeners ----------------------------------------

        /// `emitter.setMaxListeners(n)`. `n <= 0` disables the
        /// overflow warning (Node's `Infinity` / 0 semantic).
        pub fn setMaxListeners(self: *Self, n: usize) void {
            self.max_listeners = n;
        }

        /// `emitter.getMaxListeners()` — current threshold (0 if
        /// disabled).
        pub fn getMaxListeners(self: *const Self) usize {
            return self.max_listeners;
        }
    };
}

/// Typical-case alias: string event names, zero-arg listeners.
/// Phase 12.2 will introduce `EventEmitterJS` with JSValue listeners
/// once the JSC bridge lands.
pub const EventEmitterDefault = EventEmitter([]const u8, *const fn () void);

// ---- Inline tests ---------------------------------------------------

const testing = std.testing;

// Test fixtures — module-level so fn pointers are stable across
// tests. Each callback bumps a counter so we can assert the dispatch
// table fired the listener exactly once.
var hit_a: u32 = 0;
var hit_b: u32 = 0;
var hit_once: u32 = 0;

fn bumpA() void {
    hit_a += 1;
}
fn bumpB() void {
    hit_b += 1;
}
fn bumpOnce() void {
    hit_once += 1;
}

test "EventEmitter — on + emit fires listener" {
    hit_a = 0;
    hit_b = 0;
    var ee = EventEmitterDefault.init(testing.allocator);
    defer ee.deinit();

    try ee.on("data", &bumpA);
    try ee.on("data", &bumpB);

    const fired = ee.emit("data", .{});
    try testing.expect(fired);
    try testing.expectEqual(@as(u32, 1), hit_a);
    try testing.expectEqual(@as(u32, 1), hit_b);
}

test "EventEmitter — emit returns false when no listeners" {
    var ee = EventEmitterDefault.init(testing.allocator);
    defer ee.deinit();
    try testing.expect(!ee.emit("nope", .{}));
}

test "EventEmitter — once removes listener after fire" {
    hit_once = 0;
    var ee = EventEmitterDefault.init(testing.allocator);
    defer ee.deinit();

    try ee.once("ping", &bumpOnce);
    try testing.expectEqual(@as(usize, 1), ee.listenerCount("ping"));

    _ = ee.emit("ping", .{});
    try testing.expectEqual(@as(u32, 1), hit_once);
    try testing.expectEqual(@as(usize, 0), ee.listenerCount("ping"));

    // Second emit must not re-fire.
    _ = ee.emit("ping", .{});
    try testing.expectEqual(@as(u32, 1), hit_once);
}

test "EventEmitter — off removes by listener identity" {
    hit_a = 0;
    var ee = EventEmitterDefault.init(testing.allocator);
    defer ee.deinit();

    try ee.on("x", &bumpA);
    try ee.on("x", &bumpA);
    try testing.expectEqual(@as(usize, 2), ee.listenerCount("x"));

    ee.off("x", &bumpA);
    try testing.expectEqual(@as(usize, 1), ee.listenerCount("x"));

    _ = ee.emit("x", .{});
    try testing.expectEqual(@as(u32, 1), hit_a);

    // off on the last instance leaves zero.
    ee.off("x", &bumpA);
    try testing.expectEqual(@as(usize, 0), ee.listenerCount("x"));

    // off on empty is a no-op.
    ee.off("x", &bumpA);
}

test "EventEmitter — listenerCount + listeners + eventNames" {
    var ee = EventEmitterDefault.init(testing.allocator);
    defer ee.deinit();

    try ee.on("a", &bumpA);
    try ee.on("b", &bumpB);
    try ee.on("b", &bumpA);

    try testing.expectEqual(@as(usize, 1), ee.listenerCount("a"));
    try testing.expectEqual(@as(usize, 2), ee.listenerCount("b"));
    try testing.expectEqual(@as(usize, 0), ee.listenerCount("missing"));

    const b_listeners = try ee.listeners(testing.allocator, "b");
    defer testing.allocator.free(b_listeners);
    try testing.expectEqual(@as(usize, 2), b_listeners.len);
    try testing.expectEqual(@as(*const fn () void, &bumpB), b_listeners[0]);
    try testing.expectEqual(@as(*const fn () void, &bumpA), b_listeners[1]);

    const names = try ee.eventNames(testing.allocator);
    defer testing.allocator.free(names);
    try testing.expectEqual(@as(usize, 2), names.len);
}

test "EventEmitter — removeAllListeners (per-event + global)" {
    var ee = EventEmitterDefault.init(testing.allocator);
    defer ee.deinit();

    try ee.on("a", &bumpA);
    try ee.on("a", &bumpB);
    try ee.on("b", &bumpA);

    ee.removeAllListeners("a");
    try testing.expectEqual(@as(usize, 0), ee.listenerCount("a"));
    try testing.expectEqual(@as(usize, 1), ee.listenerCount("b"));

    ee.removeAllListeners(null);
    try testing.expectEqual(@as(usize, 0), ee.listenerCount("b"));
}

test "EventEmitter — setMaxListeners + warn-on-overflow" {
    clearLastWarning();
    var ee = EventEmitterDefault.init(testing.allocator);
    defer ee.deinit();

    ee.setMaxListeners(2);
    try testing.expectEqual(@as(usize, 2), ee.getMaxListeners());

    try ee.on("e", &bumpA);
    try ee.on("e", &bumpB);
    try testing.expectEqual(@as(usize, 0), lastWarning().len);

    // Third listener trips the threshold (>= max_listeners + 1).
    try ee.on("e", &bumpA);
    try testing.expect(lastWarning().len > 0);
    try testing.expect(std.mem.indexOf(u8, lastWarning(), "MaxListenersExceededWarning") != null);
}

test "EventEmitter — prependListener fires at head" {
    hit_a = 0;
    hit_b = 0;
    var ee = EventEmitterDefault.init(testing.allocator);
    defer ee.deinit();

    try ee.on("ord", &bumpA);
    try ee.prependListener("ord", &bumpB);

    const got = try ee.listeners(testing.allocator, "ord");
    defer testing.allocator.free(got);
    try testing.expectEqual(@as(*const fn () void, &bumpB), got[0]);
    try testing.expectEqual(@as(*const fn () void, &bumpA), got[1]);
}

test "EventEmitter — prependOnceListener fires once at head" {
    hit_once = 0;
    var ee = EventEmitterDefault.init(testing.allocator);
    defer ee.deinit();

    try ee.on("ord", &bumpA);
    try ee.prependOnceListener("ord", &bumpOnce);
    try testing.expectEqual(@as(usize, 2), ee.listenerCount("ord"));

    _ = ee.emit("ord", .{});
    try testing.expectEqual(@as(u32, 1), hit_once);
    try testing.expectEqual(@as(usize, 1), ee.listenerCount("ord"));
}

test "EventEmitter — addListener / removeListener aliases" {
    hit_a = 0;
    var ee = EventEmitterDefault.init(testing.allocator);
    defer ee.deinit();

    try ee.addListener("x", &bumpA);
    try testing.expectEqual(@as(usize, 1), ee.listenerCount("x"));
    ee.removeListener("x", &bumpA);
    try testing.expectEqual(@as(usize, 0), ee.listenerCount("x"));
}
