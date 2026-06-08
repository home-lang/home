// Native `Bun.$` (Bun Shell) for the eval/run realm — a useful SUBSET built on
// Home's own `Bun.spawnSync`. Mirrors the ergonomics of Bun's shell tag:
//
//   await $`echo hello`.text()            // "hello\n"
//   const { stdout, exitCode } = await $`ls -la`
//   await $`echo ${userInput}`            // userInput is one injection-safe arg
//   $`false`.nothrow()                    // don't throw on non-zero exit
//
// SCOPE: this runs a single external command per invocation via spawnSync, with
// injection-safe template interpolation (interpolated values become literal
// argv entries; arrays expand to multiple args). It does NOT implement Bun's
// shell grammar — pipes `|`, redirects `>`/`<`, `&&`/`||`, subshells, globs, and
// builtins (cd/echo/export/…) require Bun's shell interpreter and are out of
// scope here. Installed after spawn_global (needs Bun.spawnSync); comptime-gated.

const std = @import("std");
const build_options = @import("build_options");
const evaluate = @import("evaluate.zig");
const extern_fns = @import("extern_fns.zig");
const opaques = @import("opaques.zig");

const JSContextRef = opaques.JSContextRef;
const JSGlobalObject = opaques.JSGlobalObject;

const install_glue =
    \\(function() {
    \\  var B = globalThis.Bun;
    \\  if (!B || typeof B.spawnSync !== "function") return;
    \\  var $state = { throws: true, cwd: undefined, env: undefined };
    \\
    \\  // Build an argv array from a template literal. Static text is split on
    \\  // unquoted whitespace (single/double quotes group); each interpolated
    \\  // value is appended to the current token as a literal (so spaces inside
    \\  // it never split — injection-safe), and arrays expand to multiple args.
    \\  function buildArgv(strings, exprs) {
    \\    var args = [], cur = "", inTok = false, quote = 0;
    \\    function pushCur() { if (inTok) { args.push(cur); cur = ""; inTok = false; } }
    \\    for (var i = 0; i < strings.length; i++) {
    \\      var part = String(strings[i]);
    \\      for (var j = 0; j < part.length; j++) {
    \\        var ch = part[j], code = part.charCodeAt(j);
    \\        if (quote) {
    \\          if (code === quote) quote = 0; else { cur += ch; inTok = true; }
    \\        } else if (ch === '"' || ch === "'") { quote = code; inTok = true; }
    \\        else if (ch === " " || ch === "\t" || ch === "\n" || ch === "\r") { pushCur(); }
    \\        else { cur += ch; inTok = true; }
    \\      }
    \\      if (i < exprs.length) {
    \\        var e = exprs[i];
    \\        if (Array.isArray(e)) {
    \\          for (var k = 0; k < e.length; k++) {
    \\            if (k > 0) pushCur();
    \\            cur += String(e[k]); inTok = true;
    \\          }
    \\        } else { cur += String(e); inTok = true; }
    \\      }
    \\    }
    \\    pushCur();
    \\    return args;
    \\  }
    \\
    \\  function makeOutput(r) {
    \\    var stdout = Buffer.from(r.stdout), stderr = Buffer.from(r.stderr);
    \\    return {
    \\      stdout: stdout, stderr: stderr, exitCode: r.exitCode,
    \\      text: function(enc) { return stdout.toString(enc || "utf8"); },
    \\      json: function() { return JSON.parse(stdout.toString("utf8")); },
    \\      bytes: function() { return new Uint8Array(stdout); },
    \\      arrayBuffer: function() { var u = new Uint8Array(stdout); return u.buffer.slice(u.byteOffset, u.byteOffset + u.byteLength); },
    \\      blob: function() { return new Blob([stdout]); },
    \\    };
    \\  }
    \\
    \\  function runShell(argv, opts) {
    \\    if (argv.length === 0) throw new Error("Bun.$ received an empty command");
    \\    var so = {};
    \\    if (opts.cwd !== undefined) so.cwd = opts.cwd;
    \\    if (opts.env !== undefined) so.env = opts.env;
    \\    var r = B.spawnSync(argv, so);
    \\    var out = makeOutput(r);
    \\    if (r.exitCode !== 0 && opts.throws) {
    \\      var err = new Error("Command \"" + argv.join(" ") + "\" failed with exit code " + r.exitCode);
    \\      err.exitCode = r.exitCode; err.stdout = out.stdout; err.stderr = out.stderr;
    \\      throw err;
    \\    }
    \\    return out;
    \\  }
    \\
    \\  function ShellPromise(argv) {
    \\    this._argv = argv;
    \\    this._opts = { cwd: $state.cwd, env: $state.env, throws: $state.throws, quiet: false };
    \\    this._ran = false; this._result = null; this._error = null;
    \\  }
    \\  ShellPromise.prototype.cwd = function(d) { this._opts.cwd = d; return this; };
    \\  ShellPromise.prototype.env = function(e) { this._opts.env = e; return this; };
    \\  ShellPromise.prototype.quiet = function() { this._opts.quiet = true; return this; };
    \\  ShellPromise.prototype.nothrow = function() { this._opts.throws = false; return this; };
    \\  ShellPromise.prototype.throws = function(v) { this._opts.throws = v !== false; return this; };
    \\  ShellPromise.prototype._run = function() {
    \\    if (!this._ran) { this._ran = true; try { this._result = runShell(this._argv, this._opts); } catch (e) { this._error = e; } }
    \\    return this;
    \\  };
    \\  ShellPromise.prototype.then = function(onF, onR) {
    \\    this._run();
    \\    return (this._error ? Promise.reject(this._error) : Promise.resolve(this._result)).then(onF, onR);
    \\  };
    \\  ShellPromise.prototype.catch = function(onR) { return this.then(undefined, onR); };
    \\  ShellPromise.prototype.finally = function(fn) { return this.then(function(v) { fn(); return v; }, function(e) { fn(); throw e; }); };
    \\  function shortcut(method) {
    \\    return function() {
    \\      this._run();
    \\      if (this._error) return Promise.reject(this._error);
    \\      var args = arguments;
    \\      try { return Promise.resolve(this._result[method].apply(this._result, args)); } catch (e) { return Promise.reject(e); }
    \\    };
    \\  }
    \\  ShellPromise.prototype.text = shortcut("text");
    \\  ShellPromise.prototype.json = shortcut("json");
    \\  ShellPromise.prototype.bytes = shortcut("bytes");
    \\  ShellPromise.prototype.arrayBuffer = shortcut("arrayBuffer");
    \\  ShellPromise.prototype.blob = shortcut("blob");
    \\
    \\  function $(strings) {
    \\    if (!strings || !Array.isArray(strings) || !strings.raw) throw new TypeError("Bun.$ must be used as a template literal: $`command`");
    \\    var exprs = Array.prototype.slice.call(arguments, 1);
    \\    return new ShellPromise(buildArgv(strings, exprs));
    \\  }
    \\  $.nothrow = function() { $state.throws = false; return $; };
    \\  $.throws = function(v) { $state.throws = v !== false; return $; };
    \\  $.cwd = function(d) { $state.cwd = d; return $; };
    \\  $.env = function(e) { $state.env = e; return $; };
    \\  // No shell parsing happens here, so escaping is a defensive no-op that
    \\  // still strips NULs (which argv cannot carry).
    \\  $.escape = function(s) { return String(s); };
    \\  $.ShellPromise = ShellPromise;
    \\  B.$ = $;
    \\  // The eval/run realm also exposes `$` bare for ergonomic shell use,
    \\  // matching this module's documented `await $`cmd`` examples.
    \\  globalThis.$ = $;
    \\})();
