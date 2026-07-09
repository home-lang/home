// Phase 12.2 — native `Bun.spawnSync` for the eval/run realm.
//
// This is the first real subprocess primitive: it spawns an actual OS process
// through Home's OWN `std.process` (Zig 0.17 `std.Io`-based) machinery — NOT by
// delegating to a system `bun` binary. It captures stdout/stderr through pipes,
// optionally feeds stdin bytes, threads `cwd`/`env`, and reports
// `exitCode`/`signalCode`/`pid`, faithful to Bun's `spawnSync` result shape:
//
//   Bun.spawnSync(cmd: string[], opts?) | Bun.spawnSync({ cmd, ...opts })
//     -> { pid, exitCode, signalCode, success, stdout, stderr }
//
// `stdout`/`stderr` are `Buffer`s when the realm has the global `Buffer`
// (installed by `node_modules`), otherwise `Uint8Array`s. comptime-gated on
// `enable_jsc`. Installed after `bun_global` (augments the existing `Bun`) and
// after `node_modules` (so `Buffer` is available).
//
// Also exposes `Bun.which` (PATH resolution) and an eager `Bun.spawn`: an
// async-shaped Subprocess (`pid`, `exited: Promise`, `stdout`/`stderr` readers
// with text/json/bytes/arrayBuffer, `kill`/`ref`/`unref`) implemented on top of
// the sync spawn — it runs the child to completion, then presents resolved
// results. This covers `await proc.stdout.text()` / `await proc.exited`.
//
// Scope (v1): synchronous spawn with stdin written first, then stdout drained
// before stderr (sequential blocking reads — no concurrency, since the realm's
// single-threaded `std.Io` cannot satisfy a concurrent multi-pipe drain). Very
// large piped stdin, or a child that floods stderr while stdout stays open, can
// deadlock against a full pipe. True streaming `Bun.spawn` (live streams,
// interactive stdin, reaping a still-running child via the event loop) is a
// separate later milestone.

const std = @import("std");
const bun = @import("bun");
const build_options = @import("build_options");
const evaluate = @import("evaluate.zig");
const callback = @import("callback.zig");
const extern_fns = @import("extern_fns.zig");
const opaques = @import("opaques.zig");

const JSValue = opaques.JSValue;
const JSContextRef = opaques.JSContextRef;
const JSObject = opaques.JSObject;
const JSGlobalObject = opaques.JSGlobalObject;

fn argToOwnedUtf8(ctx: *JSContextRef, value: *JSValue, allocator: std.mem.Allocator) ?[]u8 {
    const string = extern_fns.JSValueToStringCopy(ctx, value, null) orelse return null;
    defer extern_fns.JSStringRelease(string);
    const capacity = extern_fns.JSStringGetLength(string) * 4 + 1;
    const buf = allocator.alloc(u8, capacity) catch return null;
    const written = extern_fns.JSStringGetUTF8CString(string, buf.ptr, buf.len);
    return buf[0 .. if (written > 0) written - 1 else 0];
}

fn makeUint8Array(ctx: *JSContextRef, bytes: []const u8) ?*JSValue {
    const array = extern_fns.JSObjectMakeTypedArray(ctx, .kJSTypedArrayTypeUint8Array, bytes.len, null) orelse
        return extern_fns.JSValueMakeNull(ctx);
    if (bytes.len > 0) {
        if (extern_fns.JSObjectGetTypedArrayBytesPtr(ctx, array, null)) |ptr| {
            const dest: [*]u8 = @ptrCast(ptr);
            @memcpy(dest[0..bytes.len], bytes);
        }
    }
    return @ptrCast(array);
}

fn setValue(ctx: *JSContextRef, object: *JSObject, key: []const u8, value: ?*JSValue) void {
    const allocator = std.heap.page_allocator;
    const key_z = bun.dupeZ(allocator, u8, key) catch return;
    defer allocator.free(key_z);
    const name = extern_fns.JSStringCreateWithUTF8CString(key_z.ptr) orelse return;
    defer extern_fns.JSStringRelease(name);
    extern_fns.JSObjectSetProperty(ctx, object, name, value, 0, null);
}

fn setBool(ctx: *JSContextRef, object: *JSObject, key: []const u8, value: bool) void {
    setValue(ctx, object, key, extern_fns.JSValueMakeBoolean(ctx, value));
}

fn setNum(ctx: *JSContextRef, object: *JSObject, key: []const u8, value: f64) void {
    setValue(ctx, object, key, extern_fns.JSValueMakeNumber(ctx, value));
}

