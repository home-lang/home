//! Bun.Terminal - Creates a pseudo-terminal (PTY) for interactive terminal sessions.
//!
//! Ported from bun/src/runtime/api/bun/Terminal.zig at upstream SHA
//! fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../../cli/LICENSE.bun.md.
//!
//! POSIX (macOS/Linux) is IMPLEMENTED here: openpty(3) creates the master/slave
//! pair, the master fd is duplicated for a nonblocking BufferedReader (→ `data`
//! callback) and StreamingWriter (`write`), `resize` issues TIOCSWINSZ, and the
//! reader's EOF/error drives the `exit` callback. The spawn integration
//! (js_bun_spawn_bindings.zig) wires `getSlaveFd()` into the child's stdio and
//! calls `closeSlaveFd()` post-fork so child exit surfaces as EOF on the master.
//!
//! Windows ConPTY is NOT ported: `createPtyWindows` returns `error.NotSupported`.

const Terminal = @This();

const log = bun.Output.scoped(.Terminal, .hidden);

// Generated bindings
pub const js = jsc.Codegen.JSTerminal;
pub const toJS = js.toJS;
pub const fromJS = js.fromJS;
pub const fromJSDirect = js.fromJSDirect;

// Reference counting. Refs held by: (1) JS side (released in finalize),
// (2) reader (released in onReaderDone/onReaderError), (3) writer (onWriterClose).
const RefCount = bun.ptr.RefCount(@This(), "ref_count", deinit, .{});
pub const ref = RefCount.ref;
pub const deref = RefCount.deref;

ref_count: RefCount,

/// The master side of the PTY (original fd, used for ioctl operations).
master_fd: bun.FD,
/// Duplicated master fd for reading.
read_fd: bun.FD,
/// Duplicated master fd for writing.
write_fd: bun.FD,
/// The slave side of the PTY (used by child processes).
slave_fd: bun.FD,
/// Windows ConPTY handle. Unused on POSIX.
hpcon: if (Environment.isWindows) ?bun.windows.HPCON else void = if (Environment.isWindows) null else {},

cols: u16,
rows: u16,

/// Terminal name (e.g., "xterm-256color").
term_name: jsc.ZigString.Slice,

/// Event loop handle for callbacks + reader/writer poll registration.
event_loop_handle: jsc.EventLoopHandle,

globalThis: *jsc.JSGlobalObject,

/// Writer for sending data to the terminal.
writer: IOWriter = .{},
/// Reader for receiving data from the terminal.
reader: IOReader = IOReader.init(@This()),

/// This value reference for GC tracking (weak when idle, strong when connected).
this_value: jsc.JSRef = jsc.JSRef.empty(),

flags: Flags = .{},

pub const Flags = packed struct(u8) {
    closed: bool = false,
    finalized: bool = false,
    raw_mode: bool = false,
    reader_started: bool = false,
    connected: bool = false,
    reader_done: bool = false,
    writer_done: bool = false,
    /// Set when an inline-created terminal has been attached to a subprocess via
    /// spawn; prevents reusing the same inline terminal for a second spawn.
    inline_spawned: bool = false,
};

pub const IOWriter = bun.io.StreamingWriter(@This(), struct {
    pub const onClose = Terminal.onWriterClose;
    pub const onWritable = Terminal.onWriterReady;
    pub const onError = Terminal.onWriterError;
    pub const onWrite = Terminal.onWrite;
});

/// Poll type alias for FilePoll Owner registration.
pub const Poll = IOWriter;

pub const IOReader = bun.io.BufferedReader;

