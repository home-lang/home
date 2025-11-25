// Home Video Library - Pipe I/O
// Support for stdin/stdout, pipes, and stream-based I/O

const std = @import("std");
const source = @import("source.zig");
const target = @import("target.zig");
const err = @import("../core/error.zig");

pub const Source = source.Source;
pub const Target = target.Target;
pub const VideoError = err.VideoError;

// ============================================================================
// Stdin Source
// ============================================================================

pub const StdinSource = struct {
    stdin: std.fs.File,
    bytes_read: u64 = 0,

    const Self = @This();

    pub fn init() Self {
        return .{
            .stdin = std.io.getStdIn(),
        };
    }

    pub fn source_interface(self: *Self) Source {
        return Source{
            .ctx = self,
            .read_fn = readImpl,
            .seek_fn = null, // stdin is not seekable
            .tell_fn = tellImpl,
            .size_fn = sizeImpl,
        };
    }

    fn readImpl(ctx: *anyopaque, buffer: []u8) anyerror!usize {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const n = try self.stdin.read(buffer);
        self.bytes_read += n;
        return n;
    }

    fn tellImpl(ctx: *anyopaque) u64 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.bytes_read;
    }

    fn sizeImpl(ctx: *anyopaque) ?u64 {
        _ = ctx;
        return null; // stdin has no known size
    }
};

// ============================================================================
// Stdout Target
// ============================================================================

pub const StdoutTarget = struct {
    stdout: std.fs.File,
    bytes_written: u64 = 0,

    const Self = @This();

    pub fn init() Self {
        return .{
            .stdout = std.io.getStdOut(),
        };
    }

    pub fn target_interface(self: *Self) Target {
        return Target{
            .ctx = self,
            .write_fn = writeImpl,
            .seek_fn = null, // stdout is not seekable
            .tell_fn = tellImpl,
            .flush_fn = flushImpl,
        };
    }

    fn writeImpl(ctx: *anyopaque, data: []const u8) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        try self.stdout.writeAll(data);
        self.bytes_written += data.len;
    }

    fn tellImpl(ctx: *anyopaque) u64 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.bytes_written;
    }

    fn flushImpl(ctx: *anyopaque) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        // Stdout doesn't have a flush method in std.fs.File
        _ = self;
    }
};

// ============================================================================
// Pipe Source (Named Pipes / FIFOs)
// ============================================================================

pub const PipeSource = struct {
    file: std.fs.File,
    bytes_read: u64 = 0,

    const Self = @This();

    pub fn open(path: []const u8) !Self {
        const file = try std.fs.cwd().openFile(path, .{});
        return .{
            .file = file,
        };
    }

    pub fn close(self: *Self) void {
        self.file.close();
    }

    pub fn source_interface(self: *Self) Source {
        return Source{
            .ctx = self,
            .read_fn = readImpl,
            .seek_fn = null, // pipes are not seekable
            .tell_fn = tellImpl,
            .size_fn = sizeImpl,
        };
    }

    fn readImpl(ctx: *anyopaque, buffer: []u8) anyerror!usize {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const n = try self.file.read(buffer);
        self.bytes_read += n;
        return n;
    }

    fn tellImpl(ctx: *anyopaque) u64 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.bytes_read;
    }

    fn sizeImpl(ctx: *anyopaque) ?u64 {
        _ = ctx;
        return null; // pipes have no known size
    }
};

// ============================================================================
// Pipe Target
// ============================================================================

pub const PipeTarget = struct {
    file: std.fs.File,
    bytes_written: u64 = 0,

    const Self = @This();

    pub fn open(path: []const u8) !Self {
        const file = try std.fs.cwd().createFile(path, .{});
        return .{
            .file = file,
        };
    }

    pub fn close(self: *Self) void {
        self.file.close();
    }

    pub fn target_interface(self: *Self) Target {
        return Target{
            .ctx = self,
            .write_fn = writeImpl,
            .seek_fn = null, // pipes are not seekable
            .tell_fn = tellImpl,
            .flush_fn = flushImpl,
        };
    }

    fn writeImpl(ctx: *anyopaque, data: []const u8) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        try self.file.writeAll(data);
        self.bytes_written += data.len;
    }

    fn tellImpl(ctx: *anyopaque) u64 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.bytes_written;
    }

    fn flushImpl(ctx: *anyopaque) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        try self.file.sync();
    }
};

// ============================================================================
// Ring Buffer for Pipe Communication
// ============================================================================