fn setStr(ctx: *JSContextRef, object: *JSObject, key: []const u8, value: []const u8) void {
    const allocator = std.heap.page_allocator;
    const z = bun.dupeZ(allocator, u8, value) catch return;
    defer allocator.free(z);
    const s = extern_fns.JSStringCreateWithUTF8CString(z.ptr) orelse return;
    defer extern_fns.JSStringRelease(s);
    setValue(ctx, object, key, extern_fns.JSValueMakeString(ctx, s));
}

/// Build `{ __spawn_error: msg }`; the JS wrapper turns this into a thrown Error.
fn makeErrorResult(ctx: *JSContextRef, msg: []const u8) ?*JSValue {
    const object = extern_fns.JSObjectMake(ctx, null, null) orelse return extern_fns.JSValueMakeNull(ctx);
    setStr(ctx, object, "__spawn_error", msg);
    return @ptrCast(object);
}

fn makeErrorResultFmt(ctx: *JSContextRef, a: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ?*JSValue {
    const msg = std.fmt.allocPrint(a, fmt, args) catch return makeErrorResult(ctx, "spawnSync: error");
    return makeErrorResult(ctx, msg);
}

/// Read a JS array of strings into an arena-owned slice (coercing each element
/// with `String()` semantics). Returns null when `value` is not array-like.
fn readStringArray(ctx: *JSContextRef, a: std.mem.Allocator, value: *JSValue) ?[][]const u8 {
    if (!extern_fns.JSValueIsObject(ctx, value)) return null;
    const obj = extern_fns.JSValueToObject(ctx, value, null) orelse return null;
    const len_name = extern_fns.JSStringCreateWithUTF8CString("length") orelse return null;
    defer extern_fns.JSStringRelease(len_name);
    const len_v = extern_fns.JSObjectGetProperty(ctx, obj, len_name, null) orelse return null;
    const len_f = extern_fns.JSValueToNumber(ctx, len_v, null);
    if (!(len_f >= 0)) return null;
    const len: usize = @intFromFloat(len_f);
    const list = a.alloc([]const u8, len) catch return null;
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const el = extern_fns.JSObjectGetPropertyAtIndex(ctx, obj, @intCast(i), null) orelse {
            list[i] = "";
            continue;
        };
        list[i] = argToOwnedUtf8(ctx, el, a) orelse "";
    }
    return list;
}

/// Faithful POSIX signal name (e.g. `SIGTERM`), avoiding `@tagName` panics on
/// any out-of-range value the OS might report.
fn signalName(a: std.mem.Allocator, sig: anytype) []const u8 {
    const n = @intFromEnum(sig);
    return switch (n) {
        1 => "SIGHUP",
        2 => "SIGINT",
        3 => "SIGQUIT",
        4 => "SIGILL",
        5 => "SIGTRAP",
        6 => "SIGABRT",
        8 => "SIGFPE",
        9 => "SIGKILL",
        10 => "SIGBUS",
        11 => "SIGSEGV",
        13 => "SIGPIPE",
        14 => "SIGALRM",
        15 => "SIGTERM",
        else => std.fmt.allocPrint(a, "SIG{d}", .{n}) catch "SIG",
    };
}