/// Options for creating a Terminal.
pub const Options = struct {
    cols: u16 = 80,
    rows: u16 = 24,
    term_name: jsc.ZigString.Slice = .{},
    data_callback: ?JSValue = null,
    exit_callback: ?JSValue = null,
    drain_callback: ?JSValue = null,

    pub const max_term_name_len = Terminal.max_term_name_len;

    pub fn parseFromJS(globalObject: *jsc.JSGlobalObject, js_options: JSValue) bun.JSError!Options {
        var options = Options{};
        errdefer options.deinit();

        if (try js_options.getTruthy(globalObject, "cols")) |v| {
            if (v.isNumber()) {
                const n = v.toInt32();
                if (n > 0 and n <= 65535) options.cols = @intCast(n);
            }
        }
        if (try js_options.getTruthy(globalObject, "rows")) |v| {
            if (v.isNumber()) {
                const n = v.toInt32();
                if (n > 0 and n <= 65535) options.rows = @intCast(n);
            }
        }
        if (try js_options.getTruthy(globalObject, "name")) |v| {
            if (v.isString()) {
                const slice = try v.toSlice(globalObject, bun.default_allocator);
                if (slice.len > Terminal.max_term_name_len) {
                    slice.deinit();
                    return globalObject.throw("Terminal name too long (max {d} characters)", .{Terminal.max_term_name_len});
                }
                options.term_name = slice;
            }
        }
        if (try js_options.getTruthy(globalObject, "data")) |v| {
            if (v.isCell() and v.isCallable()) options.data_callback = v;
        }
        if (try js_options.getTruthy(globalObject, "exit")) |v| {
            if (v.isCell() and v.isCallable()) options.exit_callback = v;
        }
        if (try js_options.getTruthy(globalObject, "drain")) |v| {
            if (v.isCell() and v.isCallable()) options.drain_callback = v;
        }
        return options;
    }

    pub fn deinit(this: *Options) void {
        this.term_name.deinit();
        this.* = .{};
    }
};

/// Result from creating a Terminal.
pub const CreateResult = struct {
    terminal: *Terminal,
    js_value: jsc.JSValue = .zero,
};

/// Maximum length for terminal name. Longest terminfo names are ~23 chars.
pub const max_term_name_len = 128;

/// COORD.X/Y are i16 on Windows; clamp the u16 cols/rows to the COORD range.
pub inline fn clampToCoord(v: u16) i16 {
    return @intCast(@min(v, std.math.maxInt(i16)));
}

pub const CreatePtyError = error{ OpenPtyFailed, DupFailed, NotSupported };
pub const InitError = CreatePtyError || error{ WriterStartFailed, ReaderStartFailed };

/// `struct termios` shape passed to `openpty(3)`.
pub const OpenPtyTermios = extern struct {
    c_iflag: u32,
    c_oflag: u32,
    c_cflag: u32,
    c_lflag: u32,
    c_cc: [20]u8,
    c_ispeed: u32,
    c_ospeed: u32,
};

/// `struct winsize` — final arg to `openpty(3)`.
pub const Winsize = extern struct {
    ws_row: u16,
    ws_col: u16,
    ws_xpixel: u16,
    ws_ypixel: u16,
};

pub const OpenPtyFn = *const fn (
    amaster: *c_int,
    aslave: *c_int,
    name: ?[*]u8,
    termp: ?*const OpenPtyTermios,
    winp: ?*const Winsize,
) callconv(.c) c_int;

// ---- PTY creation ----------------------------------------------------------

const PtyResult = struct {
    master: bun.FD,
    read_fd: bun.FD,
    write_fd: bun.FD,
    slave: bun.FD,
    hpcon: if (Environment.isWindows) bun.windows.HPCON else void,
};

/// Dynamic loading of openpty on Linux (it's in libutil which may not be linked).
const LibUtil = struct {
    var handle: ?*anyopaque = null;
    var loaded: bool = false;

    pub fn getHandle() ?*anyopaque {
        if (loaded) return handle;
        loaded = true;
        const lib_names = [_][:0]const u8{ "libutil.so", "libutil.so.1", "libc.so.6" };
        for (lib_names) |lib_name| {
            handle = bun.sys.dlopen(lib_name, .{ .LAZY = true });
            if (handle != null) return handle;
        }
        return null;
    }

    pub fn getOpenPty() ?OpenPtyFn {
        return bun.sys.dlsymWithHandle(OpenPtyFn, "openpty", getHandle);
    }
};

fn getOpenPtyFn() ?OpenPtyFn {
    // On macOS, openpty is in libc, so we can use it directly.
    if (comptime Environment.isMac) {
        const c = struct {
            extern "c" fn openpty(
                amaster: *c_int,
                aslave: *c_int,
                name: ?[*]u8,
                termp: ?*const OpenPtyTermios,
                winp: ?*const Winsize,
            ) c_int;
        };
        return &c.openpty;
    }
    if (comptime Environment.isLinux) {
        return LibUtil.getOpenPty();
    }
    return null;
}

fn createPty(cols: u16, rows: u16) CreatePtyError!PtyResult {
    if (comptime Environment.isPosix) return createPtyPosix(cols, rows);
    if (comptime Environment.isWindows) return error.NotSupported;
    return error.NotSupported;
}

