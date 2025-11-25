// Home Programming Language - Pipe System
// Anonymous pipes for inter-process communication

const Basics = @import("basics");
const sync = @import("sync.zig");
const vfs = @import("vfs.zig");

// ============================================================================
// Pipe Buffer
// ============================================================================

pub const PIPE_SIZE = 65536; // 64 KB default pipe buffer

pub const PipeBuffer = struct {
    data: []u8,
    read_pos: usize,
    write_pos: usize,
    size: usize,
    lock: sync.RwLock,
    read_wait: sync.WaitQueue,
    write_wait: sync.WaitQueue,
    allocator: Basics.Allocator,

    pub fn init(allocator: Basics.Allocator, size: usize) !*PipeBuffer {
        const buffer = try allocator.create(PipeBuffer);
        errdefer allocator.destroy(buffer);

        buffer.* = .{
            .data = try allocator.alloc(u8, size),
            .read_pos = 0,
            .write_pos = 0,
            .size = size,
            .lock = sync.RwLock.init(),
            .read_wait = sync.WaitQueue.init(),
            .write_wait = sync.WaitQueue.init(),
            .allocator = allocator,
        };

        return buffer;
    }

    pub fn deinit(self: *PipeBuffer) void {
        self.allocator.free(self.data);
        self.allocator.destroy(self);
    }

    /// Get number of bytes available to read
    pub fn available(self: *PipeBuffer) usize {
        if (self.write_pos >= self.read_pos) {
            return self.write_pos - self.read_pos;
        } else {
            return self.size - self.read_pos + self.write_pos;
        }
    }

    /// Get number of bytes available to write
    pub fn space(self: *PipeBuffer) usize {
        return self.size - self.available() - 1; // Keep 1 byte gap
    }

    /// Check if buffer is empty
    pub fn isEmpty(self: *PipeBuffer) bool {
        return self.read_pos == self.write_pos;
    }

    /// Check if buffer is full
    pub fn isFull(self: *PipeBuffer) bool {
        return self.space() == 0;
    }

    /// Read data from pipe
    pub fn read(self: *PipeBuffer, dest: []u8) usize {
        self.lock.acquireWrite();
        defer self.lock.releaseWrite();

        var bytes_read: usize = 0;
        const avail = self.available();
        const to_read = Basics.math.min(dest.len, avail);

        while (bytes_read < to_read) {
            dest[bytes_read] = self.data[self.read_pos];
            self.read_pos = (self.read_pos + 1) % self.size;
            bytes_read += 1;
        }

        // Wake up any waiting writers
        if (bytes_read > 0) {
            self.write_wait.wakeOne();
        }

        return bytes_read;
    }

    /// Write data to pipe
    pub fn write(self: *PipeBuffer, src: []const u8) usize {
        self.lock.acquireWrite();
        defer self.lock.releaseWrite();

        var bytes_written: usize = 0;
        const free_space = self.space();
        const to_write = Basics.math.min(src.len, free_space);

        while (bytes_written < to_write) {
            self.data[self.write_pos] = src[bytes_written];
            self.write_pos = (self.write_pos + 1) % self.size;
            bytes_written += 1;
        }

        // Wake up any waiting readers
        if (bytes_written > 0) {
            self.read_wait.wakeOne();
        }

        return bytes_written;
    }

    /// Wait for data to be available
    pub fn waitForData(self: *PipeBuffer) void {
        self.read_wait.wait();
    }

    /// Wait for space to be available
    pub fn waitForSpace(self: *PipeBuffer) void {
        self.write_wait.wait();
    }
};

// ============================================================================
// Pipe Endpoint
// ============================================================================

pub const PipeEndpoint = struct {
    buffer: *PipeBuffer,
    is_read_end: bool,
    is_open: bool,
    refcount: sync.RefCount,

    pub fn init(buffer: *PipeBuffer, is_read_end: bool) PipeEndpoint {
        return .{
            .buffer = buffer,
            .is_read_end = is_read_end,
            .is_open = true,
            .refcount = sync.RefCount.init(),
        };
    }

    pub fn close(self: *PipeEndpoint) void {
        if (!self.is_open) return;
        self.is_open = false;

        // Wake up any waiting processes
        if (self.is_read_end) {
            self.buffer.write_wait.wakeAll();
        } else {
            self.buffer.read_wait.wakeAll();
        }

        if (self.refcount.release()) {
            // Last reference, clean up
            self.buffer.deinit();
        }
    }
};

// ============================================================================
// Pipe Operations
// ============================================================================