/// `__home_spawn_sync(argv, cwd, envPairs, stdinBytes)` — see file header.
fn spawnSyncNative(ctx: ?*JSContextRef, function: ?*JSObject, this_object: ?*JSObject, argc: usize, argv: [*c]const ?*JSValue, exception: extern_fns.ExceptionRef) callconv(.c) ?*JSValue {
    _ = function;
    _ = this_object;
    _ = exception;
    const c = ctx orelse return null;
    if (argc < 1) return makeErrorResult(c, "spawnSync: missing argv");
    const argv_v = argv[0] orelse return makeErrorResult(c, "spawnSync: missing argv");

    var arena_inst = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_inst.deinit();
    const a = arena_inst.allocator();

    // argv (required, non-empty)
    const args = readStringArray(c, a, argv_v) orelse
        return makeErrorResult(c, "spawnSync: cmd must be a non-empty array");
    if (args.len == 0) return makeErrorResult(c, "spawnSync: cmd must be a non-empty array");

    // cwd (arg1; "" / null / undefined => inherit)
    var cwd: std.process.Child.Cwd = .inherit;
    if (argc >= 2) {
        if (argv[1]) |v| {
            if (!extern_fns.JSValueIsUndefined(c, v) and !extern_fns.JSValueIsNull(c, v)) {
                if (argToOwnedUtf8(c, v, a)) |s| {
                    if (s.len > 0) cwd = .{ .path = s };
                }
            }
        }
    }

    // env (arg2; array of "K=V" strings replaces the environment, like Bun;
    // otherwise inherit the parent process env). Built explicitly so it does not
    // depend on the locally-created io's (empty) environ.
    var env_map = std.process.Environ.Map.init(a);
    var have_js_env = false;
    if (argc >= 3) {
        if (argv[2]) |v| {
            if (!extern_fns.JSValueIsUndefined(c, v) and !extern_fns.JSValueIsNull(c, v)) {
                if (readStringArray(c, a, v)) |pairs| {
                    for (pairs) |pair| {
                        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
                        env_map.put(pair[0..eq], pair[eq + 1 ..]) catch {};
                    }
                    have_js_env = true;
                }
            }
        }
    }
    if (!have_js_env) {
        var idx: usize = 0;
        while (std.c.environ[idx]) |entry| : (idx += 1) {
            const s = std.mem.span(entry);
            const eq = std.mem.indexOfScalar(u8, s, '=') orelse continue;
            env_map.put(s[0..eq], s[eq + 1 ..]) catch {};
        }
    }
    const env_ptr: ?*const std.process.Environ.Map = &env_map;

    // stdin bytes (arg3; optional Uint8Array)
    var stdin_bytes: ?[]const u8 = null;
    if (argc >= 4) {
        if (argv[3]) |v| {
            if (extern_fns.JSValueGetTypedArrayType(c, v, null) != .kJSTypedArrayTypeNone) {
                if (extern_fns.JSValueToObject(c, v, null)) |o| {
                    const len = extern_fns.JSObjectGetTypedArrayByteLength(c, o, null);
                    const ptr = extern_fns.JSObjectGetTypedArrayBytesPtr(c, o, null);
                    if (len > 0 and ptr != null) {
                        const buf = a.alloc(u8, len) catch return makeErrorResult(c, "spawnSync: out of memory");
                        @memcpy(buf, @as([*]const u8, @ptrCast(ptr.?))[0..len]);
                        stdin_bytes = buf;
                    } else {
                        stdin_bytes = "";
                    }
                }
            }
        }
    }

    // stdio modes (args 4=stdout, 5=stderr, 6=stdin; 0=pipe, 1=inherit,
    // 2=ignore). stdout/stderr default to pipe (captured); stdin defaults to
    // ignore unless stdin bytes were supplied (then it is piped to write them).
    const stdout_mode = readMode(c, argc, argv, 4, 0);
    const stderr_mode = readMode(c, argc, argv, 5, 0);
    const stdin_mode = readMode(c, argc, argv, 6, 2);

    return runChild(c, a, args, cwd, env_ptr, stdin_bytes, stdout_mode, stderr_mode, stdin_mode);
}

/// Read a small stdio-mode int (0=pipe/1=inherit/2=ignore) from `argv[idx]`,
/// falling back to `default_mode` when absent or out of range.
fn readMode(c: *JSContextRef, argc: usize, argv: [*c]const ?*JSValue, idx: usize, default_mode: u8) u8 {
    if (argc > idx) {
        if (argv[idx]) |v| {
            if (!extern_fns.JSValueIsUndefined(c, v) and !extern_fns.JSValueIsNull(c, v)) {
                const n = extern_fns.JSValueToNumber(c, v, null);
                if (n >= 0 and n <= 2) return @intFromFloat(n);
            }
        }
    }
    return default_mode;
}

fn stdioFromMode(mode: u8) std.process.SpawnOptions.StdIo {
    return switch (mode) {
        1 => .inherit,
        2 => .ignore,
        else => .pipe,
    };
}

/// Read a child pipe to EOF (streaming mode — pipes are not seekable).
fn readPipe(a: std.mem.Allocator, i: std.Io, file: std.Io.File) []u8 {
    var buf: [4096]u8 = undefined;
    var fr = file.readerStreaming(i, &buf);
    return fr.interface.allocRemaining(a, .unlimited) catch "";
}