fn createPtyPosix(cols: u16, rows: u16) CreatePtyError!PtyResult {
    const openpty_fn = getOpenPtyFn() orelse {
        return error.NotSupported;
    };

    var master_fd: c_int = -1;
    var slave_fd: c_int = -1;

    const winsize = Winsize{
        .ws_row = rows,
        .ws_col = cols,
        .ws_xpixel = 0,
        .ws_ypixel = 0,
    };

    const result = openpty_fn(&master_fd, &slave_fd, null, null, &winsize);
    if (result != 0) {
        return error.OpenPtyFailed;
    }

    const master_fd_desc = bun.FD.fromNative(master_fd);
    const slave_fd_desc = bun.FD.fromNative(slave_fd);

    // Configure sensible "cooked mode" terminal defaults matching node-pty.
    if (std.posix.tcgetattr(slave_fd)) |termios| {
        var t = termios;

        t.iflag = .{
            .ICRNL = true,
            .IXON = true,
            .IXANY = true,
            .IMAXBEL = true,
            .BRKINT = true,
        };
        if (comptime @hasField(@TypeOf(t.iflag), "IUTF8")) {
            t.iflag.IUTF8 = true;
        }

        t.oflag = .{
            .OPOST = true,
            .ONLCR = true,
        };

        t.cflag = .{
            .CREAD = true,
            .CSIZE = .CS8,
            .HUPCL = true,
        };

        t.lflag = .{
            .ICANON = true,
            .ISIG = true,
            .IEXTEN = true,
            .ECHO = true,
            .ECHOE = true,
            .ECHOK = true,
            .ECHOKE = true,
            .ECHOCTL = true,
        };

        t.cc[@intFromEnum(std.posix.V.EOF)] = 4;
        t.cc[@intFromEnum(std.posix.V.EOL)] = 0;
        t.cc[@intFromEnum(std.posix.V.ERASE)] = 0x7f;
        t.cc[@intFromEnum(std.posix.V.WERASE)] = 23;
        t.cc[@intFromEnum(std.posix.V.KILL)] = 21;
        t.cc[@intFromEnum(std.posix.V.REPRINT)] = 18;
        t.cc[@intFromEnum(std.posix.V.INTR)] = 3;
        t.cc[@intFromEnum(std.posix.V.QUIT)] = 0x1c;
        t.cc[@intFromEnum(std.posix.V.SUSP)] = 26;
        t.cc[@intFromEnum(std.posix.V.START)] = 17;
        t.cc[@intFromEnum(std.posix.V.STOP)] = 19;
        t.cc[@intFromEnum(std.posix.V.LNEXT)] = 22;
        t.cc[@intFromEnum(std.posix.V.DISCARD)] = 15;
        t.cc[@intFromEnum(std.posix.V.MIN)] = 1;
        t.cc[@intFromEnum(std.posix.V.TIME)] = 0;

        t.ispeed = .B38400;
        t.ospeed = .B38400;

        std.posix.tcsetattr(slave_fd, .NOW, t) catch {};
    } else |err| {
        if (comptime bun.Environment.allow_assert) {
            bun.sys.syslog("tcgetattr(slave_fd={d}) failed: {s}", .{ slave_fd, @errorName(err) });
        }
    }

    // Duplicate the master fd for reading and writing separately.
    const read_fd = switch (bun.sys.dup(master_fd_desc)) {
        .result => |fd| fd,
        .err => {
            master_fd_desc.close();
            slave_fd_desc.close();
            return error.DupFailed;
        },
    };

    const write_fd = switch (bun.sys.dup(master_fd_desc)) {
        .result => |fd| fd,
        .err => {
            master_fd_desc.close();
            slave_fd_desc.close();
            read_fd.close();
            return error.DupFailed;
        },
    };

    // Master-side fds are nonblocking (async event-loop I/O); slave stays blocking.
    _ = bun.sys.updateNonblocking(master_fd_desc, true);
    _ = bun.sys.updateNonblocking(read_fd, true);
    _ = bun.sys.updateNonblocking(write_fd, true);

    // Master-side fds are close-on-exec; slave is inherited by the child.
    _ = bun.sys.setCloseOnExec(master_fd_desc);
    _ = bun.sys.setCloseOnExec(read_fd);
    _ = bun.sys.setCloseOnExec(write_fd);

    return PtyResult{
        .master = master_fd_desc,
        .read_fd = read_fd,
        .write_fd = write_fd,
        .slave = slave_fd_desc,
        .hpcon = {},
    };
}