const PipeOps = struct {
    pub fn read(file: *vfs.File, buffer: []u8, offset: u64) !usize {
        _ = offset; // Pipes ignore offset
        const pipe = @as(*PipeEndpoint, @ptrCast(@alignCast(file.private_data)));

        if (!pipe.is_read_end) return error.InvalidOperation;
        if (!pipe.is_open) return error.BrokenPipe;

        while (pipe.buffer.isEmpty()) {
            // Check if write end is closed
            if (!pipe.is_open) {
                return 0; // EOF
            }
            pipe.buffer.waitForData();
        }

        return pipe.buffer.read(buffer);
    }

    pub fn write(file: *vfs.File, buffer: []const u8, offset: u64) !usize {
        _ = offset; // Pipes ignore offset
        const pipe = @as(*PipeEndpoint, @ptrCast(@alignCast(file.private_data)));

        if (pipe.is_read_end) return error.InvalidOperation;
        if (!pipe.is_open) return error.BrokenPipe;

        var written: usize = 0;
        while (written < buffer.len) {
            while (pipe.buffer.isFull()) {
                pipe.buffer.waitForSpace();
            }

            const chunk = pipe.buffer.write(buffer[written..]);
            if (chunk == 0) break;
            written += chunk;
        }

        return written;
    }

    pub fn close(file: *vfs.File) void {
        const pipe = @as(*PipeEndpoint, @ptrCast(@alignCast(file.private_data)));
        pipe.close();
    }

    pub fn poll(file: *vfs.File, events: u32) u32 {
        const pipe = @as(*PipeEndpoint, @ptrCast(@alignCast(file.private_data)));
        var result: u32 = 0;

        const POLLIN = 0x0001;
        const POLLOUT = 0x0004;
        const POLLHUP = 0x0010;

        if (pipe.is_read_end) {
            if (!pipe.buffer.isEmpty()) {
                result |= POLLIN;
            }
            if (!pipe.is_open) {
                result |= POLLHUP;
            }
        } else {
            if (!pipe.buffer.isFull()) {
                result |= POLLOUT;
            }
            if (!pipe.is_open) {
                result |= POLLHUP;
            }
        }

        return result & events;
    }
};

// ============================================================================
// Pipe Creation
// ============================================================================

/// Create a pipe pair
pub fn createPipe(allocator: Basics.Allocator) ![2]*vfs.File {
    // Create shared buffer
    const buffer = try PipeBuffer.init(allocator, PIPE_SIZE);
    errdefer buffer.deinit();

    // Create read endpoint
    const read_endpoint = try allocator.create(PipeEndpoint);
    errdefer allocator.destroy(read_endpoint);
    read_endpoint.* = PipeEndpoint.init(buffer, true);
    read_endpoint.refcount.acquire();

    // Create write endpoint
    const write_endpoint = try allocator.create(PipeEndpoint);
    errdefer allocator.destroy(write_endpoint);
    write_endpoint.* = PipeEndpoint.init(buffer, false);
    write_endpoint.refcount.acquire();

    // Create VFS file objects
    const read_file = try vfs.File.create(allocator);
    errdefer read_file.destroy();
    read_file.ops = .{
        .read = PipeOps.read,
        .write = null,
        .close = PipeOps.close,
        .poll = PipeOps.poll,
    };
    read_file.private_data = read_endpoint;
    read_file.flags = vfs.O_RDONLY;

    const write_file = try vfs.File.create(allocator);
    errdefer write_file.destroy();
    write_file.ops = .{
        .read = null,
        .write = PipeOps.write,
        .close = PipeOps.close,
        .poll = PipeOps.poll,
    };
    write_file.private_data = write_endpoint;
    write_file.flags = vfs.O_WRONLY;

    return [2]*vfs.File{ read_file, write_file };
}

// ============================================================================
// System Call Interface
// ============================================================================

/// sys_pipe - Create a pipe
pub fn sysPipe(pipefd: *[2]i32) !void {
    const current = @import("process.zig").current() orelse return error.NoProcess;
    const allocator = current.allocator;

    const files = try createPipe(allocator);
    errdefer {
        files[0].destroy();
        files[1].destroy();
    }

    // Find two free file descriptors
    const read_fd = try current.addFile(files[0]);
    errdefer current.removeFile(read_fd);

    const write_fd = try current.addFile(files[1]);
    errdefer current.removeFile(write_fd);

    pipefd[0] = @intCast(read_fd);
    pipefd[1] = @intCast(write_fd);
}