fn runChild(
    c: *JSContextRef,
    a: std.mem.Allocator,
    args: []const []const u8,
    cwd: std.process.Child.Cwd,
    env_ptr: ?*const std.process.Environ.Map,
    stdin_bytes: ?[]const u8,
    stdout_mode: u8,
    stderr_mode: u8,
    stdin_mode: u8,
) ?*JSValue {
    // A local Threaded io with a real allocator: spawn/wait null-terminate argv
    // and env through the io's allocator, so `global_single_threaded` (which has
    // a `.failing` allocator) cannot be used here.
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const i = threaded.io();

    var child = std.process.spawn(i, .{
        .argv = args,
        .cwd = cwd,
        .environ_map = env_ptr,
        .stdin = if (stdin_bytes != null) .pipe else stdioFromMode(stdin_mode),
        .stdout = stdioFromMode(stdout_mode),
        .stderr = stdioFromMode(stderr_mode),
    }) catch |err| {
        return switch (err) {
            error.FileNotFound => makeErrorResult(c, "spawnSync: executable not found"),
            error.AccessDenied => makeErrorResult(c, "spawnSync: permission denied"),
            else => makeErrorResultFmt(c, a, "spawnSync: failed to spawn process: {s}", .{@errorName(err)}),
        };
    };
    defer child.kill(i);

    const pid_val: f64 = if (child.id) |id| @floatFromInt(@as(i64, id)) else 0;

    // Feed stdin, then close it so the child observes EOF.
    if (stdin_bytes) |bytes| {
        if (child.stdin) |sin| {
            if (bytes.len > 0) sin.writeStreamingAll(i, bytes) catch {};
            sin.close(i);
            child.stdin = null;
        }
    }

    // Read the pipes BEFORE wait: `child.wait` (childCleanupPosix) closes and
    // nulls the stdout/stderr fds. Sequential blocking reads — the child closes
    // its write ends on exit, giving EOF; we reap afterward. Non-piped streams
    // (inherit/ignore) have null fds and yield null results, like Bun.
    const out: ?[]u8 = if (child.stdout) |so| readPipe(a, i, so) else null;
    const errout: ?[]u8 = if (child.stderr) |se| readPipe(a, i, se) else null;

    const term = child.wait(i) catch |err| return makeErrorResultFmt(c, a, "spawnSync: wait failed: {s}", .{@errorName(err)});

    const object = extern_fns.JSObjectMake(c, null, null) orelse return extern_fns.JSValueMakeNull(c);
    switch (term) {
        .exited => |code| {
            setNum(c, object, "exitCode", @floatFromInt(code));
            setValue(c, object, "signalCode", extern_fns.JSValueMakeNull(c));
            setBool(c, object, "success", code == 0);
        },
        .signal => |sig| {
            setValue(c, object, "exitCode", extern_fns.JSValueMakeNull(c));
            setStr(c, object, "signalCode", signalName(a, sig));
            setBool(c, object, "success", false);
        },
        else => {
            setValue(c, object, "exitCode", extern_fns.JSValueMakeNull(c));
            setValue(c, object, "signalCode", extern_fns.JSValueMakeNull(c));
            setBool(c, object, "success", false);
        },
    }
    setNum(c, object, "pid", pid_val);
    setValue(c, object, "stdout", if (out) |o| makeUint8Array(c, o) else extern_fns.JSValueMakeNull(c));
    setValue(c, object, "stderr", if (errout) |e| makeUint8Array(c, e) else extern_fns.JSValueMakeNull(c));
    return @ptrCast(object);
}

/// `__home_which(cmd, pathString)` -> absolute path string, or null.
fn whichNative(ctx: ?*JSContextRef, function: ?*JSObject, this_object: ?*JSObject, argc: usize, argv: [*c]const ?*JSValue, exception: extern_fns.ExceptionRef) callconv(.c) ?*JSValue {
    _ = function;
    _ = this_object;
    _ = exception;
    const c = ctx orelse return null;
    if (argc < 1) return extern_fns.JSValueMakeNull(c);
    const cmd_v = argv[0] orelse return extern_fns.JSValueMakeNull(c);

    var arena_inst = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_inst.deinit();
    const a = arena_inst.allocator();

    const cmd = argToOwnedUtf8(c, cmd_v, a) orelse return extern_fns.JSValueMakeNull(c);
    if (cmd.len == 0) return extern_fns.JSValueMakeNull(c);

    // An explicit path (contains '/') is checked directly, not searched.
    if (std.mem.indexOfScalar(u8, cmd, '/') != null) {
        return if (isExecutable(a, cmd)) makeJsString(c, a, cmd) else extern_fns.JSValueMakeNull(c);
    }

    const path = if (argc >= 2) blk: {
        if (argv[1]) |v| break :blk (argToOwnedUtf8(c, v, a) orelse "");
        break :blk "";
    } else "";

    var it = std.mem.splitScalar(u8, path, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const candidate = std.fs.path.join(a, &.{ dir, cmd }) catch continue;
        if (isExecutable(a, candidate)) return makeJsString(c, a, candidate);
    }
    return extern_fns.JSValueMakeNull(c);
}