// ---- init / construct ------------------------------------------------------

fn initTerminal(
    globalObject: *jsc.JSGlobalObject,
    options: *Options,
    existing_js_value: ?jsc.JSValue,
) InitError!CreateResult {
    const pty_result = try createPty(options.cols, options.rows);

    const term_name = if (options.term_name.len > 0)
        options.term_name
    else
        jsc.ZigString.Slice.fromUTF8NeverFree("xterm-256color");
    options.term_name = .{};

    const terminal = bun.new(Terminal, .{
        .ref_count = .init(),
        .master_fd = pty_result.master,
        .read_fd = pty_result.read_fd,
        .write_fd = pty_result.write_fd,
        .slave_fd = pty_result.slave,
        .hpcon = if (comptime Environment.isWindows) pty_result.hpcon else {},
        .cols = options.cols,
        .rows = options.rows,
        .term_name = term_name,
        .event_loop_handle = jsc.EventLoopHandle.init(globalObject.bunVM().eventLoop()),
        .globalThis = globalObject,
    });

    terminal.reader.setParent(terminal);
    terminal.writer.parent = terminal;

    // Start writer (adds a ref).
    switch (terminal.writer.start(pty_result.write_fd, true)) {
        .result => terminal.ref(),
        .err => {
            terminal.flags.writer_done = true;
            terminal.read_fd.close();
            terminal.read_fd = bun.invalid_fd;
            terminal.closeInternal();
            terminal.deref();
            return error.WriterStartFailed;
        },
    }

    // Start reader (adds a ref).
    switch (terminal.reader.start(pty_result.read_fd, true)) {
        .err => {
            terminal.read_fd.close();
            terminal.read_fd = bun.invalid_fd;
            terminal.closeInternal();
            terminal.deref();
            return error.ReaderStartFailed;
        },
        .result => {
            terminal.ref();
            if (comptime Environment.isPosix) {
                if (terminal.reader.handle == .poll) {
                    const poll = terminal.reader.handle.poll;
                    // A PTY behaves like a pipe, not a socket.
                    terminal.reader.flags.nonblocking = true;
                    terminal.reader.flags.pollable = true;
                    poll.flags.insert(.nonblocking);
                }
            }
            terminal.flags.reader_started = true;
        },
    }

    terminal.reader.read();

    const this_value = existing_js_value orelse terminal.toJS(globalObject);
    terminal.this_value = jsc.JSRef.initStrong(this_value, globalObject);

    if (options.data_callback) |cb| {
        js.gc.set(.data, this_value, globalObject, cb);
    }
    if (options.exit_callback) |cb| {
        js.gc.set(.exit, this_value, globalObject, cb);
    }
    if (options.drain_callback) |cb| {
        js.gc.set(.drain, this_value, globalObject, cb);
    }

    return .{ .terminal = terminal, .js_value = this_value };
}

pub fn constructor(
    globalObject: *jsc.JSGlobalObject,
    callframe: *jsc.CallFrame,
    this_value: jsc.JSValue,
) bun.JSError!*Terminal {
    const args = callframe.argumentsAsArray(1);
    const js_options = args[0];

    if (!js_options.isObject()) {
        return globalObject.throw("Terminal constructor requires an options object", .{});
    }

    var options = try Options.parseFromJS(globalObject, js_options);

    const result = initTerminal(globalObject, &options, this_value) catch |err| {
        options.deinit();
        return switch (err) {
            error.OpenPtyFailed => globalObject.throw("Failed to open PTY", .{}),
            error.DupFailed => globalObject.throw("Failed to duplicate PTY file descriptor", .{}),
            error.NotSupported => globalObject.throw("PTY not supported on this platform", .{}),
            error.WriterStartFailed => globalObject.throw("Failed to start terminal writer", .{}),
            error.ReaderStartFailed => globalObject.throw("Failed to start terminal reader", .{}),
        };
    };

    return result.terminal;
}

/// Create a Terminal from Bun.spawn options. The slave_fd is used for the
/// subprocess's stdin/stdout/stderr; the parent reads/writes the master.
pub fn createFromSpawn(
    globalObject: *jsc.JSGlobalObject,
    options: *Options,
) InitError!CreateResult {
    return initTerminal(globalObject, options, null);
}

