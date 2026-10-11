//! Owned directory descriptors and streaming iterators. JS objects own states;
//! admitted work-pool tasks root those objects until owner-thread completion.
const bun = @import("bun");
const std = @import("std");
const jsc = bun.jsc;
const Iterator = @import("./dir_iterator.zig").WrappedIterator;
const Maybe = bun.sys.Maybe;
const allocator = bun.default_allocator;

extern fn Home__Directory__wrap(*jsc.JSGlobalObject, *State) jsc.JSValue;
extern fn Home__Directory__report(*jsc.JSGlobalObject, jsc.JSValue) void;
extern fn Home__Directory__state(*jsc.JSGlobalObject, jsc.JSValue) ?*State;

var registry_lock: bun.Mutex = .{};
var registry: ?*State = null;

const Frame = struct {
    fd: bun.FD,
    iterator: Iterator,
    path: []u8,
};

pub const State = struct {
    lock: bun.Mutex = .{},
    frames: std.array_list.Managed(Frame),
    encoding: jsc.Node.Encoding,
    recursive: bool,
    buffer_size: u32,
    buffer_path: bool,
    pending: std.array_list.Managed(ReadResult),
    pending_index: usize = 0,
    closed: bool = false,
    global: ?*jsc.JSGlobalObject = null,
    next: ?*State = null,

    pub fn open(path: [:0]const u8, encoding: jsc.Node.Encoding, recursive: bool, buffer_size: u32, buffer_path: bool) Maybe(*State) {
        const fd = switch (openAt(bun.FD.cwd(), path)) {
            .err => |err| return .{ .err = err },
            .result => |fd| fd,
        };
        return fromFD(fd, path, encoding, recursive, buffer_size, buffer_path);
    }

    pub fn fromFD(fd: bun.FD, path: []const u8, encoding: jsc.Node.Encoding, recursive: bool, buffer_size: u32, buffer_path: bool) Maybe(*State) {
        var frames = std.array_list.Managed(Frame).init(allocator);
        bun.handleOom(frames.append(.{ .fd = fd, .iterator = Iterator.init(fd), .path = bun.handleOom(allocator.dupe(u8, path)) }));
        return .{ .result = bun.new(State, .{ .frames = frames, .encoding = encoding, .recursive = recursive, .buffer_size = buffer_size, .buffer_path = buffer_path, .pending = std.array_list.Managed(ReadResult).init(allocator) }) };
    }

    pub fn toJS(this: *State, global: *jsc.JSGlobalObject) jsc.JSValue {
        const result = Home__Directory__wrap(global, this);
        registry_lock.lock();
        defer registry_lock.unlock();
        this.global = global;
        this.next = registry;
        registry = this;
        return result;
    }

    pub fn hasBuffered(this: *State) bool {
        this.lock.lock();
        defer this.lock.unlock();
        return !this.closed and this.pending_index < this.pending.items.len;
    }

    pub fn read(this: *State) Maybe(ReadResult) {
        this.lock.lock();
        defer this.lock.unlock();
        if (this.closed) return .{ .err = .{ .errno = @backingInt(bun.sys.E.BADF), .syscall = .scandir } };
        if (this.pending_index == this.pending.items.len) {
            this.pending.clearRetainingCapacity();
            this.pending_index = 0;
            while (this.pending.items.len < this.buffer_size) {
                const result = switch (this.readNext()) {
                    .err => |err| {
                        for (this.pending.items) |*entry| entry.deinitForShutdown();
                        this.pending.clearRetainingCapacity();
                        // Clone borrowed syscall diagnostics while the descriptor
                        // and iterator are still locked. Another queued operation
                        // may close or advance the iterator after this returns.
                        return .{ .err = err.clone(allocator) };
                    },
                    .result => |result| result,
                };
                if (result.entry == null) break;
                bun.handleOom(this.pending.append(result));
            }
        }
        if (this.pending_index == this.pending.items.len) return .{ .result = .{} };
        const result = this.pending.items[this.pending_index];
        this.pending.items[this.pending_index] = .{};
        this.pending_index += 1;
        return .{ .result = result };
    }

    fn readNext(this: *State) Maybe(ReadResult) {
        while (this.frames.items.len > 0) {
            const frame = &this.frames.items[this.frames.items.len - 1];
            const entry = switch (frame.iterator.next()) {
                .err => |err| return .{ .err = err },
                .result => |entry| entry,
            } orelse {
                if (this.frames.items.len == 1) return .{ .result = .{} };
                const finished = this.frames.pop().?;
                _ = finished.fd.closeAllowingStandardIo(@returnAddress());
                allocator.free(finished.path);
                continue;
            };
            const name = entry.name.slice();
            const kind = if (entry.kind == .unknown)
                switch (bun.sys.lstatat(frame.fd, entry.name.sliceAssumeZ())) {
                    .result => |stat| bun.sys.kindFromMode(@intCast(stat.mode)),
                    .err => |err| return .{ .err = err },
                }
            else
                entry.kind;
            const result = ReadResult{
                .entry = .{
                    .name = jsc.WebCore.encoding.toBunString(name, if (this.encoding == .buffer) .utf8 else this.encoding),
                    .path = bun.String.cloneUTF8(frame.path),
                    .kind = kind,
                },
                .buffer_name = if (this.encoding == .buffer) bun.handleOom(allocator.dupe(u8, name)) else null,
                .buffer_path = if (this.buffer_path) bun.handleOom(allocator.dupe(u8, frame.path)) else null,
            };
            if (this.recursive and kind == .directory) {
                const child_fd = switch (openAt(frame.fd, entry.name.sliceAssumeZ())) {
                    .err => |err| {
                        var discard = result;
                        discard.deinitForShutdown();
                        return .{ .err = err };
                    },
                    .result => |fd| fd,
                };
                const child_path = bun.handleOom(std.fmt.allocPrint(allocator, "{s}{c}{s}", .{ frame.path, std.fs.path.sep, name }));
                bun.handleOom(this.frames.append(.{ .fd = child_fd, .iterator = Iterator.init(child_fd), .path = child_path }));
            }
            return .{ .result = result };
        }
        return .{ .result = .{} };
    }

    pub fn close(this: *State) Maybe(void) {
        this.lock.lock();
        defer this.lock.unlock();
        if (this.closed) return .{ .err = .{ .errno = @backingInt(bun.sys.E.BADF), .syscall = .close } };
        this.closed = true;
        var first_error: ?bun.sys.Error = null;
        for (this.frames.items) |frame| {
            const err = frame.fd.closeAllowingStandardIo(@returnAddress());
            if (first_error == null) first_error = err;
            allocator.free(frame.path);
        }
        this.frames.clearRetainingCapacity();
        for (this.pending.items) |*entry| entry.deinitForShutdown();
        this.pending.clearRetainingCapacity();
        this.pending_index = 0;
        if (first_error) |err| return .{ .err = err };
        return .{ .result = {} };
    }

    pub fn memoryCost(this: *State) usize {
        this.lock.lock();
        defer this.lock.unlock();
        var total = @sizeOf(State) + this.frames.capacity * @sizeOf(Frame) + this.pending.capacity * @sizeOf(ReadResult);
        for (this.frames.items) |frame| total += frame.path.len;
        for (this.pending.items) |entry| {
            if (entry.buffer_name) |bytes| total += bytes.len;
            if (entry.buffer_path) |bytes| total += bytes.len;
        }
        return total;
    }

    pub fn destroy(this: *State) void {
        registry_lock.lock();
        var cursor = &registry;
        while (cursor.*) |state| {
            if (state == this) {
                cursor.* = state.next;
                break;
            }
            cursor = &state.next;
        }
        registry_lock.unlock();
        if (!this.closed) _ = this.close();
        this.frames.deinit();
        this.pending.deinit();
        bun.destroy(this);
    }
};