/// True when `path` exists and is executable by the current user.
fn isExecutable(a: std.mem.Allocator, path: []const u8) bool {
    const z = bun.dupeZ(a, u8, path) catch return false;
    return std.c.access(z.ptr, std.posix.X_OK) == 0;
}

fn makeJsString(c: *JSContextRef, a: std.mem.Allocator, s: []const u8) ?*JSValue {
    const z = bun.dupeZ(a, u8, s) catch return extern_fns.JSValueMakeNull(c);
    const js = extern_fns.JSStringCreateWithUTF8CString(z.ptr) orelse return extern_fns.JSValueMakeNull(c);
    defer extern_fns.JSStringRelease(js);
    return extern_fns.JSValueMakeString(c, js);
}

const install_glue =
    \\(function() {
    \\  var spawnSyncNative = globalThis.__home_spawn_sync;
    \\  var whichNative = globalThis.__home_which;
    \\
    \\  function toMode(v, def) {
    \\    if (v === "inherit") return 1;
    \\    if (v === "ignore") return 2;
    \\    if (v === "pipe") return 0;
    \\    return def;
    \\  }
    \\  function toEnvPairs(env) {
    \\    if (!env || typeof env !== "object") return null;
    \\    var pairs = [];
    \\    for (var k in env) {
    \\      if (Object.prototype.hasOwnProperty.call(env, k)) pairs.push(String(k) + "=" + String(env[k]));
    \\    }
    \\    return pairs;
    \\  }
    \\  function toStdinBytes(stdin) {
    \\    if (stdin == null) return null;
    \\    if (typeof stdin === "string") return new TextEncoder().encode(stdin);
    \\    if (stdin instanceof Uint8Array) return stdin;
    \\    if (ArrayBuffer.isView(stdin)) return new Uint8Array(stdin.buffer.slice(stdin.byteOffset, stdin.byteOffset + stdin.byteLength));
    \\    if (stdin instanceof ArrayBuffer) return new Uint8Array(stdin.slice(0));
    \\    return null;
    \\  }
    \\  function wrapBuf(u8) { return (typeof Buffer !== "undefined" && Buffer.from) ? Buffer.from(u8) : u8; }
    \\  // proc.stdout/stderr: a node:stream Readable (push the captured bytes) with
    \\  // Bun's text/json/bytes/arrayBuffer convenience accessors. Falls back to a
    \\  // plain reader object if node:stream isn't available.
    \\  function addAccessors(o, bytes) {
    \\    o.text = function() { return Promise.resolve(new TextDecoder().decode(bytes)); };
    \\    o.json = function() { return Promise.resolve(JSON.parse(new TextDecoder().decode(bytes))); };
    \\    o.bytes = function() { return Promise.resolve(bytes.slice()); };
    \\    o.arrayBuffer = function() { return Promise.resolve(bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength)); };
    \\    return o;
    \\  }
    \\  function makeReader(bytes) {
    \\    if (bytes == null) return null;
    \\    var S = (typeof globalThis.require === "function") ? (function() { try { return globalThis.require("node:stream"); } catch (e) { return null; } })() : null;
    \\    if (!S || !S.Readable) return addAccessors({}, bytes);
    \\    var r = new S.Readable();
    \\    addAccessors(r, bytes);
    \\    Promise.resolve().then(function() { if (bytes.length) r.push(bytes); r.push(null); });
    \\    return r;
    \\  }
    \\
    \\  function spawnSync(cmdOrOpts, maybeOpts) {
    \\    var opts, cmd;
    \\    if (Array.isArray(cmdOrOpts)) { cmd = cmdOrOpts; opts = maybeOpts || {}; }
    \\    else if (cmdOrOpts && typeof cmdOrOpts === "object") { opts = cmdOrOpts; cmd = opts.cmd; }
    \\    else { throw new TypeError("spawnSync: expected a cmd array or an options object"); }
    \\    if (!Array.isArray(cmd) || cmd.length === 0) throw new TypeError("spawnSync: cmd must be a non-empty array");
    \\    var r = spawnSyncNative(
    \\      cmd.map(String),
    \\      opts.cwd != null ? String(opts.cwd) : "",
    \\      toEnvPairs(opts.env),
    \\      toStdinBytes(opts.stdin),
    \\      toMode(opts.stdout, 0),
    \\      toMode(opts.stderr, 0),
    \\      toMode(opts.stdin, 2)
    \\    );
    \\    if (r && r.__spawn_error) throw new Error(r.__spawn_error);
    \\    return {
    \\      pid: r.pid,
    \\      exitCode: r.exitCode,
    \\      signalCode: r.signalCode,
    \\      success: r.success,
    \\      stdout: r.stdout == null ? null : wrapBuf(r.stdout),
    \\      stderr: r.stderr == null ? null : wrapBuf(r.stderr),
    \\    };
    \\  }
    \\
    \\  // Bun.spawn — async-shaped Subprocess. v1 runs the child eagerly to
    \\  // completion via the native sync spawn, then presents resolved
    \\  // exited/stdout/stderr. Covers `await proc.stdout.text()` / `await
    \\  // proc.exited`; true streaming + interactive stdin is a later refinement.
    \\  function spawn(cmdOrOpts, maybeOpts) {
    \\    var opts, cmd;
    \\    if (Array.isArray(cmdOrOpts)) { cmd = cmdOrOpts; opts = maybeOpts || {}; }
    \\    else if (cmdOrOpts && typeof cmdOrOpts === "object") { opts = cmdOrOpts; cmd = opts.cmd; }
    \\    else { throw new TypeError("spawn: expected a cmd array or an options object"); }
    \\    if (!Array.isArray(cmd) || cmd.length === 0) throw new TypeError("spawn: cmd must be a non-empty array");
    \\    var r = spawnSyncNative(
    \\      cmd.map(String),
    \\      opts.cwd != null ? String(opts.cwd) : "",
    \\      toEnvPairs(opts.env),
    \\      toStdinBytes(opts.stdin),
    \\      toMode(opts.stdout, 0),
    \\      toMode(opts.stderr, 0),
    \\      toMode(opts.stdin, 2)
    \\    );
    \\    if (r && r.__spawn_error) throw new Error(r.__spawn_error);
    \\    return {
    \\      pid: r.pid,
    \\      exitCode: r.exitCode,
    \\      signalCode: r.signalCode,
    \\      success: r.success,
    \\      exited: Promise.resolve(r.exitCode),
    \\      stdout: makeReader(r.stdout == null ? null : wrapBuf(r.stdout)),
    \\      stderr: makeReader(r.stderr == null ? null : wrapBuf(r.stderr)),
    \\      stdin: undefined,
    \\      kill: function() {},
    \\      ref: function() {},
    \\      unref: function() {},
    \\    };
    \\  }
    \\
    \\  function which(cmd, opts) {
    \\    if (cmd == null) return null;
    \\    var s = String(cmd);
    \\    // Bun throws when the binary name's UTF-8 byte length reaches
    \\    // MAX_PATH_BYTES (PATH_MAX): 4096 on linux, 1024 elsewhere. Only the
    \\    // large inputs need the precise byte count (<= 4 bytes/char).
    \\    var maxPath = (typeof process !== "undefined" && process.platform === "linux") ? 4096 : 1024;
    \\    var byteLen = s.length < (maxPath >> 2) ? s.length : new TextEncoder().encode(s).length;
    \\    if (byteLen >= maxPath) throw new Error("bin path is too long");
    \\    var path = (opts && opts.PATH != null)
    \\      ? String(opts.PATH)
    \\      : ((typeof process !== "undefined" && process.env && process.env.PATH) || "");
    \\    var r = whichNative(s, path);
    \\    return r == null ? null : r;
    \\  }
    \\
    \\  if (typeof globalThis.Bun !== "object" || globalThis.Bun === null) globalThis.Bun = {};
    \\  globalThis.Bun.spawnSync = spawnSync;
    \\  globalThis.Bun.spawn = spawn;
    \\  globalThis.Bun.which = which;
    \\  delete globalThis.__home_spawn_sync;
    \\  delete globalThis.__home_which;
    \\})();