pub fn getSlaveFd(this: *Terminal) bun.FD {
    return this.slave_fd;
}

pub fn getPseudoconsole(this: *Terminal) if (Environment.isWindows) ?bun.windows.HPCON else void {
    if (comptime Environment.isWindows) return this.hpcon;
}

/// Close the parent's copy of slave_fd after fork so child exit yields EOF on
/// the master side.
pub fn closeSlaveFd(this: *Terminal) void {
    this.flags.inline_spawned = true;
    if (this.slave_fd != bun.invalid_fd) {
        this.slave_fd.close();
        this.slave_fd = bun.invalid_fd;
    }
}

// ---- JS accessors / methods ------------------------------------------------

pub fn getClosed(this: *Terminal, _: *jsc.JSGlobalObject) JSValue {
    return JSValue.jsBoolean(this.flags.closed);
}

fn getTermiosFlag(_: *Terminal, comptime _: enum { iflag, oflag, lflag, cflag }) JSValue {
    return JSValue.jsNumber(0);
}
fn setTermiosFlag(_: *Terminal, _: *jsc.JSGlobalObject, comptime _: enum { iflag, oflag, lflag, cflag }, _: JSValue) bun.JSError!void {}

pub fn getInputFlags(this: *Terminal, _: *jsc.JSGlobalObject) JSValue {
    return this.getTermiosFlag(.iflag);
}
pub fn setInputFlags(this: *Terminal, globalObject: *jsc.JSGlobalObject, value: JSValue) bun.JSError!void {
    try this.setTermiosFlag(globalObject, .iflag, value);
}
pub fn getOutputFlags(this: *Terminal, _: *jsc.JSGlobalObject) JSValue {
    return this.getTermiosFlag(.oflag);
}
pub fn setOutputFlags(this: *Terminal, globalObject: *jsc.JSGlobalObject, value: JSValue) bun.JSError!void {
    try this.setTermiosFlag(globalObject, .oflag, value);
}
pub fn getLocalFlags(this: *Terminal, _: *jsc.JSGlobalObject) JSValue {
    return this.getTermiosFlag(.lflag);
}
pub fn setLocalFlags(this: *Terminal, globalObject: *jsc.JSGlobalObject, value: JSValue) bun.JSError!void {
    try this.setTermiosFlag(globalObject, .lflag, value);
}
pub fn getControlFlags(this: *Terminal, _: *jsc.JSGlobalObject) JSValue {
    return this.getTermiosFlag(.cflag);
}
pub fn setControlFlags(this: *Terminal, globalObject: *jsc.JSGlobalObject, value: JSValue) bun.JSError!void {
    try this.setTermiosFlag(globalObject, .cflag, value);
}

pub fn write(this: *Terminal, globalObject: *jsc.JSGlobalObject, callframe: *jsc.CallFrame) bun.JSError!JSValue {
    if (this.flags.closed) {
        return globalObject.throw("Terminal is closed", .{});
    }

    const args = callframe.argumentsAsArray(1);
    const data = args[0];

    if (data.isUndefinedOrNull()) {
        return globalObject.throw("write() requires data argument", .{});
    }

    const string_or_buffer = try jsc.Node.StringOrBuffer.fromJS(globalObject, bun.default_allocator, data) orelse {
        return globalObject.throw("write() argument must be a string or ArrayBuffer", .{});
    };
    defer string_or_buffer.deinit();

    const bytes = string_or_buffer.slice();
    if (bytes.len == 0) {
        return JSValue.jsNumber(0);
    }

    const write_result = this.writer.write(bytes);
    return switch (write_result) {
        .done => |amt| JSValue.jsNumber(@as(i32, @intCast(amt))),
        .wrote => |amt| JSValue.jsNumber(@as(i32, @intCast(amt))),
        .pending => |amt| JSValue.jsNumber(@as(i32, @intCast(if (Environment.isWindows) bytes.len else amt))),
        .err => |err| globalObject.throwValue(try err.toJS(globalObject)),
    };
}