/// sys_pipe2 - Create a pipe with flags
pub fn sysPipe2(pipefd: *[2]i32, flags: u32) !void {
    try sysPipe(pipefd);

    // Handle pipe flags
    const O_NONBLOCK: u32 = 0o4000;
    const O_CLOEXEC: u32 = 0o2000000;

    const current = process.current() orelse return error.NoProcess;

    if (flags & O_CLOEXEC != 0) {
        // Set close-on-exec flag for both file descriptors
        if (current.getFile(@intCast(pipefd[0]))) |fd| {
            fd.flags |= vfs.O_CLOEXEC;
        }
        if (current.getFile(@intCast(pipefd[1]))) |fd| {
            fd.flags |= vfs.O_CLOEXEC;
        }
    }

    if (flags & O_NONBLOCK != 0) {
        // Set non-blocking flag for both file descriptors
        if (current.getFile(@intCast(pipefd[0]))) |fd| {
            fd.flags |= vfs.O_NONBLOCK;
        }
        if (current.getFile(@intCast(pipefd[1]))) |fd| {
            fd.flags |= vfs.O_NONBLOCK;
        }
    }
}

// ============================================================================
// Named Pipes (FIFOs)
// ============================================================================

pub const Fifo = struct {
    buffer: *PipeBuffer,
    readers: u32,
    writers: u32,
    lock: sync.Spinlock,

    pub fn init(allocator: Basics.Allocator) !*Fifo {
        const fifo = try allocator.create(Fifo);
        errdefer allocator.destroy(fifo);

        fifo.* = .{
            .buffer = try PipeBuffer.init(allocator, PIPE_SIZE),
            .readers = 0,
            .writers = 0,
            .lock = sync.Spinlock.init(),
        };

        return fifo;
    }

    pub fn deinit(self: *Fifo, allocator: Basics.Allocator) void {
        self.buffer.deinit();
        allocator.destroy(self);
    }

    pub fn openRead(self: *Fifo) void {
        self.lock.acquire();
        defer self.lock.release();
        self.readers += 1;
    }

    pub fn openWrite(self: *Fifo) void {
        self.lock.acquire();
        defer self.lock.release();
        self.writers += 1;
    }

    pub fn closeRead(self: *Fifo) void {
        self.lock.acquire();
        defer self.lock.release();
        if (self.readers > 0) {
            self.readers -= 1;
        }
        if (self.readers == 0) {
            self.buffer.read_wait.wakeAll();
        }
    }

    pub fn closeWrite(self: *Fifo) void {
        self.lock.acquire();
        defer self.lock.release();
        if (self.writers > 0) {
            self.writers -= 1;
        }
        if (self.writers == 0) {
            self.buffer.write_wait.wakeAll();
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

test "pipe buffer operations" {
    const allocator = Basics.testing.allocator;
    const buffer = try PipeBuffer.init(allocator, 1024);
    defer buffer.deinit();

    try Basics.testing.expect(buffer.isEmpty());
    try Basics.testing.expect(!buffer.isFull());

    const write_data = "Hello, Pipe!";
    const written = buffer.write(write_data);
    try Basics.testing.expectEqual(write_data.len, written);

    var read_data: [20]u8 = undefined;
    const read_count = buffer.read(&read_data);
    try Basics.testing.expectEqual(write_data.len, read_count);
    try Basics.testing.expectEqualSlices(u8, write_data, read_data[0..read_count]);

    try Basics.testing.expect(buffer.isEmpty());
}

test "pipe creation" {
    const allocator = Basics.testing.allocator;
    const pipes = try createPipe(allocator);
    defer {
        pipes[0].destroy();
        pipes[1].destroy();
    }

    try Basics.testing.expect(pipes[0] != pipes[1]);
}

test "pipe circular buffer" {
    const allocator = Basics.testing.allocator;
    const buffer = try PipeBuffer.init(allocator, 16);
    defer buffer.deinit();

    // Write data that wraps around
    var data: [20]u8 = undefined;
    for (&data, 0..) |*byte, i| {
        byte.* = @intCast(i);
    }

    // Write 12 bytes
    _ = buffer.write(data[0..12]);
    try Basics.testing.expectEqual(@as(usize, 12), buffer.available());

    // Read 8 bytes
    var read_buf: [8]u8 = undefined;
    _ = buffer.read(&read_buf);
    try Basics.testing.expectEqual(@as(usize, 4), buffer.available());

    // Write 10 more bytes (should wrap around)
    _ = buffer.write(data[12..20]);
    try Basics.testing.expectEqual(@as(usize, 14), buffer.available());
}