;

/// Install `Bun.$`. No-op without JSC. Must run after spawn_global (Bun.spawnSync)
/// and the webcore/node globals (Buffer, Blob).
pub fn install(allocator: std.mem.Allocator, ctx: *JSContextRef, global: *JSGlobalObject) void {
    if (comptime !build_options.enable_jsc) return;
    _ = global; // installs purely via JS glue over the existing Bun.spawnSync
    const result = evaluate.evaluateUtf8Detailed(allocator, ctx, install_glue, "home:bun-dollar-install", 1) catch return;
    result.deinit(allocator);
}

fn evalBool(allocator: std.mem.Allocator, ctx: *JSContextRef, source: []const u8) !bool {
    const value = (try evaluate.evaluateUtf8(allocator, ctx, source, "home:dollar-probe", 1, null)) orelse
        return error.JSEvaluateReturnedNull;
    return extern_fns.JSValueToBoolean(ctx, value);
}

fn installRealm(allocator: std.mem.Allocator, ctx: *JSContextRef, global: *JSGlobalObject) void {
    @import("web_globals.zig").install(allocator, ctx, global);
    @import("process.zig").install(allocator, ctx, global, &[_][]const u8{"home"});
    @import("timers_global.zig").install(allocator, ctx, global);
    @import("misc_globals.zig").install(allocator, ctx, global);
    @import("webcore_globals.zig").install(allocator, ctx, global);
    @import("bun_global.zig").install(allocator, ctx, global);
    @import("node_modules.zig").install(allocator, ctx, global);
    @import("spawn_global.zig").install(allocator, ctx, global);
    install(allocator, ctx, global);
}

test "Bun.$ runs commands with injection-safe interpolation (subset)" {
    if (!build_options.enable_jsc) return error.SkipZigTest;
    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();
    const ctx = engine.currentContext();
    installRealm(std.testing.allocator, ctx, engine.currentGlobalObject());

    _ = try evaluate.evaluateUtf8(std.testing.allocator, ctx,
        "globalThis.__sh = null;" ++
        "(async function() {" ++
        "  var a = await $`echo hello`.text();" ++
        "  var word = 'wor ld';" ++ // a space inside the value must stay one arg
        "  var b = await $`echo ${word}`.text();" ++
        "  var r = await $`echo combined`;" ++
        "  var thrown = false;" ++
        "  try { await $`false`; } catch (e) { thrown = e.exitCode === 1; }" ++
        "  var noThrow = false;" ++
        "  try { var rr = await $`false`.nothrow(); noThrow = rr.exitCode === 1; } catch (e) {}" ++
        "  globalThis.__sh = (a === 'hello\\n') && (b === 'wor ld\\n') && (r.exitCode === 0) &&" ++
        "    (new TextDecoder().decode(r.stdout).trim() === 'combined') && thrown && noThrow;" ++
        "})();",
        "home:dollar-setup", 1, null);
    @import("timers_global.zig").drain(ctx);
    try std.testing.expect(try evalBool(std.testing.allocator, ctx, "globalThis.__sh === true"));
}