fn openAt(parent: bun.FD, path: [:0]const u8) Maybe(bun.FD) {
    return if (bun.Environment.isWindows)
        bun.sys.openDirAtWindowsA(parent, path, .{ .iterable = true, .read_only = true })
    else
        bun.sys.openat(parent, path, bun.O.DIRECTORY | bun.O.RDONLY | bun.O.CLOEXEC, 0);
}

pub const OpenResult = struct {
    state: *State,
    pub fn toJS(this: OpenResult, global: *jsc.JSGlobalObject) jsc.JSValue {
        return this.state.toJS(global);
    }
    pub fn deinitForShutdown(this: *OpenResult) void {
        this.state.destroy();
    }
};

pub const ReadResult = struct {
    entry: ?jsc.Node.Dirent = null,
    buffer_name: ?[]u8 = null,
    buffer_path: ?[]u8 = null,

    pub fn toJS(this: *ReadResult, global: *jsc.JSGlobalObject) bun.JSError!jsc.JSValue {
        var entry = this.entry orelse return .null;
        this.entry = null;
        errdefer this.deinitForShutdown();
        const result = try entry.toJSNewlyCreated(global, null);
        var rooted = jsc.Strong.create(result, global);
        defer rooted.deinit();
        if (this.buffer_name) |bytes| {
            this.buffer_name = null;
            const buffer = jsc.MarkedArrayBuffer.fromBytes(bytes, allocator, .Uint8Array);
            result.put(global, "name", buffer.toNodeBuffer(global));
        }
        if (this.buffer_path) |bytes| {
            this.buffer_path = null;
            const buffer = jsc.MarkedArrayBuffer.fromBytes(bytes, allocator, .Uint8Array);
            const path = buffer.toNodeBuffer(global);
            result.put(global, "path", path);
            result.put(global, "parentPath", path);
        }
        return result;
    }

    pub fn deinitForShutdown(this: *ReadResult) void {
        if (this.entry) |entry| entry.deref();
        if (this.buffer_name) |bytes| allocator.free(bytes);
        if (this.buffer_path) |bytes| allocator.free(bytes);
        this.* = .{};
    }
};

