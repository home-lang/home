// Copied from bun/src/http/HTTPRequestBody.zig at upstream SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
// Imports rewritten: @import("bun") → @import("home"). The internal
// `SendFile` and `ThreadSafeStreamBuffer` deps are inlined here as local
// opaque stub types — upstream's SendFile pulls in `bun.FD`/`bun.sys`/
// `bun.http.NewHTTPContext` and ThreadSafeStreamBuffer pulls in
// `bun.io.StreamBuffer`/`bun.Mutex`/`bun.ptr.ThreadSafeRefCount`. The
// stubs preserve the shape this union depends on (`content_size`,
// `deref`) so callers compile. Real impls land alongside the HTTP/1.1
// client (Phase 12.5).

const std = @import("std");

/// Opaque stub for upstream `bun/src/http/SendFile.zig`. Only
/// `content_size` is referenced by `HTTPRequestBody.len`.
pub const SendFile = struct {
    /// File descriptor — upstream uses `bun.FD`. Kept as a Zig
    /// `std.posix.fd_t` placeholder until the FD wrapper is ported.
    fd: std.posix.fd_t = 0,
    remain: usize = 0,
    offset: usize = 0,
    content_size: usize = 0,
};

/// Opaque stub for upstream `bun/src/http/ThreadSafeStreamBuffer.zig`. The
/// only method referenced from this file is `deref`, which the upstream
/// impl wires through `bun.ptr.ThreadSafeRefCount`. The stub no-ops it so
/// the union's `.detach()` path compiles.
pub const ThreadSafeStreamBuffer = struct {
    const Buffer = struct {
        cursor: usize = 0,

        pub fn slice(_: *Buffer) []const u8 {
            return "";
        }

        pub fn isEmpty(_: *Buffer) bool {
            return true;
        }

        pub fn reset(_: *Buffer) void {}
    };

    buffer: Buffer = .{},

    pub fn acquire(self: *ThreadSafeStreamBuffer) *Buffer {
        return &self.buffer;
    }

    pub fn reportDrain(_: *ThreadSafeStreamBuffer) void {}

    pub fn release(_: *ThreadSafeStreamBuffer) void {}

    pub fn deref(self: *ThreadSafeStreamBuffer) void {
        _ = self;
    }
};

pub const HTTPRequestBody = union(enum) {
    bytes: []const u8,
    sendfile: SendFile,
    stream: struct {
        buffer: ?*ThreadSafeStreamBuffer,
        ended: bool,

        pub fn detach(this: *@This()) void {
            if (this.buffer) |buffer| {
                this.buffer = null;
                buffer.deref();
            }
        }
    },

    pub fn isStream(this: *const HTTPRequestBody) bool {
        return this.* == .stream;
    }

    pub fn deinit(this: *HTTPRequestBody) void {
        switch (this.*) {
            .sendfile, .bytes => {},
            .stream => |*stream| stream.detach(),
        }
    }
    pub fn len(this: *const HTTPRequestBody) usize {
        return switch (this.*) {
            .bytes => this.bytes.len,
            .sendfile => this.sendfile.content_size,
            // unknow amounts
            .stream => std.math.maxInt(usize),
        };
    }
};

test "HTTPRequestBody.bytes reports underlying slice length" {
    const payload = "hello world";
    var body: HTTPRequestBody = .{ .bytes = payload };
    try std.testing.expectEqual(payload.len, body.len());
    try std.testing.expect(!body.isStream());
    body.deinit(); // no-op for .bytes
}

test "HTTPRequestBody.sendfile threads content_size through .len" {
    var body: HTTPRequestBody = .{ .sendfile = .{ .content_size = 4096 } };
    try std.testing.expectEqual(@as(usize, 4096), body.len());
    try std.testing.expect(!body.isStream());
    body.deinit(); // no-op for .sendfile
}

test "HTTPRequestBody.stream reports unknown length and detaches buffer on deinit" {
    var stub: ThreadSafeStreamBuffer = .{};
    var body: HTTPRequestBody = .{ .stream = .{ .buffer = &stub, .ended = false } };
    try std.testing.expectEqual(std.math.maxInt(usize), body.len());
    try std.testing.expect(body.isStream());

    body.deinit();
    // detach() should have null'd the buffer pointer in the variant.
    try std.testing.expect(body.stream.buffer == null);
}

test "HTTPRequestBody.stream with no buffer is a safe deinit" {
    var body: HTTPRequestBody = .{ .stream = .{ .buffer = null, .ended = true } };
    body.deinit();
    try std.testing.expect(body.stream.buffer == null);
}