;

/// Install native `Bun.spawnSync`. No-op without JSC. Augments the existing
/// `Bun` global (run after `bun_global`); uses `Buffer` if present (run after
/// `node_modules`).
pub fn install(allocator: std.mem.Allocator, ctx: *JSContextRef, global: *JSGlobalObject) void {
    if (comptime !build_options.enable_jsc) return;

    callback.registerCallback(ctx, global, "__home_spawn_sync", spawnSyncNative);
    callback.registerCallback(ctx, global, "__home_which", whichNative);

    const result = evaluate.evaluateUtf8Detailed(allocator, ctx, install_glue, "home:spawn-install", 1) catch return;
    result.deinit(allocator);
}

// ---- tests ---------------------------------------------------------------

fn evalBool(allocator: std.mem.Allocator, ctx: *JSContextRef, source: []const u8) !bool {
    const value = (try evaluate.evaluateUtf8(allocator, ctx, source, "home:spawn-probe", 1, null)) orelse
        return error.JSEvaluateReturnedNull;
    return extern_fns.JSValueToBoolean(ctx, value);
}

/// Evaluate `source` and return its result coerced to an owned UTF-8 string.
fn evalString(allocator: std.mem.Allocator, ctx: *JSContextRef, source: []const u8) ![]u8 {
    const value = (try evaluate.evaluateUtf8(allocator, ctx, source, "home:spawn-probe", 1, null)) orelse
        return error.JSEvaluateReturnedNull;
    return try evaluate.valueToUtf8(allocator, ctx, value);
}