pub const RingBufferPipe = struct {
    buffer: []u8,
    read_pos: usize = 0,
    write_pos: usize = 0,
    count: usize = 0,
    mutex: std.Thread.Mutex = .{},
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, size: usize) !Self {
        const buffer = try allocator.alloc(u8, size);
        return .{
            .buffer = buffer,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.buffer);
    }

    /// Write data to ring buffer
    pub fn write(self: *Self, data: []const u8) !usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        const available = self.buffer.len - self.count;
        const to_write = @min(data.len, available);

        if (to_write == 0) return 0;

        var written: usize = 0;
        while (written < to_write) {
            const chunk = @min(to_write - written, self.buffer.len - self.write_pos);
            @memcpy(
                self.buffer[self.write_pos..][0..chunk],
                data[written..][0..chunk],
            );

            self.write_pos = (self.write_pos + chunk) % self.buffer.len;
            written += chunk;
        }

        self.count += to_write;
        return to_write;
    }

    /// Read data from ring buffer
    pub fn read(self: *Self, buffer: []u8) usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        const to_read = @min(buffer.len, self.count);
        if (to_read == 0) return 0;

        var read_count: usize = 0;
        while (read_count < to_read) {
            const chunk = @min(to_read - read_count, self.buffer.len - self.read_pos);
            @memcpy(
                buffer[read_count..][0..chunk],
                self.buffer[self.read_pos..][0..chunk],
            );

            self.read_pos = (self.read_pos + chunk) % self.buffer.len;
            read_count += chunk;
        }

        self.count -= to_read;
        return to_read;
    }

    /// Get available bytes to read
    pub fn available(self: *Self) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.count;
    }

    /// Get free space for writing
    pub fn free_space(self: *Self) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.buffer.len - self.count;
    }

    /// Reset buffer
    pub fn reset(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.read_pos = 0;
        self.write_pos = 0;
        self.count = 0;
    }
};

// ============================================================================
// Asynchronous Pipe Reader (for non-blocking I/O)
// ============================================================================

pub const AsyncPipeReader = struct {
    source_file: std.fs.File,
    ring_buffer: RingBufferPipe,
    thread: ?std.Thread = null,
    running: std.atomic.Value(bool),
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, file: std.fs.File, buffer_size: usize) !Self {
        return .{
            .source_file = file,
            .ring_buffer = try RingBufferPipe.init(allocator, buffer_size),
            .running = std.atomic.Value(bool).init(false),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.stop();
        self.ring_buffer.deinit();
    }

    pub fn start(self: *Self) !void {
        if (self.running.load(.acquire)) return;

        self.running.store(true, .release);
        self.thread = try std.Thread.spawn(.{}, readThread, .{self});
    }

    pub fn stop(self: *Self) void {
        if (!self.running.load(.acquire)) return;

        self.running.store(false, .release);

        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
    }

    fn readThread(self: *Self) void {
        var temp_buffer: [8192]u8 = undefined;

        while (self.running.load(.acquire)) {
            // Try to read from source
            const n = self.source_file.read(&temp_buffer) catch break;
            if (n == 0) break; // EOF

            // Write to ring buffer (blocking if full)
            var written: usize = 0;
            while (written < n) {
                const w = self.ring_buffer.write(temp_buffer[written..n]) catch break;
                if (w == 0) {
                    // Buffer full, sleep briefly
                    std.time.sleep(1_000_000); // 1ms
                }
                written += w;
            }
        }

        self.running.store(false, .release);
    }

    pub fn read(self: *Self, buffer: []u8) usize {
        return self.ring_buffer.read(buffer);
    }

    pub fn available(self: *Self) usize {
        return self.ring_buffer.available();
    }
};

// ============================================================================
// Source/Target Detection
// ============================================================================

pub const IOUtils = struct {
    /// Detect if path is stdin
    pub fn isStdin(path: []const u8) bool {
        return std.mem.eql(u8, path, "-") or
            std.mem.eql(u8, path, "stdin") or
            std.mem.eql(u8, path, "/dev/stdin");
    }

    /// Detect if path is stdout
    pub fn isStdout(path: []const u8) bool {
        return std.mem.eql(u8, path, "-") or
            std.mem.eql(u8, path, "stdout") or
            std.mem.eql(u8, path, "/dev/stdout");
    }

    /// Detect if path is a pipe
    pub fn isPipe(path: []const u8) bool {
        return std.mem.startsWith(u8, path, "pipe:") or
            std.mem.startsWith(u8, path, "fifo:");
    }

    /// Check if file descriptor is a terminal
    pub fn isTerminal(file: std.fs.File) bool {
        return std.posix.isatty(file.handle);
    }
};
