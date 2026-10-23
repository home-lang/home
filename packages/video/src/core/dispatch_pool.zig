//! Bounded least-pending dispatch with one sent task per worker. No pointers,
//! threads or processes. Callers provide ACK/verified-join evidence and serialize.
const std = @import("std");
const Admission = @import("owned_admission.zig");
pub const Phase = enum(u32) { queued, sent, acknowledged, joined, retired };
pub fn Pool(comptime workers_capacity: usize, comptime tasks_capacity: usize) type {
    return struct {
        const Self = @This();
        const Registry = Admission.Registry(tasks_capacity);
        pub const Worker = struct { generation: u64 = 1, accepting: bool = true, joined: bool = false, pending: usize = 0, active: ?u64 = null };
        pub const Task = struct { ticket: Registry.Ticket, worker: usize, generation: u64, phase: Phase = .queued };
        admission: Registry,
        workers: [workers_capacity]Worker = @splat(.{}),
        tasks: [tasks_capacity]?Task = @splat(null),
        count: usize,
        cursor: usize = 0,
        pub fn init(workers: usize, items: usize, bytes: usize) !Self {
            if (workers == 0 or workers > workers_capacity) return error.InvalidConfiguration;
            return .{ .count = workers, .admission = try Registry.init(bytes, items) };
        }
        pub fn worker(self: *Self, index: usize, generation: u64) !*Worker {
            if (index >= self.count or self.workers[index].generation != generation) return error.StaleWorker;
            return &self.workers[index];
        }
        pub fn task(self: *Self, id: u64) !*Task {
            for (&self.tasks) |*entry| if (entry.*) |*t| {
                if (t.ticket.id == id) return t;
            };
            return error.StaleTicket;
        }
        pub fn reserve(self: *Self, bytes: usize) !Task {
            var selected: ?usize = null;
            for (0..self.count) |offset| {
                const index = (self.cursor + offset) % self.count;
                const w = &self.workers[index];
                if (!w.accepting or w.joined) continue;
                if (selected == null or w.pending < self.workers[selected.?].pending) selected = index;
            }
            const index = selected orelse return error.NoWorkers;
            const ticket = try self.admission.reserve(bytes);
            const result = Task{ .ticket = ticket, .worker = index, .generation = self.workers[index].generation };
            self.tasks[ticket.slot] = result;
            self.workers[index].pending += 1;
            self.cursor = (index + 1) % self.count;
            return result;
        }
        pub fn next(self: *Self, index: usize, generation: u64) !?u64 {
            const w = try self.worker(index, generation);
            if (!w.accepting or w.joined) return error.NoWorkers;
            if (w.active != null) return null;
            var id: ?u64 = null;
            for (self.tasks) |entry| if (entry) |t| {
                if (t.worker == index and t.generation == generation and t.phase == .queued and (id == null or t.ticket.id < id.?)) id = t.ticket.id;
            };
            return id;
        }
        /// Call only AFTER an atomic transport send succeeds.
        pub fn sent(self: *Self, id: u64) !void {
            const t = try self.task(id);
            const w = try self.worker(t.worker, t.generation);
            if (!w.accepting or w.joined) return error.NoWorkers;
            if (t.phase != .queued or w.active != null or (try self.next(t.worker, t.generation)) != id) return error.InvalidTransition;
            t.phase = .sent;
            w.active = id;
        }
        pub fn acknowledge(self: *Self, id: u64, index: usize, generation: u64) !void {
            _ = try self.worker(index, generation);
            const t = try self.task(id);
            if (t.worker != index or t.generation != generation or t.phase != .sent) return error.InvalidTransition;
            t.phase = .acknowledged;
        }
        /// Stops admission/dispatch; does NOT prove exit or allow sent retirement.
        pub fn stop(self: *Self, index: usize, generation: u64) !void {
            (try self.worker(index, generation)).accepting = false;
        }
        /// Caller must first verify process/thread exit, including mapping users.
        pub fn joined(self: *Self, index: usize, generation: u64) !void {
            const w = try self.worker(index, generation);
            w.accepting = false;
            w.joined = true;
            w.active = null;
            for (&self.tasks) |*entry| if (entry.*) |*t| {
                if (t.worker == index and t.generation == generation and (t.phase == .sent or t.phase == .acknowledged)) t.phase = .joined;
            };
        }
        /// Retire the resource, retaining admission through application cleanup.
        pub fn retire(self: *Self, id: u64) !void {
            const t = try self.task(id);
            if (t.phase == .sent) return error.NeedsJoin;
            const w = try self.worker(t.worker, t.generation);
            if (w.active == id) w.active = null;
            t.phase = .retired;
        }
        pub fn release(self: *Self, id: u64) !void {
            const t = (try self.task(id)).*;
            if (t.phase != .retired) return error.InvalidTransition;
            try self.admission.release(t.ticket);
            self.workers[t.worker].pending -= 1;
            self.tasks[t.ticket.slot] = null;
        }
        pub fn restart(self: *Self, index: usize, generation: u64) !u64 {
            const w = try self.worker(index, generation);
            if (!w.joined or w.pending != 0 or w.active != null) return error.NeedsJoin;
            if (w.generation == std.math.maxInt(u64)) return error.SequenceOverflow;
            w.* = .{ .generation = w.generation + 1 };
            return w.generation;
        }
    };
}
test "least-pending ties rotate and retired cleanup remains charged" {
    const t = std.testing;
    var p = try Pool(3, 4).init(3, 4, 10);
    const a = try p.reserve(2);
    const b = try p.reserve(2);
    const c = try p.reserve(2);
    try t.expectEqual(@as(usize, 0), a.worker);
    try t.expectEqual(@as(usize, 1), b.worker);
    try t.expectEqual(@as(usize, 2), c.worker);
    try p.retire(a.ticket.id);
    const d = try p.reserve(4);
    try t.expectEqual(@as(usize, 0), d.worker);
    try t.expectError(error.BufferFull, p.reserve(0));
    try p.release(a.ticket.id);
    try t.expectEqual(@as(usize, 8), p.admission.used);
    try t.expectError(error.StaleTicket, p.release(a.ticket.id));
    try p.sent(b.ticket.id);
    try t.expectError(error.NeedsJoin, p.retire(b.ticket.id));
    try p.acknowledge(b.ticket.id, b.worker, b.generation);
    try p.retire(b.ticket.id);
    try p.release(b.ticket.id);
    const fresh = try p.reserve(1);
    try t.expectEqual(@as(usize, 0), fresh.ticket.slot);
    try t.expectEqual(@as(usize, 1), fresh.worker);
    try t.expect(fresh.ticket.id > d.ticket.id);
}
test "stop is not join, stale workers cannot acknowledge replacement tasks" {
    const t = std.testing;
    var p = try Pool(1, 3).init(1, 3, 32);
    const a = try p.reserve(1);
    const b = try p.reserve(1);
    try t.expectEqual(a.ticket.id, (try p.next(0, 1)).?);
    try p.sent(a.ticket.id);
    try t.expect((try p.next(0, 1)) == null);
    try t.expectError(error.InvalidTransition, p.sent(b.ticket.id));
    try p.stop(0, 1);
    try t.expectError(error.NeedsJoin, p.retire(a.ticket.id));
    try t.expectError(error.NoWorkers, p.reserve(1));
    try p.joined(0, 1);
    try p.retire(a.ticket.id);
    try p.retire(b.ticket.id);
    try t.expectError(error.NeedsJoin, p.restart(0, 1));
    try p.release(a.ticket.id);
    try p.release(b.ticket.id);
    try t.expectEqual(@as(u64, 2), try p.restart(0, 1));
    const fresh = try p.reserve(1);
    try p.sent(fresh.ticket.id);
    try t.expectError(error.StaleWorker, p.acknowledge(fresh.ticket.id, 0, 1));
    try t.expectError(error.StaleWorker, p.acknowledge(fresh.ticket.id, 1, 2));
}
test "invalid dispatch transitions preserve active work and admission" {
    const t = std.testing;
    try t.expectError(error.InvalidConfiguration, Pool(2, 3).init(0, 1, 10));
    try t.expectError(error.InvalidConfiguration, Pool(2, 3).init(3, 1, 10));
    var p = try Pool(2, 3).init(2, 3, 8);
    const a = try p.reserve(4);
    const b = try p.reserve(4);
    try t.expectError(error.BufferFull, p.reserve(1));
    try t.expectEqual(@as(usize, 8), p.admission.used);
    try p.sent(a.ticket.id);
    try t.expectError(error.InvalidTransition, p.acknowledge(a.ticket.id, b.worker, 1));
    try t.expectError(error.InvalidTransition, p.release(a.ticket.id));
    try p.acknowledge(a.ticket.id, a.worker, 1);
    try t.expectError(error.InvalidTransition, p.acknowledge(a.ticket.id, a.worker, 1));
    try p.retire(a.ticket.id);
    try p.retire(a.ticket.id);
    try p.release(a.ticket.id);
    try t.expectEqual(@as(usize, 4), p.admission.used);
    try t.expectEqual(@as(usize, 1), p.admission.count);
    try t.expectEqual(b.ticket.id, (try p.next(b.worker, 1)).?);
}