fn installRealm(allocator: std.mem.Allocator, ctx: *JSContextRef, global: *JSGlobalObject) void {
    @import("web_globals.zig").install(allocator, ctx, global);
    @import("process.zig").install(allocator, ctx, global, &[_][]const u8{"home"});
    @import("bun_global.zig").install(allocator, ctx, global);
    @import("node_modules.zig").install(allocator, ctx, global);
    install(allocator, ctx, global);
}

test "Bun.spawnSync runs a real OS binary and captures stdout + exitCode" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    const ctx = engine.currentContext();
    installRealm(std.testing.allocator, ctx, engine.currentGlobalObject());

    // /bin/echo is present on macOS and Linux; this is Home's own spawn, not
    // any `bun`/`home run` delegation. On failure the diagnostic carries the
    // real native error message.
    const diag = try evalString(std.testing.allocator, ctx,
        "(function(){ try { var r = Bun.spawnSync(['/bin/echo', 'hello']); " ++
        "return 'OK:' + r.exitCode + ':' + r.success + ':' + new TextDecoder().decode(r.stdout).trim(); } " ++
        "catch (e) { return 'ERR:' + String((e && e.message) || e); } })()");
    defer std.testing.allocator.free(diag);
    std.testing.expectEqualStrings("OK:0:true:hello", diag) catch |err| {
        std.debug.print("spawnSync diag: {s}\n", .{diag});
        return err;
    };
}

test "Bun.which resolves a real binary, returns null for misses, throws on overlong names" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    const ctx = engine.currentContext();
    installRealm(std.testing.allocator, ctx, engine.currentGlobalObject());

    // Mirrors js/bun/util/which.test.ts: a real binary resolves, a miss is
    // null, an explicit PATH option is honoured, and a >PATH_MAX name throws
    // "bin path is too long".
    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "(function() {" ++
        "  function threw(fn, msg) { try { fn(); return false; } catch (e) { return e.message.indexOf(msg) >= 0; } }" ++
        "  if (typeof Bun.which('sh') !== 'string') return false;" ++
        "  if (Bun.which('definitely_not_a_real_binary_xyz') !== null) return false;" ++
        "  if (Bun.which('sh', { PATH: '/bin' }) !== '/bin/sh') return false;" ++
        "  return threw(function() { Bun.which('a'.repeat(100000)); }, 'bin path is too long'); })()"));
}

test "Bun.spawnSync threads env into the child" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    const ctx = engine.currentContext();
    installRealm(std.testing.allocator, ctx, engine.currentGlobalObject());

    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "(function(){ var r = Bun.spawnSync(['/bin/sh', '-c', 'printf %s \"$HOME_SPAWN_VAR\"'], " ++
        "{ env: { HOME_SPAWN_VAR: 'home-rt-42' } }); " ++
        "return r.exitCode === 0 && new TextDecoder().decode(r.stdout) === 'home-rt-42'; })()"));
}

test "Bun.spawnSync feeds stdin bytes to the child" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    const ctx = engine.currentContext();
    installRealm(std.testing.allocator, ctx, engine.currentGlobalObject());

    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "(function(){ var r = Bun.spawnSync(['/bin/cat'], { stdin: 'piped-in' }); " ++
        "return r.exitCode === 0 && new TextDecoder().decode(r.stdout) === 'piped-in'; })()"));
}

test "Bun.spawnSync reports non-zero exit codes" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    const ctx = engine.currentContext();
    installRealm(std.testing.allocator, ctx, engine.currentGlobalObject());

    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "(function(){ var r = Bun.spawnSync(['/bin/sh', '-c', 'exit 7']); " ++
        "return r.exitCode === 7 && r.success === false && r.signalCode === null; })()"));
}