pub fn resize(this: *Terminal, globalObject: *jsc.JSGlobalObject, callframe: *jsc.CallFrame) bun.JSError!JSValue {
    if (this.flags.closed) {
        return globalObject.throw("Terminal is closed", .{});
    }

    const args = callframe.argumentsAsArray(2);

    const new_cols: u16 = blk: {
        if (args[0].isNumber()) {
            const n = args[0].toInt32();
            if (n > 0 and n <= 65535) break :blk @intCast(n);
        }
        return globalObject.throw("resize() requires valid cols argument", .{});
    };

    const new_rows: u16 = blk: {
        if (args[1].isNumber()) {
            const n = args[1].toInt32();
            if (n > 0 and n <= 65535) break :blk @intCast(n);
        }
        return globalObject.throw("resize() requires valid rows argument", .{});
    };

    if (comptime Environment.isPosix) {
        const ioctl_c = struct {
            const TIOCSWINSZ: c_ulong = if (Environment.isMac) 0x80087467 else 0x5414;

            const IoctlWinsize = extern struct {
                ws_row: u16,
                ws_col: u16,
                ws_xpixel: u16,
                ws_ypixel: u16,
            };

            extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;
        };

        var winsize = ioctl_c.IoctlWinsize{
            .ws_row = new_rows,
            .ws_col = new_cols,
            .ws_xpixel = 0,
            .ws_ypixel = 0,
        };

        const ioctl_result = ioctl_c.ioctl(this.master_fd.cast(), ioctl_c.TIOCSWINSZ, &winsize);
        if (ioctl_result != 0) {
            return globalObject.throw("Failed to resize terminal", .{});
        }
    }

    this.cols = new_cols;
    this.rows = new_rows;

    return .js_undefined;
}

pub fn setRawMode(this: *Terminal, globalObject: *jsc.JSGlobalObject, callframe: *jsc.CallFrame) bun.JSError!JSValue {
    if (this.flags.closed) {
        return globalObject.throw("Terminal is closed", .{});
    }

    const args = callframe.argumentsAsArray(1);
    const enabled = args[0].toBoolean();

    if (comptime Environment.isPosix) {
        const tty_result = bun.tty.setMode(this.master_fd.cast(), if (enabled) .raw else .normal);
        if (tty_result != 0) {
            return globalObject.throw("Failed to set raw mode", .{});
        }
    }

    this.flags.raw_mode = enabled;
    return .js_undefined;
}

pub fn doRef(this: *Terminal, _: *jsc.JSGlobalObject, _: *jsc.CallFrame) bun.JSError!JSValue {
    this.updateRef(true);
    return .js_undefined;
}
pub fn doUnref(this: *Terminal, _: *jsc.JSGlobalObject, _: *jsc.CallFrame) bun.JSError!JSValue {
    this.updateRef(false);
    return .js_undefined;
}
fn updateRef(this: *Terminal, add: bool) void {
    this.reader.updateRef(add);
    this.writer.updateRef(this.event_loop_handle, add);
}

pub fn close(this: *Terminal, _: *jsc.JSGlobalObject, _: *jsc.CallFrame) bun.JSError!JSValue {
    this.closeInternal();
    return .js_undefined;
}

pub fn asyncDispose(this: *Terminal, globalObject: *jsc.JSGlobalObject, _: *jsc.CallFrame) bun.JSError!JSValue {
    this.this_value.downgrade();
    this.flags.finalized = true;
    this.closeInternal();
    return jsc.JSPromise.resolvedPromiseValue(globalObject, .js_undefined);
}

pub fn closeInternal(this: *Terminal) void {
    if (this.flags.closed) return;
    this.flags.closed = true;

    this.writer.close();
    this.write_fd = bun.invalid_fd;

    if (this.flags.reader_started) {
        this.reader.close();
    }
    this.read_fd = bun.invalid_fd;

    if (this.master_fd != bun.invalid_fd) {
        this.master_fd.close();
        this.master_fd = bun.invalid_fd;
    }

    if (this.slave_fd != bun.invalid_fd) {
        this.slave_fd.close();
        this.slave_fd = bun.invalid_fd;
    }
}

pub fn closePseudoconsole(this: *Terminal) void {
    _ = this;
}

// ---- IO callbacks ----------------------------------------------------------

fn onWriterClose(this: *Terminal) void {
    log("onWriterClose", .{});
    if (!this.flags.writer_done) {
        this.flags.writer_done = true;
        this.deref();
    }
}