pub const HandleArgument = struct {
    pub const owns_result_error = true;
    state: *State,
    root: jsc.Strong.Optional,

    pub fn fromJS(global: *jsc.JSGlobalObject, arguments: *jsc.CallFrame.ArgumentsSlice) bun.JSError!HandleArgument {
        const value = arguments.nextEat() orelse return global.throwInvalidArguments("directory handle is required", .{});
        const state = Home__Directory__state(global, value) orelse return error.JSError;
        return .{ .state = state, .root = .create(value, global) };
    }
    pub fn toThreadSafe(_: *HandleArgument) void {}
    pub fn didDispatch(this: *HandleArgument, global: *jsc.JSGlobalObject) void {
        Home__Directory__report(global, this.root.get().?);
    }
    pub fn deinit(this: HandleArgument) void {
        var root = this.root;
        root.deinit();
    }
};

pub const CloseArgument = struct {
    pub const owns_result_error = true;
    pub const directory_close_callback = true;
    handle: HandleArgument,
    pub fn fromJS(global: *jsc.JSGlobalObject, arguments: *jsc.CallFrame.ArgumentsSlice) bun.JSError!CloseArgument {
        return .{ .handle = try HandleArgument.fromJS(global, arguments) };
    }
    pub fn toThreadSafe(_: *CloseArgument) void {}
    pub fn didDispatch(this: *CloseArgument, global: *jsc.JSGlobalObject) void {
        this.handle.didDispatch(global);
    }
    pub fn deinit(this: CloseArgument) void {
        this.handle.deinit();
    }
};

pub export fn Home__Directory__hasBuffered(state: *State) bool {
    return state.hasBuffered();
}

pub export fn Home__Directory__isOpen(state: *State) bool {
    state.lock.lock();
    defer state.lock.unlock();
    return !state.closed;
}

pub export fn Home__Directory__memoryCost(state: *State) usize {
    return state.memoryCost();
}

pub export fn Home__Directory__release(state: *State) void {
    state.destroy();
}

/// Called only after admitted native jobs quiesce and before heap teardown.
/// Retained JS objects stay branded but their native descriptors are retired.
pub fn shutdown(global: *jsc.JSGlobalObject) void {
    registry_lock.lock();
    defer registry_lock.unlock();
    var cursor = registry;
    while (cursor) |state| : (cursor = state.next) {
        if (state.global == global and !state.closed) _ = state.close();
    }
}