test "Bun.spawnSync throws for a missing executable" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    const ctx = engine.currentContext();
    installRealm(std.testing.allocator, ctx, engine.currentGlobalObject());

    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "(function(){ try { Bun.spawnSync(['/no/such/binary/zzz']); return false; } " ++
        "catch (e) { return e instanceof Error; } })()"));
}

test "Bun.spawnSync honors stdout: 'ignore' (null stdout, still runs)" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    const ctx = engine.currentContext();
    installRealm(std.testing.allocator, ctx, engine.currentGlobalObject());

    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "(function(){ var r = Bun.spawnSync(['/bin/echo', 'hi'], { stdout: 'ignore' }); " ++
        "return r.exitCode === 0 && r.stdout === null; })()"));
}

test "Bun.spawn (eager) exposes pid, exited, and stdout.text()" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    const ctx = engine.currentContext();
    installRealm(std.testing.allocator, ctx, engine.currentGlobalObject());

    // Promise.all over already-resolved exited/stdout settles in the microtask
    // drain that follows evaluation (same pattern as the bun_global tests).
    _ = try evaluate.evaluateUtf8(std.testing.allocator, ctx,
        "globalThis.__sp = '';" ++
        "(function(){ var p = Bun.spawn(['/bin/echo', 'spawn-hi']);" ++
        "  if (typeof p.pid !== 'number' || p.pid <= 0) { globalThis.__sp = 'BADPID'; return; }" ++
        "  Promise.all([p.exited, p.stdout.text()]).then(function(a){ globalThis.__sp = 'OK:' + a[0] + ':' + a[1].trim(); }," ++
        "    function(e){ globalThis.__sp = 'ERR:' + e; });" ++
        "})();",
        "home:spawn-async-setup", 1, null);
    const diag = try evalString(std.testing.allocator, ctx, "globalThis.__sp");
    defer std.testing.allocator.free(diag);
    std.testing.expectEqualStrings("OK:0:spawn-hi", diag) catch |err| {
        std.debug.print("Bun.spawn diag: {s}\n", .{diag});
        return err;
    };
}

test "Bun.spawn .exited resolves with the child exit code" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    const ctx = engine.currentContext();
    installRealm(std.testing.allocator, ctx, engine.currentGlobalObject());

    _ = try evaluate.evaluateUtf8(std.testing.allocator, ctx,
        "globalThis.__se = '';" ++
        "Bun.spawn(['/bin/sh', '-c', 'exit 5']).exited.then(function(c){ globalThis.__se = 'C:' + c; });",
        "home:spawn-exit-setup", 1, null);
    try std.testing.expect(try evalBool(std.testing.allocator, ctx, "globalThis.__se === 'C:5'"));
}

test "Bun.spawn stdout is a node:stream Readable (on 'data'/'end')" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    const ctx = engine.currentContext();
    installRealm(std.testing.allocator, ctx, engine.currentGlobalObject());

    _ = try evaluate.evaluateUtf8(std.testing.allocator, ctx,
        "globalThis.__sps = '';" ++
        "var p = Bun.spawn(['/bin/echo', 'streamed']); var got = '';" ++
        "p.stdout.on('data', function(c) { got += (typeof c === 'string' ? c : new TextDecoder().decode(c)); });" ++
        "p.stdout.on('end', function() { globalThis.__sps = got.trim(); });",
        "home:spawn-stream-setup", 1, null);
    try std.testing.expect(try evalBool(std.testing.allocator, ctx, "globalThis.__sps === 'streamed'"));
}

test "Bun.which resolves a binary via PATH" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    const ctx = engine.currentContext();
    installRealm(std.testing.allocator, ctx, engine.currentGlobalObject());

    // Explicit PATH keeps this deterministic regardless of the test env.
    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "(function(){ var p = Bun.which('sh', { PATH: '/usr/bin:/bin' }); " ++
        "return typeof p === 'string' && p.endsWith('/sh'); })()"));
}

test "Bun.which returns null for a missing binary and resolves absolute paths" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    const ctx = engine.currentContext();
    installRealm(std.testing.allocator, ctx, engine.currentGlobalObject());

    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "(function(){ return Bun.which('home-no-such-bin-zzz', { PATH: '/usr/bin:/bin' }) === null " ++
        "&& Bun.which('/bin/sh') === '/bin/sh' " ++
        "&& Bun.which('/no/such/abs/zzz') === null; })()"));
}