fn onWriterReady(this: *Terminal) void {
    log("onWriterReady", .{});
    const this_jsvalue = this.this_value.tryGet() orelse return;
    if (js.gc.get(.drain, this_jsvalue)) |callback| {
        const globalThis = this.globalThis;
        globalThis.bunVM().eventLoop().runCallback(
            callback,
            globalThis,
            this_jsvalue,
            &.{this_jsvalue},
        );
    }
}

fn onWriterError(this: *Terminal, err: bun.sys.Error) void {
    log("onWriterError: {any}", .{err});
    if (!this.flags.closed) {
        this.closeInternal();
    }
}

fn onWrite(this: *Terminal, amount: usize, status: bun.io.WriteStatus) void {
    log("onWrite: {} bytes, status: {any}", .{ amount, status });
    _ = this;
}

pub fn onReaderDone(this: *Terminal) void {
    log("onReaderDone", .{});
    if (!this.flags.finalized) {
        this.flags.connected = false;
        this.this_value.downgrade();
        this.callExitCallback(0, null);
    }
    if (!this.flags.reader_done) {
        this.flags.reader_done = true;
        this.deref();
    }
}

pub fn onReaderError(this: *Terminal, err: bun.sys.Error) void {
    log("onReaderError: {any}", .{err});
    if (!this.flags.finalized) {
        this.flags.connected = false;
        this.this_value.downgrade();
        this.callExitCallback(1, null);
    }
    if (!this.flags.reader_done) {
        this.flags.reader_done = true;
        this.deref();
    }
}

/// Invoke the `exit` callback. exit_code is PTY-level (0=EOF, 1=error), NOT the
/// subprocess exit code.
fn callExitCallback(this: *Terminal, exit_code: i32, signal: ?bun.SignalCode) void {
    const this_jsvalue = this.this_value.tryGet() orelse return;
    const callback = js.gc.get(.exit, this_jsvalue) orelse return;

    const globalThis = this.globalThis;
    const signal_value: JSValue = if (signal) |s|
        jsc.ZigString.init(s.name() orelse "unknown").toJS(globalThis)
    else
        JSValue.jsNull();

    globalThis.bunVM().eventLoop().runCallback(
        callback,
        globalThis,
        this_jsvalue,
        &.{ this_jsvalue, JSValue.jsNumber(exit_code), signal_value },
    );
}

pub fn onReadChunk(this: *Terminal, chunk: []const u8, has_more: bun.io.ReadState) bool {
    _ = has_more;
    log("onReadChunk: {} bytes", .{chunk.len});

    if (this.flags.finalized) return true;

    if (!this.flags.connected) {
        this.flags.connected = true;
        this.this_value.upgrade(this.globalThis);
    }

    const this_jsvalue = this.this_value.tryGet() orelse return true;
    const callback = js.gc.get(.data, this_jsvalue) orelse return true;

    const globalThis = this.globalThis;
    const duped = bun.default_allocator.dupe(u8, chunk) catch |err| {
        log("Terminal data allocation OOM: chunk_size={d}, error={any}", .{ chunk.len, err });
        return true;
    };
    const data = jsc.MarkedArrayBuffer.fromBytes(
        duped,
        bun.default_allocator,
        .Uint8Array,
    ).toNodeBuffer(globalThis);

    globalThis.bunVM().eventLoop().runCallback(
        callback,
        globalThis,
        this_jsvalue,
        &.{ this_jsvalue, data },
    );

    return true;
}

pub fn eventLoop(this: *Terminal) jsc.EventLoopHandle {
    return this.event_loop_handle;
}

pub fn loop(this: *Terminal) *bun.Async.Loop {
    return this.event_loop_handle.loop();
}

fn deinit(this: *Terminal) void {
    log("deinit", .{});
    this.flags.reader_done = true;
    this.flags.writer_done = true;
    this.closeInternal();
    this.term_name.deinit();
    this.reader.deinit();
    this.writer.deinit();
    bun.destroy(this);
}

pub fn finalize(this: *Terminal) callconv(.c) void {
    log("finalize", .{});
    jsc.markBinding(@src());
    this.this_value.finalize();
    this.flags.finalized = true;
    this.closeInternal();
    this.deref();
}

const std = @import("std");

const bun = @import("bun");
const Environment = bun.Environment;

const jsc = bun.jsc;
const JSGlobalObject = jsc.JSGlobalObject;
const JSValue = jsc.JSValue;
const CallFrame = jsc.CallFrame;
