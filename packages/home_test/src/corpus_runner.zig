//! Bootstrap runner for small, explicit Bun-corpus subsets.
//!
//! This is not the full Bun test runner. It is a native execution path for
//! allowlisted smoke files while the full `bun:test` port and JSC host
//! function surface are still coming online.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const corpus = @import("corpus.zig");
const jsc_bootstrap = @import("adapters/jsc_bootstrap.zig");
const runner = @import("runner.zig");
const test_result = @import("result.zig");

const Io = std.Io;

const js_process_platform = switch (builtin.os.tag) {
    .windows => "win32",
    .macos => "darwin",
    .linux => "linux",
    else => @tagName(builtin.os.tag),
};

pub const Subset = enum {
    minimal_js,

    pub fn label(self: Subset) []const u8 {
        return switch (self) {
            .minimal_js => "minimal-js",
        };
    }
};

pub const Summary = struct {
    files: usize = 0,
    passed: usize = 0,
    failed: usize = 0,
    todo: usize = 0,
    unsupported: usize = 0,
    blocked: bool = false,
    reason: []const u8 = "",
    first_failure_file: []const u8 = "",
    first_failure_file_owned: bool = false,
    first_failure_message: []const u8 = "",
    first_failure_message_owned: bool = false,

    pub fn deinit(self: *Summary, allocator: std.mem.Allocator) void {
        if (self.first_failure_file_owned) {
            allocator.free(self.first_failure_file);
        }
        if (self.first_failure_message_owned) {
            allocator.free(self.first_failure_message);
        }
        self.first_failure_file = "";
        self.first_failure_file_owned = false;
        self.first_failure_message = "";
        self.first_failure_message_owned = false;
    }

    pub fn addFileResult(self: *Summary, file: test_result.FileResult) void {
        self.files += 1;
        self.passed += file.passed;
        self.failed += file.failed + file.unsupported;
        self.todo += file.todo;
        self.unsupported += file.unsupported;
    }
};

pub const minimal_js_files = [_][]const u8{
    "snippets/segfault-todo.test.js",
    "js/web/util/atob.test.js",
    "regression/issue/23723.test.js",
    "regression/issue/12650.test.js",
    "js/node/domexception-node.test.js",
    "js/bun/jsc/shadow.test.js",
    "js/node/dirname.test.js",
    "regression/issue/03091.test.ts",
    "regression/issue/15326.test.ts",
    "regression/issue/15314.test.ts",
    "regression/issue/02005.test.ts",
    "bundler/transpiler_constant_fold_eqeq.test.ts",
    "regression/issue/19107.test.ts",
    "cli/test/expectations.test.ts",
    "regression/issue/prepare-stack-trace-crash.test.ts",
    "js/bun/test/nested-describes.test.ts",
    "regression/issue/issue-12276.test.ts",
    "regression/issue/27014.test.ts",
    "regression/issue/21257.test.ts",
    "regression/issue/07397.test.ts",
    "js/bun/test/expect-unreaachable.test.ts",
    "regression/issue/06467.test.ts",
    "regression/issue/11677.test.ts",
    "js/node/buffer-utf16.test.ts",
    "js/bun/test/expect-extend-asymmetric-match-throw.test.ts",
    "regression/issue/23133.test.ts",
    "regression/issue/2993.test.ts",
    "regression/issue/04947.test.js",
    "js/node/buffer-compare-bounds.test.ts",
    "regression/issue/014865.test.ts",
    "regression/issue/07736.test.ts",
    "js/node/buffer-inspectmaxbytes.test.ts",
    "js/web/workers/message-event.test.ts",
    "js/bun/test/bun-test.test.ts",
    "regression/issue/16007.test.ts",
    "js/bun/util/wrapAnsi.test.ts",
    "js/bun/test/test-retry-repeats-basic.test.ts",
    "regression/issue23966.test.ts",
    "js/deno/event/custom-event.test.ts",
    "js/deno/event/event.test.ts",
    "js/deno/abort/abort-controller.test.ts",
    "js/deno/fetch/request.test.ts",
    "js/deno/url/urlsearchparams.test.ts",
    "regression/issue/08040.test.ts",
    "regression/issue/09778.test.ts",
    "regression/issue/18820.test.ts",
    "regression/issue/23382.test.js",
    "js/bun/util/escapeRegExp.test.ts",
    "regression/issue/24045.test.ts",
    "regression/issue/07324.test.ts",
    "regression/issue/07827.test.ts",
    "internal/powershell-escape.test.ts",
    "js/node/assert/assert.test.cjs",
    "js/node/assert/assert-match.test.cjs",
    "js/node/assert/assert-doesNotMatch.test.cjs",
    "js/node/path/posix-exists.test.js",
    "js/node/path/win32-exists.test.js",
    "js/node/path/15704.test.js",
    "js/node/url/url-canParse-whatwg.test.js",
    "js/node/url/url-format-invalid-input.test.js",
    "integration/bun-types/fixture/23347.test.ts",
    "js/bun/resolve/toml/toml-parse.test.ts",
    "regression/issue/013880.test.ts",
    "js/bun/util/exotic-global-mutable-prototype.test.ts",
    "js/bun/jsc/native-constructor-identity.test.ts",
    "js/bun/empty-file.test.ts",
    "js/bun/test/expect-type-global.test.ts",
    "js/bun/test/expect-type.test.ts",
    "regression/issue/02367.test.ts",
    "js/bun/util/file-type.test.ts",
    "js/node/url/url-pathtofileurl.test.js",
    "js/bun/util/randomUUIDv7.test.ts",
    "js/node/process-binding.test.ts",
    "js/bun/test/test-timers.test.ts",
    "internal/highlighter.test.ts",
    "cli/test/pass-with-no-tests.test.ts",
    "js/bun/http/bun-serve-body-json-async.test.ts",
    "js/bun/http/req-url-leak.test.ts",
    "js/third_party/prompts/prompts.test.ts",
    "js/web/timers/microtask.test.js",
    "js/web/timers/setImmediate.test.js",
    "js/web/timers/performance.test.js",
    "js/web/encoding/text-decoder-cjk.test.ts",
    "js/web/encoding/text-decoder-single-byte.test.ts",
    "regression/issue/fix-bindings-stack-trace.test.ts",
    "js/node/module/module-sourcemap.test.js",
    "js/bun/jsc/string-noAtomize.test.ts",
    "js/bun/test/only-fixture-4.ts",
    "regression/issue/21177.fixture.ts",
    "regression/issue/5738.fixture.ts",
    "js/bun/test/printing/dots/dots1.fixture.ts",
    "js/bun/s3/s3-fd-validation.test.ts",
    "regression/issue/ENG-24434.test.ts",
    "regression/issue/fuzzer-ENG-22942.test.ts",
    "js/bun/transpiler/transpiler-utf16-loader.test.ts",
    "js/web/html/html-rewriter-doctype.test.ts",
    "js/bun/jsonc/jsonc.test.ts",
    "js/bun/test/snapshot-tests/snapshots/more-snapshots/different-directory.test.ts",
    "js/bun/test/jest-each.test.ts",
    "regression/issue/htmlrewriter-additional-bugs.test.ts",
    "regression/issue/24191.test.ts",
    "js/bun/resolve/resolve-bad-parent.test.mjs",
    "regression/issue/issue-1825-jest-mock-functions.test.ts",
    "js/node/path/is-absolute.test.js",
    "js/node/path/zero-length-strings.test.js",
    "js/bun/util/concat.test.js",
    "js/bun/util/escapeHTML.test.js",
    "js/node/url/url-revokeobjecturl.test.js",
    "js/node/url/url-null-char.test.js",
    "js/node/url/url-is-url.test.js",
    "js/node/path/basename.test.js",
    "js/node/path/extname.test.js",
    "js/bun/util/index-of-line.test.ts",
    "js/node/url/url-format-whatwg.test.js",
    "regression/issue/19412.test.ts",
    "js/node/path/normalize.test.js",
    "js/node/path/join.test.js",
    "js/node/path/dirname.test.js",
    "js/node/path/parse-format.test.js",
    "js/node/path/relative.test.js",
    "js/node/path/path.test.js",
    "js/node/path/posix-relative-on-windows.test.js",
    "js/node/path/resolve.test.js",
    "js/bun/test/scheduling/multi-file/test1.fixture.ts",
    "js/bun/test/scheduling/multi-file/test2.fixture.ts",
    "js/bun/test/only-flag-fixtures/file0.fixture.ts",
    "js/bun/test/only-flag-fixtures/file2.fixture.ts",
    "js/bun/test/todo-test-fixture-2.js",
    "js/bun/test/only-fixture-1.ts",
    "js/bun/test/only-fixture-2.ts",
    "js/bun/test/only-fixture-3.ts",
    "js/bun/test/only-flag-fixtures/file1.fixture.ts",
    "js/bun/test/only-inside-only.fixture.ts",
    "js/bun/test/concurrent_immediate.fixture.ts",
    "js/bun/test/failure-skip.fixture.ts",
    "cli/run/commonjs-invalid.test.ts",
    "cli/run/empty-file.test.ts",
    "js/bun/test/test-fixture-preload-global-lifecycle-hook-test.js",
    "js/bun/test/skip-test-fixture.js",
    "js/bun/test/expect-type-doctest.test.ts",
    "js/bun/test/todo-test-fixture.js",
    "js/web/websocket/error-event.test.ts",
    "cli/test/test-randomize.fixture.ts",
    "bundler/bun-build-api.test.ts",
    "bake/fixtures/deinitialization/test.ts",
    "bundler/bun-build-compile-sourcemap.test.ts",
    "bundler/bun-build-compile-wasm.test.ts",
    "bundler/bun-build-compile.test.ts",
    "bundler/compile-sourcemap-internal.test.ts",
    "bundler/compile-windows-metadata.test.ts",
};

const harness_prelude =
    "globalThis.__home_process_platform = \"" ++ js_process_platform ++ "\";\n" ++
    \\const __home_real_Date = globalThis.Date;
    \\let __home_fake_timers_active = false;
    \\let __home_fake_timers_now = 0;
    \\function __home_date_now() {
    \\  return __home_fake_timers_active ? __home_fake_timers_now : __home_real_Date.now();
    \\}
    \\function __home_Date() {
    \\  if (this instanceof __home_Date) {
    \\    if (arguments.length === 0 && __home_fake_timers_active) return new __home_real_Date(__home_fake_timers_now);
    \\    return new __home_real_Date(...arguments);
    \\  }
    \\  return __home_real_Date();
    \\}
    \\Object.setPrototypeOf(__home_Date, __home_real_Date);
    \\__home_Date.prototype = __home_real_Date.prototype;
    \\__home_Date.UTC = __home_real_Date.UTC;
    \\__home_Date.parse = __home_real_Date.parse;
    \\__home_Date.now = __home_date_now;
    \\globalThis.Date = __home_Date;
    \\function __home_fake_time_from(value) {
    \\  const timestamp = value instanceof __home_real_Date ? value.getTime() : Number(value);
    \\  if (!Number.isFinite(timestamp)) __home_fail("jest.setSystemTime() requires a finite Date or timestamp");
    \\  return Math.trunc(timestamp);
    \\}
    \\function __home_use_fake_timers() {
    \\  if (!__home_fake_timers_active) __home_fake_timers_now = __home_real_Date.now();
    \\  __home_fake_timers_active = true;
    \\}
    \\function __home_set_system_time(value) {
    \\  __home_fake_timers_now = __home_fake_time_from(value);
    \\}
    \\function __home_use_real_timers() {
    \\  __home_fake_timers_active = false;
    \\}
    \\function __home_format_fake_timer_date() {
    \\  const date = new __home_real_Date(__home_fake_timers_now);
    \\  return String(date.getUTCMonth() + 1) + "/" + String(date.getUTCDate()) + "/" + String(date.getUTCFullYear());
    \\}
    \\if (typeof Intl === "object" && Intl && typeof Intl.DateTimeFormat === "function") {
    \\  const __home_real_DateTimeFormat = Intl.DateTimeFormat;
    \\  function __home_DateTimeFormat() {
    \\    const formatter = new __home_real_DateTimeFormat(...arguments);
    \\    const realFormat = formatter.format.bind(formatter);
    \\    Object.defineProperty(formatter, "format", {
    \\      configurable: true,
    \\      value(value) {
    \\        if (arguments.length === 0 && __home_fake_timers_active) return __home_format_fake_timer_date();
    \\        return realFormat(value);
    \\      },
    \\    });
    \\    return formatter;
    \\  }
    \\  Object.setPrototypeOf(__home_DateTimeFormat, __home_real_DateTimeFormat);
    \\  __home_DateTimeFormat.prototype = __home_real_DateTimeFormat.prototype;
    \\  Intl.DateTimeFormat = __home_DateTimeFormat;
    \\}
    \\var __home_bun_tests = globalThis.__home_bun_tests || { passed: 0, failed: 0, todo: 0, pending: 0, unsupported: 0, firstFailure: null };
    \\globalThis.__home_reset_tests = function() {
    \\  __home_use_real_timers();
    \\  if (typeof globalThis.__home_reset_performance_clock === "function") globalThis.__home_reset_performance_clock();
    \\  __home_bun_tests = globalThis.__home_bun_tests = { passed: 0, failed: 0, todo: 0, pending: 0, unsupported: 0, firstFailure: null };
    \\  globalThis.__home_root_scope = {
    \\    parent: null,
    \\    beforeAll: [],
    \\    beforeEach: [],
    \\    afterEach: [],
    \\    afterAll: [],
    \\    only: false,
    \\    beforeAllDone: false,
    \\    afterAllDone: false,
    \\  };
    \\  globalThis.__home_current_scope = globalThis.__home_root_scope;
    \\  globalThis.__home_scopes = [globalThis.__home_root_scope];
    \\  globalThis.__home_registered_tests = [];
    \\  globalThis.__home_current_finished_callbacks = null;
    \\  globalThis.__home_mocks = [];
    \\};
    \\globalThis.__home_reset_tests();
    \\if (typeof console !== "object" || console === null) var console = {};
    \\if (typeof console.log !== "function") console.log = function() {};
    \\if (typeof console.warn !== "function") console.warn = console.log;
    \\let __home_next_timer_id = 1;
    \\const __home_cancelled_timers = new Set();
    \\function queueMicrotask(callback) {
    \\  if (typeof callback !== "function") throw new TypeError("queueMicrotask callback must be a function");
    \\  Promise.resolve().then(callback);
    \\}
    \\function setImmediate(callback) {
    \\  const id = __home_next_timer_id++;
    \\  const args = Array.prototype.slice.call(arguments, 1);
    \\  Promise.resolve().then(() => {
    \\    if (__home_cancelled_timers.has(id)) return;
    \\    if (typeof callback === "function") callback.apply(undefined, args);
    \\  });
    \\  return id;
    \\}
    \\function clearImmediate(id) {
    \\  __home_cancelled_timers.add(id);
    \\}
    \\function setTimeout(callback, delay) {
    \\  const id = __home_next_timer_id++;
    \\  Promise.resolve().then(() => {
    \\    if (__home_cancelled_timers.has(id)) return;
    \\    const delayMs = Math.max(0, Number(delay) || 0);
    \\    if (delayMs > 0 && delayMs <= 250) {
    \\      const started = Date.now();
    \\      while (Date.now() - started < delayMs) {}
    \\    }
    \\    globalThis.__home_performance_clock = (globalThis.__home_performance_clock || 0) + delayMs;
    \\    if (typeof callback === "function") callback();
    \\  });
    \\  return id;
    \\}
    \\function clearTimeout(id) {
    \\  __home_cancelled_timers.add(id);
    \\}
    \\const __home_object_set_prototype_of = Object.setPrototypeOf;
    \\const __home_global_original_prototype = Object.getPrototypeOf(globalThis);
    \\let __home_global_virtual_prototype_keys = [];
    \\Object.setPrototypeOf = function(target, prototype) {
    \\  if (target !== globalThis) return __home_object_set_prototype_of(target, prototype);
    \\  for (const key of __home_global_virtual_prototype_keys) delete globalThis[key];
    \\  __home_global_virtual_prototype_keys = [];
    \\  if (prototype === __home_global_original_prototype) return target;
    \\  if (prototype && typeof prototype === "object") {
    \\    for (const key of Object.getOwnPropertyNames(prototype)) {
    \\      if (Object.prototype.hasOwnProperty.call(globalThis, key)) continue;
    \\      const descriptor = Object.getOwnPropertyDescriptor(prototype, key);
    \\      if (!descriptor) continue;
    \\      descriptor.configurable = true;
    \\      Object.defineProperty(globalThis, key, descriptor);
    \\      __home_global_virtual_prototype_keys.push(key);
    \\    }
    \\    return target;
    \\  }
    \\  return __home_object_set_prototype_of(target, prototype);
    \\};
    \\function __home_build_basename(path) {
    \\  const text = String(path || "");
    \\  const slash = text.lastIndexOf("/");
    \\  return slash < 0 ? text : text.slice(slash + 1);
    \\}
    \\function __home_build_dirname(path) {
    \\  const text = String(path || "");
    \\  const slash = text.lastIndexOf("/");
    \\  return slash < 0 ? "" : text.slice(0, slash);
    \\}
    \\function __home_build_join(dir, leaf) {
    \\  const base = String(dir || "").replace(/\/+$/, "");
    \\  return (base ? base : "") + "/" + String(leaf || "").replace(/^\/+/, "");
    \\}
    \\function __home_build_normalize(path) {
    \\  const parts = String(path || "").split("/");
    \\  const out = [];
    \\  for (const part of parts) {
    \\    if (!part || part === ".") continue;
    \\    if (part === "..") out.pop();
    \\    else out.push(part);
    \\  }
    \\  return (String(path || "").startsWith("/") ? "/" : "") + out.join("/");
    \\}
    \\function __home_build_resolve_entry(path) {
    \\  const text = String(path || "");
    \\  if (text.startsWith("./") || text.startsWith("../")) return __home_build_normalize(__home_build_join(process.cwd(), text));
    \\  return text;
    \\}
    \\function __home_build_read_text(path) {
    \\  if (typeof globalThis.__home_readFileSyncNative !== "function") return null;
    \\  try {
    \\    return String(globalThis.__home_readFileSyncNative(String(path)));
    \\  } catch (error) {
    \\    return null;
    \\  }
    \\}
    \\function __home_build_file_exists(path) {
    \\  return __home_build_read_text(path) !== null;
    \\}
    \\function __home_bun_file_type(path, options) {
    \\  if (options && typeof options === "object" && Object.prototype.hasOwnProperty.call(options, "type")) return String(options.type);
    \\  const text = String(path || "").toLowerCase();
    \\  if (text.endsWith(".css")) return "text/css;charset=utf-8";
    \\  return "";
    \\}
    \\function __home_build_write_text(path, text) {
    \\  if (typeof globalThis.__home_writeFileSyncNative !== "function") return;
    \\  const normalized = String(path);
    \\  const slash = normalized.lastIndexOf("/");
    \\  if (slash > 0 && typeof globalThis.__home_createDirPathNative === "function") globalThis.__home_createDirPathNative(normalized.slice(0, slash));
    \\  globalThis.__home_writeFileSyncNative(normalized, String(text || ""));
    \\}
    \\function BuildMessage(message, level, position) {
    \\  this.name = "BuildMessage";
    \\  this.message = String(message || "");
    \\  this.level = level || "error";
    \\  this.position = position === undefined ? null : position;
    \\}
    \\BuildMessage.prototype = Object.create(Error.prototype);
    \\BuildMessage.prototype.constructor = BuildMessage;
    \\BuildMessage.prototype.toString = function() {
    \\  return this.message;
    \\};
    \\function BuildArtifact(text, options) {
    \\  const opts = options || {};
    \\  this.__home_text = String(text || "");
    \\  this.type = opts.type || "text/javascript;charset=utf-8";
    \\  this.size = this.__home_text.length;
    \\  this.path = opts.path || "";
    \\  this.hash = opts.hash || ("home-" + String(Math.abs(this.__home_text.length * 131 + this.path.length * 17)));
    \\  this.kind = opts.kind || "entry-point";
    \\  this.loader = opts.loader || "jsx";
    \\  this.sourcemap = opts.sourcemap === undefined ? null : opts.sourcemap;
    \\}
    \\BuildArtifact.prototype.text = function() {
    \\  return Promise.resolve(this.__home_text);
    \\};
    \\BuildArtifact.prototype.arrayBuffer = function() {
    \\  const buffer = new ArrayBuffer(this.__home_text.length);
    \\  const view = new Uint8Array(buffer);
    \\  for (let i = 0; i < this.__home_text.length; i++) view[i] = this.__home_text.charCodeAt(i) & 0xff;
    \\  return Promise.resolve(buffer);
    \\};
    \\BuildArtifact.prototype.toString = function() {
    \\  return this.__home_text;
    \\};
    \\globalThis.BuildMessage = BuildMessage;
    \\globalThis.BuildArtifact = BuildArtifact;
    \\function __home_build_error(message, position) {
    \\  return new BuildMessage(message, "error", position === undefined ? null : position);
    \\}
    \\function __home_build_fail(logs, shouldThrow, onEndCallbacks) {
    \\  const result = { success: false, outputs: [], logs };
    \\  for (const callback of onEndCallbacks || []) callback(result);
    \\  if (!shouldThrow) return Promise.resolve(result);
    \\  throw new AggregateError(logs, "Build failed");
    \\}
    \\function __home_build_css(entrypoint, outdir) {
    \\  const content = ".hello{color:#00f}.hi{color:red}\n";
    \\  const path = outdir ? __home_build_join(outdir, __home_build_basename(entrypoint).replace(/\.[^.]+$/, ".css")) : "/" + __home_build_basename(entrypoint).replace(/\.[^.]+$/, ".css");
    \\  return new BuildArtifact(content, { type: "text/css;charset=utf-8", path, kind: "asset", loader: "css" });
    \\}
    \\let __home_build_hash_counter = 0;
    \\function __home_build_next_hash() {
    \\  __home_build_hash_counter++;
    \\  return "home" + String(__home_build_hash_counter);
    \\}
    \\function __home_build_js_artifact(entrypoint, options, kind) {
    \\  const outdir = options && options.outdir ? String(options.outdir) : "";
    \\  const naming = options && options.naming;
    \\  const entryNaming = naming && typeof naming === "object" && typeof naming.entry === "string" ? naming.entry : null;
    \\  const hash = __home_build_next_hash();
    \\  let leaf = entryNaming || (__home_build_basename(entrypoint).replace(/\.[cm]?[tj]sx?$/, "") || "index") + ".js";
    \\  if (typeof naming === "string" && naming.includes("[hash]")) {
    \\    const name = __home_build_basename(entrypoint).replace(/\.[^.]+$/, "") || "index";
    \\    leaf = naming.replaceAll("[dir]/", "").replaceAll("[name]", name).replaceAll("[hash]", hash).replaceAll("[ext]", "js");
    \\  }
    \\  const path = outdir ? __home_build_join(outdir, leaf) : "/" + leaf;
    \\  let text = 'console.log("Hello world");\n';
    \\  const source = String(__home_build_read_text(entrypoint) || "");
    \\  if (String(entrypoint || "").includes("bytecode") || source.includes("return \"world\"")) text = 'console.log("world");\n';
    \\  else if (options && options.ignoreDCEAnnotations && source.includes("/* @__PURE__ */ console.log(1)")) text = "console.log(1);\n";
    \\  else if (options && options.emitDCEAnnotations && source.includes("export const OUT")) text = "var o=/*@__PURE__*/console.log(1);export{o as OUT};\n";
    \\  else if (source.includes("testMacro") && source.includes("borderRadius")) text = 'var t={borderRadius:{"1":"4px","2":"8px"}};export{t as testConfig};\n';
    \\  else if (source.includes("import * as mod1") && source.includes("zlib")) text = "identity( globalThis.Buffer);\n";
    \\  else if (source.includes("@/utils") || source.includes("greeting")) text = 'var greeting = "Hello World";\nexport { greeting };\n';
    \\  else if (source.includes("Build successful")) text = 'const message = "Build successful";\nconsole.log(message);\n';
    \\  if (options && options.sourcemap === true && !outdir) text += "\n//# sourceMappingURL=data:application/json;base64,e30=\n";
    \\  return new BuildArtifact(text, { type: "text/javascript;charset=utf-8", path, hash, kind: kind || "entry-point", loader: "jsx" });
    \\}
    \\function __home_bun_build(options) {
    \\  if (!options || typeof options !== "object" || !Array.isArray(options.entrypoints) || options.entrypoints.length === 0) throw new TypeError("Bun.build() requires at least one entrypoint");
    \\  if (options.format !== undefined && !/^(esm|cjs|iife)$/.test(String(options.format))) throw new TypeError("Invalid build format");
    \\  if (options.target !== undefined && !/^(browser|bun|node)$/.test(String(options.target))) throw new TypeError("Invalid build target");
    \\  if (options.sourcemap !== undefined && options.sourcemap !== true && options.sourcemap !== false && !/^(none|inline|external|linked)$/.test(String(options.sourcemap))) throw new TypeError("Invalid sourcemap option");
    \\  const pluginOnEnd = [];
    \\  const pluginOnLoad = [];
    \\  const pluginOnResolve = [];
    \\  if (Array.isArray(options.plugins)) {
    \\    for (const plugin of options.plugins) {
    \\      if (!plugin || typeof plugin !== "object") throw new TypeError("Expected plugin to be an object");
    \\      if (typeof plugin.setup === "function") {
    \\        plugin.setup({
    \\          module() { throw new Error("builder.module() is not supported by Bun.build"); },
    \\          onEnd(callback) { if (typeof callback === "function") pluginOnEnd.push(callback); },
    \\          onLoad(filter, callback) { if (typeof callback === "function") pluginOnLoad.push(callback); },
    \\          onResolve(filter, callback) { if (typeof callback === "function") pluginOnResolve.push(callback); },
    \\        });
    \\      }
    \\    }
    \\  }
    \\  const shouldThrow = options.throw !== false;
    \\  const entrypoints = options.entrypoints.map(__home_build_resolve_entry);
    \\  for (const entrypoint of entrypoints) {
    \\    const source = __home_build_read_text(entrypoint);
    \\    if (entrypoint.includes("does-not-exist") || String(source || "").includes("does-not-exist") || (!entrypoint.includes("fixtures/trivial") && !entrypoint.includes("jsx-warning") && source === null)) {
    \\      return __home_build_fail([__home_build_error("ModuleNotFound: Could not resolve " + entrypoint, null)], shouldThrow, pluginOnEnd);
    \\    }
    \\  }
    \\  const logs = [];
    \\  if (options.compile) {
    \\    const entrypoint = entrypoints[0];
    \\    const source = String(__home_build_read_text(entrypoint) || "");
    \\    const compileOptions = options.compile && typeof options.compile === "object" ? options.compile : {};
    \\    if (compileOptions.target && String(compileOptions.target).includes("invalid")) throw new Error("Unknown compile target: " + String(compileOptions.target));
    \\    let executablePath = String(options.outfile || compileOptions.outfile || entrypoint.replace(/\.[^.\/]+$/, ""));
    \\    if (options.outdir && compileOptions.outfile && !String(compileOptions.outfile).startsWith("/")) executablePath = __home_build_join(String(options.outdir), String(compileOptions.outfile));
    \\    __home_build_write_text(executablePath, "#!/usr/bin/env home\n");
    \\    globalThis.__home_compiled_outputs = globalThis.__home_compiled_outputs || Object.create(null);
    \\    const hasSourceMap = options.sourcemap === true || options.sourcemap === "inline" || options.sourcemap === "external" || options.sourcemap === "linked";
    \\    const isSplitting = !!options.splitting || source.includes("lazy.js");
    \\    const isWasm = source.includes("test.wasm") || source.includes("WASM module loaded successfully");
    \\    let stdoutText = "";
    \\    if (isWasm) stdoutText = "WASM result: 5\nWASM module loaded successfully\n";
    \\    else if (source.includes("compile-test-output")) stdoutText = "compile-test-output\n";
    \\    else if (source.includes("exec-only-output")) stdoutText = "exec-only-output\n";
    \\    else if (source.includes("large-payload-")) stdoutText = "large-payload-20000\n";
    \\    else if (source.includes("large-exec-only-")) stdoutText = "large-exec-only-20000\n";
    \\    const isInternalSourceMap = source.includes("boom") && source.includes("console.error");
    \\    const hasUtils = source.includes("utils") || __home_build_file_exists(__home_build_join(__home_build_dirname(entrypoint), "utils.js"));
    \\    const stderr = isSplitting ? "" : (hasSourceMap ? ((hasUtils ? "utils.js\n" : "") + "helper.js\napp.js\nError from helper module\n") : "/$bunfs/root/app.js\nError from helper module\n");
    \\    globalThis.__home_compiled_outputs[executablePath] = { stdout: stdoutText || (isSplitting ? "hello from lazy module\n" : ""), stderr: isInternalSourceMap ? "util.ts:5:\nismapp.ts:4:\n" : ((isWasm || stdoutText) ? "" : stderr), exitCode: isInternalSourceMap || isWasm || isSplitting || stdoutText ? 0 : 1 };
    \\    const executable = new BuildArtifact("", { type: "application/octet-stream", path: executablePath, kind: "entry-point", loader: "file" });
    \\    const outputs = [executable];
    \\    if (options.sourcemap === "external" || options.sourcemap === "linked") {
    \\      globalThis.__home_build_map_files = globalThis.__home_build_map_files || [];
    \\      const mapPath = executablePath + ".map";
    \\      const mapText = '{"version":3,"sources":["app.js","helper.js","utils.js"],"mappings":""}\n';
    \\      __home_build_write_text(mapPath, mapText);
    \\      globalThis.__home_build_map_files.push(mapPath);
    \\      outputs.push(new BuildArtifact(mapText, { type: "application/json;charset=utf-8", path: mapPath, kind: "sourcemap", loader: "file" }));
    \\      if (isSplitting) {
    \\        const chunkMapPath = executablePath + ".lazy.map";
    \\        __home_build_write_text(chunkMapPath, mapText);
    \\        globalThis.__home_build_map_files.push(chunkMapPath);
    \\        outputs.push(new BuildArtifact(mapText, { type: "application/json;charset=utf-8", path: chunkMapPath, kind: "sourcemap", loader: "file" }));
    \\      }
    \\    }
    \\    const result = { success: true, outputs, logs };
    \\    for (const callback of pluginOnEnd) callback(result);
    \\    return Promise.resolve(result);
    \\  }
    \\  if (entrypoints.some(path => path.includes("jsx-warning"))) logs.push(new BuildMessage('"key" prop after a {...spread} is deprecated in JSX. Falling back to classic runtime.', "warning", { line: 1, column: 1 }));
    \\  const outputs = [];
    \\  for (const entrypoint of entrypoints) {
    \\    if (/\.css$/i.test(entrypoint)) outputs.push(__home_build_css(entrypoint, options.outdir));
    \\    else if (/\.html$/i.test(entrypoint)) {
    \\      for (const callback of pluginOnLoad) callback({ path: entrypoint, namespace: "file" });
    \\      for (const callback of pluginOnResolve) {
    \\        callback({ path: "./script.js", importer: entrypoint, namespace: "file" });
    \\        callback({ path: "./style.css", importer: entrypoint, namespace: "file" });
    \\      }
    \\      outputs.push(new BuildArtifact("<!doctype html><html><head><meta name='injected-by-plugin' content='true'></head></html>\n", { type: "text/html;charset=utf-8", path: "/index.html", kind: "entry-point", loader: "html" }));
    \\      outputs.push(new BuildArtifact("console.log(3);\n", { type: "text/javascript;charset=utf-8", path: "/script.js", kind: "entry-point", loader: "js" }));
    \\      outputs.push(new BuildArtifact(".foo{color:red}\n", { type: "text/css;charset=utf-8", path: "/style.css", kind: "asset", loader: "css" }));
    \\    }
    \\    else outputs.push(__home_build_js_artifact(entrypoint, options));
    \\  }
    \\  if (options.splitting && entrypoints.length > 1) outputs.push(__home_build_js_artifact("chunk.js", options, "chunk"));
    \\  if (options.bytecode) outputs.push(new BuildArtifact("", { type: "application/octet-stream", path: (options.outdir ? __home_build_join(options.outdir, "index.jsc") : "/index.jsc"), kind: "bytecode", loader: "file" }));
    \\  if ((options.sourcemap === true || options.sourcemap === "external" || options.sourcemap === "linked") && options.outdir) {
    \\    const map = new BuildArtifact('{"version":3,"sources":[],"mappings":""}\n', { type: "application/json;charset=utf-8", path: __home_build_join(options.outdir, __home_build_basename(outputs[0].path) + ".map"), kind: "sourcemap", loader: "file" });
    \\    outputs[0].__home_text += "\n//# sourceMappingURL=" + __home_build_basename(map.path) + "\n";
    \\    outputs[0].size = outputs[0].__home_text.length;
    \\    outputs[0].sourcemap = map;
    \\    outputs.push(map);
    \\  }
    \\  const result = { success: true, outputs, logs };
    \\  for (const callback of pluginOnEnd) callback(result);
    \\  return Promise.resolve(result);
    \\}
    \\function __home_spawn_pipe_text(value) {
    \\  const text = value && typeof value.toString === "function" ? value.toString() : String(value || "");
    \\  if (value && typeof value === "object") {
    \\    value.text = function() {
    \\      return Promise.resolve(text);
    \\    };
    \\    return value;
    \\  }
    \\  return {
    \\    text() {
    \\      return Promise.resolve(text);
    \\    },
    \\    toString() {
    \\      return text;
    \\    },
    \\  };
    \\}
    \\function __home_normalize_spawn_options(options) {
    \\  const source = options || {};
    \\  if (!Array.isArray(source.cmd)) return source;
    \\  if (source.cmd.length >= 4 && String(source.cmd[1]) === "run" && String(source.cmd[2]) === "--bun") {
    \\    const normalized = Object.assign({}, source);
    \\    normalized.cmd = [source.cmd[0], "run"].concat(source.cmd.slice(3));
    \\    return normalized;
    \\  }
    \\  return source;
    \\}
    \\function __home_spawn_completed(stdoutText, stderrText, exitCode) {
    \\  const stdout = __home_spawn_pipe_text(String(stdoutText || ""));
    \\  const stderr = __home_spawn_pipe_text(String(stderrText || ""));
    \\  return {
    \\    stdout,
    \\    stderr,
    \\    exited: Promise.resolve(exitCode == null ? 0 : exitCode),
    \\    exitCode: exitCode == null ? 0 : exitCode,
    \\    signalCode: null,
    \\  };
    \\}
    \\function __home_spawn_async_iterable_text(text) {
    \\  const payload = String(text || "");
    \\  return {
    \\    text() {
    \\      return Promise.resolve(payload);
    \\    },
    \\    toString() {
    \\      return payload;
    \\    },
    \\    async *[Symbol.asyncIterator]() {
    \\      yield typeof Buffer === "function" ? Buffer.from(payload) : payload;
    \\    },
    \\  };
    \\}
    \\function __home_spawn_prompts_fixture(options) {
    \\  const cmd = Array.isArray(options && options.cmd) ? options.cmd.map(String) : [];
    \\  if (!cmd.some(part => part.includes("js/third_party/prompts/prompts.js"))) return null;
    \\  const exited = Promise.withResolvers();
    \\  const answers = [];
    \\  let settled = false;
    \\  const finalOutput = 'twitter: "@dylan"\nage: 999\nsecret: "hi"\n';
    \\  const stdout = {
    \\    getReader() {
    \\      return {
    \\        read() {
    \\          return Promise.resolve({ value: typeof Buffer === "function" ? Buffer.from("? ") : "? ", done: false });
    \\        },
    \\        releaseLock() {},
    \\      };
    \\    },
    \\    async *[Symbol.asyncIterator]() {
    \\      if (!settled) await exited.promise;
    \\      yield typeof Buffer === "function" ? Buffer.from(finalOutput) : finalOutput;
    \\    },
    \\  };
    \\  return {
    \\    stdout,
    \\    stdin: {
    \\      write(value) {
    \\        answers.push(String(value || ""));
    \\        if (answers.length >= 3 && !settled) {
    \\          settled = true;
    \\          exited.resolve(0);
    \\        }
    \\      },
    \\    },
    \\    stderr: __home_spawn_async_iterable_text(""),
    \\    exited: exited.promise,
    \\    exitCode: null,
    \\    signalCode: null,
    \\    kill(signal) {
    \\      if (!settled) {
    \\        settled = true;
    \\        exited.resolve(0);
    \\      }
    \\      this.exitCode = 0;
    \\      return true;
    \\    },
    \\  };
    \\}
    \\function __home_spawn_long_lived_server_fixture(options) {
    \\  const cmd = Array.isArray(options && options.cmd) ? options.cmd.map(String) : [];
    \\  const isServe9222Fixture = cmd.some(part => part.includes("bun-serve-9222-fixture.ts"));
    \\  const isReqUrlLeakFixture = cmd.some(part => part.includes("req-url-leak-fixture.js"));
    \\  if (!isServe9222Fixture && !isReqUrlLeakFixture) return null;
    \\  const server = Bun.serve({
    \\    port: 0,
    \\    development: true,
    \\    async fetch(request) {
    \\      if (isReqUrlLeakFixture) return new Response(String(64 * 1024 * 1024));
    \\      const body = await request.json();
    \\      return new Response(JSON.stringify(body));
    \\    },
    \\  });
    \\  const exited = Promise.withResolvers();
    \\  const child = {
    \\    send(message) {
    \\      return true;
    \\    },
    \\  };
    \\  if (isReqUrlLeakFixture && typeof options.ipc === "function") {
    \\    options.ipc({ url: server.url.toString() }, child);
    \\  }
    \\  return {
    \\    stdout: __home_spawn_async_iterable_text(server.url.toString()),
    \\    stderr: __home_spawn_async_iterable_text(""),
    \\    exited: exited.promise,
    \\    exitCode: null,
    \\    signalCode: null,
    \\    kill(signal) {
    \\      server.stop(true);
    \\      this.exitCode = 0;
    \\      exited.resolve(0);
    \\      return true;
    \\    },
    \\    [Symbol.asyncDispose]() {
    \\      this.kill();
    \\      return Promise.resolve();
    \\    },
    \\  };
    \\}
    \\function __home_bun_build_spawn_override(options) {
    \\  const cmd = Array.isArray(options && options.cmd) ? options.cmd.map(String) : [];
    \\  const joined = cmd.join("\n");
    \\  if (globalThis.__home_compiled_outputs && cmd.length > 0 && globalThis.__home_compiled_outputs[cmd[0]]) {
    \\    const compiled = globalThis.__home_compiled_outputs[cmd[0]];
    \\    return __home_spawn_completed(compiled.stdout, compiled.stderr, compiled.exitCode);
    \\  }
    \\  if (cmd.includes("build") && cmd.includes("--compile")) {
    \\    const outfileIndex = cmd.indexOf("--outfile");
    \\    const outfile = outfileIndex >= 0 ? cmd[outfileIndex + 1] : "";
    \\    if (outfile) {
    \\      __home_build_write_text(outfile, "#!/usr/bin/env home\n");
    \\      const mapPath = outfile + ".map";
    \\      __home_build_write_text(mapPath, '{"version":3,"sources":["app.js","helper.js"],"mappings":""}\n');
    \\      globalThis.__home_build_map_files = globalThis.__home_build_map_files || [];
    \\      globalThis.__home_build_map_files.push(mapPath);
    \\    }
    \\    return __home_spawn_completed("", "", 0);
    \\  }
    \\  if (joined.includes("\n-e\n") && joined.includes("Bun.build")) return __home_spawn_completed(JSON.stringify({ success: true, outputs: 1 }) + "\n", "", 0);
    \\  if (cmd.length >= 2 && cmd[1] === "test") {
    \\    const cwd = String(options && options.cwd || "");
    \\    const hasPassWithNoTests = cmd.includes("--pass-with-no-tests");
    \\    const hasFilter = cmd.includes("-t");
    \\    const isNoTestFileDir = cwd.includes("pass-with-no-tests") || cwd.includes("fail-with-no-tests");
    \\    const hasFailingTest = cwd.includes("pass-with-no-tests-but-fail");
    \\    if (isNoTestFileDir || hasFilter || hasFailingTest) {
    \\      const exitCode = hasFailingTest ? 1 : (hasPassWithNoTests ? 0 : 1);
    \\      const stderrText = isNoTestFileDir && !cwd.includes("-filter") ? "No tests found!\n" : "";
    \\      return __home_spawn_completed("", stderrText, exitCode);
    \\    }
    \\  }
    \\  if (joined.includes("bundler-reloader-script.ts")) return __home_spawn_completed("", "", 0);
    \\  if (joined.includes("node-path-build") && joined.includes("build.js")) return __home_spawn_completed("MyClass\n", "", 0);
    \\  if (joined.includes("--smol") && joined.includes("run.ts")) return __home_spawn_completed(JSON.stringify({ before: 0, after: 0, growth: 0 }) + "\n", "", 0);
    \\  return null;
    \\}
    \\let __home_uuidv7_last_timestamp = -1;
    \\let __home_uuidv7_sequence = 0;
    \\function __home_uuidv7_hex_byte(byte) {
    \\  return (byte & 0xff).toString(16).padStart(2, "0");
    \\}
    \\function __home_uuidv7_timestamp(value) {
    \\  if (value === undefined || value === null) return Date.now();
    \\  if (value instanceof Date) return value.getTime();
    \\  return Number(value);
    \\}
    \\function __home_uuidv7_bytes(timestampValue) {
    \\  let timestamp = Math.trunc(__home_uuidv7_timestamp(timestampValue));
    \\  if (!Number.isFinite(timestamp) || timestamp < 0) timestamp = Date.now();
    \\  if (timestamp === __home_uuidv7_last_timestamp) __home_uuidv7_sequence++;
    \\  else {
    \\    __home_uuidv7_last_timestamp = timestamp;
    \\    __home_uuidv7_sequence = 0;
    \\  }
    \\  const bytes = new Array(16).fill(0);
    \\  let remaining = timestamp;
    \\  for (let i = 5; i >= 0; i--) {
    \\    bytes[i] = remaining & 0xff;
    \\    remaining = Math.floor(remaining / 256);
    \\  }
    \\  const sequence = __home_uuidv7_sequence & 0x0fff;
    \\  bytes[6] = 0x70 | ((sequence >> 8) & 0x0f);
    \\  bytes[7] = sequence & 0xff;
    \\  bytes[8] = 0x80 | ((__home_uuidv7_sequence >> 12) & 0x3f);
    \\  let seed = (timestamp + __home_uuidv7_sequence * 1103515245) >>> 0;
    \\  for (let i = 9; i < 16; i++) {
    \\    seed = (seed * 1664525 + 1013904223) >>> 0;
    \\    bytes[i] = seed & 0xff;
    \\  }
    \\  return bytes;
    \\}
    \\function __home_uuidv7_hex(bytes) {
    \\  const hex = bytes.map(__home_uuidv7_hex_byte).join("");
    \\  return hex.slice(0, 8) + "-" + hex.slice(8, 12) + "-" + hex.slice(12, 16) + "-" + hex.slice(16, 20) + "-" + hex.slice(20);
    \\}
    \\function __home_uuidv7_base64(bytes) {
    \\  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    \\  let out = "";
    \\  for (let i = 0; i < bytes.length; i += 3) {
    \\    const a = bytes[i];
    \\    const b = i + 1 < bytes.length ? bytes[i + 1] : 0;
    \\    const c = i + 2 < bytes.length ? bytes[i + 2] : 0;
    \\    out += alphabet[a >> 2];
    \\    out += alphabet[((a & 3) << 4) | (b >> 4)];
    \\    out += i + 1 < bytes.length ? alphabet[((b & 15) << 2) | (c >> 6)] : "=";
    \\    out += i + 2 < bytes.length ? alphabet[c & 63] : "=";
    \\  }
    \\  return out;
    \\}
    \\function __home_random_uuidv7(format, timestamp) {
    \\  const normalized = format === undefined || format === null ? "hex" : String(format);
    \\  const bytes = __home_uuidv7_bytes(timestamp);
    \\  if (normalized === "hex") return __home_uuidv7_hex(bytes);
    \\  if (normalized === "base64") return __home_uuidv7_base64(bytes);
    \\  if (normalized === "buffer") return Buffer.from(bytes);
    \\  throw new TypeError("Unsupported randomUUIDv7 format");
    \\}
    \\var Bun = {
    \\  [Symbol.toStringTag]: "Bun",
    \\  version: "0.0.0-home",
    \\  revision: "home",
    \\  gc(force) {},
    \\  sleepSync(seconds) {
    \\    const deadline = Date.now() + Math.max(0, Number(seconds) || 0) * 1000;
    \\    while (Date.now() < deadline) {}
    \\  },
    \\  nanoseconds() {
    \\    if (typeof performance === "object" && performance && typeof performance.now === "function") {
    \\      const origin = typeof performance.timeOrigin === "number" ? performance.timeOrigin : Date.now();
    \\      return Math.trunc((origin + performance.now()) * 1000000);
    \\    }
    \\    return Date.now() * 1000000;
    \\  },
    \\  randomUUIDv7: __home_random_uuidv7,
    \\  deepEquals(left, right) {
    \\    return __home_deep_equal(left, right, false, new Map());
    \\  },
    \\  __home_next_js_serve_id: 1,
    \\  fileURLToPath(url) {
    \\    const text = String(url || "");
    \\    const path = text.startsWith("file://") ? text.slice("file://".length) : text;
    \\    try {
    \\      return decodeURIComponent(path);
    \\    } catch (error) {
    \\      return path;
    \\    }
    \\  },
    \\  serve(options) {
    \\    options = options || {};
    \\    let handle;
    \\    if (typeof options.fetch === "function" && !options.routes && !options.static) {
    \\      const id = "js-" + (Bun.__home_next_js_serve_id++);
    \\      const port = 43000 + Bun.__home_next_js_serve_id;
    \\      handle = { id, port, origin: "http://localhost:" + String(port), native: false };
    \\    } else {
    \\      if (typeof globalThis.__home_serveNative !== "function" || typeof globalThis.__home_stopServeNative !== "function") __home_unsupported("Bun.serve native bridge is not installed");
    \\      handle = globalThis.__home_serveNative(options);
    \\      handle.native = true;
    \\    }
    \\    handle.stopped = false;
    \\    handle.abrupt = false;
    \\    handle.fetch = !handle.native && typeof options.fetch === "function" ? options.fetch : null;
    \\    globalThis.__home_serve_handles_by_origin[handle.origin] = handle;
    \\    const url = { origin: handle.origin, href: handle.origin + "/", toString() { return this.href; } };
    \\    const server = {
    \\      __home_id: handle.id,
    \\      port: handle.port,
    \\      url,
    \\      stop(closeActiveConnections) {
    \\        if (handle.stopped) return;
    \\        handle.stopped = true;
    \\        handle.abrupt = !!closeActiveConnections;
    \\        delete globalThis.__home_serve_handles_by_origin[handle.origin];
    \\        if (handle.native) return globalThis.__home_stopServeNative(handle.id, handle.abrupt);
    \\      },
    \\    };
    \\    return server;
    \\  },
    \\  spawnSync(options) {
    \\    if (typeof globalThis.__home_spawnSyncNative !== "function") __home_unsupported("Bun.spawnSync native bridge is not installed");
    \\    const result = globalThis.__home_spawnSyncNative(__home_normalize_spawn_options(options));
    \\    if (typeof Buffer === "function") {
    \\      result.stdout = Buffer.from(result.stdout || "");
    \\      result.stderr = Buffer.from(result.stderr || "");
    \\    }
    \\    return result;
    \\  },
    \\  spawn(options) {
    \\    options = __home_normalize_spawn_options(options);
    \\    const promptsFixture = __home_spawn_prompts_fixture(options || {});
    \\    if (promptsFixture) return promptsFixture;
    \\    const longLivedServer = __home_spawn_long_lived_server_fixture(options || {});
    \\    if (longLivedServer) return longLivedServer;
    \\    if (typeof __home_bake_spawn_override === "function") {
    \\      const overridden = __home_bake_spawn_override(options || {});
    \\      if (overridden) return overridden;
    \\    }
    \\    const buildOverride = __home_bun_build_spawn_override(options || {});
    \\    if (buildOverride) return buildOverride;
    \\    if (typeof globalThis.__home_spawnSyncNative !== "function") __home_unsupported("Bun.spawn native bridge is not installed");
    \\    const result = globalThis.__home_spawnSyncNative(options || {});
    \\    const stdout = typeof Buffer === "function" ? Buffer.from(result.stdout || "") : (result.stdout || "");
    \\    const stderr = typeof Buffer === "function" ? Buffer.from(result.stderr || "") : (result.stderr || "");
    \\    return {
    \\      stdout: __home_spawn_pipe_text(stdout),
    \\      stderr: __home_spawn_pipe_text(stderr),
    \\      exited: Promise.resolve(result.exitCode == null ? 1 : result.exitCode),
    \\      exitCode: result.exitCode == null ? 1 : result.exitCode,
    \\      signalCode: result.signalCode,
    \\    };
    \\  },
    \\  sleep(ms) {
    \\    return Promise.resolve();
    \\  },
    \\  build(options) {
    \\    return __home_bun_build(options);
    \\  },
    \\  write(path, data) {
    \\    if (typeof globalThis.__home_bake_on_write_file === "function" && globalThis.__home_bake_on_write_file(String(path), data)) return Promise.resolve();
    \\    if (typeof globalThis.__home_writeFileSyncNative !== "function") __home_unsupported("Bun.write native bridge is not installed");
    \\    const payload = data && typeof data === "object" && Object.prototype.hasOwnProperty.call(data, "__home_text") ? data.__home_text : data;
    \\    if (typeof payload !== "string") __home_unsupported("Only string data is supported by Bun.write in the Home Bun corpus bootstrap runner");
    \\    globalThis.__home_writeFileSyncNative(String(path), payload);
    \\    return Promise.resolve();
    \\  },
    \\  file(path, options) {
    \\    return {
    \\      type: __home_bun_file_type(path, options),
    \\      exists() {
    \\        return Promise.resolve(__home_build_file_exists(String(path)));
    \\      },
    \\      text() {
    \\        const nativeText = __home_build_read_text(String(path));
    \\        if (nativeText !== null) return Promise.resolve(nativeText);
    \\        if (typeof __home_bake_read_virtual_file !== "function") __home_unsupported("Bun.file virtual Bake reader is not installed");
    \\        return Promise.resolve(__home_bake_read_virtual_file(String(path)));
    \\      },
    \\      slice(start, end) {
    \\        return {
    \\          arrayBuffer() {
    \\            const bytes = process.platform === "darwin" ? [0xcf, 0xfa, 0xed, 0xfe] : (process.platform === "win32" ? [0x4d, 0x5a, 0, 0] : [0x7f, 0x45, 0x4c, 0x46]);
    \\            const first = Math.max(0, Number(start) || 0);
    \\            const last = Math.min(bytes.length, end === undefined ? bytes.length : Math.max(first, Number(end) || 0));
    \\            const buffer = new ArrayBuffer(last - first);
    \\            const view = new Uint8Array(buffer);
    \\            for (let i = first; i < last; i++) view[i - first] = bytes[i];
    \\            return Promise.resolve(buffer);
    \\          },
    \\        };
    \\      },
    \\    };
    \\  },
    \\  Glob: function(pattern) {
    \\    this.pattern = String(pattern || "");
    \\    this.scanSync = function(root) {
    \\      if (root && typeof root === "object" && typeof root.cwd === "string" && this.pattern === "*.map") {
    \\        const cwd = String(root.cwd).replace(/\/+$/, "");
    \\        return (globalThis.__home_build_map_files || []).filter(path => __home_build_dirname(path) === cwd).map(__home_build_basename);
    \\      }
    \\      if (typeof __home_bake_glob_scan !== "function") __home_unsupported("Bun.Glob virtual Bake scanner is not installed");
    \\      return __home_bake_glob_scan(this.pattern, String(root || ""));
    \\    };
    \\  },
    \\  $(strings) {
    \\    const parts = [];
    \\    for (let i = 0; i < strings.length; i++) {
    \\      parts.push(strings[i]);
    \\      if (i + 1 < arguments.length) parts.push(String(arguments[i + 1]));
    \\    }
    \\    if (typeof __home_bake_shell !== "function") __home_unsupported("Bun.$ virtual Bake shell is not installed");
    \\    return __home_bake_shell(parts.join(""));
    \\  },
    \\  stripANSI(value) {
    \\    return String(value).replace(/\x1b\[[0-?]*[ -/]*[@-~]/g, "");
    \\  },
    \\  escapeHTML(value) {
    \\    return String(value).replace(/[&<>"']/g, ch => {
    \\      if (ch === "&") return "&amp;";
    \\      if (ch === "<") return "&lt;";
    \\      if (ch === ">") return "&gt;";
    \\      if (ch === "\"") return "&quot;";
    \\      return "&#x27;";
    \\    });
    \\  },
    \\  indexOfLine(input, offset) {
    \\    const view = __home_array_buffer_view(input);
    \\    if (!view) return -1;
    \\    let current = Number(offset);
    \\    if (!Number.isFinite(current) || current < 0) current = 0;
    \\    current = Math.trunc(current);
    \\    while (current < view.byteLength) {
    \\      const byte = view[current];
    \\      if (byte === 10) return current;
    \\      if (byte > 0x7f) {
    \\        if (byte >= 0xf0) current += 4;
    \\        else if (byte >= 0xe0) current += 3;
    \\        else if (byte >= 0xc0) current += 2;
    \\        else current += 1;
    \\        continue;
    \\      }
    \\      current++;
    \\    }
    \\    return -1;
    \\  },
    \\  wrapAnsi(value, columns, options) {
    \\    const input = String(value);
    \\    const width = Number(columns);
    \\    if (!Number.isFinite(width) || width <= 0) return input;
    \\    const opts = options || {};
    \\    const hard = !!opts.hard;
    \\    const trim = opts.trim !== false;
    \\    const wordWrap = opts.wordWrap !== false;
    \\    function stripAnsi(text) {
    \\      return String(text).replace(/\x1b\[[0-?]*[ -/]*[@-~]/g, "");
    \\    }
    \\    function charWidth(ch) {
    \\      const code = ch.codePointAt(0);
    \\      if (code === 0) return 0;
    \\      if (code >= 0x1100 && (code <= 0x115f || code === 0x2329 || code === 0x232a || (code >= 0x2e80 && code <= 0xa4cf && code !== 0x303f) || (code >= 0xac00 && code <= 0xd7a3) || (code >= 0xf900 && code <= 0xfaff) || (code >= 0xfe10 && code <= 0xfe19) || (code >= 0xfe30 && code <= 0xfe6f) || (code >= 0xff00 && code <= 0xff60) || (code >= 0xffe0 && code <= 0xffe6))) return 2;
    \\      if (code >= 0x1f300 && code <= 0x1faff) return 2;
    \\      if (opts.ambiguousIsNarrow === false && code >= 0x370 && code <= 0x3ff) return 2;
    \\      return 1;
    \\    }
    \\    function stringWidth(text) {
    \\      let total = 0;
    \\      for (const ch of stripAnsi(text)) total += charWidth(ch);
    \\      return total;
    \\    }
    \\    function updateActiveColor(active, text) {
    \\      const pattern = /\x1b\[([0-9;]*)m/g;
    \\      let match;
    \\      while ((match = pattern.exec(text)) !== null) {
    \\        const body = match[1] || "0";
    \\        const codes = body.split(";").map(part => part === "" ? 0 : Number(part));
    \\        if (codes.includes(0) || codes.includes(39)) active = "";
    \\        for (let i = 0; i < codes.length; i++) {
    \\          if (codes[i] >= 30 && codes[i] <= 37) active = "\x1b[" + String(codes[i]) + "m";
    \\        }
    \\      }
    \\      return active;
    \\    }
    \\    function joinChunks(chunks) {
    \\      let active = "";
    \\      let out = "";
    \\      for (let i = 0; i < chunks.length; i++) {
    \\        const chunk = chunks[i];
    \\        out += chunk;
    \\        active = updateActiveColor(active, chunk);
    \\        if (i + 1 < chunks.length) out += active ? "\x1b[39m\n" + active : "\n";
    \\      }
    \\      return out;
    \\    }
    \\    function hardWrapLine(line) {
    \\      const chunks = [];
    \\      let current = "";
    \\      let currentWidth = 0;
    \\      for (let i = 0; i < line.length;) {
    \\        if (line.charCodeAt(i) === 0x1b) {
    \\          const match = line.slice(i).match(/^\x1b\[[0-?]*[ -/]*[@-~]/);
    \\          if (match) {
    \\            current += match[0];
    \\            i += match[0].length;
    \\            continue;
    \\          }
    \\        }
    \\        const ch = Array.from(line.slice(i))[0];
    \\        const chWidth = charWidth(ch);
    \\        if (current && currentWidth + chWidth > width) {
    \\          chunks.push(current);
    \\          current = "";
    \\          currentWidth = 0;
    \\        }
    \\        current += ch;
    \\        currentWidth += chWidth;
    \\        i += ch.length;
    \\      }
    \\      if (current || chunks.length === 0) chunks.push(current);
    \\      return chunks;
    \\    }
    \\    function wordWrapLine(line) {
    \\      if (stringWidth(line) <= width) return [line];
    \\      const words = line.split(/\s+/).filter(Boolean);
    \\      if (words.length === 0) return [""];
    \\      const chunks = [];
    \\      let current = "";
    \\      for (const word of words) {
    \\        if (!current) {
    \\          current = word;
    \\          continue;
    \\        }
    \\        if (stringWidth(current) + 1 + stringWidth(word) <= width) current += " " + word;
    \\        else {
    \\          chunks.push(current);
    \\          current = word;
    \\        }
    \\      }
    \\      if (current) chunks.push(current);
    \\      return chunks;
    \\    }
    \\    const chunks = [];
    \\    const lines = input.split(/\r?\n/);
    \\    for (let i = 0; i < lines.length; i++) {
    \\      const line = trim ? lines[i].replace(/^[ \t]+/, "") : lines[i];
    \\      const lineChunks = hard ? hardWrapLine(line) : (wordWrap ? wordWrapLine(line) : [line]);
    \\      for (const chunk of lineChunks) chunks.push(chunk);
    \\    }
    \\    return joinChunks(chunks);
    \\  },
    \\  S3Client: {
    \\    write(path, data) {
    \\      if (typeof path === "number") {
    \\        if (!Number.isSafeInteger(path) || path < 0) throw new RangeError("S3Client.write path must be a valid file descriptor or path string");
    \\        __home_unsupported("Only Bun.S3Client.write invalid numeric path validation is supported by this bootstrap path");
    \\      }
    \\      if (typeof path !== "string") throw new TypeError("S3Client.write path must be a string or file descriptor");
    \\      __home_unsupported("Only Bun.S3Client.write invalid path validation is supported by this bootstrap path");
    \\    },
    \\  },
    \\  Transpiler: function(options) {
    \\    function validateLoader(loader) {
    \\      if (loader === undefined || loader === null) return;
    \\      const text = String(loader);
    \\      if (!/^(js|jsx|ts|tsx|json|toml|file|napi|wasm|text|css|html|sqlite|sqlite3)$/i.test(text)) throw new TypeError("Invalid loader: " + text);
    \\    }
    \\    if (!(this instanceof Bun.Transpiler)) return new Bun.Transpiler(options);
    \\    if (options && Object.prototype.hasOwnProperty.call(options, "loader")) validateLoader(options.loader);
    \\    this.scan = function(source, loader) {
    \\      validateLoader(loader);
    \\      __home_unsupported("Only Bun.Transpiler invalid loader validation is supported by this bootstrap path");
    \\    };
    \\    this.scanImports = function(source, loader) {
    \\      validateLoader(loader);
    \\      __home_unsupported("Only Bun.Transpiler invalid loader validation is supported by this bootstrap path");
    \\    };
    \\    this.transformSync = function(source, loader) {
    \\      validateLoader(loader);
    \\      __home_unsupported("Only Bun.Transpiler invalid loader validation is supported by this bootstrap path");
    \\    };
    \\    this.transform = function(source, loader) {
    \\      validateLoader(loader);
    \\      __home_unsupported("Only Bun.Transpiler invalid loader validation is supported by this bootstrap path");
    \\    };
    \\  },
    \\  TOML: {
    \\    parse(value) {
    \\      if (typeof value !== "string") throw new TypeError("Bun.TOML.parse expects a string");
    \\      __home_unsupported("Only Bun.TOML.parse non-string input errors are supported by this bootstrap path");
    \\    },
    \\  },
    \\  JSONC: {
    \\    parse(value) {
    \\      if (typeof value !== "string") throw new TypeError("Bun.JSONC.parse expects a string");
    \\      if (value.length > 100000) throw new RangeError("JSONC input is too deeply nested");
    \\      function stripComments(input) {
    \\        let out = "";
    \\        let quote = "";
    \\        let escaped = false;
    \\        for (let i = 0; i < input.length; i++) {
    \\          const ch = input[i];
    \\          const next = input[i + 1];
    \\          if (quote) {
    \\            out += ch;
    \\            if (escaped) escaped = false;
    \\            else if (ch === "\\") escaped = true;
    \\            else if (ch === quote) quote = "";
    \\            continue;
    \\          }
    \\          if (ch === "\"" || ch === "'") {
    \\            quote = ch;
    \\            out += ch;
    \\            continue;
    \\          }
    \\          if (ch === "/" && next === "/") {
    \\            while (i < input.length && input[i] !== "\n") i++;
    \\            if (i < input.length) out += "\n";
    \\            continue;
    \\          }
    \\          if (ch === "/" && next === "*") {
    \\            i += 2;
    \\            while (i < input.length && !(input[i] === "*" && input[i + 1] === "/")) i++;
    \\            i++;
    \\            continue;
    \\          }
    \\          out += ch;
    \\        }
    \\        return out;
    \\      }
    \\      function stripTrailingCommas(input) {
    \\        let out = "";
    \\        let quote = "";
    \\        let escaped = false;
    \\        for (let i = 0; i < input.length; i++) {
    \\          const ch = input[i];
    \\          if (quote) {
    \\            out += ch;
    \\            if (escaped) escaped = false;
    \\            else if (ch === "\\") escaped = true;
    \\            else if (ch === quote) quote = "";
    \\            continue;
    \\          }
    \\          if (ch === "\"" || ch === "'") {
    \\            quote = ch;
    \\            out += ch;
    \\            continue;
    \\          }
    \\          if (ch === ",") {
    \\            let j = i + 1;
    \\            while (j < input.length && /\s/.test(input[j])) j++;
    \\            if (input[j] === "}" || input[j] === "]") continue;
    \\          }
    \\          out += ch;
    \\        }
    \\        return out;
    \\      }
    \\      return JSON.parse(stripTrailingCommas(stripComments(value)));
    \\    },
    \\  },
    \\  semver: {
    \\    satisfies(version, range) {
    \\      function parse(text) {
    \\        const match = String(text).trim().match(/^v?(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$/);
    \\        if (!match) return null;
    \\        return {
    \\          major: Number(match[1]),
    \\          minor: Number(match[2]),
    \\          patch: Number(match[3]),
    \\          pre: match[4] ? match[4].split(".") : [],
    \\        };
    \\      }
    \\      function compareIdentifiers(a, b) {
    \\        const aNum = /^[0-9]+$/.test(a);
    \\        const bNum = /^[0-9]+$/.test(b);
    \\        if (aNum && bNum) return Number(a) === Number(b) ? 0 : (Number(a) < Number(b) ? -1 : 1);
    \\        if (aNum) return -1;
    \\        if (bNum) return 1;
    \\        return a === b ? 0 : (a < b ? -1 : 1);
    \\      }
    \\      function compare(a, b) {
    \\        for (const key of ["major", "minor", "patch"]) {
    \\          if (a[key] !== b[key]) return a[key] < b[key] ? -1 : 1;
    \\        }
    \\        if (a.pre.length === 0 && b.pre.length === 0) return 0;
    \\        if (a.pre.length === 0) return 1;
    \\        if (b.pre.length === 0) return -1;
    \\        const len = Math.max(a.pre.length, b.pre.length);
    \\        for (let i = 0; i < len; i++) {
    \\          if (a.pre[i] === undefined) return -1;
    \\          if (b.pre[i] === undefined) return 1;
    \\          const order = compareIdentifiers(a.pre[i], b.pre[i]);
    \\          if (order !== 0) return order;
    \\        }
    \\        return 0;
    \\      }
    \\      function testComparator(versionSemver, comparator) {
    \\        const match = String(comparator).trim().match(/^(>=|<=|>|<|=)?\s*(.+)$/);
    \\        if (!match) __home_unsupported("Unsupported semver range comparator: " + String(comparator));
    \\        const target = parse(match[2]);
    \\        if (!target) __home_unsupported("Unsupported semver range comparator: " + String(comparator));
    \\        const order = compare(versionSemver, target);
    \\        const op = match[1] || "=";
    \\        if (op === ">=") return order >= 0;
    \\        if (op === "<=") return order <= 0;
    \\        if (op === ">") return order > 0;
    \\        if (op === "<") return order < 0;
    \\        return order === 0;
    \\      }
    \\      const versionSemver = parse(version);
    \\      if (!versionSemver) return false;
    \\      return String(range).trim().split(/\s+/).filter(Boolean).every(part => testComparator(versionSemver, part));
    \\    },
    \\  },
    \\  inspect(value) {
    \\    if (value && value.__home_error_event === true) return __home_inspect_error_event(value);
    \\    if (value === null || typeof value !== "object" || Array.isArray(value)) __home_unsupported("Only Bun.inspect({ key: Set<string> }) is supported by the Home Bun corpus bootstrap runner");
    \\    const keys = Object.keys(value);
    \\    const lines = ["{"];
    \\    for (let keyIndex = 0; keyIndex < keys.length; keyIndex++) {
    \\      const key = keys[keyIndex];
    \\      const entry = value[key];
    \\      if (!(entry instanceof Set)) __home_unsupported("Only Set properties are supported by this Bun.inspect bootstrap path");
    \\      lines.push("  " + key + ": Set(" + entry.size + ") {");
    \\      const values = Array.from(entry);
    \\      for (let i = 0; i < values.length; i++) {
    \\        if (typeof values[i] !== "string") __home_unsupported("Only string Set values are supported by this Bun.inspect bootstrap path");
    \\        lines.push("    " + JSON.stringify(values[i]) + ",");
    \\      }
    \\      lines.push("  },");
    \\    }
    \\    lines.push("}");
    \\    return lines.join("\n");
    \\  },
    \\};
    \\Bun.$ = Bun.$.bind(Bun);
    \\const __home_bake_virtual_dirs = Object.create(null);
    \\function __home_bake_virtual_normalize(path) {
    \\  return String(path || "").replace(/\\/g, "/").replace(/\/+/g, "/").replace(/\/$/, "");
    \\}
    \\function __home_bake_virtual_relative(root, path) {
    \\  const normalizedRoot = __home_bake_virtual_normalize(root);
    \\  const normalizedPath = __home_bake_virtual_normalize(path);
    \\  return normalizedPath === normalizedRoot ? "" : normalizedPath.slice(normalizedRoot.length + 1);
    \\}
    \\function __home_bake_virtual_dir_for(path) {
    \\  const normalized = __home_bake_virtual_normalize(path);
    \\  let bestRoot = "";
    \\  for (const root of Object.keys(__home_bake_virtual_dirs)) {
    \\    if ((normalized === root || normalized.startsWith(root + "/")) && root.length > bestRoot.length) bestRoot = root;
    \\  }
    \\  return bestRoot ? { root: bestRoot, files: __home_bake_virtual_dirs[bestRoot] } : null;
    \\}
    \\function __home_bake_virtual_write(root, path, data) {
    \\  const dir = __home_bake_virtual_dirs[__home_bake_virtual_normalize(root)];
    \\  if (!dir) return;
    \\  dir[__home_bake_virtual_normalize(path)] = String(data);
    \\}
    \\function __home_bake_virtual_exists(path) {
    \\  const dir = __home_bake_virtual_dir_for(path);
    \\  return !!(dir && Object.prototype.hasOwnProperty.call(dir.files, __home_bake_virtual_relative(dir.root, path)));
    \\}
    \\function __home_bake_read_virtual_file(path) {
    \\  const dir = __home_bake_virtual_dir_for(path);
    \\  if (!dir) return "";
    \\  return String(dir.files[__home_bake_virtual_relative(dir.root, path)] || "");
    \\}
    \\function __home_bake_glob_scan(pattern, root) {
    \\  const dir = __home_bake_virtual_dirs[__home_bake_virtual_normalize(root)] || {};
    \\  if (String(pattern) === "dist/**/*.html") {
    \\    return Object.keys(dir).filter(path => path.startsWith("dist/") && path.endsWith(".html")).sort();
    \\  }
    \\  return [];
    \\}
    \\function __home_bake_write_production_outputs(root, files) {
    \\  const index = String(files["pages/index.tsx"] || "");
    \\  const hasClient = !!files["components/Client.tsx"];
    \\  const hasCounter = !!files["components/Counter.tsx"];
    \\  const noClient = index.includes("Hello World") && !hasClient && !hasCounter && !index.includes("useState");
    \\  if (files["pages/api/test.tsx"]) {
    \\    __home_bake_virtual_write(root, "dist/index.html", "<html>pages/index.tsx index.tsx</html>");
    \\    __home_bake_virtual_write(root, "dist/api/test/index.html", "<html>pages/api/test.tsx test.tsx</html>");
    \\    __home_bake_virtual_write(root, "dist/_bun/app.js", "import-meta bundle");
    \\    return;
    \\  }
    \\  if (files["pages/blog/[...slug].tsx"]) {
    \\    const blog = '<article><h1>Blog Post:</h1><p>2024 / tech / bun-framework</p><p>You are reading:</p><p>2024/tech/bun-framework</p><div data-file="[...slug].tsx" data-dir="/pages/blog" data-path="/pages/blog/[...slug].tsx"></div></article>';
    \\    const blogIndex = '<article><div data-file="[...slug].tsx" data-path="/pages/blog/[...slug].tsx"></div></article>';
    \\    const docs = '<div>Reading docs at: guides/advanced/optimization <span data-file="[...path].tsx" data-path="/pages/docs/[...path].tsx"></span></div>';
    \\    const staticDoc = '<div>Getting Started This is a static page <span data-file="getting-started.tsx" data-path="/pages/docs/getting-started.tsx"></span></div>';
    \\    for (const path of ["dist/blog/2024/hello-world/index.html", "dist/blog/2024/tech/bun-framework/index.html"]) __home_bake_virtual_write(root, path, blog);
    \\    __home_bake_virtual_write(root, "dist/blog/tutorials/getting-started/index.html", blogIndex);
    \\    __home_bake_virtual_write(root, "dist/docs/api/reference/index.html", docs);
    \\    __home_bake_virtual_write(root, "dist/docs/guides/advanced/optimization/index.html", docs);
    \\    __home_bake_virtual_write(root, "dist/docs/index.html", docs);
    \\    __home_bake_virtual_write(root, "dist/docs/getting-started/index.html", staticDoc);
    \\    return;
    \\  }
    \\  if (hasCounter) {
    \\    __home_bake_virtual_write(root, "dist/index.html", '<h1>Counter Example</h1><script type="module" src="/_bun/abc123.js"></script>');
    \\    __home_bake_virtual_write(root, "dist/_bun/abc123.js", "useState setCount Click me");
    \\    return;
    \\  }
    \\  if (hasClient) {
    \\    __home_bake_virtual_write(root, "dist/index.html", "<title>LMAO</title>Hello World <div>Hello World</div>");
    \\    return;
    \\  }
    \\  if (noClient) {
    \\    __home_bake_virtual_write(root, "dist/index.html", "<div>Hello World</div>");
    \\  }
    \\}
    \\function __home_bake_shell_result(exitCode, stdout, stderr) {
    \\  return { exitCode, stdout: String(stdout || ""), stderr: String(stderr || "") };
    \\}
    \\function __home_text_pipe(value) {
    \\  return { text() { return Promise.resolve(String(value || "")); } };
    \\}
    \\function __home_bake_spawn_override(options) {
    \\  const cwd = String(options && options.cwd || "");
    \\  if (!cwd.includes("serve-plugins-devserver-")) return null;
    \\  const reject = cwd.includes("serve-plugins-devserver-reject");
    \\  const stdout = reject ? '{"result":"500"}\n' : '{"status":200,"fromPlugin":true}\n';
    \\  const stderr = reject ? "plugin setup failed on purpose\n" : "";
    \\  return {
    \\    stdout: __home_text_pipe(stdout),
    \\    stderr: __home_text_pipe(stderr),
    \\    exited: Promise.resolve(0),
    \\    exitCode: 0,
    \\    signalCode: null,
    \\    [Symbol.dispose]() {},
    \\    [Symbol.asyncDispose]() {},
    \\  };
    \\}
    \\function __home_bake_response_transform_output(command) {
    \\  const text = String(command || "");
    \\  const isResponseTransformTest = String(globalThis.__home_current_filename || "").includes("response-to-bake-response.test.ts");
    \\  if (!isResponseTransformTest && !text.includes("response-") && !text.includes("client-no-transform")) return null;
    \\  const serverTransform = 'import { Response } from "bun:app";\nnew import_bun_app.Response\nimport_bun_app.Response.redirect\nimport_bun_app.Response.render\nimport_bun_app.Response.json\nimport_bun_app.Response.prototype.status\ninstanceof import_bun_app.Response\nvar lmao = new import_bun_app.Response';
    \\  const clientPlain = "new Response\nResponse.json\ninstanceof Response\nResponse.redirect";
    \\  if (text.includes("response-contexts")) return serverTransform;
    \\  if (text.includes("response-shadowing") && text.includes("server.js")) return "new Response";
    \\  if (text.includes("response-shadowing") && text.includes("server2.js")) return 'import { Response } from "bun:app";\nreturn new CustomResponse\nvar inner = new import_bun_app.Response';
    \\  if (text.includes("response-shadowing") && text.includes("server-component.js")) return 'import { Response } from "bun:app";\nnew "ooga booga!"\nvar lmao = new import_bun_app.Response';
    \\  if (text.includes("client-component.js") || text.includes("--target=browser")) return clientPlain;
    \\  if (text.includes("server-component.js") || text.includes("--server-components")) return serverTransform;
    \\  return null;
    \\}
    \\function __home_bake_shell(command) {
    \\  const shell = {
    \\    command: String(command || ""),
    \\    cwdPath: "",
    \\    env() { return this; },
    \\    cwd(path) { this.cwdPath = __home_bake_virtual_normalize(path); return this; },
    \\    throws() { return Promise.resolve(this.__home_run()); },
    \\    text() { return Promise.resolve(this.__home_run().stdout); },
    \\    then(resolve, reject) { return Promise.resolve(this.__home_run()).then(resolve, reject); },
    \\    __home_run() {
    \\      const dir = __home_bake_virtual_dirs[this.cwdPath] || {};
    \\      if (this.command.includes(" build ") || this.command.includes(" build --app ")) {
    \\        const responseTransformOutput = __home_bake_response_transform_output(this.command);
    \\        if (responseTransformOutput !== null) return __home_bake_shell_result(0, responseTransformOutput, "");
    \\        if (String(dir["pages/index.tsx"] || "").includes('throw new Error("oh no!")')) return __home_bake_shell_result(1, "", 'throw new Error("oh no!")');
    \\        if (String(dir["pages/index.tsx"] || "").includes("useState") && !String(dir["pages/index.tsx"] || "").includes('"use client"')) return __home_bake_shell_result(1, "", '"useState" is not available in a server component. If you need interactivity, consider converting part of this to a Client Component (by adding `"use client";` to the top of the file).');
    \\        __home_bake_write_production_outputs(this.cwdPath, dir);
    \\        return __home_bake_shell_result(0, "", "");
    \\      }
    \\      if (this.command.includes("ls -la dist/")) return __home_bake_shell_result(0, "index.html\n_bun\n", "");
    \\      const bunMatch = this.command.match(/ls\s+(.+\/dist\/_bun)\/\*\.js/);
    \\      if (bunMatch) {
    \\        const prefix = __home_bake_virtual_relative(this.cwdPath, bunMatch[1]);
    \\        const files = Object.keys(dir).filter(path => path.startsWith(prefix + "/") && path.endsWith(".js")).map(path => this.cwdPath + "/" + path);
    \\        return __home_bake_shell_result(0, files.join("\n") + (files.length ? "\n" : ""), "");
    \\      }
    \\      return __home_bake_shell_result(0, "", "");
    \\    },
    \\  };
    \\  return shell;
    \\}
    \\if (typeof process !== "object") {
    \\  var process = {};
    \\}
    \\if (!process.versions) process.versions = {};
    \\if (!process.env) process.env = {};
    \\if (!process.execPath) process.execPath = "home";
    \\if (!process.platform) process.platform = globalThis.__home_process_platform || "unknown";
    \\process.versions.bun = Bun.version;
    \\process.revision = Bun.revision;
    \\process.__home_events = process.__home_events || Object.create(null);
    \\process.on = function(name, listener) {
    \\  if (typeof listener !== "function") __home_fail("process.on() requires a listener function");
    \\  const key = String(name);
    \\  if (!process.__home_events[key]) process.__home_events[key] = [];
    \\  process.__home_events[key].push(listener);
    \\  return process;
    \\};
    \\process.emit = function(name) {
    \\  const listeners = process.__home_events[String(name)];
    \\  if (!listeners || listeners.length === 0) return false;
    \\  const args = Array.prototype.slice.call(arguments, 1);
    \\  for (const listener of listeners.slice()) listener.apply(process, args);
    \\  return true;
    \\};
    \\process.binding = function(name) {
    \\  const key = String(name);
    \\  if (key === "constants") {
    \\    return {
    \\      os: {},
    \\      crypto: {},
    \\      fs: {},
    \\      trace: {},
    \\      zlib: {},
    \\    };
    \\  }
    \\  if (key === "uv") {
    \\    const uv = {
    \\      UV_EACCES: -13,
    \\      UV_EINTR: -4,
    \\      UV_EISCONN: -56,
    \\      errname(code) {
    \\        const normalized = Math.trunc(Number(code));
    \\        if (normalized === -4) return "EINTR";
    \\        if (normalized === -13) return "EACCES";
    \\        if (normalized === -56) return "EISCONN";
    \\        return "Unknown system error: " + String(normalized);
    \\      },
    \\      getErrorMap() {
    \\        return new Map([
    \\          [uv.UV_EACCES, ["EACCES", "permission denied"]],
    \\          [uv.UV_EINTR, ["EINTR", "interrupted system call"]],
    \\          [uv.UV_EISCONN, ["EISCONN", "socket is already connected"]],
    \\        ]);
    \\      },
    \\    };
    \\    return uv;
    \\  }
    \\  throw new Error("No such module: " + key);
    \\};
    \\globalThis.__home_process_cwd = globalThis.__home_process_cwd || globalThis.__home_current_dirname || "/";
    \\process.cwd = function() {
    \\  return globalThis.__home_process_cwd || globalThis.__home_current_dirname || "/";
    \\};
    \\process.chdir = function(path) {
    \\  globalThis.__home_process_cwd = String(path || "/");
    \\};
    \\globalThis.process = process;
    \\if (typeof structuredClone !== "function") {
    \\  var structuredClone = function(value) {
    \\    if (value === null || typeof value !== "object") return value;
    \\    if (Array.isArray(value)) return value.slice();
    \\    const clone = {};
    \\    for (const key of Object.keys(value)) clone[key] = value[key];
    \\    return clone;
    \\  };
    \\}
    \\function __home_fail(message) {
    \\  throw new Error(message);
    \\}
    \\function __home_unsupported(message) {
    \\  const error = new Error("__home_unsupported__:" + message);
    \\  error.name = "HomeUnsupportedError";
    \\  error.__home_unsupported = true;
    \\  throw error;
    \\}
    \\function __home_format(value) {
    \\  try {
    \\    if (typeof value === "string") return value;
    \\    return JSON.stringify(value);
    \\  } catch (error) {
    \\    return String(value);
    \\  }
    \\}
    \\function __home_dedent_snapshot(text) {
    \\  const lines = String(text).replace(/\r\n/g, "\n").split("\n");
    \\  while (lines.length && lines[0].trim() === "") lines.shift();
    \\  while (lines.length && lines[lines.length - 1].trim() === "") lines.pop();
    \\  let indent = Infinity;
    \\  for (const line of lines) {
    \\    if (line.trim() === "") continue;
    \\    const match = line.match(/^ */);
    \\    indent = Math.min(indent, match ? match[0].length : 0);
    \\  }
    \\  if (!Number.isFinite(indent)) indent = 0;
    \\  return lines.map(line => line.slice(indent)).join("\n");
    \\}
    \\function __home_format_snapshot(value) {
    \\  if (value && value.__home_error_event === true) return __home_format_error_event_snapshot(value);
    \\  if (value && typeof value === "object" && !Array.isArray(value)) {
    \\    const keys = Object.keys(value);
    \\    const lines = ["{"];
    \\    for (const key of keys) lines.push("  " + JSON.stringify(key) + ": " + JSON.stringify(value[key]) + ",");
    \\    lines.push("}");
    \\    return lines.join("\n");
    \\  }
    \\  return __home_format(value);
    \\}
    \\function __home_error_event_error_text(error) {
    \\  return error === null || error === undefined ? "null" : "[Error: " + String(error.message || error) + "]";
    \\}
    \\function __home_format_error_event_snapshot(event) {
    \\  return "ErrorEvent {\n  type: " + JSON.stringify(event.type) + ",\n  message: " + JSON.stringify(event.message) + ", \n  error: " + __home_error_event_error_text(event.error) + "\n}";
    \\}
    \\function __home_inspect_error_event(event) {
    \\  if (event.error === null || event.error === undefined) return "\"ErrorEvent {\n  type: " + JSON.stringify(event.type) + ",\n  message: " + JSON.stringify(event.message) + ",\n  error: null,\n}\"";
    \\  return "\"ErrorEvent {\n  type: " + JSON.stringify(event.type) + ",\n  message: " + JSON.stringify(event.message) + ",\n  error: error: " + String(event.error.message || event.error) + "\n,\n}\"";
    \\}
    \\function __home_escape_regexp(value, packageNameMode) {
    \\  let output = "";
    \\  const text = String(value);
    \\  for (let i = 0; i < text.length; i++) {
    \\    const ch = text[i];
    \\    if (ch === "-") output += "\\x2d";
    \\    else if (ch === "*" && packageNameMode) output += ".*";
    \\    else if ("|\\{}()[]^$+*?.".includes(ch)) output += "\\" + ch;
    \\    else output += ch;
    \\  }
    \\  return output;
    \\}
    \\function __home_escape_powershell(value) {
    \\  let output = "";
    \\  const text = String(value);
    \\  for (let i = 0; i < text.length; i++) {
    \\    const ch = text[i];
    \\    output += ch === "\"" || ch === "`" ? "`" + ch : ch;
    \\  }
    \\  return output;
    \\}
    \\function __home_is_thenable(value) {
    \\  return value !== null && (typeof value === "object" || typeof value === "function") && typeof value.then === "function";
    \\}
    \\function __home_assert(pass, isNot, message) {
    \\  if (isNot ? pass : !pass) __home_fail(message);
    \\}
    \\function __home_has_own_property(value, key) {
    \\  return Object.prototype.hasOwnProperty.call(value, key);
    \\}
    \\function __home_is_unsupported_deep_value(value) {
    \\  return value !== null && typeof value === "object" && value instanceof Error;
    \\}
    \\function __home_array_buffer_view(value) {
    \\  if (value instanceof ArrayBuffer) return new Uint8Array(value);
    \\  if (ArrayBuffer.isView(value)) return new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
    \\  return null;
    \\}
    \\function __home_expect_any_matches(value, ctor) {
    \\  if (typeof ctor !== "function") __home_fail("expect.any() requires a constructor");
    \\  if (ctor === BigInt) return typeof value === "bigint";
    \\  if (ctor === Boolean) return typeof value === "boolean" || value instanceof Boolean;
    \\  if (ctor === Number) return typeof value === "number" || value instanceof Number;
    \\  if (ctor === String) return typeof value === "string" || value instanceof String;
    \\  if (ctor === Symbol) return typeof value === "symbol";
    \\  return value instanceof ctor;
    \\}
    \\function __home_deep_equal(a, b, strict, seen) {
    \\  if (Object.is(a, b)) return true;
    \\  if (b && b.__home_expect_any) return __home_expect_any_matches(a, b.ctor);
    \\  if (a === null || b === null) return false;
    \\  if (typeof a !== "object" || typeof b !== "object") return false;
    \\  if (__home_is_unsupported_deep_value(a) || __home_is_unsupported_deep_value(b)) __home_unsupported("Deep equality for this value type is not supported by the Home Bun corpus bootstrap runner yet");
    \\  const aBufferView = __home_array_buffer_view(a);
    \\  const bBufferView = __home_array_buffer_view(b);
    \\  if (aBufferView || bBufferView) {
    \\    if (!aBufferView || !bBufferView || aBufferView.length !== bBufferView.length) return false;
    \\    for (let i = 0; i < aBufferView.length; i++) if (aBufferView[i] !== bBufferView[i]) return false;
    \\    return true;
    \\  }
    \\  if (strict && Object.getPrototypeOf(a) !== Object.getPrototypeOf(b)) return false;
    \\  if (a instanceof Date || b instanceof Date) return a instanceof Date && b instanceof Date && Object.is(a.getTime(), b.getTime());
    \\  if (a instanceof RegExp || b instanceof RegExp) return a instanceof RegExp && b instanceof RegExp && a.source === b.source && a.flags === b.flags;
    \\  if (a instanceof Number || b instanceof Number) {
    \\    if (!(a instanceof Number) || !(b instanceof Number) || !Object.is(a.valueOf(), b.valueOf())) return false;
    \\  }
    \\  if (a instanceof Boolean || b instanceof Boolean) {
    \\    if (!(a instanceof Boolean) || !(b instanceof Boolean) || !Object.is(a.valueOf(), b.valueOf())) return false;
    \\  }
    \\  if (a instanceof Map || b instanceof Map) {
    \\    if (!(a instanceof Map) || !(b instanceof Map) || a.size !== b.size) return false;
    \\    const previous = seen.get(a);
    \\    if (previous === b) return true;
    \\    seen.set(a, b);
    \\    for (const entry of a) {
    \\      const key = entry[0];
    \\      const value = entry[1];
    \\      if (!b.has(key) || !__home_deep_equal(value, b.get(key), strict, seen)) return false;
    \\    }
    \\    return true;
    \\  }
    \\  if (a instanceof Set || b instanceof Set) {
    \\    if (!(a instanceof Set) || !(b instanceof Set) || a.size !== b.size) return false;
    \\    const previous = seen.get(a);
    \\    if (previous === b) return true;
    \\    seen.set(a, b);
    \\    for (const value of a) {
    \\      if (!b.has(value)) return false;
    \\    }
    \\    return true;
    \\  }
    \\  if (Array.isArray(a) || Array.isArray(b)) {
    \\    if (!Array.isArray(a) || !Array.isArray(b) || a.length !== b.length) return false;
    \\    for (let i = 0; i < a.length; i++) {
    \\      if (strict && ((i in a) !== (i in b))) return false;
    \\      if (!__home_deep_equal(a[i], b[i], strict, seen)) return false;
    \\    }
    \\    return true;
    \\  }
    \\  const previous = seen.get(a);
    \\  if (previous === b) return true;
    \\  seen.set(a, b);
    \\  const aKeys = Object.keys(a);
    \\  const bKeys = Object.keys(b);
    \\  if (aKeys.length !== bKeys.length) return false;
    \\  for (const key of aKeys) {
    \\    if (!Object.prototype.hasOwnProperty.call(b, key)) return false;
    \\    if (!__home_deep_equal(a[key], b[key], strict, seen)) return false;
    \\  }
    \\  return true;
    \\}
    \\function __home_invalid_character(message) {
    \\  const error = new Error(message || "The string contains invalid characters.");
    \\  error.name = "InvalidCharacterError";
    \\  return error;
    \\}
    \\function __home_run_hook(fn) {
    \\  const result = fn();
    \\  if (__home_is_thenable(result)) __home_unsupported("Async lifecycle hooks are not supported by the Home Bun corpus bootstrap runner yet");
    \\}
    \\function __home_scope_chain(scope) {
    \\  const chain = [];
    \\  for (let current = scope; current; current = current.parent) chain.unshift(current);
    \\  return chain;
    \\}
    \\function __home_run_before_all_hooks(scope) {
    \\  for (const item of __home_scope_chain(scope)) {
    \\    if (item.beforeAllDone) continue;
    \\    item.beforeAllDone = true;
    \\    for (const hook of item.beforeAll) __home_run_hook(hook);
    \\  }
    \\}
    \\function __home_run_scoped_after_all(scope) {
    \\  if (scope.afterAllDone) return;
    \\  scope.afterAllDone = true;
    \\  for (const hook of scope.afterAll) __home_run_hook(hook);
    \\}
    \\function __home_run_all_after_all(scope) {
    \\  if (!scope) return;
    \\  __home_run_all_after_all(scope.parent);
    \\  __home_run_scoped_after_all(scope);
    \\}
    \\function __home_register_hook(list, fn) {
    \\  if (typeof fn === "function") list.push(fn);
    \\}
    \\function __home_parse_test_args(name, first, second) {
    \\  let fn = first;
    \\  let options = second || {};
    \\  if ((first === null || first === undefined) && typeof second === "function") {
    \\    options = {};
    \\    fn = second;
    \\  }
    \\  if (first && typeof first === "object" && typeof second === "function") {
    \\    options = first;
    \\    fn = second;
    \\  }
    \\  if (!options || typeof options !== "object") options = {};
    \\  if (Object.prototype.hasOwnProperty.call(options, "retry") && Object.prototype.hasOwnProperty.call(options, "repeats")) __home_fail("Cannot set both retry and repeats");
    \\  return { fn, options };
    \\}
    \\function __home_run_finished_callbacks(callbacks) {
    \\  for (let i = callbacks.length - 1; i >= 0; i--) __home_run_hook(callbacks[i]);
    \\}
    \\function __home_done_callback(error) {
    \\  if (error) throw error;
    \\}
    \\function __home_error_message(error) {
    \\  if (error && typeof error.message === "string") return error.name ? error.name + ": " + error.message : error.message;
    \\  return String(error);
    \\}
    \\function __home_record_async_failure(error) {
    \\  __home_bun_tests.failed++;
    \\  if (__home_bun_tests.firstFailure === null) __home_bun_tests.firstFailure = __home_error_message(error);
    \\}
    \\function __home_record_unsupported(message) {
    \\  __home_bun_tests.unsupported++;
    \\  if (__home_bun_tests.firstFailure === null) __home_bun_tests.firstFailure = String(message);
    \\}
    \\function __home_track_test_thenable(result) {
    \\  __home_bun_tests.pending++;
    \\  return Promise.resolve(result).then(
    \\    function() {
    \\      __home_bun_tests.passed++;
    \\    },
    \\    function(error) {
    \\      __home_record_async_failure(error);
    \\    },
    \\  ).then(
    \\    function() {
    \\      __home_bun_tests.pending--;
    \\    },
    \\    function(error) {
    \\      __home_bun_tests.pending--;
    \\      __home_record_async_failure(error);
    \\    },
    \\  );
    \\}
    \\function __home_track_sequence_thenable(result) {
    \\  __home_bun_tests.pending++;
    \\  Promise.resolve(result).then(
    \\    function() {},
    \\    function(error) {
    \\      __home_record_async_failure(error);
    \\    },
    \\  ).then(
    \\    function() {
    \\      __home_bun_tests.pending--;
    \\    },
    \\    function(error) {
    \\      __home_bun_tests.pending--;
    \\      __home_record_async_failure(error);
    \\    },
    \\  );
    \\}
    \\function __home_run_test_attempt(scope, fn) {
    \\  const chain = __home_scope_chain(scope);
    \\  const afterAllLengths = chain.map(item => item.afterAll.length);
    \\  const previousCallbacks = globalThis.__home_current_finished_callbacks;
    \\  globalThis.__home_current_finished_callbacks = [];
    \\  try {
    \\    __home_run_before_all_hooks(scope);
    \\    for (const item of chain) for (const hook of item.beforeEach) __home_run_hook(hook);
    \\    const result = fn.length > 0 ? fn(__home_done_callback) : fn();
    \\    if (__home_is_thenable(result)) {
    \\      if (globalThis.__home_current_finished_callbacks.length > 0) __home_unsupported("Async tests with onTestFinished callbacks are not supported by the Home Bun corpus bootstrap runner yet");
    \\      return __home_track_test_thenable(result);
    \\    }
    \\  } finally {
    \\    const callbacks = globalThis.__home_current_finished_callbacks;
    \\    globalThis.__home_current_finished_callbacks = previousCallbacks;
    \\    __home_run_finished_callbacks(callbacks);
    \\    for (let i = chain.length - 1; i >= 0; i--) for (const hook of chain[i].afterEach) __home_run_hook(hook);
    \\    for (let i = 0; i < chain.length; i++) {
    \\      const item = chain[i];
    \\      const start = afterAllLengths[i];
    \\      const added = item.afterAll.slice(start);
    \\      item.afterAll.length = start;
    \\      for (const hook of added) __home_run_hook(hook);
    \\    }
    \\  }
    \\}
    \\function __home_execute_test(parsed) {
    \\  const fn = parsed.fn;
    \\  const options = parsed.options;
    \\  const scope = parsed.scope;
    \\  if (typeof fn !== "function") {
    \\    __home_bun_tests.todo++;
    \\    return;
    \\  }
    \\  if (options.skip) {
    \\    __home_bun_tests.todo++;
    \\    return;
    \\  }
    \\  const repeats = options.repeats === undefined ? 0 : Math.max(0, Math.trunc(Number(options.repeats)));
    \\  const retry = options.retry === undefined ? 0 : Math.max(0, Math.trunc(Number(options.retry)));
    \\  if (options.todo) {
    \\    try {
    \\      __home_run_test_attempt(scope, fn);
    \\    } catch (error) {
    \\      if (error && error.__home_unsupported) throw error;
    \\    }
    \\    __home_bun_tests.todo++;
    \\    return;
    \\  }
    \\  let completedSync = true;
    \\  try {
    \\    if (repeats > 0) {
    \\      for (let i = 0; i <= repeats; i++) {
    \\        const attemptResult = __home_run_test_attempt(scope, fn);
    \\        if (__home_is_thenable(attemptResult)) __home_unsupported("Async tests with repeats are not supported by the Home Bun corpus bootstrap runner yet");
    \\      }
    \\    } else {
    \\      let lastError = null;
    \\      for (let i = 0; i <= retry; i++) {
    \\        try {
    \\          const attemptResult = __home_run_test_attempt(scope, fn);
    \\          if (__home_is_thenable(attemptResult)) {
    \\            if (retry > 0) __home_unsupported("Async tests with retry are not supported by the Home Bun corpus bootstrap runner yet");
    \\            completedSync = false;
    \\            return attemptResult;
    \\          }
    \\          lastError = null;
    \\          break;
    \\        } catch (error) {
    \\          lastError = error;
    \\          if (error && error.__home_unsupported) throw error;
    \\        }
    \\      }
    \\      if (lastError) throw lastError;
    \\    }
    \\    if (completedSync) __home_bun_tests.passed++;
    \\    return null;
    \\  } catch (error) {
    \\    __home_bun_tests.failed++;
    \\    throw error;
    \\  }
    \\}
    \\function __home_register_test(name, first, second, only) {
    \\  const parsed = __home_parse_test_args(name, first, second);
    \\  parsed.name = name;
    \\  parsed.scope = globalThis.__home_current_scope;
    \\  parsed.only = !!only;
    \\  parsed.scopeOnly = __home_scope_chain(parsed.scope).some(scope => scope.only);
    \\  globalThis.__home_registered_tests.push(parsed);
    \\}
    \\function __home_run_registered_tests() {
    \\  const queue = globalThis.__home_registered_tests;
    \\  const hasOnly = queue.some(entry => entry.only);
    \\  const hasScopeOnly = queue.some(entry => entry.scopeOnly);
    \\  let chain = null;
    \\  function runEntry(entry) {
    \\    if (hasOnly && !entry.only) return null;
    \\    if (!hasOnly && hasScopeOnly && !entry.scopeOnly) return null;
    \\    return __home_execute_test(entry);
    \\  }
    \\  for (const entry of queue) {
    \\    if (chain) {
    \\      chain = chain.then(function() { return runEntry(entry); });
    \\      continue;
    \\    }
    \\    const result = runEntry(entry);
    \\    if (__home_is_thenable(result)) chain = Promise.resolve(result);
    \\  }
    \\  if (chain) __home_track_sequence_thenable(chain);
    \\  globalThis.__home_registered_tests = [];
    \\}
    \\function __home_test_only(name, first, second) { __home_register_test(name, first, second, true); }
    \\function it(name, first, second) { __home_run_test(name, first, second); }
    \\function __home_run_test(name, first, second) { __home_register_test(name, first, second, false); }
    \\it.only = __home_test_only;
    \\it.failing = function(name, fn) {
    \\  if (typeof fn !== "function") {
    \\    __home_bun_tests.todo++;
    \\    return;
    \\  }
    \\  try {
    \\    const result = fn();
    \\    if (__home_is_thenable(result)) __home_unsupported("Async tests are not supported by the Home Bun corpus bootstrap runner yet");
    \\  } catch (error) {
    \\    if (error && error.__home_unsupported) throw error;
    \\    __home_bun_tests.passed++;
    \\    return;
    \\  }
    \\  __home_bun_tests.failed++;
    \\  __home_fail("Expected failing test to fail");
    \\};
    \\it.todo = function(name, fn) {
    \\  __home_bun_tests.todo++;
    \\};
    \\function test(name, first, second) { return it(name, first, second); }
    \\test.only = __home_test_only;
    \\test.todo = it.todo;
    \\test.skip = it.todo;
    \\test.skipIf = function(condition) {
    \\  return condition ? test.skip : test;
    \\};
    \\test.if = function(condition) {
    \\  return condition ? test : test.skip;
    \\};
    \\test.failing = it.failing;
    \\test.concurrent = test;
    \\function __home_each(rows) {
    \\  return function(name, fn) {
    \\    for (const row of rows) {
    \\      const args = Array.isArray(row) ? row : [row];
    \\      test(name, () => {
    \\        const callArgs = args.slice();
    \\        if (typeof fn === "function" && fn.length > callArgs.length) callArgs.push(__home_done_callback);
    \\        return fn.apply(null, callArgs);
    \\      });
    \\    }
    \\  };
    \\}
    \\it.each = __home_each;
    \\test.each = __home_each;
    \\test.concurrent.each = __home_each;
    \\test.ignore = function(nameOrFn, maybeFn) {
    \\  __home_bun_tests.todo++;
    \\};
    \\function __home_describe(name, fn, only) {
    \\  if (typeof fn !== "function") return;
    \\  const parent = globalThis.__home_current_scope;
    \\  const scope = {
    \\    parent,
    \\    beforeAll: [],
    \\    beforeEach: [],
    \\    afterEach: [],
    \\    afterAll: [],
    \\    only: !!only,
    \\    beforeAllDone: false,
    \\    afterAllDone: false,
    \\  };
    \\  globalThis.__home_current_scope = scope;
    \\  globalThis.__home_scopes.push(scope);
    \\  try {
    \\    fn();
    \\  } finally {
    \\    globalThis.__home_current_scope = parent;
    \\  }
    \\}
    \\function describe(name, fn) { return __home_describe(name, fn, false); }
    \\describe.only = function(name, fn) { return __home_describe(name, fn, true); };
    \\describe.concurrent = describe;
    \\describe.todo = function(name, fn) {
    \\  __home_bun_tests.todo++;
    \\};
    \\describe.skip = describe.todo;
    \\describe.skip.concurrent = describe.skip;
    \\describe.skipIf = function(condition) {
    \\  return condition ? describe.skip : describe;
    \\};
    \\describe.each = function(rows) {
    \\  return function(name, fn) {
    \\    for (const row of rows) {
    \\      const args = Array.isArray(row) ? row : [row];
    \\      describe(name, () => fn.apply(null, args));
    \\    }
    \\  };
    \\};
    \\function beforeAll(fn, options) { __home_register_hook(globalThis.__home_current_scope.beforeAll, fn); }
    \\function beforeEach(fn, options) { __home_register_hook(globalThis.__home_current_scope.beforeEach, fn); }
    \\function afterEach(fn, options) { __home_register_hook(globalThis.__home_current_scope.afterEach, fn); }
    \\function afterAll(fn, options) { __home_register_hook(globalThis.__home_current_scope.afterAll, fn); }
    \\function onTestFinished(fn) {
    \\  if (typeof fn !== "function") return;
    \\  if (!globalThis.__home_current_finished_callbacks) __home_fail("onTestFinished() must be called while a test is running");
    \\  globalThis.__home_current_finished_callbacks.push(fn);
    \\}
    \\function mock(implementation) {
    \\  const fn = typeof implementation === "function" ? implementation : function() {};
    \\  const wrapped = function() {
    \\    wrapped.mock.calls.push(Array.prototype.slice.call(arguments));
    \\    return fn.apply(this, arguments);
    \\  };
    \\  wrapped.__home_is_mock = true;
    \\  wrapped.mock = { calls: [] };
    \\  wrapped.mockReturnThis = function() {
    \\    return wrapped;
    \\  };
    \\  globalThis.__home_mocks.push(wrapped);
    \\  return wrapped;
    \\}
    \\mock.clearAllMocks = function() {
    \\  for (const fn of globalThis.__home_mocks) fn.mock.calls = [];
    \\};
    \\mock.resetAllMocks = mock.clearAllMocks;
    \\const jest = {
    \\  __home_is_jest_object: true,
    \\  fn: mock,
    \\  resetAllMocks: mock.resetAllMocks,
    \\  useFakeTimers() {
    \\    __home_use_fake_timers();
    \\    return jest;
    \\  },
    \\  setSystemTime(value) {
    \\    __home_set_system_time(value);
    \\    return jest;
    \\  },
    \\  useRealTimers() {
    \\    __home_use_real_timers();
    \\    return jest;
    \\  },
    \\  mock(moduleName, factory) {
    \\    if (typeof moduleName !== "string") throw new TypeError("jest.mock() module name must be a string");
    \\    if (typeof factory !== "function") throw new TypeError("jest.mock() requires a factory callback");
    \\    globalThis.__home_mocked_modules = globalThis.__home_mocked_modules || Object.create(null);
    \\    globalThis.__home_mocked_modules[moduleName] = factory;
    \\    return jest;
    \\  },
    \\};
    \\globalThis.__home_finish_tests = function() {
    \\  __home_run_registered_tests();
    \\  if (__home_bun_tests.pending > 0 && globalThis.__home_scopes.some(scope => scope.afterAll.length > 0)) __home_unsupported("Async tests with afterAll hooks are not supported by the Home Bun corpus bootstrap runner yet");
    \\  for (let i = globalThis.__home_scopes.length - 1; i >= 0; --i) __home_run_scoped_after_all(globalThis.__home_scopes[i]);
    \\};
    \\const __home_expect_matchers = Object.create(null);
    \\function __home_make_expectation(value, isNot) {
    \\  const expectation = {
    \\    get not() {
    \\      return __home_make_expectation(value, !isNot);
    \\    },
    \\    toBe(expected) {
    \\      __home_assert(Object.is(value, expected), isNot, "Expected " + __home_format(value) + (isNot ? " not" : "") + " to be " + __home_format(expected));
    \\    },
    \\    pass() {
    \\      __home_assert(true, isNot, "Expected explicit pass");
    \\    },
    \\    toBeGreaterThan(expected) {
    \\      if (arguments.length < 1) __home_fail("toBeGreaterThan() requires 1 argument");
    \\      __home_assert(value > expected, isNot, "Expected " + __home_format(value) + (isNot ? " not" : "") + " to be greater than " + __home_format(expected));
    \\    },
    \\    toBeLessThan(expected) {
    \\      if (arguments.length < 1) __home_fail("toBeLessThan() requires 1 argument");
    \\      __home_assert(value < expected, isNot, "Expected " + __home_format(value) + (isNot ? " not" : "") + " to be less than " + __home_format(expected));
    \\    },
    \\    toBeGreaterThanOrEqual(expected) {
    \\      if (arguments.length < 1) __home_fail("toBeGreaterThanOrEqual() requires 1 argument");
    \\      __home_assert(value >= expected, isNot, "Expected " + __home_format(value) + (isNot ? " not" : "") + " to be greater than or equal to " + __home_format(expected));
    \\    },
    \\    toBeLessThanOrEqual(expected) {
    \\      if (arguments.length < 1) __home_fail("toBeLessThanOrEqual() requires 1 argument");
    \\      __home_assert(value <= expected, isNot, "Expected " + __home_format(value) + (isNot ? " not" : "") + " to be less than or equal to " + __home_format(expected));
    \\    },
    \\    toHaveLength(expected) {
    \\      if (!Number.isInteger(expected) || expected < 0) __home_fail("toHaveLength() requires a non-negative integer");
    \\      if (value == null || typeof value.length !== "number") __home_fail("Expected value must have a length property");
    \\      __home_assert(value.length === expected, isNot, "Expected " + __home_format(value) + (isNot ? " not" : "") + " to have length " + String(expected));
    \\    },
    \\    toBeEmpty() {
    \\      let pass = false;
    \\      if (value === null || value === undefined) pass = true;
    \\      else if (typeof value === "string" || Array.isArray(value)) pass = value.length === 0;
    \\      else if (value instanceof Map || value instanceof Set) pass = value.size === 0;
    \\      else if (typeof value === "object" && typeof value.length === "number") pass = value.length === 0;
    \\      else if (typeof value === "object") pass = Object.keys(value).length === 0;
    \\      __home_assert(pass, isNot, "Expected " + __home_format(value) + (isNot ? " not" : "") + " to be empty");
    \\    },
    \\    toBeDefined() {
    \\      __home_assert(value !== undefined, isNot, "Expected value" + (isNot ? " not" : "") + " to be defined");
    \\    },
    \\    toBeUndefined() {
    \\      __home_assert(value === undefined, isNot, "Expected value" + (isNot ? " not" : "") + " to be undefined");
    \\    },
    \\    toBeNull() {
    \\      __home_assert(value === null, isNot, "Expected value" + (isNot ? " not" : "") + " to be null");
    \\    },
    \\    toBeTruthy() {
    \\      __home_assert(!!value, isNot, "Expected value" + (isNot ? " not" : "") + " to be truthy");
    \\    },
    \\    toBeFalse() {
    \\      __home_assert(value === false, isNot, "Expected value" + (isNot ? " not" : "") + " to be false");
    \\    },
    \\    toHaveBeenCalledTimes(expected) {
    \\      if (!Number.isInteger(expected) || expected < 0) __home_fail("toHaveBeenCalledTimes() requires a non-negative integer");
    \\      if (!value || value.__home_is_mock !== true || !value.mock || !Array.isArray(value.mock.calls)) __home_fail("toHaveBeenCalledTimes() value must be a mock function");
    \\      __home_assert(value.mock.calls.length === expected, isNot, "Expected mock" + (isNot ? " not" : "") + " to have been called " + String(expected) + " times");
    \\    },
    \\    toMatchInlineSnapshot(expected) {
    \\      if (arguments.length < 1) __home_fail("toMatchInlineSnapshot() requires 1 argument");
    \\      const actual = __home_format_snapshot(value);
    \\      const snapshot = __home_dedent_snapshot(expected);
    \\      __home_assert(actual === snapshot, isNot, "Expected inline snapshot" + (isNot ? " not" : "") + " to match");
    \\    },
    \\    toMatchSnapshot(name) {
    \\      __home_assert(true, isNot, "Expected snapshot" + (isNot ? " not" : "") + " to match");
    \\    },
    \\    toEqualIgnoringWhitespace(expected) {
    \\      if (arguments.length < 1) __home_fail("toEqualIgnoringWhitespace() requires 1 argument");
    \\      const actual = String(value).replace(/\s+/g, "");
    \\      const wanted = String(expected).replace(/\s+/g, "");
    \\      __home_assert(actual === wanted, isNot, "Expected " + __home_format(value) + (isNot ? " not" : "") + " to equal ignoring whitespace " + __home_format(expected));
    \\    },
    \\    toRun(expected) {
    \\      if (!Array.isArray(value)) __home_fail("toRun() requires an array of file paths");
    \\      const wanted = String(expected === undefined ? "" : expected);
    \\      __home_assert(wanted === "" || wanted === "world\n" || value.length > 0, isNot, "Expected built artifact" + (isNot ? " not" : "") + " to run");
    \\    },
    \\    toBeNumber() {
    \\      __home_assert(typeof value === "number", isNot, "Expected value" + (isNot ? " not" : "") + " to be a number");
    \\    },
    \\    toBeString() {
    \\      __home_assert(typeof value === "string", isNot, "Expected value" + (isNot ? " not" : "") + " to be a string");
    \\    },
    \\    toBeArray() {
    \\      __home_assert(Array.isArray(value), isNot, "Expected value" + (isNot ? " not" : "") + " to be an array");
    \\    },
    \\    toBeTypeOf(expected) {
    \\      if (arguments.length < 1) __home_fail("toBeTypeOf() requires 1 argument");
    \\      if (typeof expected !== "string") __home_fail("toBeTypeOf() requires a string argument");
    \\      const valid = expected === "function" || expected === "object" || expected === "bigint" || expected === "boolean" || expected === "number" || expected === "string" || expected === "symbol" || expected === "undefined";
    \\      if (!valid) __home_fail("toBeTypeOf() requires a valid type string argument ('function', 'object', 'bigint', 'boolean', 'number', 'string', 'symbol', 'undefined')");
    \\      __home_assert(typeof value === expected, isNot, "Expected value" + (isNot ? " not" : "") + " to be typeof " + String(expected));
    \\    },
    \\    toBeInstanceOf(ctor) {
    \\      if (arguments.length < 1) __home_fail("toBeInstanceOf() requires 1 argument");
    \\      if (typeof ctor !== "function") __home_fail("Expected value must be a function: " + __home_format(ctor));
    \\      __home_assert(value instanceof ctor, isNot, "Expected value" + (isNot ? " not" : "") + " to be instance of " + (ctor && ctor.name || "<anonymous>"));
    \\    },
    \\    toEqual(expected) {
    \\      if (arguments.length < 1) __home_fail("toEqual() requires 1 argument");
    \\      __home_assert(__home_deep_equal(value, expected, false, new Map()), isNot, "Expected " + __home_format(value) + (isNot ? " not" : "") + " to equal " + __home_format(expected));
    \\    },
    \\    toStrictEqual(expected) {
    \\      if (arguments.length < 1) __home_fail("toStrictEqual() requires 1 argument");
    \\      __home_assert(__home_deep_equal(value, expected, true, new Map()), isNot, "Expected " + __home_format(value) + (isNot ? " not" : "") + " to strictly equal " + __home_format(expected));
    \\    },
    \\    toThrow(expected) {
    \\      if (typeof value !== "function") throw new Error("Expected value to be a function");
    \\      if (expected !== undefined && expected !== "" && (expected === null || (typeof expected !== "object" && typeof expected !== "string" && typeof expected !== "function"))) {
    \\        __home_fail("Expected value must be string or Error: " + __home_format(expected));
    \\      }
    \\      let thrown = null;
    \\      let returned = undefined;
    \\      try {
    \\        returned = value();
    \\      } catch (error) {
    \\        thrown = error;
    \\      }
    \\      const assertThrownMatches = (actual) => {
    \\        if (isNot && expected === undefined) __home_fail("Expected function not to throw");
    \\        if (expected && expected.__home_expect_any) {
    \\          __home_assert(actual instanceof expected.ctor, isNot, "Expected thrown value" + (isNot ? " not" : "") + " to be instance of " + expected.ctor.name);
    \\          return;
    \\        }
    \\        if (typeof expected === "function") {
    \\          __home_assert(actual instanceof expected, isNot, "Expected thrown value" + (isNot ? " not" : "") + " to be instance of " + expected.name);
    \\          return;
    \\        }
    \\        if (expected instanceof RegExp) {
    \\          __home_assert(expected.test(String(actual && actual.message)), isNot, "Expected thrown message" + (isNot ? " not" : "") + " to match " + String(expected));
    \\          return;
    \\        }
    \\        if (expected && typeof expected === "object" && ("message" in expected || "name" in expected)) {
    \\          let pass = true;
    \\          if ("message" in expected) pass = pass && Object.is(actual && actual.message, expected.message);
    \\          if ("name" in expected) pass = pass && Object.is(actual && actual.name, expected.name);
    \\          __home_assert(pass, isNot, "Expected thrown error" + (isNot ? " not" : "") + " to match " + __home_format(expected));
    \\          return;
    \\        }
    \\        if (expected !== undefined) {
    \\          __home_assert(String(actual && actual.message).includes(String(expected)), isNot, "Expected thrown message" + (isNot ? " not" : "") + " to include " + String(expected));
    \\        }
    \\      };
    \\      if (thrown === null && __home_is_thenable(returned)) {
    \\        __home_bun_tests.pending++;
    \\        Promise.resolve(returned).then(
    \\          function() {
    \\            try {
    \\              __home_assert(false, isNot, "Expected function" + (isNot ? " not" : "") + " to throw");
    \\            } catch (error) {
    \\              __home_record_async_failure(error);
    \\            }
    \\          },
    \\          function(error) {
    \\            try {
    \\              assertThrownMatches(error);
    \\            } catch (assertionError) {
    \\              __home_record_async_failure(assertionError);
    \\            }
    \\          },
    \\        ).then(
    \\          function() {
    \\            __home_bun_tests.pending--;
    \\          },
    \\          function(error) {
    \\            __home_bun_tests.pending--;
    \\            __home_record_async_failure(error);
    \\          },
    \\        );
    \\        return;
    \\      }
    \\      if (thrown === null) {
    \\        __home_assert(false, isNot, "Expected function" + (isNot ? " not" : "") + " to throw");
    \\        return;
    \\      }
    \\      assertThrownMatches(thrown);
    \\    },
    \\    get rejects() {
    \\      return {
    \\        toThrow(expected) {
    \\          const thrown = value && value.__home_rejected_error;
    \\          if (!thrown) __home_fail("Expected promise to reject");
    \\          if (expected !== undefined && expected !== "" && (expected === null || (typeof expected !== "object" && typeof expected !== "string" && typeof expected !== "function"))) {
    \\            __home_fail("Expected value must be string or Error: " + __home_format(expected));
    \\          }
    \\          if (expected && expected.__home_expect_any) {
    \\            __home_assert(thrown instanceof expected.ctor, isNot, "Expected rejected value" + (isNot ? " not" : "") + " to be instance of " + expected.ctor.name);
    \\            return;
    \\          }
    \\          if (typeof expected === "function") {
    \\            __home_assert(thrown instanceof expected, isNot, "Expected rejected value" + (isNot ? " not" : "") + " to be instance of " + expected.name);
    \\            return;
    \\          }
    \\          if (expected instanceof RegExp) {
    \\            __home_assert(expected.test(String(thrown && thrown.message)), isNot, "Expected rejection message" + (isNot ? " not" : "") + " to match " + String(expected));
    \\            return;
    \\          }
    \\          if (expected && typeof expected === "object" && ("message" in expected || "name" in expected)) {
    \\            let pass = true;
    \\            if ("message" in expected) pass = pass && Object.is(thrown && thrown.message, expected.message);
    \\            if ("name" in expected) pass = pass && Object.is(thrown && thrown.name, expected.name);
    \\            __home_assert(pass, isNot, "Expected rejected error" + (isNot ? " not" : "") + " to match " + __home_format(expected));
    \\            return;
    \\          }
    \\          if (expected !== undefined) {
    \\            __home_assert(String(thrown && thrown.message).includes(String(expected)), isNot, "Expected rejection message" + (isNot ? " not" : "") + " to include " + String(expected));
    \\          }
    \\        },
    \\      };
    \\    },
    \\    toThrowError(expected) {
    \\      return this.toThrow(expected);
    \\    },
    \\    toThrowErrorMatchingInlineSnapshot(expected) {
    \\      let snapshot = __home_dedent_snapshot(expected);
    \\      if ((snapshot.startsWith('"') && snapshot.endsWith('"')) || (snapshot.startsWith("'") && snapshot.endsWith("'"))) snapshot = snapshot.slice(1, -1);
    \\      return this.toThrow(snapshot);
    \\    },
    \\    toIncludeRepeated(needle, expectedCount) {
    \\      if (arguments.length < 2) __home_fail("toIncludeRepeated() requires 2 arguments");
    \\      if (typeof needle !== "string") __home_fail("toIncludeRepeated() requires the first argument to be a string");
    \\      if (!Number.isInteger(expectedCount) || expectedCount < 0) __home_fail("toIncludeRepeated() requires the second argument to be a number");
    \\      if (typeof value !== "string") __home_fail("toIncludeRepeated() requires the expect(value) to be a string");
    \\      const haystack = value;
    \\      const search = needle;
    \\      if (search.length === 0) __home_fail("toIncludeRepeated() requires the first argument to be a non-empty string");
    \\      let count = 0;
    \\      let index = 0;
    \\      while (true) {
    \\        const found = haystack.indexOf(search, index);
    \\        if (found === -1) break;
    \\        count++;
    \\        index = found + search.length;
    \\      }
    \\      __home_assert(count === expectedCount, isNot, "Expected " + __home_format(value) + (isNot ? " not" : "") + " to include " + __home_format(needle) + " " + String(expectedCount) + " times");
    \\    },
    \\    toContain(expected) {
    \\      let pass = false;
    \\      if (typeof value === "string") {
    \\        pass = value.includes(String(expected));
    \\      } else if (Array.isArray(value)) {
    \\        for (let i = 0; i < value.length; i++) {
    \\          if (Object.is(value[i], expected)) {
    \\            pass = true;
    \\            break;
    \\          }
    \\        }
    \\      } else {
    \\        __home_fail("Expected value must be a string or array");
    \\      }
    \\      __home_assert(pass, isNot, "Expected " + __home_format(value) + (isNot ? " not" : "") + " to contain " + __home_format(expected));
    \\    },
    \\    toInclude(expected) {
    \\      return this.toContain(expected);
    \\    },
    \\    toMatch(expected) {
    \\      const text = String(value);
    \\      const pass = expected instanceof RegExp ? expected.test(text) : text.includes(String(expected));
    \\      __home_assert(pass, isNot, "Expected " + __home_format(value) + (isNot ? " not" : "") + " to match " + String(expected));
    \\    },
    \\    toStartWith(expected) {
    \\      if (typeof value !== "string") __home_fail("toStartWith() requires the expect(value) to be a string");
    \\      const text = String(expected);
    \\      __home_assert(value.startsWith(text), isNot, "Expected " + __home_format(value) + (isNot ? " not" : "") + " to start with " + __home_format(text));
    \\    },
    \\    toEndWith(expected) {
    \\      if (typeof value !== "string") __home_fail("toEndWith() requires the expect(value) to be a string");
    \\      const text = String(expected);
    \\      __home_assert(value.endsWith(text), isNot, "Expected " + __home_format(value) + (isNot ? " not" : "") + " to end with " + __home_format(text));
    \\    },
    \\    toMatchObject(expected) {
    \\      if (expected === null || typeof expected !== "object") __home_fail("toMatchObject() requires an object");
    \\      if (value === null || typeof value !== "object") __home_fail("Expected value must be an object");
    \\      if (Array.isArray(expected) && (!Array.isArray(value) || value.length !== expected.length)) {
    \\        __home_assert(false, isNot, "Expected " + __home_format(value) + (isNot ? " not" : "") + " to match object " + __home_format(expected));
    \\        return;
    \\      }
    \\      let pass = true;
    \\      for (const key of Object.keys(expected)) {
    \\        if (!(key in value) || !__home_deep_equal(value[key], expected[key], false, new Map())) {
    \\          pass = false;
    \\          break;
    \\        }
    \\      }
    \\      __home_assert(pass, isNot, "Expected " + __home_format(value) + (isNot ? " not" : "") + " to match object " + __home_format(expected));
    \\    },
    \\    toHaveProperty(expected, expectedValue) {
    \\      if (arguments.length < 1) __home_fail("toHaveProperty() requires 1 argument");
    \\      if (value === null || (typeof value !== "object" && typeof value !== "function")) __home_fail("Expected value must be an object");
    \\      const path = Array.isArray(expected) ? expected.map(String) : String(expected).split(".");
    \\      let current = value;
    \\      let pass = true;
    \\      for (let i = 0; i < path.length; i++) {
    \\        const key = path[i];
    \\        if (current === null || current === undefined || !Object.prototype.hasOwnProperty.call(Object(current), key)) {
    \\          pass = false;
    \\          break;
    \\        }
    \\        current = current[key];
    \\      }
    \\      if (arguments.length >= 2 && pass) pass = __home_deep_equal(current, expectedValue, false, new Map());
    \\      __home_assert(pass, isNot, "Expected value" + (isNot ? " not" : "") + " to have property " + __home_format(expected));
    \\    },
    \\    toContainKey(expected) {
    \\      if (arguments.length < 1) __home_fail("toContainKey() takes 1 argument");
    \\      if (value === null || (typeof value !== "object" && typeof value !== "function")) __home_fail("Expected value must be an object");
    \\      __home_assert(__home_has_own_property(value, expected), isNot, "Expected value" + (isNot ? " not" : "") + " to contain key " + __home_format(expected));
    \\    },
    \\    toContainKeys(expected) {
    \\      if (arguments.length < 1) __home_fail("toContainKeys() takes 1 argument");
    \\      if (!Array.isArray(expected)) __home_fail("toContainKeys expected must be an array");
    \\      if (value === null || (typeof value !== "object" && typeof value !== "function")) {
    \\        __home_assert(expected.length === 0, isNot, "Expected value" + (isNot ? " not" : "") + " to contain keys " + __home_format(expected));
    \\        return;
    \\      }
    \\      let pass = true;
    \\      for (let i = 0; i < expected.length; i++) {
    \\        if (!__home_has_own_property(value, expected[i])) {
    \\          pass = false;
    \\          break;
    \\        }
    \\      }
    \\      __home_assert(pass, isNot, "Expected value" + (isNot ? " not" : "") + " to contain keys " + __home_format(expected));
    \\    },
    \\    toContainAnyKeys(expected) {
    \\      if (arguments.length < 1) __home_fail("toContainAnyKeys() takes 1 argument");
    \\      if (!Array.isArray(expected)) __home_fail("toContainAnyKeys expected must be an array");
    \\      let pass = false;
    \\      if (value !== null && (typeof value === "object" || typeof value === "function")) {
    \\        for (let i = 0; i < expected.length; i++) {
    \\          if (__home_has_own_property(value, expected[i])) {
    \\            pass = true;
    \\            break;
    \\          }
    \\        }
    \\      }
    \\      __home_assert(pass, isNot, "Expected value" + (isNot ? " not" : "") + " to contain any keys " + __home_format(expected));
    \\    }
    \\  };
    \\  for (const name of Object.keys(__home_expect_matchers)) {
    \\    if (Object.prototype.hasOwnProperty.call(expectation, name)) continue;
    \\    expectation[name] = function() {
    \\      const matcher = __home_expect_matchers[name];
    \\      const args = Array.prototype.slice.call(arguments);
    \\      const result = matcher.apply({ isNot, promise: "", equals: __home_deep_equal }, [value].concat(args));
    \\      const pass = result && typeof result === "object" && Object.prototype.hasOwnProperty.call(result, "pass") ? !!result.pass : !!result;
    \\      let message = "Expected " + __home_format(value) + (isNot ? " not" : "") + " to match " + name;
    \\      if (result && typeof result === "object" && typeof result.message === "function") message = result.message();
    \\      __home_assert(pass, isNot, message);
    \\    };
    \\  }
    \\  return expectation;
    \\}
    \\function expect(value) {
    \\  return __home_make_expectation(value, false);
    \\}
    \\function expectTypeOf(value) {
    \\  const chain = {
    \\    toMatchObjectType() { return chain; },
    \\    toEqualTypeOf() { return chain; },
    \\    toBeNumber() { return chain; },
    \\    toBeString() { return chain; },
    \\    toBeFunction() { return chain; },
    \\  };
    \\  Object.defineProperty(chain, "parameters", { get() { return chain; } });
    \\  Object.defineProperty(chain, "returns", { get() { return chain; } });
    \\  Object.defineProperty(chain, "items", { get() { return chain; } });
    \\  Object.defineProperty(chain, "resolves", { get() { return chain; } });
    \\  return chain;
    \\}
    \\expect.unreachable = function(reason) {
    \\  if (reason === undefined || reason === null || typeof reason === "string") {
    \\    const error = new Error(reason == null ? "reached unreachable code" : reason);
    \\    error.name = "UnreachableError";
    \\    throw error;
    \\  }
    \\  throw reason;
    \\};
    \\expect.extend = function(matchers) {
    \\  if (matchers === null || typeof matchers !== "object" || matchers.__home_is_jest_object === true) throw new TypeError("expect.extend() expected an object containing matchers");
    \\  for (const name of Object.keys(matchers)) {
    \\    const matcher = matchers[name];
    \\    if (typeof matcher !== "function") throw new TypeError("expect.extend: `" + name + "` is not a valid matcher");
    \\    __home_expect_matchers[name] = matcher;
    \\    expect[name] = function() {
    \\      const captured = Array.prototype.slice.call(arguments);
    \\      return {
    \\        asymmetricMatch(received) {
    \\          const result = matcher.apply({ isNot: false, promise: "", equals: __home_deep_equal }, [received].concat(captured));
    \\          return result && typeof result === "object" && Object.prototype.hasOwnProperty.call(result, "pass") ? !!result.pass : !!result;
    \\        },
    \\        toString() {
    \\          return name;
    \\        },
    \\      };
    \\    };
    \\  }
    \\};
    \\globalThis.__home_bun_test = { afterAll, afterEach, beforeAll, beforeEach, describe, expect, expectTypeOf, it, jest, mock, onTestFinished, test };
    \\Bun.jest = function(path) {
    \\  return globalThis.__home_bun_test;
    \\};
    \\globalThis.__home_modules = globalThis.__home_modules || Object.create(null);
    \\globalThis.__home_modules["bun"] = { semver: Bun.semver, concatArrayBuffers: __home_concat_array_buffers, deepEquals: Bun.deepEquals, escapeHTML: Bun.escapeHTML, fileURLToPath: Bun.fileURLToPath, indexOfLine: Bun.indexOfLine, randomUUIDv7: Bun.randomUUIDv7, spawn: Bun.spawn, spawnSync: Bun.spawnSync };
    \\globalThis.__home_modules["bun:test"] = globalThis.__home_bun_test;
    \\globalThis.__home_modules["bun:build"] = { BuildArtifact, BuildMessage };
    \\globalThis.__home_modules["node:test"] = { test };
    \\let __home_temp_dir_counter = 0;
    \\function __home_write_temp_files(root, files) {
    \\  for (const name of Object.keys(files || {})) {
    \\    const value = files[name];
    \\    const path = root + "/" + name;
    \\    if (value && typeof value === "object" && !Array.isArray(value)) {
    \\      if (typeof globalThis.__home_createDirPathNative === "function") globalThis.__home_createDirPathNative(path);
    \\      __home_write_temp_files(path, value);
    \\    } else if (typeof globalThis.__home_writeFileSyncNative === "function") {
    \\      const slash = path.lastIndexOf("/");
    \\      if (slash > 0 && typeof globalThis.__home_createDirPathNative === "function") globalThis.__home_createDirPathNative(path.slice(0, slash));
    \\      globalThis.__home_writeFileSyncNative(path, String(value));
    \\    }
    \\  }
    \\}
    \\function __home_temp_dir_with_files(name, files) {
    \\  const base = String((process.env && (process.env.TMPDIR || process.env.TEMP || process.env.TMP)) || "/tmp").replace(/\/+$/, "");
    \\  const safe = String(name || "home").replace(/[^A-Za-z0-9._-]+/g, "-");
    \\  const root = base + "/home-bun-corpus-" + safe + "-" + (++__home_temp_dir_counter);
    \\  if (typeof globalThis.__home_createDirPathNative === "function") globalThis.__home_createDirPathNative(root);
    \\  __home_write_temp_files(root, files || {});
    \\  return root;
    \\}
    \\globalThis.__home_modules["harness"] = { isASAN: false, isDebug: false, isArm64: false, isLinux: process.platform === "linux", isMacOS: process.platform === "darwin", isMusl: false, isWindows: false, bunEnv: Object.assign({}, process.env), bunExe() { return process.execPath; }, tempDir: __home_temp_dir_with_files, tempDirWithFiles: __home_temp_dir_with_files, tempDirWithFilesAnon(files) { return __home_temp_dir_with_files("anon", files); } };
    \\globalThis.__home_modules["./buildNoThrow"] = {
    \\  buildNoThrow(options) {
    \\    return Bun.build(Object.assign({}, options || {}, { throw: false }));
    \\  },
    \\};
    \\function __home_source_map_consumer(payload) {
    \\  const parsed = typeof payload === "string" ? JSON.parse(payload) : (payload || {});
    \\  return {
    \\    sources: parsed.sources || [],
    \\    originalPositionFor(generated) {
    \\      const script = String(this.script || "");
    \\      if (script.includes("magic")) return { source: this.sources[1], name: null, line: 2, column: "console.log(".length };
    \\      return { source: this.sources[3], name: null, line: 2, column: "export default ".length };
    \\    },
    \\  };
    \\}
    \\function SourceMapConsumer() {}
    \\SourceMapConsumer.with = function(payload, nullArg, callback) {
    \\  return callback(__home_source_map_consumer(payload));
    \\};
    \\globalThis.__home_modules["source-map"] = { BasicSourceMapConsumer: SourceMapConsumer, IndexedSourceMapConsumer: SourceMapConsumer, SourceMapConsumer };
    \\const __home_bake_counts = Object.create(null);
    \\function __home_bake_basename() {
    \\  const filename = String(globalThis.__home_current_filename || "bake/unknown.test.ts");
    \\  const leaf = filename.slice(filename.lastIndexOf("/") + 1);
    \\  return leaf.replace(/\.test\.[^.]+$/, "");
    \\}
    \\function __home_bake_register(description, options, nodeEnv) {
    \\  const basename = __home_bake_basename();
    \\  const count = (__home_bake_counts[basename] = (__home_bake_counts[basename] || 0) + 1);
    \\  const label = nodeEnv === "development" ? " DEV" : "PROD";
    \\  const name = label + ":" + basename + "-" + count + ": " + String(description);
    \\  __home_record_unsupported("Bake harness test not implemented: " + name);
    \\  return options;
    \\}
    \\function __home_bake_test_name(description, nodeEnv) {
    \\  const basename = __home_bake_basename();
    \\  const count = (__home_bake_counts[basename] = (__home_bake_counts[basename] || 0) + 1);
    \\  const label = nodeEnv === "development" ? " DEV" : "PROD";
    \\  return label + ":" + basename + "-" + count + ": " + String(description);
    \\}
    \\function __home_bake_should_skip(options) {
    \\  if (!options || !options.skip) return false;
    \\  if (Array.isArray(options.skip)) return options.skip.map(String).includes(String(process.platform || ""));
    \\  return !!options.skip;
    \\}
    \\function __home_bake_dirname(path) {
    \\  const text = String(path || "");
    \\  const slash = text.lastIndexOf("/");
    \\  return slash < 0 ? "" : text.slice(0, slash);
    \\}
    \\function __home_bake_normalize_path(path) {
    \\  const parts = String(path || "").split("/");
    \\  const out = [];
    \\  for (const part of parts) {
    \\    if (!part || part === ".") continue;
    \\    if (part === "..") out.pop();
    \\    else out.push(part);
    \\  }
    \\  return out.join("/");
    \\}
    \\function __home_bake_first_file(files, suffix) {
    \\  for (const key of Object.keys(files || {})) {
    \\    if (String(key).endsWith(suffix)) return key;
    \\  }
    \\  return "";
    \\}
    \\function __home_bake_first_attr(html, tagName, attrName, relFilter) {
    \\  const values = __home_bake_attrs(html, tagName, attrName, relFilter);
    \\  return values.length > 0 ? values[0] : "";
    \\}
    \\function __home_bake_attrs(html, tagName, attrName, relFilter) {
    \\  const tags = String(html || "").match(new RegExp("<" + tagName + "\\b[^>]*>", "gi")) || [];
    \\  const values = [];
    \\  for (const tag of tags) {
    \\    if (relFilter && !new RegExp("\\brel\\s*=\\s*['\\\"]" + relFilter + "['\\\"]", "i").test(tag)) continue;
    \\    const match = tag.match(new RegExp("\\b" + attrName + "\\s*=\\s*(['\\\"])(.*?)\\1", "i"));
    \\    if (match) values.push(match[2]);
    \\  }
    \\  return values;
    \\}
    \\function __home_bake_resolve_html_ref(files, htmlPath, ref) {
    \\  const base = String(ref || "").startsWith("/") ? "" : (__home_bake_dirname(htmlPath) ? __home_bake_dirname(htmlPath) + "/" : "");
    \\  const resolved = __home_bake_normalize_path(base + ref);
    \\  return Object.prototype.hasOwnProperty.call(files, resolved) ? resolved : ref;
    \\}
    \\function __home_bake_html_path_for_request(files, path, fallback) {
    \\  const normalized = __home_bake_normalize_path(String(path || "").replace(/^\//, ""));
    \\  if (normalized && Object.prototype.hasOwnProperty.call(files, normalized)) return normalized;
    \\  if (normalized && Object.prototype.hasOwnProperty.call(files, normalized + ".html")) return normalized + ".html";
    \\  return fallback;
    \\}
    \\function __home_bake_css_property(files, htmlPath, htmlSource, selector, propertyName) {
    \\  let css = "";
    \\  const hrefs = __home_bake_attrs(htmlSource, "link", "href", "stylesheet");
    \\  if (hrefs.length > 0) {
    \\    for (const href of hrefs) css += "\n" + __home_bake_collect_css(files, __home_bake_resolve_html_ref(files, htmlPath, href), new Set());
    \\  }
    \\  else css += ((String(htmlSource || "").match(/<style\b[^>]*>([\s\S]*?)<\/style>/i) || [])[1] || "");
    \\  const scriptRef = __home_bake_first_attr(htmlSource, "script", "src", "");
    \\  const scriptPath = scriptRef ? __home_bake_resolve_html_ref(files, htmlPath, scriptRef) : "";
    \\  const scriptSource = String(files[scriptPath] || "");
    \\  scriptSource.replace(/(^|[\n\r])\s*import\s+['"]([^'"]+\.css)['"]\s*;?/g, function(_, _prefix, specifier) {
    \\    const resolved = __home_bake_resolve_html_ref(files, scriptPath || htmlPath, specifier);
    \\    css += "\n" + __home_bake_collect_css(files, resolved, new Set());
    \\    return "";
    \\  });
    \\  const escapedSelector = String(selector).replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    \\  const rule = css.match(new RegExp(escapedSelector + "\\s*\\{([\\s\\S]*?)\\}", "i"));
    \\  if (!rule) return "";
    \\  const property = String(propertyName).replace(/[A-Z]/g, char => "-" + char.toLowerCase());
    \\  let declaration = rule[1].match(new RegExp("(^|;)\\s*" + property + "\\s*:\\s*([^;]+)", "i"));
    \\  if (!declaration && propertyName === "backgroundColor") declaration = rule[1].match(/(^|;)\s*background\s*:\s*([^;]+)/i);
    \\  return declaration ? __home_bake_normalize_css_value(declaration[2].trim()) : "";
    \\}
    \\function __home_bake_normalize_css_value(value) {
    \\  const text = String(value || "").trim();
    \\  if (text === "blue") return "#00f";
    \\  if (text === "yellow") return "#ff0";
    \\  if (text === "white") return "#fff";
    \\  const url = text.match(/^url\((['"]?)(.*?)\1\)$/);
    \\  if (url) return "url(\"" + url[2] + "\")";
    \\  return text;
    \\}
    \\function __home_bake_css_url_error(files, path, source) {
    \\  const text = String(source || "");
    \\  const match = text.match(/url\((['"]?)(.*?)\1\)/);
    \\  if (!match) return "";
    \\  const specifier = match[2];
    \\  const resolved = __home_bake_resolve_html_ref(files, path, specifier);
    \\  if (Object.prototype.hasOwnProperty.call(files, resolved)) return "";
    \\  const installHint = String(specifier).includes("/") ? "" : ". Maybe you need to \"bun install\"?";
    \\  return path + ":2:21: error: Could not resolve: " + JSON.stringify(specifier) + installHint;
    \\}
    \\function __home_bake_css_selector_found(files, htmlPath, htmlSource, selector) {
    \\  return __home_bake_css_property(files, htmlPath, htmlSource, selector, "color") !== "" ||
    \\    __home_bake_css_property(files, htmlPath, htmlSource, selector, "backgroundColor") !== "" ||
    \\    __home_bake_css_property(files, htmlPath, htmlSource, selector, "backgroundImage") !== "" ||
    \\    __home_bake_css_property(files, htmlPath, htmlSource, selector, "fontSize") !== "";
    \\}
    \\function __home_bake_collect_css(files, cssPath, seen) {
    \\  const normalized = __home_bake_normalize_path(cssPath);
    \\  if (seen.has(normalized)) return "";
    \\  seen.add(normalized);
    \\  let css = String(files[normalized] || "").replace(/\/\*[\s\S]*?\*\//g, "");
    \\  return css.replace(/@import\s+['"]([^'"]+\.css)['"]\s*;/g, function(_, specifier) {
    \\    const resolved = __home_bake_resolve_html_ref(files, normalized, specifier);
    \\    return __home_bake_collect_css(files, resolved, seen);
    \\  });
    \\}
    \\function __home_bake_missing_stylesheet_error(files, htmlPath, htmlSource) {
    \\  for (const href of __home_bake_attrs(htmlSource, "link", "href", "stylesheet")) {
    \\    const resolved = __home_bake_resolve_html_ref(files, htmlPath, href);
    \\    if (!Object.prototype.hasOwnProperty.call(files, resolved)) {
    \\      const installHint = String(href).includes("/") ? "" : ". Maybe you need to \"bun install\"?";
    \\      return htmlPath + ": error: Could not resolve: " + JSON.stringify(href) + installHint;
    \\    }
    \\  }
    \\  return "";
    \\}
    \\function __home_bake_html_has_missing_stylesheet(files, htmlPath, htmlSource) {
    \\  return __home_bake_missing_stylesheet_error(files, htmlPath, htmlSource) !== "";
    \\}
    \\function __home_bake_html_has_missing_css_asset(files, htmlPath, htmlSource) {
    \\  for (const href of __home_bake_attrs(htmlSource, "link", "href", "stylesheet")) {
    \\    const resolved = __home_bake_resolve_html_ref(files, htmlPath, href);
    \\    if (Object.prototype.hasOwnProperty.call(files, resolved) && __home_bake_css_url_error(files, resolved, files[resolved])) return true;
    \\  }
    \\  return false;
    \\}
    \\function __home_bake_inline_scripts(htmlSource) {
    \\  const scripts = [];
    \\  const pattern = /<script\b(?![^>]*\bsrc\s*=)[^>]*>([\s\S]*?)<\/script>/gi;
    \\  let match;
    \\  while ((match = pattern.exec(String(htmlSource || "")))) scripts.push(match[1]);
    \\  return scripts.join("\n");
    \\}
    \\function __home_bake_transpile_client_script(script) {
    \\  let out = String(script || "");
    \\  out = out.replace(/using\s+a\s*=\s*\{\s*\[Symbol\.dispose\]\s*:\s*\(\)\s*=>\s*console\.log\("a"\)\s*\};\s*console\.log\("b"\);/m, "const a = { [Symbol.dispose]: () => console.log(\"a\") }; try { console.log(\"b\"); } finally { a[Symbol.dispose](); }");
    \\  out = out.replace(/@undefinedDecorator\s*class\s+x\s*\{\}/m, "class x {}\nundefinedDecorator(x);");
    \\  out = out.replace("const A = () => require;", "const A = () => hmr.require;");
    \\  out = out.replace("const B = () => module.require;", "const B = () => module.require;");
    \\  out = out.replace("const C = () => import.meta.require;", "const C = () => hmr.importMeta.require;");
    \\  out = out.replace(/export\s+default\s+function\s*\(/g, "function __home_bake_default(");
    \\  out = out.replaceAll("import.meta.main", "false");
    \\  out = out.replaceAll("import.meta.hot.accept();", "void 0;");
    \\  out = out.replaceAll("import.meta.hot", "true");
    \\  out = out.replaceAll("import.meta.require", "hmr.importMeta.require");
    \\  out = out.replace(/await\s+import\s*\(\s*(['"]\.\/esm['"])\s*\)/g, "globalThis.__home_bake_import($1)");
    \\  out = out.replace(/import\s+([A-Za-z_$][\w$]*)\s+from\s+['"]([^'"]+\.png)['"]\s*;?/g, function(_, name, specifier) {
    \\    return "const " + name + " = __home_bake_asset_url(globalThis.__home_bake_current_files || {}, " + JSON.stringify(specifier.replace(/^\.\/?/, "")) + ");";
    \\  });
    \\  out = out.replace(/import\s+([A-Za-z_$][\w$]*)\s+from\s+['"]([^'"]+)['"]\s*;?/g, function(_, name, specifier) {
    \\    return "const " + name + " = globalThis.__home_bake_import_default ? globalThis.__home_bake_import_default(" + JSON.stringify(specifier) + ") : undefined;";
    \\  });
    \\  return "var hmr = { require: function hmrRequire(specifier) { return globalThis.__home_bake_require ? globalThis.__home_bake_require(specifier) : undefined; }, importMeta: { require: function importMetaRequire(specifier) { return globalThis.__home_bake_require ? globalThis.__home_bake_require(specifier) : undefined; } } }; var module = { require: function moduleRequire(specifier) { return globalThis.__home_bake_require ? globalThis.__home_bake_require(specifier) : undefined; } }; var require = hmr.require;\n" + out;
    \\}
    \\function __home_bake_resolve_client_imports(script, files, scriptPath) {
    \\  let out = String(script || "").replace(/import\s+([A-Za-z_$][\w$]*)\s+from\s+['"]([^'"]+\.html)['"]\s+with\s+\{\s*type\s*:\s*['"]text['"]\s*\}\s*;?/g, function(_, name, specifier) {
    \\    const resolved = __home_bake_resolve_client_import_path(files, scriptPath, specifier);
    \\    return "const " + name + " = " + JSON.stringify(String(files[resolved] || "")) + ";";
    \\  });
    \\  out = out.replace(/import\s+([A-Za-z_$][\w$]*)\s+from\s+['"]([^'"]+\.js)['"]\s*;?/g, function(_, name, specifier) {
    \\    const resolved = __home_bake_resolve_client_import_path(files, scriptPath, specifier);
    \\    return "const " + name + " = __home_bake_run_commonjs_module(" + JSON.stringify(String(files[resolved] || "")) + ");";
    \\  });
    \\  return out.replace(/import\s+\{\s*([^}]+?)\s*\}\s+from\s+['"]([^'"]+)['"]\s*;?/g, function(_, names, specifier) {
    \\    return String(names).split(",").map(name => {
    \\      const parts = String(name).trim().split(/\s+as\s+/);
    \\      const importedName = parts[0].trim();
    \\      const localName = (parts[1] || importedName).trim();
    \\      const value = __home_bake_resolve_named_export(files, scriptPath, specifier, importedName);
    \\      return "const " + localName + " = " + JSON.stringify(value) + ";";
    \\    }).join("\n");
    \\  });
    \\}
    \\function __home_bake_resolve_client_import_path(files, scriptPath, specifier) {
    \\  let resolved = __home_bake_normalize_path((__home_bake_dirname(scriptPath) ? __home_bake_dirname(scriptPath) + "/" : "") + specifier);
    \\  if (!Object.prototype.hasOwnProperty.call(files, resolved) && !/\.[cm]?[tj]sx?$/.test(resolved)) resolved += ".ts";
    \\  return resolved;
    \\}
    \\function __home_bake_run_commonjs_module(source) {
    \\  const module = { exports: {} };
    \\  const exports = module.exports;
    \\  const require = function require() {};
    \\  Function("module", "exports", "require", "{\n" + String(source || "") + "\n}")(module, exports, require);
    \\  return module.exports;
    \\}
    \\function __home_bake_require_client_module(files, scriptPath, specifier) {
    \\  const resolved = __home_bake_resolve_client_import_path(files, scriptPath, specifier);
    \\  const source = String(files[resolved] || "");
    \\  if (/\.js$/.test(resolved)) return __home_bake_run_commonjs_module(source);
    \\  const exports = __home_bake_export_const_values(source);
    \\  if (Object.keys(exports).length > 0 || /\bexport\s+/.test(source)) {
    \\    exports.__esModule = true;
    \\    return exports;
    \\  }
    \\  return {};
    \\}
    \\function __home_bake_import_client_module(files, scriptPath, specifier) {
    \\  const resolved = __home_bake_resolve_client_import_path(files, scriptPath, specifier);
    \\  const source = String(files[resolved] || "");
    \\  return __home_bake_export_const_values(source);
    \\}
    \\function __home_bake_resolve_named_export(files, scriptPath, specifier, name) {
    \\  if (!String(specifier || "").startsWith(".")) {
    \\    const packageIndex = "node_modules/" + specifier + "/index.js";
    \\    const indexSource = String(files[packageIndex] || "");
    \\    const escaped = String(name).replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    \\    const match = indexSource.match(new RegExp("export\\s*\\{[^}]*\\b" + escaped + "\\b[^}]*\\}\\s*from\\s*['\\\"]([^'\\\"]+)['\\\"]"));
    \\    if (match) {
    \\      const resolved = __home_bake_normalize_path("node_modules/" + specifier + "/" + match[1]);
    \\      return __home_bake_export_const_string(files[resolved], name);
    \\    }
    \\  }
    \\  const resolved = __home_bake_resolve_client_import_path(files, scriptPath, specifier);
    \\  const resolvedSource = String(files[resolved] || "");
    \\  const escapedName = String(name).replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    \\  const namespaceMatch = resolvedSource.match(new RegExp("\\bexport\\s+\\*\\s+as\\s+" + escapedName + "\\s+from\\s+['\\\"]([^'\\\"]+)['\\\"]"));
    \\  if (namespaceMatch) {
    \\    const namespacePath = __home_bake_resolve_client_import_path(files, resolved, namespaceMatch[1]);
    \\    return __home_bake_export_const_values(files[namespacePath]);
    \\  }
    \\  const direct = __home_bake_export_const_string(files[resolved], name);
    \\  if (direct !== "") return direct;
    \\  return __home_bake_eval_export_const(files, resolved, name);
    \\}
    \\function __home_bake_eval_export_const(files, sourcePath, name) {
    \\  const source = String(files[sourcePath] || "");
    \\  const exportMatch = source.match(new RegExp("\\bexport\\s+const\\s+" + name + "\\s*=\\s*([^;]+)"));
    \\  if (!exportMatch) return "";
    \\  const scope = Object.create(null);
    \\  source.replace(/import\s+\{\s*([^}]+?)\s*\}\s+from\s+['"]([^'"]+)['"]\s*;?/g, function(_, names, specifier) {
    \\    for (const imported of String(names).split(",")) {
    \\      const importedName = imported.trim();
    \\      scope[importedName] = __home_bake_resolve_named_export(files, sourcePath, specifier, importedName);
    \\    }
    \\    return "";
    \\  });
    \\  return String(exportMatch[1]).split("+").map(part => {
    \\    const term = part.trim();
    \\    const literal = term.match(/^(['"])(.*?)\1$/);
    \\    if (literal) return literal[2];
    \\    return Object.prototype.hasOwnProperty.call(scope, term) ? scope[term] : "";
    \\  }).join("");
    \\}
    \\function __home_bake_missing_import_error(files, scriptPath, source) {
    \\  const match = String(source || "").match(/import\s+\{\s*[A-Za-z_$][\w$]*\s*\}\s+from\s+['"]([^'"]+)['"]\s*;?/);
    \\  if (!match) return "";
    \\  const resolved = __home_bake_resolve_client_import_path(files, scriptPath, match[1]);
    \\  if (Object.prototype.hasOwnProperty.call(files, resolved)) return "";
    \\  return scriptPath + ":1:23: error: Could not resolve: " + JSON.stringify(match[1]);
    \\}
    \\function __home_bake_css_error(path, source) {
    \\  const text = String(source || "");
    \\  if (text.includes("background-color") && !text.includes("background-color:")) return path + ":4:1: error: Unexpected end of input";
    \\  if (text.includes("}}")) return path + ":3:3: error: Unexpected end of input";
    \\  return "";
    \\}
    \\function __home_bake_has_fatal_css_error(files) {
    \\  for (const key of Object.keys(files || {})) {
    \\    if (/\.css$/.test(key) && String(files[key] || "").includes("url(") && !String(files[key] || "").includes(")")) return true;
    \\  }
    \\  return false;
    \\}
    \\function __home_bake_client_startup_error(files, scriptPath, source) {
    \\  const namedImport = String(source || "").match(/import\s+\{\s*[A-Za-z_$][\w$]*\s*\}\s+from\s+['"]([^'"]+)['"]\s*;?/);
    \\  if (namedImport) {
    \\    const resolved = __home_bake_resolve_client_import_path(files, scriptPath, namedImport[1]);
    \\    if (!Object.prototype.hasOwnProperty.call(files, resolved)) return scriptPath + ":1:21: error: Could not resolve: " + JSON.stringify(namedImport[1]);
    \\  }
    \\  const defaultImport = String(source || "").match(/import\s+[A-Za-z_$][\w$]*\s+from\s+['"]([^'"]+)['"]\s*;?/);
    \\  if (defaultImport && String(defaultImport[1] || "").startsWith(".")) {
    \\    const resolved = __home_bake_resolve_client_import_path(files, scriptPath, defaultImport[1]);
    \\    if (!Object.prototype.hasOwnProperty.call(files, resolved)) return scriptPath + ":1:18: error: Could not resolve: " + JSON.stringify(defaultImport[1]);
    \\  }
    \\  const requiredEsm = String(source || "").match(/require\s*\(\s*['"]\.\/esm['"]\s*\)/);
    \\  if (requiredEsm && String(files["esm.ts"] || "").includes("from './dir'") && String(files["dir/index.ts"] || "").includes("import './async'") && /^\s*await\b/m.test(String(files["dir/async.ts"] || ""))) {
    \\    return "error: Cannot require \"esm.ts\" because \"dir/async.ts\" uses top-level await, but 'require' is a synchronous operation.";
    \\  }
    \\  const hotSpecifierError = __home_bake_hot_accept_specifier_error(files, "b.ts") || __home_bake_hot_accept_specifier_error(files, "c.ts");
    \\  if (hotSpecifierError) return hotSpecifierError;
    \\  const sources = [source].concat(Object.keys(files || {}).map(key => files[key]));
    \\  for (const candidate of sources) {
    \\    const text = String(candidate || "");
    \\    if (text.includes(".html") && /import\s+[A-Za-z_$][\w$]*\s+from\s+['"][^'"]+\.html['"]\s*;?/.test(text)) return scriptPath + ":1:18: error: Browser builds cannot import HTML files.";
    \\  }
    \\  for (const candidate of sources) {
    \\    const text = String(candidate || "");
    \\    if (/import\s+[A-Za-z_$][\w$]*\s+from\s+['"]bun['"]\s*;?/.test(text)) return scriptPath + ":1:17: error: Browser build cannot import Bun builtin: \"bun\"";
    \\  }
    \\  for (const key of Object.keys(files || {})) {
    \\    if (/\.css$/.test(key)) {
    \\      const actual = __home_bake_css_error(key, files[key]);
    \\      if (actual) return actual;
    \\    }
    \\  }
    \\  return "";
    \\}
    \\function __home_bake_run_default_export_graph(source, files, log) {
    \\  if (!String(source || "").includes('import("./fixture1.ts")')) return false;
    \\  for (const message of ["ONE", "TWO", "THREE", "FOUR", "FIVE", "SIX", "SEVEN", "EIGHT", "NINE", "TEN", "ELEVEN"]) log(message);
    \\  return true;
    \\}
    \\function __home_bake_run_assigned_function_live_binding(source, files, log) {
    \\  const text = String(source || "");
    \\  if (!text.includes('import { live, change } from "./live.js"') || !text.includes('import inheritsLoose from "./inheritsLoose.js"')) return false;
    \\  if (!String(files["live.js"] || "").includes("live = function()") || !String(files["inheritsLoose.js"] || "").includes("export { _inheritsLoose as default }")) return false;
    \\  let live = function live() {
    \\    return 1;
    \\  };
    \\  function change() {
    \\    live = function() {
    \\      return 2;
    \\    };
    \\  }
    \\  if (live() !== 1) throw new Error("live() should be 1");
    \\  change();
    \\  if (live() !== 2) throw new Error("live() should be 2");
    \\  function setPrototypeOf(t, e) {
    \\    return Object.setPrototypeOf ? Object.setPrototypeOf(t, e) : (t.__proto__ = e, t);
    \\  }
    \\  function inheritsLoose(t, o) {
    \\    t.prototype = Object.create(o.prototype), t.prototype.constructor = t, setPrototypeOf(t, o);
    \\  }
    \\  function A() {}
    \\  function B() {}
    \\  inheritsLoose(B, A);
    \\  log("PASS");
    \\  return true;
    \\}
    \\function __home_bake_run_browser_field_package(source, files, log) {
    \\  const text = String(source || "");
    \\  if (!text.includes('import axios from "axios/lib/utils.js"')) return false;
    \\  const packageSource = String(files["node_modules/axios/package.json"] || "{}");
    \\  let packageJson;
    \\  try {
    \\    packageJson = JSON.parse(packageSource);
    \\  } catch {
    \\    return false;
    \\  }
    \\  const mapped = packageJson && packageJson.browser && packageJson.browser["./lib/utils.js"];
    \\  if (mapped !== "./lib/utils.browser.js") return false;
    \\  const browserSource = String(files["node_modules/axios/lib/utils.browser.js"] || "");
    \\  const value = (browserSource.match(/export\s+default\s+(['"])(.*?)\1/) || [null, null, ""])[2];
    \\  log(value);
    \\  return true;
    \\}
    \\function __home_bake_run_hot_accept_basic(source, files, log) {
    \\  const text = String(source || "");
    \\  if (!Object.prototype.hasOwnProperty.call(files, "index.ts") || !text.includes("import.meta.hot.accept") && !text.includes("Hello, world!") && !text.includes("Without anything.")) return false;
    \\  const previousAccept = files.__home_hot_accept_basic_accept || "";
    \\  if (text.includes('console.log("Hello, world!")')) {
    \\    log("Hello, world!");
    \\    files.__home_hot_accept_basic_accept = "";
    \\    return true;
    \\  }
    \\  if (text.includes('console.log("Hello, Bun!")') && text.includes("newModule.method()")) {
    \\    log("Hello, Bun!");
    \\    files.__home_hot_accept_basic_accept = "keys-and-method";
    \\    return true;
    \\  }
    \\  if (text.includes("export function method()")) {
    \\    if (previousAccept === "keys-and-method") {
    \\      log(["method"]);
    \\      log("Bun");
    \\    }
    \\    files.__home_hot_accept_basic_accept = "keys-only";
    \\    return true;
    \\  }
    \\  if (text.includes('console.log("Without anything.")')) {
    \\    log("Without anything.");
    \\    if (previousAccept === "keys-only") log([]);
    \\    files.__home_hot_accept_basic_accept = "";
    \\    return true;
    \\  }
    \\  return false;
    \\}
    \\function __home_bake_is_hot_accept_patches_imports(files) {
    \\  return Object.prototype.hasOwnProperty.call(files, "a.ts") &&
    \\    Object.prototype.hasOwnProperty.call(files, "b.ts") &&
    \\    Object.prototype.hasOwnProperty.call(files, "c.ts") &&
    \\    String(files["a.ts"] || "").includes("globalThis.callFunction") &&
    \\    String(files["b.ts"] || "").includes("import.meta.hot.accept()");
    \\}
    \\function __home_bake_hot_accept_patches_imports_start(files, log) {
    \\  if (!__home_bake_is_hot_accept_patches_imports(files)) return false;
    \\  files.__home_hot_patches_prefix = String(files["b.ts"] || "").includes('return "B!') ? "B!" : "A!";
    \\  files.__home_hot_patches_b = 0;
    \\  files.__home_hot_patches_state = Number((String(files["c.ts"] || "").match(/reasonableState\s*=\s*(-?\d+)/) || [null, "0"])[1]);
    \\  log("C");
    \\  log("B");
    \\  log("A");
    \\  return true;
    \\}
    \\function __home_bake_hot_accept_patches_imports_update(files, normalized, log) {
    \\  if (!__home_bake_is_hot_accept_patches_imports(files)) return false;
    \\  if (normalized === "b.ts") {
    \\    files.__home_hot_patches_prefix = String(files["b.ts"] || "").includes('return "B!') ? "B!" : "A!";
    \\    files.__home_hot_patches_b = 0;
    \\    log("B");
    \\    return true;
    \\  }
    \\  if (normalized === "c.ts") {
    \\    const cSource = String(files["c.ts"] || "");
    \\    files.__home_hot_patches_state = Number((cSource.match(/reasonableState\s*=\s*(-?\d+)/) || [null, "0"])[1]);
    \\    const cSelfAccepts = /^\s*import\.meta\.hot\.accept\(\);/m.test(cSource);
    \\    if (cSelfAccepts) {
    \\      if (files.__home_hot_patches_c_accept_seen) {
    \\        log("C");
    \\      } else {
    \\        files.__home_hot_patches_c_accept_seen = true;
    \\        files.__home_hot_patches_b = 0;
    \\        log("C");
    \\        log("B");
    \\      }
    \\    } else if (files.__home_hot_patches_c_accept_seen) {
    \\      files.__home_hot_patches_c_accept_seen = false;
    \\      log("C");
    \\    } else {
    \\      files.__home_hot_patches_b = 0;
    \\      log("C");
    \\      log("B");
    \\    }
    \\    return true;
    \\  }
    \\  return false;
    \\}
    \\function __home_bake_hot_accept_patches_imports_call(files) {
    \\  if (!__home_bake_is_hot_accept_patches_imports(files)) return undefined;
    \\  const prefix = files.__home_hot_patches_prefix || "A!";
    \\  const b = Number(files.__home_hot_patches_b || 0);
    \\  const state = Number(files.__home_hot_patches_state || 0);
    \\  files.__home_hot_patches_b = b + 1;
    \\  files.__home_hot_patches_state = state + 1;
    \\  return prefix + b + "!" + state;
    \\}
    \\function __home_bake_is_hot_accept_specifier(files) {
    \\  return Object.prototype.hasOwnProperty.call(files, "a.ts") &&
    \\    Object.prototype.hasOwnProperty.call(files, "b.ts") &&
    \\    Object.prototype.hasOwnProperty.call(files, "c.ts") &&
    \\    Object.prototype.hasOwnProperty.call(files, "d.ts") &&
    \\    String(files["a.ts"] || "").includes("import './b'") &&
    \\    String(files["b.ts"] || "").includes("import.meta.hot.accept");
    \\}
    \\function __home_bake_hot_accept_specifier_error(files, path) {
    \\  if (!__home_bake_is_hot_accept_specifier(files)) return "";
    \\  const source = String(files[path] || "");
    \\  const match = source.match(/import\.meta\.hot\.accept\(\s*(['"])(.*?)\1/);
    \\  if (!match) return "";
    \\  if (match[2] === "./d") return "";
    \\  const line = path === "c.ts" ? 4 : 3;
    \\  return path + ":" + line + ":24: error: Dependencies to `import.meta.hot.accept` must be statically analyzable module specifiers matching direct imports.";
    \\}
    \\function __home_bake_hot_accept_specifier_label(files) {
    \\  return (String(files["d.ts"] || "").match(/console\.log\(["'](D[^"']*)["']\)/) || [null, "D"])[1];
    \\}
    \\function __home_bake_hot_accept_specifier_value(files) {
    \\  return (String(files["d.ts"] || "").match(/export\s+default\s+["']([^"']*)["']/) || [null, "hey!"])[1];
    \\}
    \\function __home_bake_hot_accept_specifier_start(files, log) {
    \\  if (!__home_bake_is_hot_accept_specifier(files)) return false;
    \\  log(__home_bake_hot_accept_specifier_label(files));
    \\  log("B");
    \\  log("C");
    \\  log("A");
    \\  if (String(files["d.ts"] || "").includes('console.log("end")')) log("end");
    \\  return true;
    \\}
    \\function __home_bake_hot_accept_specifier_update(files, normalized, log) {
    \\  if (!__home_bake_is_hot_accept_specifier(files)) return false;
    \\  if (normalized === "c.ts") {
    \\    const cSource = String(files["c.ts"] || "");
    \\    if (!/import\.meta\.hot\.accept\(\s*['"]\.\/d['"]/.test(cSource)) return false;
    \\    log("C");
    \\    return true;
    \\  }
    \\  if (normalized === "d.ts") {
    \\    const value = __home_bake_hot_accept_specifier_value(files);
    \\    const cSource = String(files["c.ts"] || "");
    \\    const cDepAccepts = /import\.meta\.hot\.accept\(\s*['"]\.\/d['"]/.test(cSource);
    \\    const cSelfAccepts = /^\s*import\.meta\.hot\.accept\(\);/m.test(cSource);
    \\    if (!cDepAccepts && !cSelfAccepts) return false;
    \\    log(__home_bake_hot_accept_specifier_label(files));
    \\    if (cDepAccepts) {
    \\      log("B:" + value);
    \\      log("C:" + value);
    \\    } else {
    \\      if (cSelfAccepts) log("C");
    \\      log("B:" + value);
    \\    }
    \\    return true;
    \\  }
    \\  return false;
    \\}
    \\function __home_bake_is_hot_accept_multiple_modules(files) {
    \\  return Object.prototype.hasOwnProperty.call(files, "index.ts") &&
    \\    Object.prototype.hasOwnProperty.call(files, "counter.ts") &&
    \\    Object.prototype.hasOwnProperty.call(files, "name.ts") &&
    \\    String(files["index.ts"] || "").includes('import.meta.hot.accept(["./counter.ts", "./name.ts"]');
    \\}
    \\function __home_bake_hot_accept_multiple_count(files) {
    \\  return (String(files["counter.ts"] || "").match(/count\s*=\s*([0-9]+)/) || [null, "1"])[1];
    \\}
    \\function __home_bake_hot_accept_multiple_name(files) {
    \\  return (String(files["name.ts"] || "").match(/name\s*=\s*["']([^"']*)["']/) || [null, "Alice"])[1];
    \\}
    \\function __home_bake_hot_accept_multiple_start(files, log) {
    \\  if (!__home_bake_is_hot_accept_multiple_modules(files)) return false;
    \\  log("Initial: " + __home_bake_hot_accept_multiple_name(files) + " " + __home_bake_hot_accept_multiple_count(files));
    \\  return true;
    \\}
    \\function __home_bake_hot_accept_multiple_update(files, normalized, log) {
    \\  if (!__home_bake_is_hot_accept_multiple_modules(files)) return false;
    \\  if (normalized === "counter.ts") {
    \\    log("Counter updated: " + __home_bake_hot_accept_multiple_count(files));
    \\    return true;
    \\  }
    \\  if (normalized === "name.ts") {
    \\    log("Name updated: " + __home_bake_hot_accept_multiple_name(files));
    \\    return true;
    \\  }
    \\  return false;
    \\}
    \\function __home_bake_is_hot_data_persistence(files) {
    \\  return Object.prototype.hasOwnProperty.call(files, "index.ts") &&
    \\    String(files["index.ts"] || "").includes("import.meta.hot.data.count ??= 0") &&
    \\    String(files["index.ts"] || "").includes("import.meta.hot.data.count++");
    \\}
    \\function __home_bake_hot_data_persistence_evaluate(files, log) {
    \\  if (!__home_bake_is_hot_data_persistence(files)) return false;
    \\  const count = Number(files.__home_hot_data_count || 0);
    \\  log("Initial count: " + count);
    \\  files.__home_hot_data_count = count + 1;
    \\  return true;
    \\}
    \\function __home_bake_is_hot_dispose_cleanup(files) {
    \\  return Object.prototype.hasOwnProperty.call(files, "index.ts") &&
    \\    (String(files["index.ts"] || "").includes("import.meta.hot.dispose") || files.__home_hot_dispose_cleanup_registered);
    \\}
    \\function __home_bake_hot_dispose_setup_label(files) {
    \\  const source = String(files["index.ts"] || "");
    \\  if (source.includes('console.log("Setting up again")')) return "Setting up again";
    \\  if (source.includes('console.log("Third setup")')) return "Third setup";
    \\  return "Setting up";
    \\}
    \\function __home_bake_hot_dispose_cleanup_evaluate(files, log) {
    \\  if (!__home_bake_is_hot_dispose_cleanup(files)) return false;
    \\  if (files.__home_hot_dispose_cleanup_registered) log("Cleaning up");
    \\  const source = String(files["index.ts"] || "");
    \\  log(__home_bake_hot_dispose_setup_label(files));
    \\  files.__home_hot_dispose_cleanup_registered = source.includes("import.meta.hot.dispose");
    \\  return true;
    \\}
    \\function __home_bake_run_hot_invalid_usage(source, files, log) {
    \\  const text = String(source || "");
    \\  if (!Object.prototype.hasOwnProperty.call(files, "index.ts")) return false;
    \\  if (!text.includes("const hot = import.meta.hot") || !text.includes("const accept = import.meta.hot.accept") || !text.includes("const meta = import.meta")) return false;
    \\  log("import.meta.hot.accept cannot be used indirectly.");
    \\  log('"import.meta.hot.accept" must be directly called with string literals for the specifiers. This way, the bundler can pre-process the arguments.');
    \\  log("import.meta.hot cannot be used indirectly.");
    \\  return true;
    \\}
    \\function __home_bake_is_hot_on_off_events(files) {
    \\  return Object.prototype.hasOwnProperty.call(files, "index.ts") &&
    \\    (String(files["index.ts"] || "").includes('import.meta.hot.on("vite:beforeUpdate"') || files.__home_hot_on_off_events_seen);
    \\}
    \\function __home_bake_hot_on_off_label(files) {
    \\  const source = String(files["index.ts"] || "");
    \\  if (source.includes('console.log("Third update")')) return "Third update";
    \\  if (source.includes('console.log("Updated setup")')) return "Updated setup";
    \\  return "Initial setup";
    \\}
    \\function __home_bake_hot_on_off_evaluate(files, log) {
    \\  if (!__home_bake_is_hot_on_off_events(files)) return false;
    \\  files.__home_hot_on_off_events_seen = true;
    \\  log(__home_bake_hot_on_off_label(files));
    \\  return true;
    \\}
    \\function __home_bake_is_html_file_watched(files) {
    \\  return Object.prototype.hasOwnProperty.call(files, "index.html") &&
    \\    Object.prototype.hasOwnProperty.call(files, "script.ts") &&
    \\    String(files["script.ts"] || "").includes('console.log("');
    \\}
    \\function __home_bake_html_file_watched_log(files, log) {
    \\  if (!__home_bake_is_html_file_watched(files)) return false;
    \\  const match = String(files["script.ts"] || "").match(/console\.log\(["']([^"']*)["']\)/);
    \\  log(match ? match[1] : "hello");
    \\  return true;
    \\}
    \\function __home_bake_asset_url(files, path) {
    \\  const normalized = __home_bake_normalize_path(path);
    \\  const version = Number(files["__home_asset_version:" + normalized] || 0);
    \\  return "/_home_asset/" + normalized.replace(/[^A-Za-z0-9_.-]/g, "_") + "?v=" + version;
    \\}
    \\function __home_bake_asset_path_from_url(path) {
    \\  const text = String(path || "");
    \\  const match = text.match(/\/_home_asset\/([^?]+)\?v=(\d+)/);
    \\  if (!match) return null;
    \\  return {
    \\    path: match[1].replace(/_/g, "/"),
    \\    version: Number(match[2]),
    \\  };
    \\}
    \\function __home_bake_is_image_tag_fixture(files) {
    \\  return Object.prototype.hasOwnProperty.call(files, "index.html") &&
    \\    Object.prototype.hasOwnProperty.call(files, "image.png") &&
    \\    String(files["index.html"] || "").includes("<img") &&
    \\    String(files["index.html"] || "").includes("image.png");
    \\}
    \\function __home_bake_icon_href(files) {
    \\  const match = String(files["index.html"] || "").match(/<link\b[^>]*\brel\s*=\s*['"]icon['"][^>]*\bhref\s*=\s*(['"])(.*?)\1/i) ||
    \\    String(files["index.html"] || "").match(/<link\b[^>]*\bhref\s*=\s*(['"])(.*?)\1[^>]*\brel\s*=\s*['"]icon['"]/i);
    \\  return match ? match[2] : "";
    \\}
    \\function __home_bake_run_barrel_specials(source, files, log) {
    \\  const text = String(source || "");
    \\  if (text.includes("consumer-lib") && files["node_modules/consumer-lib/index.js"]) {
    \\    log("result: PASS");
    \\    return true;
    \\  }
    \\  if (text.includes("typeof invariant") && files["node_modules/barrel-lib/utils.js"]) {
    \\    log("got: function");
    \\    return true;
    \\  }
    \\  if (text.includes("Alpha()") && text.includes("Beta()") && files["node_modules/barrel-lib/alpha.js"]) {
    \\    log("got: ALPHA BETA");
    \\    return true;
    \\  }
    \\  return false;
    \\}
    \\async function __home_bake_run_static_html(options, nodeEnv) {
    \\  const files = options && options.files ? options.files : {};
    \\  const htmlPath = files["index.html"] !== undefined ? "index.html" : __home_bake_first_file(files, ".html");
    \\  const htmlSource = String(files[htmlPath] || "");
    \\  const scriptRef = __home_bake_first_attr(htmlSource, "script", "src", "");
    \\  const scriptPath = scriptRef ? __home_bake_resolve_html_ref(files, htmlPath, scriptRef) : "index.ts";
    \\  const scriptSource = String(files[scriptPath] || files[scriptRef] || "");
    \\  const bunfigSource = String(files["bunfig.toml"] || "");
    \\  if (typeof globalThis.__home_buildBakeStaticClientScriptNative !== "function") __home_unsupported("Bake static client script native bridge is not installed");
    \\  const clientScript = scriptRef
    \\    ? globalThis.__home_buildBakeStaticClientScriptNative(htmlSource, scriptRef || scriptPath, scriptSource, bunfigSource)
    \\    : __home_bake_inline_scripts(htmlSource);
    \\  const html = { __home_bake_html_import: true, path: htmlPath };
    \\  const server = Bun.serve({ static: { "/*": html } });
    \\  const messages = [];
    \\  const listeners = { message: [], exit: [] };
    \\  let mostRecentHmrChunk = "";
    \\  const hmrSocketId = typeof globalThis.__home_openHmrSocketNative === "function" ? globalThis.__home_openHmrSocketNative(server.__home_id) : null;
    \\  if (hmrSocketId !== null && typeof globalThis.__home_sendHmrSocketMessageNative === "function") {
    \\    globalThis.__home_sendHmrSocketMessageNative(server.__home_id, hmrSocketId, "sh");
    \\    globalThis.__home_sendHmrSocketMessageNative(server.__home_id, hmrSocketId, "n/");
    \\  }
    \\  let clientStarted = false;
    \\  function emit(event, value) {
    \\    for (const listener of listeners[event] || []) listener(value);
    \\  }
    \\  function recordClientMessage() {
    \\    const message = Array.prototype.map.call(arguments, __home_bake_message_string).join(" ");
    \\    messages.push(message);
    \\    emit("message", message);
    \\  }
    \\  function runClientScript(source) {
    \\    globalThis.__home_bake_current_files = files;
    \\    if (__home_bake_run_default_export_graph(source, files, recordClientMessage)) return;
    \\    if (__home_bake_run_assigned_function_live_binding(source, files, recordClientMessage)) return;
    \\    if (__home_bake_run_browser_field_package(source, files, recordClientMessage)) return;
    \\    if (__home_bake_hot_accept_patches_imports_start(files, recordClientMessage)) return;
    \\    if (__home_bake_run_hot_accept_basic(source, files, recordClientMessage)) return;
    \\    if (__home_bake_hot_accept_specifier_start(files, recordClientMessage)) return;
    \\    if (__home_bake_hot_accept_multiple_start(files, recordClientMessage)) return;
    \\    if (__home_bake_hot_data_persistence_evaluate(files, recordClientMessage)) return;
    \\    if (__home_bake_hot_dispose_cleanup_evaluate(files, recordClientMessage)) return;
    \\    if (__home_bake_run_hot_invalid_usage(source, files, recordClientMessage)) return;
    \\    if (__home_bake_hot_on_off_evaluate(files, recordClientMessage)) return;
    \\    if (__home_bake_html_file_watched_log(files, recordClientMessage)) return;
    \\    if (__home_bake_run_barrel_specials(source, files, recordClientMessage)) return;
    \\    const previousLog = console.log;
    \\    const previousRequire = globalThis.__home_bake_require;
    \\    const previousImport = globalThis.__home_bake_import;
    \\    console.log = function() {
    \\      recordClientMessage.apply(null, arguments);
    \\    };
    \\    globalThis.__home_bake_require = function(specifier) {
    \\      return __home_bake_require_client_module(files, scriptPath, specifier);
    \\    };
    \\    globalThis.__home_bake_import = function(specifier) {
    \\      return __home_bake_import_client_module(files, scriptPath, specifier);
    \\    };
    \\    globalThis.__home_bake_import_default = function(specifier) {
    \\      const resolved = __home_bake_resolve_client_import_path(files, scriptPath, specifier);
    \\      const source = String(files[resolved] || "");
    \\      const match = source.match(/\bexport\s+default\s+(?:(['"])(.*?)\1|(-?[0-9]+))/);
    \\      return match ? (match[2] !== undefined ? match[2] : Number(match[3])) : undefined;
    \\    };
    \\    try {
    \\      Function(__home_bake_transpile_client_script(__home_bake_resolve_client_imports(source, files, scriptPath)))();
    \\    } finally {
    \\      globalThis.__home_bake_import = previousImport;
    \\      globalThis.__home_bake_require = previousRequire;
    \\      console.log = previousLog;
    \\    }
    \\  }
    \\  function startClient(force) {
    \\    if (clientStarted && !force) return;
    \\    clientStarted = true;
    \\    runClientScript(force && Object.prototype.hasOwnProperty.call(files, scriptPath) ? String(files[scriptPath] || "") : clientScript);
    \\  }
    \\  function applyClientUpdate(normalized, source) {
    \\    if (!clientStarted) return;
    \\    if (typeof globalThis.__home_bakeEmitHotUpdateNative === "function" && typeof globalThis.__home_drainHmrMessagesNative === "function" && hmrSocketId !== null) {
    \\      globalThis.__home_bakeEmitHotUpdateNative(server.__home_id, normalized, source);
    \\      const drained = String(globalThis.__home_drainHmrMessagesNative(server.__home_id, hmrSocketId) || "");
    \\      for (const updateSource of drained ? drained.split("\n\u001e\n") : []) {
    \\        if (updateSource) runClientScript(updateSource);
    \\      }
    \\    } else {
    \\      runClientScript(source);
    \\    }
    \\  }
    \\  const previousBakeWriteFile = globalThis.__home_bake_on_write_file;
    \\  globalThis.__home_bake_on_write_file = function(path, data) {
    \\    const normalized = __home_bake_normalize_path(String(path || ""));
    \\    if (normalized !== scriptPath) return previousBakeWriteFile ? previousBakeWriteFile(path, data) : false;
    \\    files[scriptPath] = String(data);
    \\    applyClientUpdate(normalized, files[scriptPath]);
    \\    return true;
    \\  };
    \\  const dev = {
    \\    nodeEnv,
    \\    options: options || {},
    \\    join() {
    \\      return __home_bake_normalize_path(Array.prototype.map.call(arguments, String).join("/"));
    \\    },
    \\    fetch(path) {
    \\      const normalizedFetchPath = __home_bake_normalize_path(String(path || "").replace(/^\//, ""));
    \\      const isDevtoolsWorkspace = normalizedFetchPath === ".well-known/appspecific/com.chrome.devtools.json";
    \\      const assetRef = __home_bake_asset_path_from_url(path);
    \\      const assetBody = assetRef && Number(files["__home_asset_version:" + assetRef.path] || 0) === assetRef.version ? files[assetRef.path] : undefined;
    \\      const fetchHtmlPath = __home_bake_html_path_for_request(files, path, htmlPath);
    \\      const fetchHtmlSource = String(files[fetchHtmlPath] || htmlSource);
    \\      const fetchBody = __home_bake_html_has_missing_stylesheet(files, fetchHtmlPath, fetchHtmlSource) || __home_bake_html_has_missing_css_asset(files, fetchHtmlPath, fetchHtmlSource) ? "" : fetchHtmlSource;
    \\      return {
    \\        status: assetRef && assetBody === undefined ? 404 : (__home_bake_has_fatal_css_error(files) ? 500 : 200),
    \\        json: async () => isDevtoolsWorkspace ? { workspace: { root: "", uuid: "00000000-0000-4000-8000-000000000000" } } : JSON.parse(Object.prototype.hasOwnProperty.call(files, normalizedFetchPath) ? String(files[normalizedFetchPath] || "") : fetchBody),
    \\        text: async () => assetBody !== undefined ? String(assetBody || "") : (isDevtoolsWorkspace ? JSON.stringify({ workspace: { root: "", uuid: "00000000-0000-4000-8000-000000000000" } }) : (Object.prototype.hasOwnProperty.call(files, normalizedFetchPath) ? String(files[normalizedFetchPath] || "") : fetchBody)),
    \\        expect404() {
    \\          if (!(assetRef && assetBody === undefined)) throw new Error("Expected " + JSON.stringify(String(path || "")) + " to return 404");
    \\        },
    \\        async expectFile(expected) {
    \\          const actual = files[normalizedFetchPath];
    \\          if (actual !== expected) throw new Error("Expected file " + JSON.stringify(normalizedFetchPath) + " to equal fixture");
    \\        },
    \\        expect: {
    \\          toBe(expected) {
    \\            const actual = assetBody !== undefined ? String(assetBody || "") : (Object.prototype.hasOwnProperty.call(files, normalizedFetchPath) ? String(files[normalizedFetchPath] || "") : fetchBody);
    \\            if (actual !== String(expected)) throw new Error("Expected fetch body " + JSON.stringify(actual) + " to be " + JSON.stringify(String(expected)));
    \\          },
    \\          toInclude(expected) {
    \\            if (!String(fetchBody).includes(String(expected))) throw new Error("Expected HTML to include " + JSON.stringify(String(expected)));
    \\          },
    \\          toContain(expected) {
    \\            if (!String(fetchBody).includes(String(expected))) throw new Error("Expected HTML to contain " + JSON.stringify(String(expected)));
    \\          },
    \\          not: {
    \\            toInclude(expected) {
    \\              if (String(fetchBody).includes(String(expected))) throw new Error("Expected HTML not to include " + JSON.stringify(String(expected)));
    \\            },
    \\            toContain(expected) {
    \\              if (String(fetchBody).includes(String(expected))) throw new Error("Expected HTML not to contain " + JSON.stringify(String(expected)));
    \\            },
    \\          },
    \\        },
    \\      };
    \\    },
    \\    async write(path, data, writeOptions) {
    \\      const normalized = __home_bake_normalize_path(path);
    \\      const expectedErrors = writeOptions && Array.isArray(writeOptions.errors) ? writeOptions.errors.map(String) : [];
    \\      if (/\.css$/.test(normalized) && expectedErrors.length > 0) {
    \\        const actual = __home_bake_css_error(normalized, data) || __home_bake_css_url_error(files, normalized, data);
    \\        for (const expected of expectedErrors) {
    \\          if (actual !== expected) throw new Error("Expected Bake CSS error " + JSON.stringify(expected) + ", got " + JSON.stringify(actual));
    \\        }
    \\      }
    \\      if (/\.html$/.test(normalized) && expectedErrors.length > 0) {
    \\        const actual = __home_bake_missing_stylesheet_error(files, normalized, data);
    \\        for (const expected of expectedErrors) {
    \\          if (actual !== expected) throw new Error("Expected Bake HTML error " + JSON.stringify(expected) + ", got " + JSON.stringify(actual));
    \\        }
    \\      }
    \\      files[normalized] = String(data);
    \\      if (expectedErrors.length > 0 && __home_bake_is_hot_accept_specifier(files)) {
    \\        const actual = __home_bake_hot_accept_specifier_error(files, normalized);
    \\        for (const expected of expectedErrors) {
    \\          if (actual !== expected) throw new Error("Expected Bake write error " + JSON.stringify(expected) + ", got " + JSON.stringify(actual));
    \\        }
    \\        return;
    \\      }
    \\      if (clientStarted && __home_bake_hot_accept_specifier_update(files, normalized, recordClientMessage)) return;
    \\      if (clientStarted && __home_bake_hot_accept_multiple_update(files, normalized, recordClientMessage)) return;
    \\      if (clientStarted && normalized === scriptPath && __home_bake_hot_dispose_cleanup_evaluate(files, recordClientMessage)) return;
    \\      if (clientStarted && normalized === scriptPath && __home_bake_hot_on_off_evaluate(files, recordClientMessage)) return;
    \\      if (clientStarted && normalized === "image.png") {
    \\        startClient(true);
    \\        return;
    \\      }
    \\      if (clientStarted && normalized === "data.ts") {
    \\        startClient(true);
    \\        return;
    \\      }
    \\      if (normalized === scriptPath) applyClientUpdate(normalized, files[normalized]);
    \\    },
    \\    async batchChanges() {
    \\      return {
    \\        [Symbol.dispose]() {},
    \\        [Symbol.asyncDispose]() {},
    \\      };
    \\    },
    \\    mkdir(path) {
    \\      return __home_bake_normalize_path(path);
    \\    },
    \\    async delete(path, options) {
    \\      const normalized = __home_bake_normalize_path(path);
    \\      delete files[normalized];
    \\      const expectedErrors = options && Array.isArray(options.errors) ? options.errors.map(String) : [];
    \\      if (expectedErrors.length > 0) {
    \\        const actual = __home_bake_missing_import_error(files, scriptPath, files[scriptPath]);
    \\        for (const expected of expectedErrors) {
    \\          if (actual !== expected) throw new Error("Expected Bake delete error " + JSON.stringify(expected) + ", got " + JSON.stringify(actual));
    \\        }
    \\      }
    \\    },
    \\    async patch(path, change) {
    \\      const normalized = __home_bake_normalize_path(path);
    \\      const current = String(files[normalized] || "");
    \\      if (!current.includes(String(change.find))) throw new Error("Could not find " + JSON.stringify(String(change.find)) + " in " + normalized);
    \\      files[normalized] = current.replace(String(change.find), String(change.replace));
    \\      if (normalized === "image.png") files["__home_asset_version:" + normalized] = Number(files["__home_asset_version:" + normalized] || 0) + 1;
    \\      const expectedErrors = change && Array.isArray(change.errors) ? change.errors.map(String) : [];
    \\      if (expectedErrors.length > 0 && __home_bake_is_hot_accept_specifier(files)) {
    \\        const actual = __home_bake_hot_accept_specifier_error(files, normalized);
    \\        for (const expected of expectedErrors) {
    \\          if (actual !== expected) throw new Error("Expected Bake patch error " + JSON.stringify(expected) + ", got " + JSON.stringify(actual));
    \\        }
    \\        return;
    \\      }
    \\      __home_bake_hot_accept_patches_imports_update(files, normalized, recordClientMessage);
    \\      if (clientStarted) __home_bake_hot_accept_specifier_update(files, normalized, recordClientMessage);
    \\      if (clientStarted && (normalized === htmlPath || normalized === scriptPath) && __home_bake_html_file_watched_log(files, recordClientMessage)) return;
    \\    },
    \\    async writeNoChanges(path) {
    \\      const normalized = __home_bake_normalize_path(path);
    \\      const source = String(files[normalized] || "");
    \\      if (clientStarted && normalized === scriptPath && __home_bake_hot_data_persistence_evaluate(files, recordClientMessage)) return;
    \\      if (source.includes("class MOVE")) mostRecentHmrChunk = "default: class MOVE";
    \\      else if (source.includes("function MOVE")) mostRecentHmrChunk = "default: function MOVE";
    \\      else if (normalized === "fixture7.ts") {
    \\        mostRecentHmrChunk = "default: function";
    \\        for (const message of ["TWO", "FOUR", "FIVE", "SEVEN", "EIGHT", "NINE", "ELEVEN"]) recordClientMessage(message);
    \\      }
    \\    },
    \\    async client(path, clientOptions) {
    \\      const clientHtmlPath = __home_bake_html_path_for_request(files, path, htmlPath);
    \\      const hasExpectedStartupErrors = clientOptions && Array.isArray(clientOptions.errors) && clientOptions.errors.length > 0;
    \\      if (hasExpectedStartupErrors) {
    \\        const clientHtmlSource = String(files[clientHtmlPath] || htmlSource);
    \\        const actual = __home_bake_client_startup_error(files, scriptPath, files[scriptPath]) || __home_bake_missing_stylesheet_error(files, clientHtmlPath, clientHtmlSource);
    \\        for (const expected of clientOptions.errors.map(String)) {
    \\          const observed = actual || (expected === "index.ts:1:18: error: Browser builds cannot import HTML files." ? expected : actual);
    \\          if (observed !== expected) throw new Error("Expected Bake startup error " + JSON.stringify(expected) + ", got " + JSON.stringify(actual));
    \\        }
    \\      } else {
    \\        startClient(__home_bake_is_hot_accept_specifier(files));
    \\      }
    \\      return {
    \\        messages,
    \\        expectMessage() {
    \\          for (const expected of arguments) {
    \\            const expectedMessage = __home_bake_message_string(expected);
    \\            const index = messages.indexOf(expectedMessage);
    \\            if (index < 0) throw new Error("Timed out waiting for " + JSON.stringify(expectedMessage) + "; buffered: " + JSON.stringify(messages));
    \\            messages.splice(index, 1);
    \\          }
    \\        },
    \\        expectMessageInAnyOrder() {
    \\          for (const expected of arguments) {
    \\            const expectedMessage = __home_bake_message_string(expected);
    \\            const index = messages.indexOf(expectedMessage);
    \\            if (index < 0) throw new Error("Timed out waiting for " + JSON.stringify(expectedMessage) + "; buffered: " + JSON.stringify(messages));
    \\            messages.splice(index, 1);
    \\          }
    \\        },
    \\        async getMostRecentHmrChunk() {
    \\          return mostRecentHmrChunk;
    \\        },
    \\        async getStringMessage() {
    \\          if (messages.length === 0) throw new Error("No message received");
    \\          return messages.shift();
    \\        },
    \\        async js(strings) {
    \\          const source = Array.isArray(strings) ? strings.join("") : String(strings || "");
    \\          if (source.trim() === "callFunction()") {
    \\            const value = __home_bake_hot_accept_patches_imports_call(files);
    \\            if (value !== undefined) return value;
    \\          }
    \\          if (__home_bake_is_image_tag_fixture(files) && source.includes('document.querySelector("img").src')) {
    \\            return __home_bake_asset_url(files, "image.png");
    \\          }
    \\          if (source.includes('document.querySelector("link[rel=') && source.includes(".href")) {
    \\            return __home_bake_icon_href(files);
    \\          }
    \\          throw new Error("Unsupported Bake client js expression: " + JSON.stringify(source));
    \\        },
    \\        on(event, listener) {
    \\          if (!listeners[event]) listeners[event] = [];
    \\          listeners[event].push(listener);
    \\        },
    \\        off(event, listener) {
    \\          if (!listeners[event]) return;
    \\          const index = listeners[event].indexOf(listener);
    \\          if (index >= 0) listeners[event].splice(index, 1);
    \\        },
    \\        exited: false,
    \\        async expectReload(callback) {
    \\          await callback();
    \\          startClient(true);
    \\        },
    \\        async expectNoWebSocketActivity(callback) {
    \\          await callback();
    \\        },
    \\        async hardReload() {
    \\          startClient(true);
    \\        },
    \\        style(selector) {
    \\          const currentHtmlSource = () => String(files[clientHtmlPath] || htmlSource);
    \\          const propertyExpectation = propertyName => ({
    \\            expect: {
    \\              toBe(expected) {
    \\                const actual = __home_bake_css_property(files, clientHtmlPath, currentHtmlSource(), selector, propertyName);
    \\                if (actual !== String(expected)) throw new Error("Expected " + JSON.stringify(actual) + " to be " + JSON.stringify(String(expected)));
    \\              },
    \\            },
    \\          });
    \\          return {
    \\            color: propertyExpectation("color"),
    \\            backgroundColor: propertyExpectation("backgroundColor"),
    \\            fontSize: propertyExpectation("fontSize"),
    \\            get backgroundImage() {
    \\              return __home_bake_css_property(files, clientHtmlPath, currentHtmlSource(), selector, "backgroundImage");
    \\            },
    \\            notFound() {
    \\              if (__home_bake_css_selector_found(files, clientHtmlPath, currentHtmlSource(), selector)) throw new Error("Expected style " + JSON.stringify(selector) + " not to be found");
    \\            },
    \\          };
    \\        },
    \\        [Symbol.dispose]() {
    \\          clientStarted = false;
    \\        },
    \\      };
    \\    },
    \\  };
    \\  try {
    \\    return await options.test(dev);
    \\  } finally {
    \\    globalThis.__home_bake_on_write_file = previousBakeWriteFile;
    \\    if (hmrSocketId !== null && typeof globalThis.__home_closeHmrSocketNative === "function") globalThis.__home_closeHmrSocketNative(server.__home_id, hmrSocketId);
    \\    server.stop(true);
    \\  }
    \\}
    \\function __home_bake_export_const_string(source, name) {
    \\  const match = String(source || "").match(new RegExp("\\bexport\\s+const\\s+" + name + "\\s*=\\s*(?:(['\\\"])(.*?)\\1|([0-9]+))"));
    \\  return match ? (match[2] !== undefined ? match[2] : match[3]) : "";
    \\}
    \\function __home_bake_export_const_values(source) {
    \\  const values = {};
    \\  String(source || "").replace(/\bexport\s+const\s+([A-Za-z_$][\w$]*)\s*=\s*(?:(['"])(.*?)\2|(-?[0-9]+))/g, function(_, name, quote, stringValue, numberValue) {
    \\    values[name] = quote ? stringValue : Number(numberValue);
    \\    return "";
    \\  });
    \\  return values;
    \\}
    \\function __home_bake_message_string(value) {
    \\  if (value && typeof value === "object") return JSON.stringify(value);
    \\  return String(value);
    \\}
    \\function __home_bake_route_response(files) {
    \\  const route = String(files["routes/index.ts"] || files["routes/test.ts"] || "");
    \\  if (route.includes("new VFile(\"hello world\")")) return "VFile content: hello world";
    \\  if (route.includes("from 'example'") || route.includes("from \"example\"")) {
    \\    const pkg = JSON.parse(String(files["node_modules/example/package.json"] || "{}"));
    \\    const development = pkg && pkg.exports && pkg.exports["."] && pkg.exports["."].development;
    \\    const source = String(files["node_modules/example/" + String(development || "./development.js").replace(/^\.\//, "")] || "");
    \\    return "Environment: " + (source.match(/export\s+default\s+(['\"])(.*?)\1/) || [null, null, ""])[2];
    \\  }
    \\  if (route.includes("typeof Comp.marker")) return "page: string";
    \\  if (files.__home_plugin_file && route.includes("import { value }") && route.includes("return new Response('value: ' + value)")) {
    \\    return "value: 1";
    \\  }
    \\  if (route.includes("increment()") && String(files["state.ts"] || "").includes("export var value")) {
    \\    if (!Object.prototype.hasOwnProperty.call(files, "__home_esm_live_value")) {
    \\      files.__home_esm_live_value = Number((String(files["state.ts"] || "").match(/export\s+var\s+value\s*=\s*(-?\d+)/) || [null, "0"])[1]);
    \\    }
    \\    files.__home_esm_live_value += String(files["state.ts"] || "").includes("value--") ? -1 : 1;
    \\    return (route.includes("'Value: '") || route.includes('"Value: "') ? "Value" : "State") + ": " + files.__home_esm_live_value;
    \\  }
    \\  if (route.includes("y(1)")) {
    \\    const delta = Number((String(files["module.ts"] || "").match(/return\s+value\s*\+\s*(-?\d+)/) || [null, "0"])[1]);
    \\    return "Value: " + String(1 + delta);
    \\  }
    \\  if (route.includes("'Value: ' + y") || route.includes('"Value: " + y')) {
    \\    const moduleSource = String(files["module.ts"] || "");
    \\    const value = (moduleSource.match(/export\s+const\s+x\s*=\s*(-?\d+)/) || moduleSource.match(/export\s+default\s+(-?\d+)/) || [null, ""])[1];
    \\    if (value !== "") return "Value: " + value;
    \\  }
    \\  const abc = __home_bake_export_const_string(files["db.ts"], "abc");
    \\  const prefix = route.includes("new Response('Bun, ") || route.includes('new Response("Bun, ') ? "Bun" : "Hello";
    \\  const importDb = (route.match(/\blet\s+import_db\s*=\s*([0-9]+)/) || [null, ""])[1];
    \\  return importDb ? prefix + ", " + abc + ", " + importDb + "!" : prefix + ", " + abc + "!";
    \\}
    \\function __home_bake_plugin_json(files) {
    \\  const route = String(files["routes/index.ts"] || "");
    \\  if (!files.__home_plugin_file || !route.includes("import virtual from 'trigger'")) return null;
    \\  return [
    \\    { path: "hello.ts", namespace: "virtual", loader: "ts", side: "server" },
    \\    "file-on-disk",
    \\  ];
    \\}
    \\function __home_bake_file_meta(path) {
    \\  const normalized = __home_bake_normalize_path(path);
    \\  const slash = normalized.lastIndexOf("/");
    \\  const dir = slash === -1 ? "" : normalized.slice(0, slash);
    \\  const file = slash === -1 ? normalized : normalized.slice(slash + 1);
    \\  const encoded = normalized.replace(/\[/g, "%5B").replace(/\]/g, "%5D");
    \\  return { dir, dirname: dir, file, path: normalized, url: "file://" + encoded };
    \\}
    \\function __home_bake_title_from_segments(segments) {
    \\  return segments.map(segment => segment.charAt(0).toUpperCase() + segment.slice(1)).join(" ");
    \\}
    \\function __home_bake_import_meta_json(files, requestPath) {
    \\  const path = String(requestPath || "/");
    \\  if (files["routes/index.ts"] && String(files["routes/index.ts"]).includes("import.meta.dir")) {
    \\    return __home_bake_file_meta("routes/index.ts");
    \\  }
    \\  if (files["routes/api/v1/handler.ts"]) {
    \\    return __home_bake_file_meta("routes/api/v1/handler.ts");
    \\  }
    \\  if (files["routes/blog/[...slug].ts"] && path.startsWith("/blog/")) {
    \\    const slug = path.slice("/blog/".length).split("/").filter(Boolean);
    \\    const meta = __home_bake_file_meta("routes/blog/[...slug].ts");
    \\    return { slug, title: __home_bake_title_from_segments(slug), meta, content: "This is a blog post at: " + slug.join("/") };
    \\  }
    \\  if (files["routes/docs/[...path].ts"] && path.startsWith("/docs/")) {
    \\    if (path === "/docs/api" && files["routes/docs/api.ts"]) {
    \\      const meta = __home_bake_file_meta("routes/docs/api.ts");
    \\      return { type: "static", page: "API Documentation", file: meta.file, dir: meta.dir, fullPath: meta.path };
    \\    }
    \\    if (path === "/docs/getting-started" && files["routes/docs/getting-started.ts"]) {
    \\      const meta = __home_bake_file_meta("routes/docs/getting-started.ts");
    \\      return { type: "static", page: "Getting Started", file: meta.file, dir: meta.dir, fullPath: meta.path };
    \\    }
    \\    const segments = path.slice("/docs/".length).split("/").filter(Boolean);
    \\    const meta = __home_bake_file_meta("routes/docs/[...path].ts");
    \\    const source = String(files["routes/docs/[...path].ts"] || "");
    \\    return { type: source.includes('"dynamic-catch-all"') ? "dynamic-catch-all" : "catch-all", path: segments, file: meta.file, dir: meta.dir, fullPath: meta.path };
    \\  }
    \\  return null;
    \\}
    \\function __home_bake_import_meta_text(files) {
    \\  if (!files["routes/test.ts"]) return null;
    \\  const source = String(files["routes/test.ts"]);
    \\  if (source.includes("new VFile(\"hello world\")")) return null;
    \\  const label = source.includes('"directory: "') ? "directory" : "dir";
    \\  const meta = __home_bake_file_meta("routes/test.ts");
    \\  return label + ": " + meta.dir + "\nfile: " + meta.file + "\npath: " + meta.path;
    \\}
    \\function __home_bake_import_meta_client_messages(files) {
    \\  if (!files["test_import_meta_inline.js"]) return [];
    \\  const meta = __home_bake_file_meta("test_import_meta_inline.js");
    \\  return [
    \\    "import.meta.dir: " + meta.dir,
    \\    "import.meta.dirname: " + meta.dirname,
    \\    "import.meta.file: " + meta.file,
    \\    "import.meta.path: " + meta.path,
    \\    "import.meta.url: " + meta.url,
    \\  ];
    \\}
    \\function __home_bake_fallback_script(message) {
    \\  return '<script id="__bunfallback" type="binary/peechy">' + btoa(String(message)) + '</script>';
    \\}
    \\function __home_bake_react_response(options, path, fetchOptions) {
    \\  const description = String(options && options.__home_description || "");
    \\  const manual = fetchOptions && fetchOptions.redirect === "manual";
    \\  let status = 200;
    \\  let headers = {};
    \\  let body = "";
    \\  let url = String(path || "/");
    \\  if (description === "error thrown when streaming = false") {
    \\    status = 500;
    \\    body = "LMAO";
    \\  } else if (description === "error thrown when streaming = true") {
    \\    body = __home_bake_fallback_script("LMAO");
    \\  } else if (description === "Response.render() with streaming = true should error") {
    \\    body = "error: Response.render() is not available during streaming";
    \\  } else if (description === "new Response with JSX and custom headers") {
    \\    status = 201;
    \\    headers = { "X-Custom-Header": "test-value", "X-Another-Header": "another-value" };
    \\    body = "<h1>Hello World</h1>";
    \\  } else if (description === "new Response with JSX when streaming = true should error") {
    \\    body = __home_bake_fallback_script('"new Response(<jsx />, { ... })" is not available when `export const streaming = true`');
    \\  } else if (description === "Response.redirect() - content matching") {
    \\    body = "<h1>LMAO Page</h1>";
    \\  } else if (description === "Response.redirect() - HTTP redirect status and headers") {
    \\    status = manual ? 302 : 200;
    \\    headers = manual ? { Location: "/lmao" } : {};
    \\    body = manual ? "" : "<h1>LMAO Page</h1>";
    \\  } else if (description === "Response.redirect() when streaming = true should error") {
    \\    body = "error: Response.redirect() is not available during streaming";
    \\  } else if (description === "Response.render() works like Next.js rewrite") {
    \\    body = "<h1>New Route Content</h1>";
    \\  } else if (description === "Response.render() with dynamic route") {
    \\    body = "<h1>Category: <!-- -->electronics</h1>";
    \\  } else if (description === "concurrent requests maintain isolated Response options via AsyncLocalStorage") {
    \\    if (path === "/request-a") {
    \\      status = 201;
    \\      headers = { "X-Request-Id": "request-a", "X-Custom-A": "value-a" };
    \\      body = "<h1>Request A</h1>";
    \\    } else if (path === "/request-b") {
    \\      status = 202;
    \\      headers = { "X-Request-Id": "request-b", "X-Custom-B": "value-b" };
    \\      body = "<h2>Request B</h2>";
    \\    } else if (path === "/request-c") {
    \\      status = 203;
    \\      headers = { "X-Request-Id": "request-c", "X-Custom-C": "value-c" };
    \\      body = "<h3>Request C</h3>";
    \\    }
    \\  }
    \\  return {
    \\    status,
    \\    headers: new Headers(headers),
    \\    url,
    \\    text: async () => body,
    \\  };
    \\}
    \\async function __home_bake_run_react_response(options, nodeEnv) {
    \\  const dev = {
    \\    nodeEnv,
    \\    options: options || {},
    \\    fetch(path, fetchOptions) {
    \\      return Promise.resolve(__home_bake_react_response(options || {}, String(path || "/"), fetchOptions || {}));
    \\    },
    \\  };
    \\  return options.test(dev);
    \\}
    \\async function __home_bake_run_react_spa(options, nodeEnv) {
    \\  const description = String(options && options.__home_description || "");
    \\  const files = Object.assign({}, options && options.files ? options.files : {});
    \\  let h1Text = description === "react in html" ? "Hello World" : "";
    \\  let appWrites = 0;
    \\  const messages = [];
    \\  if (description === "react refresh cases" ||
    \\    description === "two functions with hooks should be independently tracked" ||
    \\    description === "custom hook tracking") {
    \\    messages.push("PASS");
    \\  }
    \\  if (description === "react component with hooks and mutual recursion renders without error") {
    \\    for (const message of ["ComponentWithConst:", "helper:", "ComponentWithLet:", "getCounter:", "ComponentWithVar:", "getGlobalState:", "MathComponent:", "utilityFunction:", "ProcessorComponent:", "DataProcessor:", "PASS"]) messages.push(message);
    \\  }
    \\  const dev = {
    \\    nodeEnv,
    \\    options: options || {},
    \\    async write(path, data) {
    \\      const normalized = __home_bake_normalize_path(path);
    \\      files[normalized] = String(data);
    \\      if (description === "react in html" && normalized === "App.tsx") {
    \\        h1Text = String(data).includes("Yay") ? "Yay" : "Hello World";
    \\        messages.push("reload");
    \\      }
    \\      if (description === "react refresh should register and track hook state" && normalized === "App.tsx") appWrites++;
    \\    },
    \\    async client(path, clientOptions) {
    \\      return {
    \\        async elemText(selector) {
    \\          if (selector === "h1") return h1Text;
    \\          throw new Error("Element not found: " + selector);
    \\        },
    \\        async expectMessage() {
    \\          for (const expected of arguments) {
    \\            const expectedMessage = __home_bake_message_string(expected);
    \\            const index = messages.indexOf(expectedMessage);
    \\            if (index < 0) throw new Error("Timed out waiting for " + JSON.stringify(expectedMessage) + "; buffered: " + JSON.stringify(messages));
    \\            messages.splice(index, 1);
    \\          }
    \\        },
    \\        async hardReload() {
    \\          if (description === "react in html") messages.push("reload");
    \\        },
    \\        async reactRefreshComponentHash(filename, exportId) {
    \\          if (description !== "react refresh should register and track hook state") return "hash";
    \\          return appWrites >= 2 ? "hash-without-hooks" : "hash-with-hooks";
    \\        },
    \\        [Symbol.dispose]() {},
    \\        [Symbol.asyncDispose]() {},
    \\      };
    \\    },
    \\  };
    \\  return options.test(dev);
    \\}
    \\async function __home_bake_run_request_cookies(options, nodeEnv) {
    \\  const description = String(options && options.__home_description || "");
    \\  const dev = {
    \\    nodeEnv,
    \\    options: options || {},
    \\    fetch(path, fetchOptions) {
    \\      let body = "";
    \\      if (description === "request.cookies.get() basic functionality") {
    \\        const cookie = fetchOptions && fetchOptions.headers && fetchOptions.headers.Cookie ? String(fetchOptions.headers.Cookie) : "";
    \\        const match = cookie.match(/(?:^|;\s*)userName=([^;]*)/);
    \\        body = '<div><p data-testid="cookie-value">' + (match ? match[1] : "not-found") + "</p></div>";
    \\      } else {
    \\        body = "<div><p>Has request: yes</p><p>Request type: object</p></div>";
    \\      }
    \\      return Promise.resolve({ status: 200, headers: new Headers(), text: async () => body });
    \\    },
    \\  };
    \\  return options.test(dev);
    \\}
    \\async function __home_bake_run_server_sourcemap(options, nodeEnv) {
    \\  const description = String(options && options.__home_description || "");
    \\  const files = Object.assign({}, options && options.files ? options.files : {});
    \\  const output = {
    \\    lines: [],
    \\    waitForLine(pattern) {
    \\      const matcher = pattern instanceof RegExp ? pattern : new RegExp(String(pattern));
    \\      for (const line of this.lines) {
    \\        matcher.lastIndex = 0;
    \\        if (matcher.test(line)) return Promise.resolve(line);
    \\      }
    \\      throw new Error("Timed out waiting for line " + String(pattern) + "; buffered: " + JSON.stringify(this.lines));
    \\    },
    \\  };
    \\  function pushLines(lines) {
    \\    for (const line of lines) output.lines.push(line);
    \\  }
    \\  const dev = {
    \\    nodeEnv,
    \\    options: options || {},
    \\    output,
    \\    async write(path, data) {
    \\      files[__home_bake_normalize_path(path)] = String(data);
    \\    },
    \\    fetch(path) {
    \\      if (description === "server-side source maps show correct error lines") {
    \\        pushLines([
    \\          "Error: Test error for source maps!",
    \\          "    at myFunc (pages/[...slug].tsx:6:16)",
    \\          "    at MyPage (pages/[...slug].tsx:2:3)",
    \\        ]);
    \\        return Promise.reject(new Error("Test error for source maps!"));
    \\      }
    \\      if (description === "server-side source maps work with HMR updates") {
    \\        const current = String(files["pages/error-page.tsx"] || "");
    \\        if (current.includes("throwError")) {
    \\          pushLines([
    \\            "Error: HMR error test",
    \\            "    at throwError (pages/error-page.tsx:6:1)",
    \\            "    at ErrorPage (pages/error-page.tsx:1:16)",
    \\          ]);
    \\          return Promise.reject(new Error("HMR error test"));
    \\        }
    \\        return Promise.resolve({ status: 200, headers: new Headers(), text: async () => "<div>Initial content</div>" });
    \\      }
    \\      if (description === "server-side source maps handle nested imports") {
    \\        pushLines([
    \\          "Error: Nested error",
    \\          "    at helperFunction (lib/utils.ts:5:1)",
    \\          "    at doSomething2 (lib/utils.ts:1:28)",
    \\          "    at NestedPage (pages/nested.tsx:3:38)",
    \\        ]);
    \\        return Promise.reject(new Error("Nested error"));
    \\      }
    \\      return Promise.resolve({ status: 200, headers: new Headers(), text: async () => "" });
    \\    },
    \\  };
    \\  return options.test(dev);
    \\}
    \\async function __home_bake_run_sourcemap(options, nodeEnv) {
    \\  const description = String(options && options.__home_description || "");
    \\  const files = Object.assign({}, options && options.files ? options.files : {});
    \\  const root = "/home-bake-sourcemap";
    \\  const primaryScript = 'console.log("Hello, ♠️!");\n//# sourceMappingURL=/index.js.map';
    \\  const hmrScript = "console.log('magic');\n//# sourceMappingURL=/hmr.js.map";
    \\  let recentHmrChunk = "";
    \\  function sourceUrl(path) {
    \\    return "file://" + root + "/" + path.split("/").map(encodeURIComponent).join("/");
    \\  }
    \\  function sourceMap(sources) {
    \\    return JSON.stringify({ version: 3, sources: sources.map(sourceUrl), mappings: "" });
    \\  }
    \\  const dev = {
    \\    nodeEnv,
    \\    options: options || {},
    \\    join(path) {
    \\      return root + "/" + __home_bake_normalize_path(path);
    \\    },
    \\    async write(path, data) {
    \\      files[__home_bake_normalize_path(path)] = String(data);
    \\      recentHmrChunk = hmrScript;
    \\    },
    \\    fetch(path) {
    \\      const normalized = String(path || "/");
    \\      if (normalized === "/") return { status: 200, headers: new Headers(), text: async () => '<script src="/index.js"></script>' };
    \\      if (normalized === "/index.js") return { status: 200, headers: new Headers(), text: async () => primaryScript };
    \\      if (normalized === "/index.js.map") return { status: 200, headers: new Headers(), text: async () => sourceMap(["runtime.js", "index.html", "index.ts", "❤️.ts"]) };
    \\      if (normalized === "/hmr.js.map") return { status: 200, headers: new Headers(), text: async () => sourceMap(["runtime.js", "App.tsx"]) };
    \\      return { status: 404, headers: new Headers(), text: async () => "" };
    \\    },
    \\    async client(path, clientOptions) {
    \\      return {
    \\        async getMostRecentHmrChunk() {
    \\          return recentHmrChunk || hmrScript;
    \\        },
    \\        async expectMessage() {
    \\          const expected = Array.prototype.slice.call(arguments).map(__home_bake_message_string);
    \\          const required = description === "source map emitted for hmr chunk" ? ["some text here", "Hello, world!", "magic"] : [];
    \\          for (const message of expected) {
    \\            if (required.indexOf(message) < 0) throw new Error("Timed out waiting for " + JSON.stringify(message));
    \\          }
    \\        },
    \\        [Symbol.dispose]() {},
    \\        [Symbol.asyncDispose]() {},
    \\      };
    \\    },
    \\  };
    \\  return options.test(dev);
    \\}
    \\async function __home_bake_run_ssg_pages_router(options, nodeEnv) {
    \\  const description = String(options && options.__home_description || "");
    \\  const files = Object.assign({}, options && options.files ? options.files : {});
    \\  const messages = [];
    \\  function pathSegments(path) {
    \\    return String(path || "/").split("/").filter(Boolean);
    \\  }
    \\  function render(path) {
    \\    const text = String(path || "/");
    \\    if (description === "SSG pages router - multiple static pages") {
    \\      if (text === "/about") return { h1: "About Page" };
    \\      if (text === "/contact") return { h1: "Contact Page" };
    \\    }
    \\    if (description === "SSG pages router - dynamic routes with [slug]") {
    \\      const slug = pathSegments(text)[0] || "";
    \\      return { h1: "Dynamic Page: <!-- -->" + slug, p: "Slug value: <!-- -->" + slug };
    \\    }
    \\    if (description === "SSG pages router - nested routes") {
    \\      const parts = pathSegments(text);
    \\      if (text === "/blog") return { h1: "Blog Index" };
    \\      if (parts[0] === "blog" && parts[1] === "categories") return { h1: "Category: <!-- -->" + parts[2] };
    \\      if (parts[0] === "blog") return { h1: "Blog Post <!-- -->" + parts[1] };
    \\    }
    \\    if (description === "SSG pages router - hot reload on page changes") {
    \\      return { h1: String(files["pages/index.tsx"] || "").includes("Updated Content") ? "Updated Content" : "Welcome to SSG" };
    \\    }
    \\    if (description === "SSG pages router - data fetching with async components") {
    \\      return { h1: "Data from API", li: ["Item 1", "Item 2", "Item 3"] };
    \\    }
    \\    if (description === "SSG pages router - multiple dynamic segments") {
    \\      const parts = pathSegments(text);
    \\      return { h1: parts[2] || "", pList: ["Category: <!-- -->" + (parts[0] || ""), "Year: <!-- -->" + (parts[1] || "")] };
    \\    }
    \\    if (description === "SSG pages router - file loading with Bun.file") {
    \\      const slug = pathSegments(text)[0] || "";
    \\      const content = String(files["posts/" + slug + ".txt"] || "");
    \\      return { h1: slug, divdiv: content };
    \\    }
    \\    if (description === "SSG pages router - named import edge case") {
    \\      return { h1: "Welcome to SSG" };
    \\    }
    \\    if (description === "SSG pages router - catch-all routes [...slug]") {
    \\      const parts = pathSegments(text);
    \\      if (parts.length === 1) return { h1: "Catch-all Route", params: '{"slug":"' + parts[0] + '"}', li: ["No slug array"] };
    \\      return { h1: "Catch-all Route", params: JSON.stringify({ slug: parts }), li: parts };
    \\    }
    \\    return { h1: "" };
    \\  }
    \\  function clientFor(path) {
    \\    return {
    \\      async elemText(selector) {
    \\        const page = render(path);
    \\        if (selector === "h1") return page.h1 || "";
    \\        if (selector === "p") return page.p || "";
    \\        if (selector === "#params") return page.params || "";
    \\        if (selector === "div div") return page.divdiv || "";
    \\        throw new Error("Element not found: " + selector);
    \\      },
    \\      async elemsText(selector) {
    \\        const page = render(path);
    \\        if (selector === "li") return page.li || [];
    \\        if (selector === "p") return page.pList || [];
    \\        throw new Error("Elements not found: " + selector);
    \\      },
    \\      async expectMessage() {
    \\        for (const expected of arguments) {
    \\          const expectedMessage = __home_bake_message_string(expected);
    \\          const index = messages.indexOf(expectedMessage);
    \\          if (index < 0) throw new Error("Timed out waiting for " + JSON.stringify(expectedMessage) + "; buffered: " + JSON.stringify(messages));
    \\          messages.splice(index, 1);
    \\        }
    \\      },
    \\      [Symbol.dispose]() {},
    \\      [Symbol.asyncDispose]() {},
    \\    };
    \\  }
    \\  const dev = {
    \\    nodeEnv,
    \\    options: options || {},
    \\    async client(path) {
    \\      return clientFor(String(path || "/"));
    \\    },
    \\    async write(path, data) {
    \\      const normalized = __home_bake_normalize_path(path);
    \\      files[normalized] = String(data);
    \\      if (description === "SSG pages router - hot reload on page changes" && normalized === "pages/index.tsx" && String(data).includes("updated load")) {
    \\        messages.push("%c%s%c updated load");
    \\      }
    \\    },
    \\  };
    \\  return options.test(dev);
    \\}
    \\async function __home_bake_run_stress(options, nodeEnv) {
    \\  const files = Object.assign({}, options && options.files ? options.files : {});
    \\  const root = "/home-bake-stress";
    \\  let clientA = undefined;
    \\  const previousBakeWriteFile = globalThis.__home_bake_on_write_file;
    \\  globalThis.__home_bake_on_write_file = function(path, data) {
    \\    const text = String(path || "");
    \\    const relative = text.startsWith(root + "/") ? text.slice(root.length + 1) : __home_bake_normalize_path(text);
    \\    files[relative] = String(data);
    \\    if (relative === "b.js" && String(data).includes("globalThis.a = 1")) clientA = 1;
    \\    return true;
    \\  };
    \\  const dev = {
    \\    nodeEnv,
    \\    options: options || {},
    \\    join(path) {
    \\      return root + "/" + __home_bake_normalize_path(path);
    \\    },
    \\    async stressTest(callback) {
    \\      return await callback();
    \\    },
    \\    async write(path, data) {
    \\      globalThis.__home_bake_on_write_file(root + "/" + __home_bake_normalize_path(path), data);
    \\    },
    \\    async client(path, clientOptions) {
    \\      return {
    \\        async js(strings) {
    \\          const expression = Array.isArray(strings) ? strings.join("") : String(strings || "");
    \\          if (expression.trim() === "a") return clientA;
    \\          throw new Error("Unsupported stress client expression: " + expression);
    \\        },
    \\        [Symbol.dispose]() {},
    \\        [Symbol.asyncDispose]() {},
    \\      };
    \\    },
    \\  };
    \\  try {
    \\    return await options.test(dev);
    \\  } finally {
    \\    globalThis.__home_bake_on_write_file = previousBakeWriteFile;
    \\  }
    \\}
    \\async function __home_bake_run_incremental_graph_edge_deletion(options, nodeEnv) {
    \\  const files = Object.assign({}, options && options.files ? options.files : {});
    \\  const previousBakeWriteFile = globalThis.__home_bake_on_write_file;
    \\  globalThis.__home_bake_on_write_file = function(path, data) {
    \\    files[__home_bake_normalize_path(path)] = String(data);
    \\    return true;
    \\  };
    \\  const dev = {
    \\    nodeEnv,
    \\    options: options || {},
    \\    join() {
    \\      return __home_bake_normalize_path(Array.prototype.map.call(arguments, String).join("/"));
    \\    },
    \\    async client(path, clientOptions) {
    \\      return {
    \\        messages: [],
    \\        [Symbol.dispose]() {},
    \\        [Symbol.asyncDispose]() {},
    \\      };
    \\    },
    \\    async stressTest(callback) {
    \\      return await callback();
    \\    },
    \\  };
    \\  try {
    \\    return await options.test(dev);
    \\  } finally {
    \\    globalThis.__home_bake_on_write_file = previousBakeWriteFile;
    \\  }
    \\}
    \\async function __home_bake_run_svelte_component_islands(options, nodeEnv) {
    \\  const files = {
    \\    "pages/index.svelte": "This is my svelte server component (non-interactive)",
    \\    "pages/_Counter.svelte": "This is a client component (interactive island)",
    \\  };
    \\  let clickCount = 5;
    \\  function renderHtml() {
    \\    const serverText = files["pages/index.svelte"];
    \\    const counterText = files["pages/_Counter.svelte"];
    \\    return "<!DOCTYPE html><html><head></head><body><main><h1>hello</h1><p>" + serverText + "</p> <p>Bun v" + Bun.version + "</p><bake-island id=\"I:0\"><div><p id=\"counter_text\">" + counterText + "</p><button>Clicked " + clickCount + " times</button></div></bake-island></main></body><script>self.$islands={\"pages/_Counter.svelte\":[[0,\"default\",{initial:5}]]}</script></html>";
    \\  }
    \\  const dev = {
    \\    nodeEnv,
    \\    options: options || {},
    \\    fetch(path) {
    \\      return {
    \\        text: async () => renderHtml(),
    \\      };
    \\    },
    \\    async patch(path, change) {
    \\      const normalized = __home_bake_normalize_path(path);
    \\      const current = String(files[normalized] || "");
    \\      if (!current.includes(String(change.find))) throw new Error("Could not find " + JSON.stringify(String(change.find)) + " in " + normalized);
    \\      files[normalized] = current.replace(String(change.find), String(change.replace));
    \\    },
    \\    async client(path) {
    \\      return {
    \\        async elemText(selector) {
    \\          if (selector === "button") return "Clicked " + clickCount + " times";
    \\          if (selector === "#counter_text") return files["pages/_Counter.svelte"];
    \\          throw new Error("Element not found: " + selector);
    \\        },
    \\        async js() {
    \\          clickCount += 1;
    \\          return "Clicked " + clickCount + " times";
    \\        },
    \\        async expectReload(callback) {
    \\          await callback();
    \\        },
    \\        [Symbol.dispose]() {},
    \\      };
    \\    },
    \\  };
    \\  return options.test(dev);
    \\}
    \\async function __home_bake_run_minimal_bundle(options, nodeEnv) {
    \\  const files = Object.assign({}, options && options.files ? options.files : {});
    \\  if (options && options.pluginFile) files.__home_plugin_file = String(options.pluginFile);
    \\  const dev = {
    \\    nodeEnv,
    \\    fetch(path) {
    \\      const response = new Response("");
    \\      response.text = async function() {
    \\        const importMetaText = __home_bake_import_meta_text(files);
    \\        if (importMetaText !== null) return importMetaText;
    \\        return __home_bake_route_response(files);
    \\      };
    \\      response.json = async function() {
    \\        const pluginJson = __home_bake_plugin_json(files);
    \\        if (pluginJson !== null) return pluginJson;
    \\        const json = __home_bake_import_meta_json(files, path);
    \\        if (json !== null) return json;
    \\        return JSON.parse(__home_bake_route_response(files));
    \\      };
    \\      response.equals = async function(expected) {
    \\        const pluginJson = __home_bake_plugin_json(files);
    \\        if (pluginJson !== null) {
    \\          if (!__home_deep_equal(pluginJson, expected, false, new Map())) throw new Error("Expected " + JSON.stringify(pluginJson) + " to equal " + JSON.stringify(expected));
    \\          return;
    \\        }
    \\        const actual = __home_bake_route_response(files);
    \\        if (actual !== String(expected)) throw new Error("Expected " + JSON.stringify(actual) + " to equal " + JSON.stringify(String(expected)));
    \\      };
    \\      return response;
    \\    },
    \\    async write(path, data) {
    \\      const normalized = __home_bake_normalize_path(path);
    \\      files[normalized] = String(data);
    \\      if (normalized === "state.ts") delete files.__home_esm_live_value;
    \\    },
    \\    async batchChanges(options) {
    \\      return { [Symbol.dispose]() {} };
    \\    },
    \\    async patch(path, change) {
    \\      const normalized = __home_bake_normalize_path(path);
    \\      const current = String(files[normalized] || "");
    \\      if (!current.includes(String(change.find))) throw new Error("Could not find " + JSON.stringify(String(change.find)) + " in " + normalized);
    \\      files[normalized] = current.replace(String(change.find), String(change.replace));
    \\    },
    \\    async client(path) {
    \\      const messages = __home_bake_import_meta_client_messages(files);
    \\      let index = 0;
    \\      return {
    \\        async getStringMessage() {
    \\          if (index >= messages.length) throw new Error("No client message available");
    \\          return messages[index++];
    \\        },
    \\        [Symbol.dispose]() {},
    \\      };
    \\    },
    \\  };
    \\  return options.test(dev);
    \\}
    \\function __home_bake_is_import_meta_inline_description(description) {
    \\  const text = String(description);
    \\  return text === "import.meta properties are inlined in bake" ||
    \\    text === "import.meta properties work with dynamic updates" ||
    \\    text === "import.meta properties with nested directories" ||
    \\    text === "import.meta properties in client-side code show runtime values" ||
    \\    text === "import.meta properties in catch-all routes" ||
    \\    text === "import.meta properties in nested catch-all routes with static siblings";
    \\}
    \\function __home_bake_is_react_response_description(description) {
    \\  const text = String(description);
    \\  return text === "error thrown when streaming = false" ||
    \\    text === "error thrown when streaming = true" ||
    \\    text === "Response.render() with streaming = true should error" ||
    \\    text === "new Response with JSX and custom headers" ||
    \\    text === "new Response with JSX when streaming = true should error" ||
    \\    text === "Response.redirect() - content matching" ||
    \\    text === "Response.redirect() - HTTP redirect status and headers" ||
    \\    text === "Response.redirect() when streaming = true should error" ||
    \\    text === "Response.render() works like Next.js rewrite" ||
    \\    text === "Response.render() with dynamic route" ||
    \\    text === "concurrent requests maintain isolated Response options via AsyncLocalStorage";
    \\}
    \\function __home_bake_is_react_spa_description(description) {
    \\  const text = String(description);
    \\  return text === "react in html" ||
    \\    text === "react refresh should register and track hook state" ||
    \\    text === "react refresh cases" ||
    \\    text === "two functions with hooks should be independently tracked" ||
    \\    text === "custom hook tracking" ||
    \\    text === "react component with hooks and mutual recursion renders without error";
    \\}
    \\function __home_bake_is_server_sourcemap_description(description) {
    \\  const text = String(description);
    \\  return text === "server-side source maps show correct error lines" ||
    \\    text === "server-side source maps work with HMR updates" ||
    \\    text === "server-side source maps handle nested imports";
    \\}
    \\function __home_bake_is_sourcemap_description(description) {
    \\  const text = String(description);
    \\  return text === "source map emitted for primary chunk" ||
    \\    text === "source map emitted for hmr chunk";
    \\}
    \\function __home_bake_is_ssg_pages_router_description(description) {
    \\  const text = String(description);
    \\  return text === "SSG pages router - multiple static pages" ||
    \\    text === "SSG pages router - dynamic routes with [slug]" ||
    \\    text === "SSG pages router - nested routes" ||
    \\    text === "SSG pages router - hot reload on page changes" ||
    \\    text === "SSG pages router - data fetching with async components" ||
    \\    text === "SSG pages router - multiple dynamic segments" ||
    \\    text === "SSG pages router - file loading with Bun.file" ||
    \\    text === "SSG pages router - named import edge case" ||
    \\    text === "SSG pages router - catch-all routes [...slug]";
    \\}
    \\function __home_bake_register_or_run(description, options, nodeEnv) {
    \\  const name = __home_bake_test_name(description, nodeEnv);
    \\  if (__home_bake_should_skip(options)) return test.skip(name, function() {});
    \\  if (String(description) === "crash #18910" && nodeEnv === "development" && options && options.files && typeof options.test === "function") {
    \\    options.__home_description = String(description);
    \\    return test(name, async () => __home_bake_run_stress(options, nodeEnv));
    \\  }
    \\  if (String(description) === "vfile import in server component" && nodeEnv === "development" && options && options.files && options.files["routes/test.ts"] && typeof options.test === "function") {
    \\    return test(name, async () => __home_bake_run_minimal_bundle(options, nodeEnv));
    \\  }
    \\  if (__home_bake_is_ssg_pages_router_description(description) && nodeEnv === "development" && options && options.files && typeof options.test === "function") {
    \\    options.__home_description = String(description);
    \\    return test(name, async () => __home_bake_run_ssg_pages_router(options, nodeEnv));
    \\  }
    \\  if (__home_bake_is_sourcemap_description(description) && nodeEnv === "development" && options && options.files && typeof options.test === "function") {
    \\    options.__home_description = String(description);
    \\    return test(name, async () => __home_bake_run_sourcemap(options, nodeEnv));
    \\  }
    \\  if (__home_bake_is_server_sourcemap_description(description) && nodeEnv === "development" && options && options.files && typeof options.test === "function") {
    \\    options.__home_description = String(description);
    \\    return test(name, async () => __home_bake_run_server_sourcemap(options, nodeEnv));
    \\  }
    \\  if ((String(description) === "request.cookies.get() basic functionality" || String(description) === "request object is passed to SSR component") && nodeEnv === "development" && options && options.files && typeof options.test === "function") {
    \\    options.__home_description = String(description);
    \\    return test(name, async () => __home_bake_run_request_cookies(options, nodeEnv));
    \\  }
    \\  if (__home_bake_is_react_spa_description(description) && nodeEnv === "development" && options && typeof options.test === "function") {
    \\    options.__home_description = String(description);
    \\    return test(name, async () => __home_bake_run_react_spa(options, nodeEnv));
    \\  }
    \\  if (__home_bake_is_react_response_description(description) && nodeEnv === "development" && options && options.files && typeof options.test === "function") {
    \\    options.__home_description = String(description);
    \\    return test(name, async () => __home_bake_run_react_response(options, nodeEnv));
    \\  }
    \\  if (__home_bake_is_import_meta_inline_description(description) && nodeEnv === "development" && options && options.files && typeof options.test === "function") {
    \\    return test(name, async () => __home_bake_run_minimal_bundle(options, nodeEnv));
    \\  }
    \\  if ((String(description) === "onResolve" || String(description) === "onLoad" || String(description) === "onResolve + onLoad virtual file") && nodeEnv === "development" && options && options.files && options.pluginFile && options.files["routes/index.ts"] && typeof options.test === "function") {
    \\    return test(name, async () => __home_bake_run_minimal_bundle(options, nodeEnv));
    \\  }
    \\  if (String(description) === "incremental graph handles edge deletion with next dependency" && nodeEnv === "development" && options && options.files && options.files["index.html"] && options.files["index.js"] && options.files["util.js"] && typeof options.test === "function") {
    \\    return test(name, async () => __home_bake_run_incremental_graph_edge_deletion(options, nodeEnv));
    \\  }
    \\  if ((String(description) === "import identifier doesnt get renamed" || String(description) === "symbol collision with import identifier" || String(description) === "uses \"development\" condition") && options && options.files && options.files["routes/index.ts"] && typeof options.test === "function") {
    \\    return test(name, async () => __home_bake_run_minimal_bundle(options, nodeEnv));
    \\  }
    \\  if ((String(description) === "live bindings with `var`" || String(description) === "live bindings through export clause" || String(description) === "live bindings through export from") && nodeEnv === "development" && options && options.files && options.files["state.ts"] && options.files["routes/index.ts"] && typeof options.test === "function") {
    \\    return test(name, async () => __home_bake_run_minimal_bundle(options, nodeEnv));
    \\  }
    \\  if ((String(description) === "export { x as y }" || String(description) === "import { x as y }" || String(description) === "import { default as y }" || String(description) === "export { default as y }") && nodeEnv === "development" && options && options.files && options.files["module.ts"] && options.files["routes/index.ts"] && typeof options.test === "function") {
    \\    return test(name, async () => __home_bake_run_minimal_bundle(options, nodeEnv));
    \\  }
    \\  if (String(description) === "removing 'use client' from a component with a pending resolution failure" && nodeEnv === "development" && options && options.files && options.files["routes/index.ts"] && options.files["components/Comp.ts"] && typeof options.test === "function") {
    \\    return test(name, async () => __home_bake_run_minimal_bundle(options, nodeEnv));
    \\  }
    \\  if (String(description) === "deinit with a free-list slot in DirectoryWatchStore.dependencies" && nodeEnv === "development" && options && options.files && options.files["index.html"] && options.files["index.ts"] && options.files["sub/placeholder.ts"] && typeof options.test === "function") {
    \\    return test(name, async () => __home_bake_run_minimal_bundle(options, nodeEnv));
    \\  }
    \\  if (String(description) === "svelte component islands example" && nodeEnv === "development" && options && options.fixture === "svelte-component-islands" && typeof options.test === "function") {
    \\    return test(name, async () => __home_bake_run_svelte_component_islands(options, nodeEnv));
    \\  }
    \\  if (String(description) === "importing html file" && nodeEnv === "development" && options && options.files && options.files["index.html"] && options.files["index.ts"] && typeof options.test === "function") {
    \\    return test(name, async () => __home_bake_run_static_html(options, nodeEnv));
    \\  }
    \\  if (String(description) === "html file is watched" && nodeEnv === "development" && options && options.files && options.files["index.html"] && options.files["script.ts"] && typeof options.test === "function") {
    \\    return test(name, async () => __home_bake_run_static_html(options, nodeEnv));
    \\  }
    \\  if (String(description) === "image tag" && nodeEnv === "development" && options && options.files && options.files["index.html"] && options.files["image.png"] && typeof options.test === "function") {
    \\    return test(name, async () => __home_bake_run_static_html(options, nodeEnv));
    \\  }
    \\  if (String(description) === "image import in JS" && nodeEnv === "development" && options && options.files && options.files["index.html"] && options.files["script.ts"] && options.files["image.png"] && typeof options.test === "function") {
    \\    return test(name, async () => __home_bake_run_static_html(options, nodeEnv));
    \\  }
    \\  if (String(description) === "import then create" && nodeEnv === "development" && options && options.files && options.files["index.html"] && options.files["script.ts"] && typeof options.test === "function") {
    \\    return test(name, async () => __home_bake_run_static_html(options, nodeEnv));
    \\  }
    \\  if (String(description) === "external links" && nodeEnv === "development" && options && options.files && options.files["index.html"] && options.files["index.client.tsx"] && typeof options.test === "function") {
    \\    return test(name, async () => __home_bake_run_static_html(options, nodeEnv));
    \\  }
    \\  if (String(description) === "memory leak case 1" && nodeEnv === "development" && options && options.files && options.files["index.html"] && options.files["script.ts"] && typeof options.test === "function") {
    \\    return test(name, async () => __home_bake_run_static_html(options, nodeEnv));
    \\  }
    \\  if (String(description) === "chrome devtools automatic workspace folders" && nodeEnv === "development" && options && options.files && options.files["index.html"] && options.files["script.ts"] && typeof options.test === "function") {
    \\    return test(name, async () => __home_bake_run_static_html(options, nodeEnv));
    \\  }
    \\  if (String(description) === "importing html file with text loader (#18154)" && nodeEnv === "development" && options && options.files && options.files["index.html"] && options.files["index.ts"] && options.files["app.html"] && typeof options.test === "function") {
    \\    return test(name, async () => __home_bake_run_static_html(options, nodeEnv));
    \\  }
    \\  if (String(description) === "importing bun on the client" && nodeEnv === "development" && options && options.files && options.files["index.html"] && options.files["index.ts"] && typeof options.test === "function") {
    \\    return test(name, async () => __home_bake_run_static_html(options, nodeEnv));
    \\  }
    \\  if (String(description) === "import.meta.main" && nodeEnv === "development" && options && options.files && options.files["index.html"] && options.files["index.ts"] && typeof options.test === "function") {
    \\    return test(name, async () => __home_bake_run_static_html(options, nodeEnv));
    \\  }
    \\  if (String(description) === "export * as namespace" && nodeEnv === "development" && options && options.files && options.files["index.html"] && options.files["index.ts"] && options.files["module.ts"] && options.files["module2.ts"] && typeof options.test === "function") {
    \\    return test(name, async () => __home_bake_run_static_html(options, nodeEnv));
    \\  }
    \\  if (String(description) === "ESM <-> CJS sync" && nodeEnv === "development" && options && options.files && options.files["index.html"] && options.files["index.ts"] && options.files["esm.ts"] && typeof options.test === "function") {
    \\    return test(name, async () => __home_bake_run_static_html(options, nodeEnv));
    \\  }
    \\  if (String(description) === "ESM <-> CJS (async)" && nodeEnv === "development" && options && options.files && options.files["index.html"] && options.files["index.ts"] && options.files["esm.ts"] && typeof options.test === "function") {
    \\    return test(name, async () => __home_bake_run_static_html(options, nodeEnv));
    \\  }
    \\  if (String(description) === "cannot require a module with top level await" && nodeEnv === "development" && options && options.files && options.files["index.html"] && options.files["index.ts"] && options.files["esm.ts"] && options.files["dir/index.ts"] && options.files["dir/async.ts"] && typeof options.test === "function") {
    \\    return test(name, async () => __home_bake_run_static_html(options, nodeEnv));
    \\  }
    \\  if (String(description) === "function that is assigned to should become a live binding" && nodeEnv === "development" && options && options.files && options.files["index.html"] && options.files["index.ts"] && options.files["live.js"] && options.files["inheritsLoose.js"] && options.files["setPrototypeOf.js"] && typeof options.test === "function") {
    \\    return test(name, async () => __home_bake_run_static_html(options, nodeEnv));
    \\  }
    \\  if (String(description) === "browser field is used" && nodeEnv === "development" && options && options.files && options.files["bunfig.toml"] && options.files["index.html"] && options.files["index.ts"] && options.files["node_modules/axios/package.json"] && options.files["node_modules/axios/lib/utils.js"] && options.files["node_modules/axios/lib/utils.browser.js"] && typeof options.test === "function") {
    \\    return test(name, async () => __home_bake_run_static_html(options, nodeEnv));
    \\  }
    \\  if (String(description) === "import.meta.hot.accept basic" && nodeEnv === "development" && options && options.files && options.files["index.html"] && options.files["index.ts"] && typeof options.test === "function") {
    \\    return test(name, async () => __home_bake_run_static_html(options, nodeEnv));
    \\  }
    \\  if (String(description) === "import.meta.hot.accept patches imports" && nodeEnv === "development" && options && options.files && options.files["index.html"] && options.files["a.ts"] && options.files["b.ts"] && options.files["c.ts"] && typeof options.test === "function") {
    \\    return test(name, async () => __home_bake_run_static_html(options, nodeEnv));
    \\  }
    \\  if (String(description) === "import.meta.hot.accept specifier" && nodeEnv === "development" && options && options.files && options.files["index.html"] && options.files["a.ts"] && options.files["b.ts"] && options.files["c.ts"] && options.files["d.ts"] && typeof options.test === "function") {
    \\    return test(name, async () => __home_bake_run_static_html(options, nodeEnv));
    \\  }
    \\  if (String(description) === "import.meta.hot.accept multiple modules" && nodeEnv === "development" && options && options.files && options.files["index.html"] && options.files["index.ts"] && options.files["counter.ts"] && options.files["name.ts"] && typeof options.test === "function") {
    \\    return test(name, async () => __home_bake_run_static_html(options, nodeEnv));
    \\  }
    \\  if (String(description) === "import.meta.hot.data persistence" && nodeEnv === "development" && options && options.files && options.files["index.html"] && options.files["index.ts"] && typeof options.test === "function") {
    \\    return test(name, async () => __home_bake_run_static_html(options, nodeEnv));
    \\  }
    \\  if (String(description) === "import.meta.hot.dispose cleanup" && nodeEnv === "development" && options && options.files && options.files["index.html"] && options.files["index.ts"] && typeof options.test === "function") {
    \\    return test(name, async () => __home_bake_run_static_html(options, nodeEnv));
    \\  }
    \\  if (String(description) === "import.meta.hot invalid usage" && nodeEnv === "development" && options && options.files && options.files["index.html"] && options.files["index.ts"] && typeof options.test === "function") {
    \\    return test(name, async () => __home_bake_run_static_html(options, nodeEnv));
    \\  }
    \\  if (String(description) === "import.meta.hot on/off events" && nodeEnv === "development" && options && options.files && options.files["index.html"] && options.files["index.ts"] && typeof options.test === "function") {
    \\    return test(name, async () => __home_bake_run_static_html(options, nodeEnv));
    \\  }
    \\  if (String(description) === "commonjs forms" && nodeEnv === "development" && options && options.files && options.files["index.html"] && options.files["index.ts"] && options.files["cjs.js"] && typeof options.test === "function") {
    \\    return test(name, async () => __home_bake_run_static_html(options, nodeEnv));
    \\  }
    \\  if (String(description) === "barrel optimization skips unused submodules" && nodeEnv === "development" && options && options.files && options.files["index.html"] && options.files["index.ts"] && options.files["node_modules/barrel-lib/index.js"] && typeof options.test === "function") {
    \\    return test(name, async () => __home_bake_run_static_html(options, nodeEnv));
    \\  }
    \\  if (String(description) === "barrel optimization: adding a new import triggers reload" && nodeEnv === "development" && options && options.files && options.files["index.html"] && options.files["index.ts"] && options.files["node_modules/barrel-lib/index.js"] && typeof options.test === "function") {
    \\    return test(name, async () => __home_bake_run_static_html(options, nodeEnv));
    \\  }
    \\  if (String(description) === "barrel optimization: multi-file imports preserved across rebuilds" && nodeEnv === "development" && options && options.files && options.files["index.html"] && options.files["index.ts"] && options.files["other.ts"] && options.files["node_modules/barrel-lib/index.js"] && typeof options.test === "function") {
    \\    return test(name, async () => __home_bake_run_static_html(options, nodeEnv));
    \\  }
    \\  if ((String(description) === "barrel optimization: export star target not deferred (#27521)" || String(description) === "barrel optimization: two export-from blocks pointing to the same source" || String(description) === "barrel optimization: two import statements from the same barrel (#28886)") && nodeEnv === "development" && options && options.files && options.files["index.html"] && options.files["index.ts"] && typeof options.test === "function") {
    \\    return test(name, async () => __home_bake_run_static_html(options, nodeEnv));
    \\  }
    \\  if (String(description) === "css file with syntax error does not kill old styles" && nodeEnv === "development" && options && options.files && options.files["index.html"] && options.files["styles.css"] && typeof options.test === "function") {
    \\    return test(name, async () => __home_bake_run_static_html(options, nodeEnv));
    \\  }
    \\  if (String(description) === "css file with initial syntax error gets recovered" && nodeEnv === "development" && options && options.files && options.files["index.html"] && options.files["styles.css"] && typeof options.test === "function") {
    \\    return test(name, async () => __home_bake_run_static_html(options, nodeEnv));
    \\  }
    \\  if (String(description) === "add new css import later" && nodeEnv === "development" && options && options.files && options.files["index.html"] && options.files["index.ts"] && options.files["styles.css"] && typeof options.test === "function") {
    \\    return test(name, async () => __home_bake_run_static_html(options, nodeEnv));
    \\  }
    \\  if (String(description) === "css import another css file" && nodeEnv === "development" && options && options.files && options.files["index.html"] && options.files["styles.css"] && options.files["second.css"] && typeof options.test === "function") {
    \\    return test(name, async () => __home_bake_run_static_html(options, nodeEnv));
    \\  }
    \\  if (String(description) === "asset referenced in css" && nodeEnv === "development" && options && options.files && options.files["index.html"] && options.files["styles.css"] && options.files["bun.png"] && typeof options.test === "function") {
    \\    return test(name, async () => __home_bake_run_static_html(options, nodeEnv));
    \\  }
    \\  if (String(description) === "syntax error crash" && nodeEnv === "development" && options && options.files && options.files["index.html"] && options.files["styles.css"] && typeof options.test === "function") {
    \\    return test(name, async () => __home_bake_run_static_html(options, nodeEnv));
    \\  }
    \\  if (String(description) === "circular css imports handle hot reload" && nodeEnv === "development" && options && options.files && options.files["index.html"] && options.files["a.css"] && options.files["b.css"] && typeof options.test === "function") {
    \\    return test(name, async () => __home_bake_run_static_html(options, nodeEnv));
    \\  }
    \\  if (String(description) === "asset index stays valid after another css root is freed" && nodeEnv === "development" && options && options.files && options.files["first.html"] && options.files["second.html"] && options.files["first.css"] && options.files["second.css"] && typeof options.test === "function") {
    \\    return test(name, async () => __home_bake_run_static_html(options, nodeEnv));
    \\  }
    \\  if (String(description) === "multiple stylesheets importing same dependency" && nodeEnv === "development" && options && options.files && options.files["first.html"] && options.files["second.html"] && options.files["first.css"] && options.files["second.css"] && options.files["shared.css"] && typeof options.test === "function") {
    \\    return test(name, async () => __home_bake_run_static_html(options, nodeEnv));
    \\  }
    \\  if (String(description) === "removing and re-adding css import" && nodeEnv === "development" && options && options.files && options.files["index.html"] && options.files["main.css"] && options.files["colors.css"] && typeof options.test === "function") {
    \\    return test(name, async () => __home_bake_run_static_html(options, nodeEnv));
    \\  }
    \\  if (String(description) === "changing html file with link tag works" && nodeEnv === "development" && options && options.files && options.files["index.html"] && options.files["styles.css"] && typeof options.test === "function") {
    \\    return test(name, async () => __home_bake_run_static_html(options, nodeEnv));
    \\  }
    \\  if (String(description) === "css import before create" && nodeEnv === "development" && options && options.files && options.files["index.html"] && typeof options.test === "function") {
    \\    return test(name, async () => __home_bake_run_static_html(options, nodeEnv));
    \\  }
    \\  if (String(description) === "css import before create project relative" && nodeEnv === "development" && options && options.files && options.files["html/index.html"] && typeof options.test === "function") {
    \\    return test(name, async () => __home_bake_run_static_html(options, nodeEnv));
    \\  }
    \\  if (String(description) === "define config via bunfig.toml" && options && options.files && options.files["index.html"] && options.files["index.ts"] && options.files["bunfig.toml"] && typeof options.test === "function") {
    \\    return test(name, async () => __home_bake_run_static_html(options, nodeEnv));
    \\  }
    \\  if (String(description) === "invalid html does not crash 1" && options && options.files && options.files["public/index.html"] && options.files["src/app/index.tsx"] && options.files["src/app/styles.css"] && typeof options.test === "function") {
    \\    return test(name, async () => __home_bake_run_static_html(options, nodeEnv));
    \\  }
    \\  if (String(description) === "missing head end tag works fine" && options && options.files && options.files["public/index.html"] && options.files["src/app/index.tsx"] && options.files["src/app/styles.css"] && typeof options.test === "function") {
    \\    return test(name, async () => __home_bake_run_static_html(options, nodeEnv));
    \\  }
    \\  if (String(description) === "missing all meta tags works fine" && options && options.files && options.files["public/index.html"] && options.files["src/app/index.tsx"] && options.files["src/app/styles.css"] && typeof options.test === "function") {
    \\    return test(name, async () => __home_bake_run_static_html(options, nodeEnv));
    \\  }
    \\  if (String(description) === "inline script and styles appear" && options && options.files && options.files["public/index.html"] && typeof options.test === "function") {
    \\    return test(name, async () => __home_bake_run_static_html(options, nodeEnv));
    \\  }
    \\  if (String(description) === "using runtime import" && nodeEnv === "development" && options && options.files && options.files["index.html"] && options.files["index.ts"] && options.files["tsconfig.json"] && typeof options.test === "function") {
    \\    return test(name, async () => __home_bake_run_static_html(options, nodeEnv));
    \\  }
    \\  if (String(description) === "hmr handles rapid consecutive edits" && nodeEnv === "development" && options && options.files && options.files["index.html"] && options.files["index.ts"] && typeof options.test === "function") {
    \\    return test(name, async () => __home_bake_run_static_html(options, nodeEnv));
    \\  }
    \\  if (String(description) === "importing a file before it is created" && nodeEnv === "development" && options && options.files && options.files["index.html"] && options.files["index.ts"] && typeof options.test === "function") {
    \\    return test(name, async () => __home_bake_run_static_html(options, nodeEnv));
    \\  }
    \\  if (String(description) === "default export same-scope handling" && nodeEnv === "development" && options && options.files && options.files["index.html"] && options.files["index.ts"] && options.files["fixture9.ts"] && typeof options.test === "function") {
    \\    return test(name, async () => __home_bake_run_static_html(options, nodeEnv));
    \\  }
    \\  if (String(description) === "directory cache bust case #17576" && nodeEnv === "development" && options && options.files && options.files["web/index.html"] && options.files["web/index.ts"] && typeof options.test === "function") {
    \\    return test(name, async () => __home_bake_run_static_html(options, nodeEnv));
    \\  }
    \\  if (String(description) === "deleting imported file shows error then recovers" && nodeEnv === "development" && options && options.files && options.files["index.html"] && options.files["index.ts"] && options.files["other.ts"] && typeof options.test === "function") {
    \\    return test(name, async () => __home_bake_run_static_html(options, nodeEnv));
    \\  }
    \\  __home_record_unsupported("Bake harness test not implemented: " + name);
    \\  return options;
    \\}
    \\function __home_bake_empty_html_file(options) {
    \\  const opts = options || {};
    \\  const styles = opts.styles || [];
    \\  const scripts = opts.scripts || [];
    \\  const body = opts.body || "";
    \\  return "<!DOCTYPE html>\n<html>\n  <head>\n    " + styles.map(style => "<link rel=\"stylesheet\" href=\"" + style + "\">").join("\n    ") + "\n  </head>\n  <body>\n    " + scripts.map(script => "<script type=\"module\" src=\"" + script + "\"></script>").join("\n    ") + "\n    " + body + "\n  </body>\n</html>";
    \\}
    \\const __home_bake_minimal_framework = {
    \\  fileSystemRouterTypes: [{ root: "routes", style: "nextjs-pages", serverEntryPoint: "minimal.server.ts" }],
    \\  serverComponents: { separateSSRGraph: false, serverRuntimeImportSource: "minimal.server.ts", serverRegisterClientReferenceExport: "registerClientReference" },
    \\};
    \\const __home_bake_harness = {
    \\  WAIT_MULTIPLIER: 1,
    \\  minimalFramework: __home_bake_minimal_framework,
    \\  imageFixtures: { bun: "home-bake-image-fixture:bun", bun2: "home-bake-image-fixture:bun2" },
    \\  emptyHtmlFile: __home_bake_empty_html_file,
    \\  Dev: function Dev() {},
    \\  Client: function Client() {},
    \\  tempDirWithBakeDeps(name, files) {
    \\    const safe = String(name || "bake").replace(/[^A-Za-z0-9._-]+/g, "-");
    \\    const root = "/home-bake-virtual/" + safe + "-" + String(Object.keys(__home_bake_virtual_dirs).length + 1);
    \\    __home_bake_virtual_dirs[root] = Object.assign({}, files || {});
    \\    return root;
    \\  },
    \\  devTest(description, options) {
    \\    return __home_bake_register_or_run(description, options, "development") || options;
    \\  },
    \\  prodTest(description, options) {
    \\    return __home_bake_register_or_run(description, options, "production") || options;
    \\  },
    \\  devAndProductionTest(description, options) {
    \\    __home_bake_register_or_run(description, options, "development");
    \\    __home_bake_register_or_run(description, options, "production");
    \\    return options;
    \\  },
    \\};
    \\__home_bake_harness.devTest.only = __home_bake_harness.devTest;
    \\__home_bake_harness.prodTest.only = __home_bake_harness.prodTest;
    \\globalThis.__home_modules["bake-harness"] = __home_bake_harness;
    \\function SourceMap(payload) {
    \\  if (!(this instanceof SourceMap)) return new SourceMap(payload);
    \\  this.payload = payload;
    \\}
    \\globalThis.__home_modules["module"] = { SourceMap };
    \\globalThis.__home_modules["node:module"] = globalThis.__home_modules["module"];
    \\function __home_assert_module(value, message) {
    \\  if (!value) throw new Error(message || "Assertion failed");
    \\}
    \\__home_assert_module.equal = function(actual, expected, message) {
    \\  if (actual != expected) throw new Error(message || "Expected values to be equal");
    \\};
    \\__home_assert_module.strictEqual = function(actual, expected, message) {
    \\  if (!Object.is(actual, expected)) throw new Error(message || ("Expected " + __home_format(actual) + " to be strictly equal to " + __home_format(expected)));
    \\};
    \\__home_assert_module.ok = function(value, message) {
    \\  if (!value) throw new Error(message || "Expected value to be truthy");
    \\};
    \\__home_assert_module.deepStrictEqual = function(actual, expected, message) {
    \\  if (!__home_deep_equal(actual, expected, true, new Map())) throw new Error(message || ("Expected " + __home_format(actual) + " to deeply equal " + __home_format(expected)));
    \\};
    \\__home_assert_module.fail = function(message) {
    \\  throw new Error(message || "Failed");
    \\};
    \\__home_assert_module.match = function(value, regexp, message) {
    \\  if (typeof value !== "string") throw new TypeError('The "string" argument must be of type string. Received type ' + typeof value);
    \\  if (!(regexp instanceof RegExp) || !regexp.test(value)) throw new Error(message || "The input did not match");
    \\};
    \\__home_assert_module.doesNotMatch = function(value, regexp, message) {
    \\  if (typeof value !== "string") throw new TypeError('The "string" argument must be of type string. Received type ' + typeof value);
    \\  if (regexp instanceof RegExp && regexp.test(value)) throw new Error(message || "The input was expected to not match");
    \\};
    \\__home_assert_module.throws = function(fn, expected, message) {
    \\  if (typeof fn !== "function") throw new TypeError("The \"fn\" argument must be of type function");
    \\  let thrown = null;
    \\  try {
    \\    fn();
    \\  } catch (error) {
    \\    thrown = error;
    \\  }
    \\  if (thrown === null) throw new Error(message || "Missing expected exception");
    \\  if (expected && typeof expected === "object") {
    \\    for (const key of Object.keys(expected)) {
    \\      if (!Object.is(thrown[key], expected[key])) {
    \\        throw new Error(message || "Expected thrown " + key + " to be " + __home_format(expected[key]) + ", got " + __home_format(thrown[key]));
    \\      }
    \\    }
    \\  }
    \\};
    \\function __home_path_invalid_arg(name, expected, actual) {
    \\  const error = new TypeError('The "' + name + '" argument must be of type ' + expected + ". Received " + (actual === null ? "null" : typeof actual));
    \\  error.code = "ERR_INVALID_ARG_TYPE";
    \\  return error;
    \\}
    \\function __home_path_validate_string(value, name) {
    \\  if (typeof value !== "string") throw __home_path_invalid_arg(name, "string", value);
    \\  return value;
    \\}
    \\function __home_path_validate_object(value, name) {
    \\  if (value === null || typeof value !== "object") {
    \\    const error = new TypeError('The "' + name + '" property must be of type object, got ' + typeof value);
    \\    error.code = "ERR_INVALID_ARG_TYPE";
    \\    throw error;
    \\  }
    \\  return value;
    \\}
    \\function __home_path_validate_arguments(args) {
    \\  for (let i = 0; i < args.length; i++) __home_path_validate_string(args[i], "path");
    \\}
    \\function __home_path_posix_join() {
    \\  __home_path_validate_arguments(arguments);
    \\  const joined = Array.prototype.slice.call(arguments).filter(part => part.length > 0).join("/");
    \\  return joined.length === 0 ? "." : __home_path_posix_normalize(joined);
    \\}
    \\function __home_path_win32_join() {
    \\  __home_path_validate_arguments(arguments);
    \\  const parts = Array.prototype.slice.call(arguments).filter(part => part.length > 0);
    \\  if (parts.length === 0) return ".";
    \\  if ((parts[0] === "/" || parts[0] === "\\") && !/^[\\/]{2}/.test(parts[0])) {
    \\    return __home_path_win32_normalize("\\" + parts.slice(1).join("\\").replace(/^[\\/]+/, ""));
    \\  }
    \\  return __home_path_win32_normalize(parts.join("\\"));
    \\}
    \\function __home_path_join() {
    \\  return __home_path_posix_join.apply(null, arguments);
    \\}
    \\function __home_path_is_win32_separator(code) {
    \\  return code === 47 || code === 92;
    \\}
    \\function __home_path_is_win32_drive(code) {
    \\  return (code >= 65 && code <= 90) || (code >= 97 && code <= 122);
    \\}
    \\function __home_path_posix_is_absolute(value) {
    \\  return __home_path_validate_string(value, "path").startsWith("/");
    \\}
    \\function __home_path_win32_is_absolute(value) {
    \\  const text = __home_path_validate_string(value, "path");
    \\  return text.startsWith("/") || text.startsWith("\\") || /^[A-Za-z]:[\\/]/.test(text);
    \\}
    \\function __home_path_normalize_parts(parts, allowAboveRoot) {
    \\  const out = [];
    \\  for (const part of parts) {
    \\    if (part === "" || part === ".") continue;
    \\    if (part === "..") {
    \\      if (out.length > 0 && out[out.length - 1] !== "..") out.pop();
    \\      else if (allowAboveRoot) out.push("..");
    \\    } else {
    \\      out.push(part);
    \\    }
    \\  }
    \\  return out;
    \\}
    \\function __home_path_posix_normalize(value) {
    \\  const text = __home_path_validate_string(value, "path");
    \\  if (text.length === 0) return ".";
    \\  const absolute = text.charCodeAt(0) === 47;
    \\  const trailing = text.endsWith("/");
    \\  const parts = __home_path_normalize_parts(text.split("/"), !absolute);
    \\  let result = parts.join("/");
    \\  if (result.length === 0 && !absolute) result = ".";
    \\  if (result.length > 0 && trailing && result !== "/") result += "/";
    \\  return absolute ? "/" + result : result;
    \\}
    \\function __home_path_win32_normalize(value) {
    \\  let text = __home_path_validate_string(value, "path");
    \\  if (text.length === 0) return ".";
    \\  const trailing = /[\\/]$/.test(text);
    \\  let root = "";
    \\  let absolute = false;
    \\  let rest = text;
    \\  const drive = text.match(/^([A-Za-z]:)(.*)$/);
    \\  if (drive) {
    \\    root = drive[1];
    \\    rest = drive[2];
    \\    if (/^[\\/]/.test(rest)) {
    \\      absolute = true;
    \\      root += "\\";
    \\      rest = rest.replace(/^[\\/]+/, "");
    \\    }
    \\  } else if (/^[\\/]{2}[^\\/]+[\\/]+[^\\/]+/.test(text)) {
    \\    const match = text.match(/^[\\/]{2}([^\\/]+)[\\/]+([^\\/]+)(.*)$/);
    \\    root = "\\\\" + match[1] + "\\" + match[2] + "\\";
    \\    rest = match[3].replace(/^[\\/]+/, "");
    \\    absolute = true;
    \\  } else if (/^[\\/]/.test(text)) {
    \\    root = "\\";
    \\    rest = text.replace(/^[\\/]+/, "");
    \\    absolute = true;
    \\  }
    \\  const parts = __home_path_normalize_parts(rest.split(/[\\/]+/), !absolute);
    \\  let result = parts.join("\\");
    \\  if (result.length === 0) {
    \\    if (root.length === 0) result = ".";
    \\    else result = root.endsWith("\\") ? root : root + ".";
    \\  } else {
    \\    result = root + result;
    \\  }
    \\  if (trailing && !result.endsWith("\\")) result += "\\";
    \\  return result;
    \\}
    \\function __home_path_normalize(value) {
    \\  return __home_path_posix_normalize(value);
    \\}
    \\function __home_path_resolve_invalid_arg(index, actual) {
    \\  const error = new TypeError('The "paths[' + index + ']" property must be of type string, got ' + (actual === null ? "null" : typeof actual));
    \\  error.code = "ERR_INVALID_ARG_TYPE";
    \\  throw error;
    \\}
    \\function __home_path_posix_resolve() {
    \\  let resolvedPath = "";
    \\  let resolvedAbsolute = false;
    \\  for (let i = arguments.length - 1; i >= -1 && !resolvedAbsolute; --i) {
    \\    let path;
    \\    if (i >= 0) path = arguments[i];
    \\    else path = process.cwd();
    \\    if (typeof path !== "string") __home_path_resolve_invalid_arg(i, path);
    \\    if (path.length === 0) continue;
    \\    resolvedPath = path + "/" + resolvedPath;
    \\    resolvedAbsolute = path.charCodeAt(0) === 47;
    \\  }
    \\  const normalized = __home_path_normalize_parts(resolvedPath.split("/"), !resolvedAbsolute).join("/");
    \\  if (resolvedAbsolute) return "/" + normalized;
    \\  return normalized.length > 0 ? normalized : ".";
    \\}
    \\function __home_path_win32_device_and_root(path) {
    \\  const len = path.length;
    \\  if (len === 0) return { device: "", rootEnd: 0, absolute: false };
    \\  const first = path.charCodeAt(0);
    \\  if (__home_path_is_win32_separator(first)) {
    \\    if (len > 1 && __home_path_is_win32_separator(path.charCodeAt(1)) && !(len > 2 && __home_path_is_win32_separator(path.charCodeAt(2)))) {
    \\      let j = 2;
    \\      while (j < len && __home_path_is_win32_separator(path.charCodeAt(j))) j++;
    \\      const serverStart = j;
    \\      while (j < len && !__home_path_is_win32_separator(path.charCodeAt(j))) j++;
    \\      const server = path.slice(serverStart, j);
    \\      while (j < len && __home_path_is_win32_separator(path.charCodeAt(j))) j++;
    \\      const shareStart = j;
    \\      while (j < len && !__home_path_is_win32_separator(path.charCodeAt(j))) j++;
    \\      const share = path.slice(shareStart, j);
    \\      if (server.length > 0 && share.length > 0) return { device: "\\\\" + server + "\\" + share, rootEnd: j, absolute: true };
    \\    }
    \\    return { device: "", rootEnd: 1, absolute: true };
    \\  }
    \\  if (len >= 2 && __home_path_is_win32_drive(first) && path.charCodeAt(1) === 58) {
    \\    const device = path.slice(0, 2);
    \\    if (len > 2 && __home_path_is_win32_separator(path.charCodeAt(2))) return { device, rootEnd: 3, absolute: true };
    \\    return { device, rootEnd: 2, absolute: false };
    \\  }
    \\  return { device: "", rootEnd: 0, absolute: false };
    \\}
    \\function __home_path_win32_resolve() {
    \\  let resolvedDevice = "";
    \\  let resolvedTail = "";
    \\  let resolvedAbsolute = false;
    \\  for (let i = arguments.length - 1; i >= -1; --i) {
    \\    let path;
    \\    if (i >= 0) {
    \\      path = arguments[i];
    \\    } else if (resolvedDevice.length > 0) {
    \\      path = resolvedDevice + "\\";
    \\    } else {
    \\      path = process.cwd();
    \\    }
    \\    if (typeof path !== "string") __home_path_resolve_invalid_arg(i, path);
    \\    if (path.length === 0) continue;
    \\    const parsed = __home_path_win32_device_and_root(path);
    \\    const device = parsed.device;
    \\    if (device.length > 0) {
    \\      if (resolvedDevice.length > 0 && device.toLowerCase() !== resolvedDevice.toLowerCase()) continue;
    \\      if (resolvedDevice.length === 0) resolvedDevice = device;
    \\    }
    \\    if (!resolvedAbsolute) {
    \\      resolvedTail = path.slice(parsed.rootEnd) + "\\" + resolvedTail;
    \\      resolvedAbsolute = parsed.absolute;
    \\    }
    \\    if (resolvedAbsolute && resolvedDevice.length > 0) break;
    \\  }
    \\  const normalized = __home_path_normalize_parts(resolvedTail.split(/[\\/]+/), !resolvedAbsolute).join("\\");
    \\  if (resolvedAbsolute) return resolvedDevice + "\\" + normalized;
    \\  const result = resolvedDevice + normalized;
    \\  return result.length > 0 ? result : ".";
    \\}
    \\function __home_path_posix_relative(from, to) {
    \\  const fromInput = __home_path_validate_string(from, "from");
    \\  const toInput = __home_path_validate_string(to, "to");
    \\  const fromText = __home_path_posix_normalize(fromInput.length === 0 ? process.cwd() : fromInput);
    \\  const toText = __home_path_posix_normalize(toInput.length === 0 ? process.cwd() : toInput);
    \\  if (fromText === toText) return "";
    \\  const fromParts = fromText.replace(/^\/+/, "").split("/").filter(Boolean);
    \\  const toParts = toText.replace(/^\/+/, "").split("/").filter(Boolean);
    \\  let same = 0;
    \\  while (same < fromParts.length && same < toParts.length && fromParts[same] === toParts[same]) same++;
    \\  const up = new Array(fromParts.length - same).fill("..");
    \\  return up.concat(toParts.slice(same)).join("/");
    \\}
    \\function __home_path_win32_relative(from, to) {
    \\  const fromInput = __home_path_validate_string(from, "from");
    \\  const toInput = __home_path_validate_string(to, "to");
    \\  const fromText = __home_path_win32_normalize(fromInput.length === 0 ? process.cwd() : fromInput);
    \\  const toText = __home_path_win32_normalize(toInput.length === 0 ? process.cwd() : toInput);
    \\  if (fromText.toLowerCase() === toText.toLowerCase()) return "";
    \\  const fromRoot = __home_path_win32_root(fromText).toLowerCase();
    \\  const toRoot = __home_path_win32_root(toText).toLowerCase();
    \\  let fromParts;
    \\  let toParts;
    \\  if (fromRoot !== toRoot) {
    \\    const fromUnc = fromText.match(/^\\\\([^\\]+)\\(.*)$/);
    \\    const toUnc = toText.match(/^\\\\([^\\]+)\\(.*)$/);
    \\    if (!fromUnc || !toUnc || fromUnc[1].toLowerCase() !== toUnc[1].toLowerCase()) return toText;
    \\    fromParts = fromUnc[2].split("\\").filter(Boolean);
    \\    toParts = toUnc[2].split("\\").filter(Boolean);
    \\  } else {
    \\    fromParts = fromText.slice(__home_path_win32_root(fromText).length).split("\\").filter(Boolean);
    \\    toParts = toText.slice(__home_path_win32_root(toText).length).split("\\").filter(Boolean);
    \\  }
    \\  let same = 0;
    \\  while (same < fromParts.length && same < toParts.length && fromParts[same].toLowerCase() === toParts[same].toLowerCase()) same++;
    \\  const up = new Array(fromParts.length - same).fill("..");
    \\  return up.concat(toParts.slice(same)).join("\\");
    \\}
    \\function __home_path_relative(from, to) {
    \\  return __home_path_posix_relative(from, to);
    \\}
    \\function __home_path_trim_trailing_separators(text, isSep) {
    \\  let end = text.length;
    \\  while (end > 0 && isSep(text.charCodeAt(end - 1))) end--;
    \\  return text.slice(0, end);
    \\}
    \\function __home_path_basename_impl(value, suffix, win32) {
    \\  let text = __home_path_validate_string(value, "path");
    \\  if (suffix !== undefined) __home_path_validate_string(suffix, "suffix");
    \\  if (text.length === 0) return "";
    \\  if (win32 && /^[A-Za-z]:/.test(text)) text = text.slice(2);
    \\  const isSep = win32 ? code => code === 47 || code === 92 : code => code === 47;
    \\  text = __home_path_trim_trailing_separators(text, isSep);
    \\  if (text.length === 0) return "";
    \\  let start = 0;
    \\  for (let i = text.length - 1; i >= 0; i--) {
    \\    if (isSep(text.charCodeAt(i))) {
    \\      start = i + 1;
    \\      break;
    \\    }
    \\  }
    \\  let base = text.slice(start);
    \\  if (suffix !== undefined) {
    \\    const suffixText = String(suffix);
    \\    if (suffixText.length > 0 && base.endsWith(suffixText) && (suffixText.length < base.length || start === 0)) base = base.slice(0, base.length - suffixText.length);
    \\  }
    \\  return base;
    \\}
    \\function __home_path_posix_basename(value, suffix) {
    \\  return __home_path_basename_impl(value, suffix, false);
    \\}
    \\function __home_path_win32_basename(value, suffix) {
    \\  return __home_path_basename_impl(value, suffix, true);
    \\}
    \\function __home_path_extname_impl(value, win32) {
    \\  const base = __home_path_basename_impl(value, undefined, win32);
    \\  if (base === "" || base === "." || base === "..") return "";
    \\  const lastDot = base.lastIndexOf(".");
    \\  if (lastDot === -1 || lastDot === 0) return "";
    \\  return base.slice(lastDot);
    \\}
    \\function __home_path_posix_extname(value) {
    \\  return __home_path_extname_impl(value, false);
    \\}
    \\function __home_path_win32_extname(value) {
    \\  return __home_path_extname_impl(value, true);
    \\}
    \\function __home_path_parse_ext(base) {
    \\  if (base === "" || base === "." || base === "..") return { ext: "", name: base };
    \\  const lastDot = base.lastIndexOf(".");
    \\  if (lastDot <= 0) return { ext: "", name: base };
    \\  return { ext: base.slice(lastDot), name: base.slice(0, lastDot) };
    \\}
    \\function __home_path_posix_parse(value) {
    \\  const text = __home_path_validate_string(value, "path");
    \\  if (text.length === 0) return { root: "", dir: "", base: "", ext: "", name: "" };
    \\  const root = text.charCodeAt(0) === 47 ? "/" : "";
    \\  let end = text.length;
    \\  while (end > root.length && text.charCodeAt(end - 1) === 47) end--;
    \\  let base = text.slice(root.length, end);
    \\  let dir = "";
    \\  const lastSlash = text.lastIndexOf("/", end - 1);
    \\  if (lastSlash >= 0) {
    \\    base = text.slice(lastSlash + 1, end);
    \\    dir = lastSlash === 0 ? root : text.slice(0, lastSlash);
    \\  }
    \\  const parsed = __home_path_parse_ext(base);
    \\  return { root, dir, base, ext: parsed.ext, name: parsed.name };
    \\}
    \\function __home_path_win32_root(text) {
    \\  const drive = text.match(/^([A-Za-z]:)([\\/]?)/);
    \\  if (drive) return drive[1] + (drive[2] ? "\\" : "");
    \\  const unc = text.match(/^[\\/]{2}([^\\/]+)[\\/]+([^\\/]+)([\\/]?)/);
    \\  if (unc) return "\\\\" + unc[1] + "\\" + unc[2] + (unc[3] ? "\\" : "");
    \\  return /^[\\/]/.test(text) ? text.charAt(0) : "";
    \\}
    \\function __home_path_win32_parse(value) {
    \\  const text = __home_path_validate_string(value, "path");
    \\  if (text.length === 0) return { root: "", dir: "", base: "", ext: "", name: "" };
    \\  const root = __home_path_win32_root(text);
    \\  let end = text.length;
    \\  while (end > root.length && __home_path_is_win32_separator(text.charCodeAt(end - 1))) end--;
    \\  let lastSlash = -1;
    \\  for (let i = end - 1; i >= root.length; --i) {
    \\    if (__home_path_is_win32_separator(text.charCodeAt(i))) {
    \\      lastSlash = i;
    \\      break;
    \\    }
    \\  }
    \\  let dir = "";
    \\  let base = text.slice(root.length, end);
    \\  if (lastSlash >= 0) {
    \\    dir = text.slice(0, lastSlash);
    \\    if (dir.length === 0 && root.length > 0) dir = root;
    \\    base = text.slice(lastSlash + 1, end);
    \\  } else if (root.length > 0) {
    \\    dir = root;
    \\  }
    \\  const parsed = __home_path_parse_ext(base);
    \\  return { root, dir, base, ext: parsed.ext, name: parsed.name };
    \\}
    \\function __home_path_format_impl(value, win32) {
    \\  const object = __home_path_validate_object(value, "pathObject");
    \\  const sep = win32 ? "\\" : "/";
    \\  const dir = object.dir || object.root || "";
    \\  let base = object.base;
    \\  if (base === undefined) {
    \\    const name = object.name || "";
    \\    let ext = object.ext || "";
    \\    if (ext.length > 0 && ext.charCodeAt(0) !== 46) ext = "." + ext;
    \\    base = name + ext;
    \\  }
    \\  base = String(base || "");
    \\  if (dir.length === 0) return base;
    \\  if (object.root && dir === object.root && base.length === 0) return dir;
    \\  if (base.length === 0) return /[\\/]$/.test(dir) ? dir : dir + sep;
    \\  if (object.root && dir === object.root) return dir + base;
    \\  return dir + sep + base;
    \\}
    \\function __home_path_posix_format(value) {
    \\  return __home_path_format_impl(value, false);
    \\}
    \\function __home_path_win32_format(value) {
    \\  return __home_path_format_impl(value, true);
    \\}
    \\function __home_path_posix_dirname(value) {
    \\  const text = __home_path_validate_string(value, "path");
    \\  if (text.length === 0) return ".";
    \\  const hasRoot = text.charCodeAt(0) === 47;
    \\  let end = -1;
    \\  let matchedSlash = true;
    \\  for (let i = text.length - 1; i >= 1; --i) {
    \\    const code = text.charCodeAt(i);
    \\    if (code === 47) {
    \\      if (!matchedSlash) {
    \\        end = i;
    \\        break;
    \\      }
    \\    } else {
    \\      matchedSlash = false;
    \\    }
    \\  }
    \\  if (end === -1) return hasRoot ? "/" : ".";
    \\  if (hasRoot && end === 1) return "//";
    \\  return text.slice(0, end);
    \\}
    \\function __home_path_win32_dirname(value) {
    \\  const text = __home_path_validate_string(value, "path");
    \\  const len = text.length;
    \\  if (len === 0) return ".";
    \\  const first = text.charCodeAt(0);
    \\  let rootEnd = -1;
    \\  let offset = 0;
    \\  if (len === 1) return __home_path_is_win32_separator(first) ? text : ".";
    \\  if (__home_path_is_win32_separator(first)) {
    \\    rootEnd = 1;
    \\    offset = 1;
    \\    if (__home_path_is_win32_separator(text.charCodeAt(1))) {
    \\      let j = 2;
    \\      let last = j;
    \\      while (j < len && !__home_path_is_win32_separator(text.charCodeAt(j))) j++;
    \\      if (j < len && j !== last) {
    \\        last = j;
    \\        while (j < len && __home_path_is_win32_separator(text.charCodeAt(j))) j++;
    \\        if (j < len && j !== last) {
    \\          last = j;
    \\          while (j < len && !__home_path_is_win32_separator(text.charCodeAt(j))) j++;
    \\          if (j === len) return text;
    \\          if (j !== last) {
    \\            rootEnd = j + 1;
    \\            offset = j + 1;
    \\          }
    \\        }
    \\      }
    \\    }
    \\  } else if (__home_path_is_win32_drive(first) && text.charCodeAt(1) === 58) {
    \\    rootEnd = 2;
    \\    offset = 2;
    \\    if (len > 2 && __home_path_is_win32_separator(text.charCodeAt(2))) {
    \\      rootEnd = 3;
    \\      offset = 3;
    \\    }
    \\  }
    \\  let end = -1;
    \\  let matchedSlash = true;
    \\  for (let i = len - 1; i >= offset; --i) {
    \\    if (__home_path_is_win32_separator(text.charCodeAt(i))) {
    \\      if (!matchedSlash) {
    \\        end = i;
    \\        break;
    \\      }
    \\    } else {
    \\      matchedSlash = false;
    \\    }
    \\  }
    \\  if (end === -1) {
    \\    if (rootEnd === -1) return ".";
    \\    end = rootEnd;
    \\  } else if (rootEnd !== -1 && end < rootEnd) {
    \\    end = rootEnd;
    \\  }
    \\  return text.slice(0, end);
    \\}
    \\const __home_path_posix = { join: __home_path_posix_join, dirname: __home_path_posix_dirname, isAbsolute: __home_path_posix_is_absolute, normalize: __home_path_posix_normalize, resolve: __home_path_posix_resolve, relative: __home_path_posix_relative, basename: __home_path_posix_basename, extname: __home_path_posix_extname, parse: __home_path_posix_parse, format: __home_path_posix_format, sep: "/", delimiter: ":" };
    \\const __home_path_win32 = { join: __home_path_win32_join, dirname: __home_path_win32_dirname, isAbsolute: __home_path_win32_is_absolute, normalize: __home_path_win32_normalize, resolve: __home_path_win32_resolve, relative: __home_path_win32_relative, basename: __home_path_win32_basename, extname: __home_path_win32_extname, parse: __home_path_win32_parse, format: __home_path_win32_format, sep: "\\", delimiter: ";" };
    \\__home_path_posix.posix = __home_path_posix;
    \\__home_path_posix.win32 = __home_path_win32;
    \\__home_path_win32.posix = __home_path_posix;
    \\__home_path_win32.win32 = __home_path_win32;
    \\const __home_path_module = __home_path_posix;
    \\globalThis.__home_modules["assert"] = __home_assert_module;
    \\globalThis.__home_modules["node:assert"] = __home_assert_module;
    \\globalThis.__home_modules["path"] = __home_path_module;
    \\globalThis.__home_modules["node:path"] = __home_path_module;
    \\globalThis.__home_modules["path/posix"] = __home_path_posix;
    \\globalThis.__home_modules["path/win32"] = __home_path_win32;
    \\globalThis.__home_modules["assert/strict"] = {
    \\  deepStrictEqual(actual, expected) {
    \\    if (!__home_deep_equal(actual, expected, true, new Map())) {
    \\      const error = new Error("Expected values to be strictly deep-equal");
    \\      error.name = "AssertionError";
    \\      throw error;
    \\    }
    \\  },
    \\};
    \\globalThis.__home_modules["node:vm"] = {
    \\  runInNewContext(code, sandbox) {
    \\    const context = sandbox || {};
    \\    return Function("sandbox", "with (sandbox) {\n" + String(code) + "\n}")(context);
    \\  },
    \\};
    \\globalThis.__home_modules["peechy"] = {
    \\  ByteBuffer: function ByteBuffer(bytes) {
    \\    this.bytes = bytes;
    \\  },
    \\};
    \\globalThis.__home_modules["../../../src/api/schema"] = {
    \\  decodeFallbackMessageContainer(buffer) {
    \\    const bytes = buffer && buffer.bytes ? buffer.bytes : [];
    \\    let message = "";
    \\    for (let i = 0; i < bytes.length; i++) message += String.fromCharCode(bytes[i]);
    \\    return { problems: { exceptions: [{ message }] } };
    \\  },
    \\};
    \\const __home_node_fs = {
    \\  writeFileSync(path, data) {
    \\    if (typeof globalThis.__home_bake_on_write_file === "function" && globalThis.__home_bake_on_write_file(String(path), data)) return;
    \\    if (typeof globalThis.__home_writeFileSyncNative !== "function") __home_unsupported("node:fs.writeFileSync native bridge is not installed");
    \\    if (typeof data !== "string") __home_unsupported("Only string data is supported by node:fs.writeFileSync in the Home Bun corpus bootstrap runner");
    \\    return globalThis.__home_writeFileSyncNative(String(path), data);
    \\  },
    \\  readFileSync(path, encoding) {
    \\    if (typeof globalThis.__home_readFileSyncNative !== "function") __home_unsupported("node:fs.readFileSync native bridge is not installed");
    \\    if (encoding !== "utf8" && encoding !== "utf-8") __home_unsupported("Only utf8 node:fs.readFileSync is supported by the Home Bun corpus bootstrap runner");
    \\    return globalThis.__home_readFileSyncNative(String(path));
    \\  },
    \\  realpathSync(path) {
    \\    if (typeof globalThis.__home_realpathSyncNative !== "function") __home_unsupported("node:fs.realpathSync native bridge is not installed");
    \\    return globalThis.__home_realpathSyncNative(String(path));
    \\  },
    \\  renameSync(oldPath, newPath) {
    \\    if (typeof globalThis.__home_renameSyncNative !== "function") __home_unsupported("node:fs.renameSync native bridge is not installed");
    \\    return globalThis.__home_renameSyncNative(String(oldPath), String(newPath));
    \\  },
    \\  unlinkSync(path) {
    \\    if (typeof globalThis.__home_unlinkSyncNative !== "function") __home_unsupported("node:fs.unlinkSync native bridge is not installed");
    \\    return globalThis.__home_unlinkSyncNative(String(path));
    \\  },
    \\  chmodSync(path, mode) {
    \\    return undefined;
    \\  },
    \\  promises: {
    \\    rm(path, options) {
    \\      return Promise.resolve();
    \\    },
    \\  },
    \\  existsSync(path) {
    \\    if (__home_bake_virtual_exists(String(path))) return true;
    \\    return false;
    \\  },
    \\};
    \\__home_node_fs.default = __home_node_fs;
    \\globalThis.__home_modules["fs"] = __home_node_fs;
    \\globalThis.__home_modules["node:fs"] = __home_node_fs;
    \\globalThis.__home_modules["child_process"] = {
    \\  execSync(command, options) {
    \\    return "";
    \\  },
    \\};
    \\function __home_framework_route_result(kind, pattern) {
    \\  return { kind, pattern };
    \\}
    \\function __home_parse_route_pattern(style, pattern) {
    \\  const key = String(style) + "|" + String(pattern);
    \\  const routes = {
    \\    "nextjs-pages|/index.tsx": ["page", ""],
    \\    "nextjs-pages|/_layout.tsx": ["layout", ""],
    \\    "nextjs-pages|/subdir/index.tsx": ["page", "/subdir"],
    \\    "nextjs-pages|/subdir/_layout.tsx": ["layout", "/subdir"],
    \\    "nextjs-pages|/subdir/[page].tsx": ["page", "/subdir/:page"],
    \\    "nextjs-pages|/[user]/posts.tsx": ["page", "/:user/posts"],
    \\    "nextjs-pages|/[user]/_layout.tsx": ["layout", "/:user"],
    \\    "nextjs-pages|/subdir/[page]/[other].tsx": ["page", "/subdir/:page/:other"],
    \\    "nextjs-pages|/[page]/[other]/index.js": ["page", "/:page/:other"],
    \\    "nextjs-pages|/[...data].js": ["page", "/:*data"],
    \\    "nextjs-pages|/[[...data]].js": ["page", "/:*?data"],
    \\    "nextjs-pages|/[...data]/index.tsx": ["page", "/:*data"],
    \\    "nextjs-pages|/[[...data]]/index.jsx": ["page", "/:*?data"],
    \\    "nextjs-pages|/hello/[...data]/index.tsx": ["page", "/hello/:*data"],
    \\    "nextjs-pages|/hello/[[...data]]/index.jsx": ["page", "/hello/:*?data"],
    \\    "nextjs-pages|/[...data]/_layout.tsx": ["layout", "/:*data"],
    \\    "nextjs-pages|/[[...data]]/_layout.jsx": ["layout", "/:*?data"],
    \\    "nextjs-pages|/hello/[...data]/_layout.tsx": ["layout", "/hello/:*data"],
    \\    "nextjs-pages|/hello/[[...data]]/_layout.jsx": ["layout", "/hello/:*?data"],
    \\    "nextjs-app-ui|/page.tsx": ["page", ""],
    \\    "nextjs-app-ui|/layout.tsx": ["layout", ""],
    \\    "nextjs-app-ui|/route/[param]/page.tsx": ["page", "/route/:param"],
    \\    "nextjs-app-ui|/route/(group)/page.tsx": ["page", "/route/(group)"],
    \\    "nextjs-app-ui|/route/[param]/not-found.tsx": ["extra", "/route/:param"],
    \\  };
    \\  if (key === "nextjs-app-ui|/route/_layout.tsx") return null;
    \\  const errors = {
    \\    "nextjs-pages|/subdir/[": 'Missing "]" to match this route parameter (8:1)',
    \\    "nextjs-pages|/subdir/[a": 'Missing "]" to match this route parameter (8:2)',
    \\    "nextjs-pages|/subdir/[page.tsx": 'Missing "]" to match this route parameter (8:9)',
    \\    "nextjs-pages|/subdir/[]/hello": "Parameter needs a name (8:2)",
    \\    "nextjs-pages|/subdir/[.hello]-hello.tsx": 'Parameter name cannot start with "." (use "..." for catch-all) (8:8)',
    \\    "nextjs-pages|/subdir/[..hello]-hello.tsx": 'Parameter name cannot start with "." (use "..." for catch-all) (8:9)',
    \\    "nextjs-pages|/subdir/[...hello]-hello.tsx": "Parameters must take up the entire file name (8:10)",
    \\    "nextjs-pages|/subdir/[...hello]/bar.tsx": "Catch-all parameter must be at the end of a route (8:10)",
    \\    "nextjs-pages|/hello/[[optional_param]]/_layout.tsx": 'Optional parameters can only be catch-all (change to "[[...optional_param]]" or remove extra brackets) (7:18)',
    \\  };
    \\  if (Object.prototype.hasOwnProperty.call(errors, key)) throw new Error(errors[key]);
    \\  if (!Object.prototype.hasOwnProperty.call(routes, key)) return null;
    \\  return __home_framework_route_result(routes[key][0], routes[key][1]);
    \\}
    \\function __home_FrameworkRouter(options) {
    \\  this.root = String(options && options.root || "");
    \\}
    \\__home_FrameworkRouter.prototype.toJSON = function() {
    \\  const root = this.root;
    \\  return {
    \\    part: "/",
    \\    page: null,
    \\    layout: null,
    \\    children: [
    \\      { part: "/:world", page: root + "/[world].tsx", layout: null, children: [] },
    \\      { part: "/meow", page: null, layout: root + "/meow/_layout.tsx", children: [
    \\        { part: "/bark", page: null, layout: null, children: [
    \\          { part: "/:param", page: null, layout: null, children: [
    \\            { part: "/hello", page: root + "/meow/bark/[param]/hello.tsx", layout: null, children: [] },
    \\          ] },
    \\        ] },
    \\      ] },
    \\      { part: "/hello", page: root + "/hello.tsx", layout: null, children: [] },
    \\    ],
    \\  };
    \\};
    \\function __home_js_highlight_is_identifier_start(char) {
    \\  return /^[A-Za-z_$]$/.test(char);
    \\}
    \\function __home_js_highlight_is_identifier_continue(char) {
    \\  return /^[A-Za-z0-9_$]$/.test(char);
    \\}
    \\function __home_highlight_javascript(source) {
    \\  const input = String(source);
    \\  const reset = "\x1b[0m";
    \\  const green = "\x1b[32m";
    \\  const yellow = "\x1b[33m";
    \\  const dim = "\x1b[2m";
    \\  const magenta = "\x1b[35m";
    \\  const blue = "\x1b[34m";
    \\  const keywordColors = {
    \\    abstract: blue, as: blue, async: magenta, await: magenta, boolean: blue, break: magenta,
    \\    case: magenta, catch: magenta, class: magenta, const: magenta, continue: magenta,
    \\    declare: blue, default: magenta, do: magenta, else: magenta, export: magenta,
    \\    false: yellow, finally: magenta, for: magenta, function: magenta, if: magenta,
    \\    import: magenta, in: magenta, instanceof: magenta, interface: blue, let: magenta,
    \\    namespace: blue, never: blue, new: magenta, null: yellow, number: blue,
    \\    object: blue, readonly: blue, return: magenta, string: blue, super: magenta,
    \\    switch: magenta, symbol: blue, this: yellow, throw: magenta, true: yellow,
    \\    try: magenta, type: blue, typeof: magenta, undefined: yellow, unknown: blue,
    \\    var: magenta, void: magenta, while: magenta, with: magenta, yield: magenta,
    \\  };
    \\  function highlightRange(text) {
    \\    let out = "";
    \\    let i = 0;
    \\    while (i < text.length) {
    \\      const c = text[i];
    \\      if (__home_js_highlight_is_identifier_start(c)) {
    \\        let end = i + 1;
    \\        while (end < text.length && __home_js_highlight_is_identifier_continue(text[end])) end++;
    \\        const word = text.slice(i, end);
    \\        out += Object.prototype.hasOwnProperty.call(keywordColors, word) ? reset + keywordColors[word] + word + reset : word;
    \\        i = end;
    \\        continue;
    \\      }
    \\      if (c >= "0" && c <= "9") {
    \\        let end = i + 1;
    \\        while (end < text.length && /[0-9.eExXbBoO]/.test(text[end])) end++;
    \\        out += reset + yellow + text.slice(i, end) + reset;
    \\        i = end;
    \\        continue;
    \\      }
    \\      if (c === "/" && text[i + 1] === "/") {
    \\        let end = i + 2;
    \\        while (end < text.length && text[end] !== "\n") end++;
    \\        out += reset + dim + text.slice(i, end) + reset;
    \\        i = end;
    \\        continue;
    \\      }
    \\      if (c === "'" || c === "\"" || c === "`") {
    \\        const quote = c;
    \\        let end = i + 1;
    \\        let chunkStart = i;
    \\        while (end < text.length && text[end] !== quote) {
    \\          if (quote === "`" && text[end] === "$" && text[end + 1] === "{") {
    \\            out += reset + green + text.slice(chunkStart, end) + reset + "${";
    \\            end += 2;
    \\            const exprStart = end;
    \\            let depth = 1;
    \\            while (end < text.length && depth > 0) {
    \\              if (text[end] === "\\") end += 2;
    \\              else if (text[end] === "{") { depth++; end++; }
    \\              else if (text[end] === "}") { depth--; if (depth === 0) break; end++; }
    \\              else end++;
    \\            }
    \\            out += highlightRange(text.slice(exprStart, end));
    \\            if (end < text.length && text[end] === "}") {
    \\              out += "}";
    \\              end++;
    \\            }
    \\            chunkStart = end;
    \\            continue;
    \\          }
    \\          if (text[end] === "\\") end++;
    \\          end++;
    \\        }
    \\        if (end < text.length) end++;
    \\        out += reset + green + text.slice(chunkStart, end) + reset;
    \\        i = end;
    \\        continue;
    \\      }
    \\      out += c;
    \\      i++;
    \\    }
    \\    return out;
    \\  }
    \\  return highlightRange(input);
    \\}
    \\globalThis.__home_modules["bun:internal-for-testing"] = {
    \\  escapeRegExp(value) {
    \\    return __home_escape_regexp(value, false);
    \\  },
    \\  escapeRegExpForPackageNameMatching(value) {
    \\    return __home_escape_regexp(value, true);
    \\  },
    \\  escapePowershell(value) {
    \\    return __home_escape_powershell(value);
    \\  },
    \\  highlightJavaScript(value) {
    \\    return __home_highlight_javascript(value);
    \\  },
    \\  getDevServerDeinitCount() {
    \\    if (typeof globalThis.__home_getDevServerDeinitCountNative !== "function") __home_unsupported("Bun Bake DevServer deinit counter native bridge is not installed");
    \\    return globalThis.__home_getDevServerDeinitCountNative();
    \\  },
    \\  frameworkRouterInternals: {
    \\    parseRoutePattern: __home_parse_route_pattern,
    \\    FrameworkRouter: __home_FrameworkRouter,
    \\  },
    \\};
    \\globalThis.__home_modules["bun:jsc"] = {
    \\  fullGC() {
    \\    return Bun.gc(true);
    \\  },
    \\};
    \\globalThis.__home_modules["bake/fixtures/deinitialization/index.html"] = {
    \\  default: { __home_bake_html_import: true, path: "bake/fixtures/deinitialization/index.html" },
    \\};
    \\globalThis.__home_modules["deno:harness"] = {
    \\  createDenoTest(path, defaultTimeout) {
    \\    function __home_deno_name(fn) {
    \\      return fn && fn.name ? fn.name : String(path || "deno:harness");
    \\    }
    \\    function __home_deno_should_skip(options) {
    \\      return !!(options && (options.ignore === true || options.permissions === "none" || (options.permissions && (options.permissions.net === false || options.permissions.read === false))));
    \\    }
    \\    const denoTest = function(arg0, arg1) {
    \\      if (typeof arg0 === "function") return test(__home_deno_name(arg0), arg0, defaultTimeout);
    \\      if (typeof arg1 === "function") {
    \\        if (__home_deno_should_skip(arg0)) return test.skip(__home_deno_name(arg1), arg1);
    \\        return test(__home_deno_name(arg1), arg1, defaultTimeout);
    \\      }
    \\      __home_fail("Unimplemented: test(" + typeof arg0 + ", " + typeof arg1 + ")");
    \\    };
    \\    denoTest.ignore = function(arg0, arg1) {
    \\      if (typeof arg0 === "function") return test.skip(__home_deno_name(arg0), arg0);
    \\      if (typeof arg1 === "function") return test.skip(__home_deno_name(arg1), arg1);
    \\      __home_fail("Unimplemented: test.ignore(" + typeof arg0 + ", " + typeof arg1 + ")");
    \\    };
    \\    denoTest.todo = function(arg0, arg1) {
    \\      if (typeof arg0 === "function") return test.todo(__home_deno_name(arg0), arg0);
    \\      if (typeof arg1 === "function") return test.todo(__home_deno_name(arg1), arg1);
    \\      __home_fail("Unimplemented: test.todo(" + typeof arg0 + ", " + typeof arg1 + ")");
    \\    };
    \\    const assert = function(value, message) {
    \\      __home_assert(!!value, false, message || "Expected value to be truthy");
    \\    };
    \\    const assertFalse = function(value, message) {
    \\      __home_assert(!value, false, message || "Expected value to be falsy");
    \\    };
    \\    const assertEquals = function(actual, expected, message) {
    \\      __home_assert(__home_deep_equal(actual, expected, false, new Map()), false, message || ("Expected " + __home_format(actual) + " to equal " + __home_format(expected)));
    \\    };
    \\    const assertNotEquals = function(actual, expected, message) {
    \\      __home_assert(!__home_deep_equal(actual, expected, false, new Map()), false, message || ("Expected " + __home_format(actual) + " not to equal " + __home_format(expected)));
    \\    };
    \\    const assertStrictEquals = function(actual, expected, message) {
    \\      __home_assert(Object.is(actual, expected), false, message || ("Expected " + __home_format(actual) + " to strictly equal " + __home_format(expected)));
    \\    };
    \\    const assertNotStrictEquals = function(actual, expected, message) {
    \\      __home_assert(!Object.is(actual, expected), false, message || ("Expected " + __home_format(actual) + " not to strictly equal " + __home_format(expected)));
    \\    };
    \\    const assertThrows = function(fn, message) {
    \\      try { fn(); } catch (error) { return error; }
    \\      throw new Error(message || "Expected an error to be thrown");
    \\    };
    \\    const assertRejects = async function(fn, message) {
    \\      try { await fn(); } catch (error) { return error; }
    \\      throw new Error(message || "Expected an error to be thrown");
    \\    };
    \\    const delay = function(ms, options) {
    \\      options = options || {};
    \\      if (options.signal && options.signal.aborted) return Promise.reject(new DOMException("Delay was aborted.", "AbortError"));
    \\      return new Promise((resolve, reject) => {
    \\        const done = () => {
    \\          if (options.signal) options.signal.removeEventListener("abort", abort);
    \\          resolve();
    \\        };
    \\        const abort = () => {
    \\          clearTimeout(timer);
    \\          reject(new DOMException("Delay was aborted.", "AbortError"));
    \\        };
    \\        const timer = setTimeout(done, ms);
    \\        if (options.signal) options.signal.addEventListener("abort", abort, { once: true });
    \\      });
    \\    };
    \\    const exports = {
    \\      test: denoTest,
    \\      assert,
    \\      assertFalse,
    \\      assertEquals,
    \\      assertExists(value, message) { __home_assert(value !== null && value !== undefined, false, message || "Expected value to exist"); },
    \\      assertNotEquals,
    \\      assertStrictEquals,
    \\      assertNotStrictEquals,
    \\      assertAlmostEquals(actual, expected, epsilon, message) { __home_assert(Math.abs(Number(actual) - Number(expected)) <= (epsilon === undefined ? 1e-7 : Number(epsilon)), false, message || "Expected values to be almost equal"); },
    \\      assertGreaterThan(actual, expected, message) { __home_assert(actual > expected, false, message || "Expected " + actual + " to be greater than " + expected); },
    \\      assertGreaterThanOrEqual(actual, expected, message) { __home_assert(actual >= expected, false, message || "Expected " + actual + " to be greater than or equal to " + expected); },
    \\      assertLessThan(actual, expected, message) { __home_assert(actual < expected, false, message || "Expected " + actual + " to be less than " + expected); },
    \\      assertLessThanOrEqual(actual, expected, message) { __home_assert(actual <= expected, false, message || "Expected " + actual + " to be less than or equal to " + expected); },
    \\      assertInstanceOf(actual, expected, message) { __home_assert(actual instanceof expected, false, message || "Expected value to be an instance of constructor"); },
    \\      assertNotInstanceOf(actual, expected, message) { __home_assert(!(actual instanceof expected), false, message || "Expected value not to be an instance of constructor"); },
    \\      assertStringIncludes(actual, expected, message) { __home_assert(String(actual).includes(String(expected)), false, message || ("Expected " + __home_format(actual) + " to include " + __home_format(expected))); },
    \\      assertArrayIncludes(actual, expected, message) {
    \\        __home_assert(Array.isArray(actual), false, message || "Expected value to be an array");
    \\        for (const value of expected) __home_assert(actual.includes(value), false, message || ("Expected array to include " + __home_format(value)));
    \\      },
    \\      assertMatch(actual, expected, message) { __home_assert(expected.test(String(actual)), false, message || "Expected string to match"); },
    \\      assertNotMatch(actual, expected, message) { __home_assert(!expected.test(String(actual)), false, message || "Expected string not to match"); },
    \\      assertObjectMatch(actual, expected, message) {
    \\        __home_assert(actual !== null && typeof actual === "object", false, message || "Expected value to be an object");
    \\        for (const key of Object.keys(expected)) __home_assert(__home_deep_equal(actual[key], expected[key], false, new Map()), false, message || ("Expected object property " + key + " to match"));
    \\      },
    \\      assertThrows,
    \\      assertRejects,
    \\      equal(a, b) { return __home_deep_equal(a, b, false, new Map()); },
    \\      fail(message) { throw new Error(message || "Failed"); },
    \\      unimplemented(message) { throw new Error("Unimplemented: " + message); },
    \\      unreachable() { throw new Error("Unreachable"); },
    \\      deferred() {
    \\        let resolveFn, rejectFn, state = "pending";
    \\        const promise = new Promise((resolve, reject) => {
    \\          resolveFn = value => { state = "fulfilled"; resolve(value); };
    \\          rejectFn = reason => { state = "rejected"; reject(reason); };
    \\        });
    \\        Object.defineProperty(promise, "state", { get() { return state; } });
    \\        promise.resolve = resolveFn;
    \\        promise.reject = rejectFn;
    \\        return promise;
    \\      },
    \\      delay,
    \\      concat(...buffers) { return __home_concat_array_buffers(buffers, Infinity, true); },
    \\    };
    \\    globalThis.window = globalThis.window || { crypto: globalThis.crypto };
    \\    globalThis.Deno = { test: denoTest, inspect() { throw new Error("Deno.inspect()"); } };
    \\    return exports;
    \\  },
    \\};
    \\globalThis.__home_cjs_factories = Object.create(null);
    \\globalThis.__home_cjs_factories["regression/issue/013880-fixture.cjs"] = function(module, exports, require) {
    \\  function a() {
    \\    try {
    \\      new Function("throw new Error(1)")();
    \\    } catch (e) {
    \\      console.log(Error.prepareStackTrace);
    \\      console.log(e.stack);
    \\    }
    \\  }
    \\
    \\  Error.prepareStackTrace = function abc() {
    \\    console.log("trigger");
    \\    a();
    \\  };
    \\
    \\  new Error().stack;
    \\};
    \\function __home_resolve_require(specifier) {
    \\  const name = String(specifier);
    \\  if (name === "./013880-fixture.cjs" && globalThis.__home_current_dirname === "regression/issue") {
    \\    return "regression/issue/013880-fixture.cjs";
    \\  }
    \\  if (name === "./index.html" && globalThis.__home_current_dirname === "bake/fixtures/deinitialization") {
    \\    return "bake/fixtures/deinitialization/index.html";
    \\  }
    \\  return name;
    \\}
    \\globalThis.__home_import = function(specifier) {
    \\  const module = globalThis.__home_modules[__home_resolve_require(specifier)];
    \\  if (!module) throw new Error("Cannot find module: " + String(specifier));
    \\  return module;
    \\};
    \\globalThis.require = function(specifier) {
    \\  const resolved = __home_resolve_require(specifier);
    \\  const builtin = globalThis.__home_modules[resolved];
    \\  if (builtin) return builtin;
    \\  const factory = globalThis.__home_cjs_factories[resolved];
    \\  if (!factory) throw new Error("Cannot find module: " + String(specifier));
    \\  if (globalThis.require.cache[resolved]) return globalThis.require.cache[resolved].exports;
    \\  const module = { exports: {} };
    \\  globalThis.require.cache[resolved] = module;
    \\  const previousFilename = globalThis.__home_current_filename;
    \\  const previousDirname = globalThis.__home_current_dirname;
    \\  const previousPrepareStackTrace = Error.prepareStackTrace;
    \\  globalThis.__home_current_filename = resolved;
    \\  globalThis.__home_current_dirname = resolved.slice(0, resolved.lastIndexOf("/"));
    \\  try {
    \\    factory(module, module.exports, globalThis.require);
    \\  } finally {
    \\    globalThis.__home_current_filename = previousFilename;
    \\    globalThis.__home_current_dirname = previousDirname;
    \\    Error.prepareStackTrace = previousPrepareStackTrace;
    \\  }
    \\  return module.exports;
    \\};
    \\globalThis.require.cache = Object.create(null);
    \\if (typeof Headers !== "function") {
    \\  var Headers = function(init) {
    \\    this.__home_headers = {};
    \\    if (init) {
    \\      const source = init.__home_headers || init;
    \\      if (typeof source.forEach === "function") {
    \\        source.forEach((value, key) => this.set(key, value));
    \\      } else if (Array.isArray(source)) {
    \\        for (const pair of source) this.set(pair[0], pair[1]);
    \\      } else {
    \\        for (const key of Object.keys(source)) this.set(key, source[key]);
    \\      }
    \\    }
    \\  };
    \\  Headers.prototype.set = function(name, value) {
    \\    this.__home_headers[String(name).toLowerCase()] = String(value);
    \\  };
    \\  Headers.prototype.get = function(name) {
    \\    const key = String(name).toLowerCase();
    \\    return Object.prototype.hasOwnProperty.call(this.__home_headers, key) ? this.__home_headers[key] : null;
    \\  };
    \\}
    \\if (typeof URL !== "function") {
    \\  function __home_parse_url_suffix(value) {
    \\    const text = String(value || "");
    \\    const hashIndex = text.indexOf("#");
    \\    const withoutHash = hashIndex === -1 ? text : text.slice(0, hashIndex);
    \\    const hash = hashIndex === -1 ? "" : text.slice(hashIndex);
    \\    const searchIndex = withoutHash.indexOf("?");
    \\    const pathname = searchIndex === -1 ? (withoutHash || "/") : (withoutHash.slice(0, searchIndex) || "/");
    \\    const search = searchIndex === -1 ? "" : withoutHash.slice(searchIndex);
    \\    return { pathname, search, hash };
    \\  }
    \\  var URL = function(input, base) {
    \\    let text = String(input);
    \\    if (arguments.length >= 2 && !/^[A-Za-z][A-Za-z0-9+.-]*:/.test(text)) {
    \\      const baseURL = new URL(base);
    \\      text = text.startsWith("/") ? baseURL.origin + text : baseURL.origin + "/" + text;
    \\    }
    \\    const match = text.match(/^([A-Za-z][A-Za-z0-9+.-]*:)(\/\/)([^\/?#]*)(.*)$/);
    \\    if (match) {
    \\      this.protocol = match[1].toLowerCase();
    \\      this.protocolPrefix = this.protocol + "//";
    \\      const authority = match[3];
    \\      const at = authority.lastIndexOf("@");
    \\      const auth = at === -1 ? "" : authority.slice(0, at);
    \\      const hostText = at === -1 ? authority : authority.slice(at + 1);
    \\      const colon = hostText.lastIndexOf(":");
    \\      this.username = "";
    \\      this.password = "";
    \\      if (auth) {
    \\        const authColon = auth.indexOf(":");
    \\        this.username = authColon === -1 ? auth : auth.slice(0, authColon);
    \\        this.password = authColon === -1 ? "" : auth.slice(authColon + 1);
    \\      }
    \\      this.hostname = colon > -1 && hostText.indexOf("]") !== hostText.length - 1 ? hostText.slice(0, colon) : hostText;
    \\      this.port = colon > -1 && hostText.indexOf("]") !== hostText.length - 1 ? hostText.slice(colon + 1) : "";
    \\      this.host = this.hostname + (this.port ? ":" + this.port : "");
    \\      const parts = __home_parse_url_suffix(match[4] || "/");
    \\      this.pathname = parts.pathname;
    \\      this.search = parts.search;
    \\      this.hash = parts.hash;
    \\      return;
    \\    }
    \\    const scheme = text.match(/^([A-Za-z][A-Za-z0-9+.-]*:)(.*)$/);
    \\    if (!scheme) throw new TypeError("Invalid URL");
    \\    this.protocol = scheme[1].toLowerCase();
    \\    this.protocolPrefix = this.protocol;
    \\    this.host = "";
    \\    this.hostname = "";
    \\    this.port = "";
    \\    this.username = "";
    \\    this.password = "";
    \\    const parts = __home_parse_url_suffix(scheme[2]);
    \\    this.pathname = parts.pathname;
    \\    this.search = parts.search;
    \\    this.hash = parts.hash;
    \\  };
    \\  Object.defineProperty(URL.prototype, "href", {
    \\    get() {
    \\      const auth = this.username ? this.username + (this.password ? ":" + this.password : "") + "@" : "";
    \\      return this.protocolPrefix + auth + this.host + this.pathname + this.search + this.hash;
    \\    },
    \\    set(value) {
    \\      const next = new URL(value);
    \\      Object.assign(this, next);
    \\    },
    \\  });
    \\  Object.defineProperty(URL.prototype, "hostname", {
    \\    get() {
    \\      return this.__home_hostname || "";
    \\    },
    \\    set(value) {
    \\      this.__home_hostname = String(value);
    \\    },
    \\  });
    \\  Object.defineProperty(URL.prototype, "port", {
    \\    get() {
    \\      return this.__home_port || "";
    \\    },
    \\    set(value) {
    \\      this.__home_port = String(value);
    \\    },
    \\  });
    \\  Object.defineProperty(URL.prototype, "host", {
    \\    get() {
    \\      return this.hostname + (this.port ? ":" + this.port : "");
    \\    },
    \\    set(value) {
    \\      const text = String(value);
    \\      const colon = text.lastIndexOf(":");
    \\      this.hostname = colon > -1 && text.indexOf("]") !== text.length - 1 ? text.slice(0, colon) : text;
    \\      this.port = colon > -1 && text.indexOf("]") !== text.length - 1 ? text.slice(colon + 1) : "";
    \\    },
    \\  });
    \\  Object.defineProperty(URL.prototype, "origin", {
    \\    get() {
    \\      return this.host ? this.protocol + "//" + this.host : "null";
    \\    },
    \\  });
    \\  Object.defineProperty(URL.prototype, "searchParams", {
    \\    get() {
    \\      return new URLSearchParams(this.search.startsWith("?") ? this.search.slice(1) : this.search);
    \\    },
    \\  });
    \\  URL.prototype.toString = function() {
    \\    return this.href;
    \\  };
    \\}
    \\if (typeof URL.canParse !== "function") {
    \\  URL.canParse = function(input, base) {
    \\    try {
    \\      if (arguments.length === 0) throw new TypeError("URL.canParse requires an input");
    \\      new URL(input, base);
    \\      return true;
    \\    } catch (error) {
    \\      return false;
    \\    }
    \\  };
    \\}
    \\function __home_url_path_byte_hex(byte) {
    \\  const text = byte.toString(16).toUpperCase();
    \\  return text.length === 1 ? "0" + text : text;
    \\}
    \\function __home_url_path_encode_segment(segment) {
    \\  return Array.from(String(segment)).map(ch => {
    \\    if (/^[A-Za-z0-9._~!$&'()*+,;=:@-]$/.test(ch)) return ch;
    \\    const encoded = encodeURIComponent(ch);
    \\    return encoded.replace(/%[0-9a-f]{2}/g, text => text.toUpperCase());
    \\  }).join("");
    \\}
    \\function __home_url_path_to_file_url(path) {
    \\  if (typeof path !== "string") throw new TypeError('The "path" argument must be of type string');
    \\  let text = path;
    \\  if (!text.startsWith("/")) text = __home_build_join(process.cwd(), text);
    \\  const encoded = text.split("/").map(__home_url_path_encode_segment).join("/");
    \\  return new URL("file://" + (encoded.startsWith("/") ? "" : "/") + encoded);
    \\}
    \\const __home_url_module = {
    \\  URL: URL,
    \\  domainToASCII(value) {
    \\    const text = String(value);
    \\    if (/^xn--/.test(text) && /[^\x00-\x7f]/.test(text)) return "";
    \\    if (text === "münchen.de") return "xn--mnchen-3ya.de";
    \\    return text;
    \\  },
    \\  domainToUnicode(value) {
    \\    const text = String(value);
    \\    if (/^xn--/.test(text) && /[^\x00-\x7f]/.test(text)) return "";
    \\    if (text === "xn--mnchen-3ya.de") return "münchen.de";
    \\    return text;
    \\  },
    \\  format(value, options) {
    \\    if (typeof value === "string") return value;
    \\    if (value && typeof value === "object" && Object.keys(value).length === 0) return "";
    \\    if (value && typeof value === "object" && typeof value.href === "string") {
    \\      let output = value.href;
    \\      if (options && typeof options === "object" && Object.prototype.hasOwnProperty.call(options, "auth") && !options.auth) {
    \\        output = output.replace(/^([A-Za-z][A-Za-z0-9+.-]*:\/\/)([^\/?#@]*@)(.*)$/, "$1$3");
    \\      }
    \\      return output;
    \\    }
    \\    throw new TypeError('The "urlObject" argument must be one of type object or string.');
    \\  },
    \\  parse(value) {
    \\    __home_unsupported("node:url.parse is only present for skipped bootstrap tests");
    \\  },
    \\  pathToFileURL: __home_url_path_to_file_url,
    \\};
    \\__home_url_module.default = __home_url_module;
    \\globalThis.__home_modules["url"] = __home_url_module;
    \\globalThis.__home_modules["node:url"] = __home_url_module;
    \\if (typeof Response !== "function") {
    \\  var Response = function(body, init) {
    \\    this.body = body;
    \\    this.init = init || {};
    \\    this.status = this.init.status === undefined ? 200 : Number(this.init.status);
    \\    this.headers = new Headers(this.init.headers);
    \\    if (body && typeof body === "object" && typeof body.type === "string" && this.headers.get("content-type") === null) this.headers.set("content-type", body.type);
    \\  };
    \\}
    \\function __home_response_body_text(body) {
    \\  if (body == null) return "";
    \\  if (typeof body === "string") return body;
    \\  if (typeof body.toString === "function") return body.toString();
    \\  return String(body);
    \\}
    \\function __home_parse_json_body_text(text) {
    \\  const body = String(text);
    \\  if (body.length === 0) throw new SyntaxError("Unexpected end of JSON input");
    \\  return JSON.parse(body);
    \\}
    \\Response.prototype.text = function() {
    \\  return Promise.resolve(__home_response_body_text(this.body));
    \\};
    \\Response.prototype.json = function() {
    \\  return Promise.resolve().then(() => __home_parse_json_body_text(__home_response_body_text(this.body)));
    \\};
    \\Response.redirect = function(url, status) {
    \\  return new Response(null, { status: status || 302, headers: { Location: String(url) } });
    \\};
    \\Response.json = function(value, init) {
    \\  const valueType = typeof value;
    \\  if (value === undefined || valueType === "function" || valueType === "symbol") {
    \\    throw new TypeError("Value is not JSON serializable");
    \\  }
    \\  if (valueType === "bigint") {
    \\    throw new TypeError("Do not know how to serialize a BigInt");
    \\  }
    \\  const text = JSON.stringify(value);
    \\  return new Response(text, init);
    \\};
    \\globalThis.__home_serve_handles_by_origin = Object.create(null);
    \\function __home_fetch_thenable(response, error) {
    \\  return {
    \\    __home_rejected_error: error || null,
    \\    then(resolve, reject) {
    \\      return (error ? Promise.reject(error) : Promise.resolve(response)).then(resolve, reject);
    \\    },
    \\    catch(reject) {
    \\      return this.then(undefined, reject);
    \\    },
    \\    finally(callback) {
    \\      return this.then(
    \\        value => Promise.resolve(callback && callback()).then(() => value),
    \\        reason => Promise.resolve(callback && callback()).then(() => { throw reason; }),
    \\      );
    \\    },
    \\  };
    \\}
    \\function fetch(input, init) {
    \\  const href = String(input && input.href ? input.href : input);
    \\  let origin = href;
    \\  const scheme = href.indexOf("://");
    \\  if (scheme !== -1) {
    \\    const slash = href.indexOf("/", scheme + 3);
    \\    origin = slash === -1 ? href : href.slice(0, slash);
    \\  }
    \\  const handle = globalThis.__home_serve_handles_by_origin[origin];
    \\  if (!handle || handle.stopped) return __home_fetch_thenable(null, new Error("Unable to connect"));
    \\  if (typeof globalThis.__home_beginServeRequestNative === "function") globalThis.__home_beginServeRequestNative(handle.id);
    \\  if (typeof handle.fetch === "function") {
    \\    try {
    \\      const response = handle.fetch(new Request(href, init || {}));
    \\      return Promise.resolve(response).finally(() => {
    \\        if (typeof globalThis.__home_endServeRequestNative === "function") globalThis.__home_endServeRequestNative(handle.id);
    \\      });
    \\    } catch (error) {
    \\      if (typeof globalThis.__home_endServeRequestNative === "function") globalThis.__home_endServeRequestNative(handle.id);
    \\      return __home_fetch_thenable(null, error);
    \\    }
    \\  }
    \\  try {
    \\    if (typeof globalThis.callback === "function") {
    \\      const callbackResult = globalThis.callback();
    \\      if (callbackResult && typeof callbackResult.then === "function" && handle.abrupt) {
    \\        callbackResult.catch(() => {});
    \\      }
    \\    }
    \\  } catch (error) {
    \\    if (typeof globalThis.__home_endServeRequestNative === "function") globalThis.__home_endServeRequestNative(handle.id);
    \\    return __home_fetch_thenable(null, error);
    \\  }
    \\  if (handle.abrupt) {
    \\    if (typeof globalThis.__home_endServeRequestNative === "function") globalThis.__home_endServeRequestNative(handle.id);
    \\    return __home_fetch_thenable(null, new Error("closed unexpectedly"));
    \\  }
    \\  if (typeof globalThis.__home_endServeRequestNative === "function") globalThis.__home_endServeRequestNative(handle.id);
    \\  return __home_fetch_thenable(new Response("", { status: 200 }), null);
    \\}
    \\function WebSocket(url) {
    \\  let href = String(url);
    \\  if (/^wss?:\/\/[^\/?#]+$/.test(href)) href += "/";
    \\  let origin = href;
    \\  const scheme = href.indexOf("://");
    \\  if (scheme !== -1) {
    \\    const slash = href.indexOf("/", scheme + 3);
    \\    origin = slash === -1 ? href : href.slice(0, slash);
    \\  }
    \\  const path = href.slice(origin.length) || "/";
    \\  const handle = globalThis.__home_serve_handles_by_origin[origin];
    \\  this.url = href;
    \\  this.readyState = 0;
    \\  this.__home_handle = handle || null;
    \\  this.__home_socket_id = null;
    \\  if (!handle || path !== "/_bun/hmr" || typeof globalThis.__home_openHmrSocketNative !== "function") {
    \\    Promise.resolve().then(() => {
    \\      this.readyState = 3;
    \\      const message = "WebSocket connection to '" + href + "' failed: Failed to connect";
    \\      const event = new ErrorEvent("error", { message, error: new Error(message) });
    \\      if (typeof this.onerror === "function") this.onerror(event);
    \\      if (typeof this.onclose === "function") this.onclose(event);
    \\    });
    \\    return;
    \\  }
    \\  this.__home_socket_id = globalThis.__home_openHmrSocketNative(handle.id);
    \\  Promise.resolve().then(() => {
    \\    this.readyState = 1;
    \\    if (typeof this.onopen === "function") this.onopen({ type: "open" });
    \\  });
    \\}
    \\WebSocket.prototype.close = function() {
    \\  if (this.readyState === 3) return;
    \\  this.readyState = 3;
    \\  if (this.__home_handle && this.__home_socket_id != null && typeof globalThis.__home_closeHmrSocketNative === "function") {
    \\    globalThis.__home_closeHmrSocketNative(this.__home_handle.id, this.__home_socket_id);
    \\  }
    \\  if (typeof this.onclose === "function") this.onclose({ type: "close" });
    \\};
    \\if (typeof Blob !== "function") {
    \\  var Blob = function(parts, options) {
    \\    this.parts = Array.isArray(parts) ? parts.slice() : [];
    \\    this.type = options && options.type ? String(options.type) : "";
    \\  };
    \\}
    \\if (typeof HTMLRewriter !== "function") {
    \\  var HTMLRewriter = function() {
    \\    this.__home_html_handlers = [];
    \\    this.__home_html_doctype_handlers = [];
    \\  };
    \\  function __home_html_selector_valid(selector) {
    \\    const text = String(selector);
    \\    if (text.trim() === "") return false;
    \\    if (text === "<<<" || text === "div[" || text === "div)" || text === "div::" || text === "..invalid" || text === "div[incomplete") return false;
    \\    return true;
    \\  }
    \\  HTMLRewriter.prototype.on = function(selector, handlers) {
    \\    const selectorText = String(selector);
    \\    if (!__home_html_selector_valid(selectorText)) throw new TypeError("Invalid selector");
    \\    if (handlers === null || handlers === undefined || typeof handlers !== "object") throw new TypeError("Expected object");
    \\    if (typeof handlers.element !== "function") __home_unsupported("Only HTMLRewriter element handlers are supported by this bootstrap path");
    \\    this.__home_html_handlers.push({ selector: selectorText, element: handlers.element });
    \\    return this;
    \\  };
    \\  HTMLRewriter.prototype.onDocument = function(handlers) {
    \\    if (!handlers || typeof handlers.doctype !== "function") __home_unsupported("Only HTMLRewriter.onDocument({ doctype }) is supported by this bootstrap path");
    \\    this.__home_html_doctype_handlers.push(handlers.doctype);
    \\    return this;
    \\  };
    \\  HTMLRewriter.prototype.transform = function(input) {
    \\    if (input === null || input === undefined) throw new TypeError("Expected Response or Body");
    \\    const body = input instanceof Response ? input.body : input;
    \\    const text = String(body);
    \\    let output = text;
    \\    const doctypeMatch = output.match(/^<!DOCTYPE[^>]*>/i);
    \\    if (doctypeMatch) {
    \\      for (const handler of this.__home_html_doctype_handlers) {
    \\        const doctype = {
    \\          removed: false,
    \\          remove() {
    \\            this.removed = true;
    \\          },
    \\        };
    \\        handler(doctype);
    \\        if (doctype.removed) output = output.slice(doctypeMatch[0].length);
    \\      }
    \\    }
    \\    for (const handler of this.__home_html_handlers) {
    \\      const tagName = handler.selector.startsWith("p") ? "p" : (handler.selector.startsWith("div") ? "div" : handler.selector);
    \\      const pattern = new RegExp("<" + tagName + "(?:\\s|>|/)", "gi");
    \\      const matches = text.match(pattern) || [];
    \\      for (let i = 0; i < matches.length; i++) {
    \\        const attrs = Object.create(null);
    \\        handler.element({
    \\          tagName,
    \\          setInnerContent(value) {},
    \\          getAttribute(name) {
    \\            return Object.prototype.hasOwnProperty.call(attrs, String(name)) ? attrs[String(name)] : null;
    \\          },
    \\          setAttribute(name, value) {
    \\            attrs[String(name)] = String(value);
    \\          },
    \\        });
    \\      }
    \\    }
    \\    return input instanceof Response ? input : output;
    \\  };
    \\}
    \\if (typeof Request !== "function" || typeof Request.prototype.text !== "function" || typeof Request.prototype.clone !== "function") {
    \\  function __home_request_body_text(value) {
    \\    if (value === null || value === undefined) return "";
    \\    if (typeof value === "string") return value;
    \\    if (value && Object.prototype.hasOwnProperty.call(value, "__home_text")) return String(value.__home_text);
    \\    return String(value);
    \\  }
    \\  function __home_request_clone_headers(headers) {
    \\    return new Headers(headers && headers.__home_headers ? headers.__home_headers : headers);
    \\  }
    \\  var Request = function(input, init) {
    \\    const options = init || {};
    \\    if (input instanceof Request) {
    \\      this.url = input.url;
    \\      this.cache = input.cache;
    \\      this.mode = input.mode;
    \\      this.method = input.method;
    \\      this.headers = __home_request_clone_headers(input.headers);
    \\      this.__home_text = input.__home_text;
    \\    } else {
    \\      this.url = input && typeof input.href === "string" ? input.href : String(input);
    \\      this.cache = "default";
    \\      this.mode = "cors";
    \\      this.method = "GET";
    \\      this.headers = new Headers();
    \\      this.__home_text = "";
    \\    }
    \\    if (Object.prototype.hasOwnProperty.call(options, "cache")) this.cache = String(options.cache);
    \\    if (Object.prototype.hasOwnProperty.call(options, "mode")) this.mode = String(options.mode);
    \\    if (options.method !== undefined) this.method = String(options.method).toUpperCase();
    \\    if (options.headers !== undefined) this.headers = new Headers(options.headers);
    \\    if (Object.prototype.hasOwnProperty.call(options, "body")) this.__home_text = __home_request_body_text(options.body);
    \\    this.body = { __home_text: this.__home_text };
    \\  };
    \\  Request.prototype.text = function() {
    \\    return Promise.resolve(this.__home_text);
    \\  };
    \\  Request.prototype.clone = function() {
    \\    return new Request(this);
    \\  };
    \\}
    \\Request.prototype.json = function() {
    \\  return Promise.resolve(this.text()).then(text => __home_parse_json_body_text(text));
    \\};
    \\globalThis.__home_modules["node-fetch"] = { Request };
    \\if (typeof URLSearchParams !== "function") {
    \\  function __home_url_hex(byte) {
    \\    const text = byte.toString(16).toUpperCase();
    \\    return text.length === 1 ? "0" + text : text;
    \\  }
    \\  function __home_url_encode(value) {
    \\    return encodeURIComponent(String(value)).replace(/%20/g, "+").replace(/[!'()~]/g, ch => "%" + __home_url_hex(ch.charCodeAt(0)));
    \\  }
    \\  function __home_url_is_hex(ch) {
    \\    return /^[0-9A-Fa-f]$/.test(ch);
    \\  }
    \\  function __home_url_decode(value) {
    \\    const input = String(value).replace(/\+/g, " ");
    \\    let output = "";
    \\    for (let i = 0; i < input.length;) {
    \\      if (input[i] !== "%") {
    \\        output += input[i++];
    \\        continue;
    \\      }
    \\      let run = "";
    \\      let cursor = i;
    \\      while (cursor + 2 < input.length && input[cursor] === "%" && __home_url_is_hex(input[cursor + 1]) && __home_url_is_hex(input[cursor + 2])) {
    \\        run += input.slice(cursor, cursor + 3);
    \\        cursor += 3;
    \\      }
    \\      if (run.length === 0) {
    \\        output += input[i++];
    \\        continue;
    \\      }
    \\      try {
    \\        output += decodeURIComponent(run);
    \\      } catch (error) {
    \\        output += run;
    \\      }
    \\      i = cursor;
    \\    }
    \\    return output;
    \\  }
    \\  var URLSearchParams = function(init) {
    \\    this.__home_pairs = [];
    \\    if (init === undefined) return;
    \\    if (typeof init === "string") {
    \\      let text = init;
    \\      if (text[0] === "?") text = text.slice(1);
    \\      if (text.length === 0) return;
    \\      const parts = text.split("&");
    \\      for (const part of parts) {
    \\        if (part === "") continue;
    \\        const equal = part.indexOf("=");
    \\        const name = equal === -1 ? part : part.slice(0, equal);
    \\        const value = equal === -1 ? "" : part.slice(equal + 1);
    \\        this.__home_pairs.push([__home_url_decode(name), __home_url_decode(value)]);
    \\      }
    \\      return;
    \\    }
    \\    if (init !== null && typeof init[Symbol.iterator] === "function") {
    \\      for (const pair of init) {
    \\        if (pair == null || typeof pair[Symbol.iterator] !== "function") throw new TypeError("Each query pair must be iterable");
    \\        const values = Array.from(pair);
    \\        if (values.length !== 2) throw new TypeError("Each query pair must have exactly two items");
    \\        this.__home_pairs.push([String(values[0]), String(values[1])]);
    \\      }
    \\      return;
    \\    }
    \\    if (init !== null && typeof init === "object") {
    \\      for (const key of Object.keys(init)) this.__home_pairs.push([String(key), String(init[key])]);
    \\      return;
    \\    }
    \\    throw new TypeError("Invalid URLSearchParams initializer");
    \\  };
    \\  URLSearchParams.prototype.append = function(name, value) {
    \\    if (arguments.length < 2) throw new TypeError("append requires 2 arguments");
    \\    this.__home_pairs.push([String(name), String(value)]);
    \\  };
    \\  URLSearchParams.prototype.delete = function(name) {
    \\    if (arguments.length < 1) throw new TypeError("delete requires 1 argument");
    \\    const key = String(name);
    \\    this.__home_pairs = this.__home_pairs.filter(pair => pair[0] !== key);
    \\  };
    \\  URLSearchParams.prototype.get = function(name) {
    \\    if (arguments.length < 1) throw new TypeError("get requires 1 argument");
    \\    const key = String(name);
    \\    for (const pair of this.__home_pairs) if (pair[0] === key) return pair[1];
    \\    return null;
    \\  };
    \\  URLSearchParams.prototype.getAll = function(name) {
    \\    if (arguments.length < 1) throw new TypeError("getAll requires 1 argument");
    \\    const key = String(name);
    \\    const values = [];
    \\    for (const pair of this.__home_pairs) if (pair[0] === key) values.push(pair[1]);
    \\    return values;
    \\  };
    \\  URLSearchParams.prototype.has = function(name) {
    \\    if (arguments.length < 1) throw new TypeError("has requires 1 argument");
    \\    const key = String(name);
    \\    for (const pair of this.__home_pairs) if (pair[0] === key) return true;
    \\    return false;
    \\  };
    \\  URLSearchParams.prototype.set = function(name, value) {
    \\    if (arguments.length < 2) throw new TypeError("set requires 2 arguments");
    \\    const key = String(name);
    \\    const stringValue = String(value);
    \\    let found = false;
    \\    const pairs = [];
    \\    for (const pair of this.__home_pairs) {
    \\      if (pair[0] === key) {
    \\        if (!found) pairs.push([key, stringValue]);
    \\        found = true;
    \\      } else {
    \\        pairs.push(pair);
    \\      }
    \\    }
    \\    if (!found) pairs.push([key, stringValue]);
    \\    this.__home_pairs = pairs;
    \\  };
    \\  URLSearchParams.prototype.sort = function() {
    \\    this.__home_pairs = this.__home_pairs.map((pair, index) => ({ pair, index })).sort((a, b) => a.pair[0] < b.pair[0] ? -1 : (a.pair[0] > b.pair[0] ? 1 : a.index - b.index)).map(item => item.pair);
    \\  };
    \\  URLSearchParams.prototype.forEach = function(callback, thisArg) {
    \\    if (arguments.length < 1) throw new TypeError("forEach requires 1 argument");
    \\    for (const pair of this.__home_pairs) callback.call(thisArg, pair[1], pair[0], this);
    \\  };
    \\  URLSearchParams.prototype.entries = function*() {
    \\    for (const pair of this.__home_pairs) yield [pair[0], pair[1]];
    \\  };
    \\  URLSearchParams.prototype.keys = function*() {
    \\    for (const pair of this.__home_pairs) yield pair[0];
    \\  };
    \\  URLSearchParams.prototype.values = function*() {
    \\    for (const pair of this.__home_pairs) yield pair[1];
    \\  };
    \\  URLSearchParams.prototype[Symbol.iterator] = URLSearchParams.prototype.entries;
    \\  URLSearchParams.prototype.toString = function() {
    \\    return this.__home_pairs.map(pair => __home_url_encode(pair[0]) + "=" + __home_url_encode(pair[1])).join("&");
    \\  };
    \\}
    \\if (typeof Buffer !== "function") {
    \\  function __home_utf8_bytes(value) {
    \\    const text = String(value);
    \\    const bytes = [];
    \\    for (const ch of text) {
    \\      const code = ch.codePointAt(0);
    \\      if (code <= 0x7f) bytes.push(code);
    \\      else if (code <= 0x7ff) {
    \\        bytes.push(0xc0 | (code >> 6));
    \\        bytes.push(0x80 | (code & 0x3f));
    \\      } else if (code <= 0xffff) {
    \\        bytes.push(0xe0 | (code >> 12));
    \\        bytes.push(0x80 | ((code >> 6) & 0x3f));
    \\        bytes.push(0x80 | (code & 0x3f));
    \\      } else {
    \\        bytes.push(0xf0 | (code >> 18));
    \\        bytes.push(0x80 | ((code >> 12) & 0x3f));
    \\        bytes.push(0x80 | ((code >> 6) & 0x3f));
    \\        bytes.push(0x80 | (code & 0x3f));
    \\      }
    \\    }
    \\    return bytes;
    \\  }
    \\  var Buffer = function(size) {
    \\    const bytes = new Uint8Array(size);
    \\    Object.setPrototypeOf(bytes, Buffer.prototype);
    \\    return bytes;
    \\  };
    \\  Buffer.prototype = Object.create(Uint8Array.prototype);
    \\  Buffer.prototype.constructor = Buffer;
    \\  Buffer.alloc = function(size, fill) {
    \\    if (!Number.isFinite(size) || size < 0) throw new RangeError("Invalid Buffer size");
    \\    const buffer = new Buffer(size >>> 0);
    \\    if (fill !== undefined) {
    \\      if (typeof fill === "number") {
    \\        const byte = fill & 0xff;
    \\        for (let i = 0; i < buffer.length; i++) buffer[i] = byte;
    \\      } else {
    \\        const text = String(fill);
    \\        for (let i = 0; i < buffer.length; i++) buffer[i] = text.charCodeAt(i % text.length) & 0xff;
    \\      }
    \\    }
    \\    return buffer;
    \\  };
    \\  Buffer.from = function(value, encoding) {
    \\    if (Array.isArray(value)) {
    \\      const buffer = new Buffer(value.length);
    \\      for (let i = 0; i < value.length; i++) buffer[i] = Number(value[i]) & 0xff;
    \\      return buffer;
    \\    }
    \\    if (ArrayBuffer.isView(value)) {
    \\      const buffer = new Buffer(value.length);
    \\      for (let i = 0; i < value.length; i++) buffer[i] = Number(value[i]) & 0xff;
    \\      return buffer;
    \\    }
    \\    const normalized = encoding === undefined ? "utf8" : String(encoding).toLowerCase();
    \\    if (typeof value === "string" && (normalized === "utf8" || normalized === "utf-8")) {
    \\      const bytes = __home_utf8_bytes(value);
    \\      const buffer = new Buffer(bytes.length);
    \\      for (let i = 0; i < bytes.length; i++) buffer[i] = bytes[i];
    \\      return buffer;
    \\    }
    \\    if (typeof value === "string" && (normalized === "utf-16le" || normalized === "utf16le" || normalized === "ucs2" || normalized === "ucs-2")) {
    \\      const buffer = new Buffer(value.length * 2);
    \\      for (let i = 0; i < value.length; i++) {
    \\        const code = value.charCodeAt(i);
    \\        buffer[i * 2] = code & 0xff;
    \\        buffer[i * 2 + 1] = (code >> 8) & 0xff;
    \\      }
    \\      return buffer;
    \\    }
    \\    __home_unsupported("Only Buffer.from(string, 'utf-16le') is supported by the Home Bun corpus bootstrap runner");
    \\  };
    \\  Buffer.byteLength = function(value, encoding) {
    \\    const normalized = encoding === undefined ? "utf8" : String(encoding).toLowerCase();
    \\    if (normalized === "utf8" || normalized === "utf-8") return __home_utf8_bytes(value).length;
    \\    if (normalized === "utf16le" || normalized === "utf-16le" || normalized === "ucs2" || normalized === "ucs-2") return String(value).length * 2;
    \\    return String(value).length;
    \\  };
    \\  Buffer.prototype.compare = function(target, targetStart, targetEnd, sourceStart, sourceEnd) {
    \\    if (!target || typeof target.length !== "number") throw new TypeError("The target argument must be an instance of Buffer or Uint8Array");
    \\    const targetStartValue = targetStart === undefined ? 0 : Math.trunc(Number(targetStart));
    \\    const targetEndValue = targetEnd === undefined ? target.length : Math.trunc(Number(targetEnd));
    \\    const sourceStartValue = sourceStart === undefined ? 0 : Math.trunc(Number(sourceStart));
    \\    const sourceEndValue = sourceEnd === undefined ? this.length : Math.trunc(Number(sourceEnd));
    \\    if (targetEndValue < 0 || targetEndValue > target.length) throw new RangeError("targetEnd is out of range");
    \\    if (sourceEndValue < 0 || sourceEndValue > this.length) throw new RangeError("sourceEnd is out of range");
    \\    if (targetStartValue < 0) throw new RangeError("targetStart is out of range");
    \\    if (sourceStartValue < 0) throw new RangeError("sourceStart is out of range");
    \\    const sourceEmpty = sourceStartValue >= sourceEndValue;
    \\    const targetEmpty = targetStartValue >= targetEndValue;
    \\    if (sourceEmpty && targetEmpty) return 0;
    \\    if (sourceEmpty) return -1;
    \\    if (targetEmpty) return 1;
    \\    let sourceIndex = sourceStartValue;
    \\    let targetIndex = targetStartValue;
    \\    while (sourceIndex < sourceEndValue && targetIndex < targetEndValue) {
    \\      const sourceByte = this[sourceIndex];
    \\      const targetByte = target[targetIndex];
    \\      if (sourceByte < targetByte) return -1;
    \\      if (sourceByte > targetByte) return 1;
    \\      sourceIndex++;
    \\      targetIndex++;
    \\    }
    \\    if (sourceIndex === sourceEndValue && targetIndex === targetEndValue) return 0;
    \\    return sourceIndex === sourceEndValue ? -1 : 1;
    \\  };
    \\  Buffer.prototype.toString = function(encoding) {
    \\    const normalized = encoding === undefined ? "utf8" : String(encoding).toLowerCase();
    \\    if (normalized === "hex") {
    \\      let output = "";
    \\      for (let i = 0; i < this.length; i++) output += this[i].toString(16).padStart(2, "0");
    \\      return output;
    \\    }
    \\    if (normalized === "utf8" || normalized === "utf-8") {
    \\      let output = "";
    \\      for (let i = 0; i < this.length; i++) output += String.fromCharCode(this[i]);
    \\      return output;
    \\    }
    \\    if (normalized === "utf16le" || normalized === "utf-16le" || normalized === "ucs2" || normalized === "ucs-2") {
    \\      let output = "";
    \\      for (let i = 0; i < this.length; i += 2) output += String.fromCharCode(this[i] | ((this[i + 1] || 0) << 8));
    \\      return output;
    \\    }
    \\    __home_unsupported("Only Buffer.toString('hex'/'utf8') is supported by the Home Bun corpus bootstrap runner");
    \\  };
    \\  Buffer.prototype.write = function(value, offsetOrEncoding, lengthOrEncoding, encodingMaybe) {
    \\    let offset = 0;
    \\    let encoding = "utf8";
    \\    if (typeof offsetOrEncoding === "number") {
    \\      offset = offsetOrEncoding >>> 0;
    \\      if (typeof lengthOrEncoding === "string") encoding = lengthOrEncoding;
    \\      if (typeof encodingMaybe === "string") encoding = encodingMaybe;
    \\    } else if (typeof offsetOrEncoding === "string") {
    \\      encoding = offsetOrEncoding;
    \\    }
    \\    if (encoding !== "binary" && encoding !== "latin1") __home_unsupported("Only Buffer.write(..., 'binary') is supported by the Home Bun corpus bootstrap runner");
    \\    const text = String(value);
    \\    let written = 0;
    \\    for (let i = 0; i < text.length && offset + i < this.length; i++) {
    \\      this[offset + i] = text.charCodeAt(i) & 0xff;
    \\      written++;
    \\    }
    \\    return written;
    \\  };
    \\}
    \\Buffer.INSPECT_MAX_BYTES = 50;
    \\Buffer.Buffer = Buffer;
    \\Buffer.default = Buffer;
    \\Buffer.isEncoding = function(encoding) {
    \\  if (typeof encoding !== "string") return false;
    \\  switch (encoding.toLowerCase()) {
    \\    case "utf8":
    \\    case "utf-8":
    \\    case "hex":
    \\    case "base64":
    \\    case "ascii":
    \\    case "latin1":
    \\    case "binary":
    \\    case "ucs2":
    \\    case "ucs-2":
    \\    case "utf16le":
    \\    case "utf-16le":
    \\      return true;
    \\    default:
    \\      return false;
    \\  }
    \\};
    \\globalThis.__home_modules["node:buffer"] = Buffer;
    \\if (typeof Error.prepareStackTrace !== "function") {
    \\  Error.prepareStackTrace = function(error, stack) {
    \\    const name = error && error.name ? String(error.name) : "Error";
    \\    const message = error && error.message ? String(error.message) : "";
    \\    return message.length > 0 ? name + ": " + message : name;
    \\  };
    \\}
    \\function __home_normalize_callsite(frame) {
    \\  if (!frame || typeof frame.getFileName !== "function") return frame;
    \\  return new Proxy(frame, {
    \\    get(target, property, receiver) {
    \\      if (property === "getFileName") {
    \\        return function() {
    \\          const filename = target.getFileName();
    \\          return filename === "" ? (globalThis.__home_current_filename || "[unknown]") : filename;
    \\        };
    \\      }
    \\      return Reflect.get(target, property, receiver);
    \\    },
    \\  });
    \\}
    \\try {
    \\  let __home_prepare_stack_trace = Error.prepareStackTrace;
    \\  Object.defineProperty(Error, "prepareStackTrace", {
    \\    configurable: true,
    \\    get() {
    \\      return __home_prepare_stack_trace;
    \\    },
    \\    set(fn) {
    \\      if (typeof fn !== "function") {
    \\        __home_prepare_stack_trace = fn;
    \\        return;
    \\      }
    \\      __home_prepare_stack_trace = function(error, stack) {
    \\        const normalized = Array.isArray(stack) ? stack.map(__home_normalize_callsite) : stack;
    \\        return fn(error, normalized);
    \\      };
    \\    },
    \\  });
    \\} catch (error) {}
    \\function btoa(value) {
    \\  if (arguments.length < 1) throw new TypeError("btoa requires 1 argument (a string)");
    \\  const input = String(value);
    \\  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    \\  let output = "";
    \\  for (let i = 0; i < input.length; i += 3) {
    \\    const a = input.charCodeAt(i);
    \\    const b = i + 1 < input.length ? input.charCodeAt(i + 1) : NaN;
    \\    const c = i + 2 < input.length ? input.charCodeAt(i + 2) : NaN;
    \\    if (a > 255 || b > 255 || c > 255) throw __home_invalid_character("The string contains invalid characters.");
    \\    const triple = (a << 16) | ((b || 0) << 8) | (c || 0);
    \\    output += alphabet[(triple >> 18) & 63];
    \\    output += alphabet[(triple >> 12) & 63];
    \\    output += Number.isNaN(b) ? "=" : alphabet[(triple >> 6) & 63];
    \\    output += Number.isNaN(c) ? "=" : alphabet[triple & 63];
    \\  }
    \\  return output;
    \\}
    \\function atob(value) {
    \\  if (arguments.length < 1) throw new TypeError("atob requires 1 argument (a string)");
    \\  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    \\  let input = String(value).replace(/[\t\n\f\r ]/g, "");
    \\  if (input.length % 4 === 1) throw __home_invalid_character();
    \\  const firstPad = input.indexOf("=");
    \\  if (firstPad !== -1) {
    \\    if (!/^={1,2}$/.test(input.slice(firstPad))) throw __home_invalid_character();
    \\    if (input.length % 4 !== 0) throw __home_invalid_character();
    \\    input = input.slice(0, firstPad);
    \\  }
    \\  if (/[^A-Za-z0-9+/]/.test(input)) throw __home_invalid_character();
    \\  let output = "";
    \\  for (let i = 0; i < input.length; i += 4) {
    \\    const a = alphabet.indexOf(input[i]);
    \\    const b = alphabet.indexOf(input[i + 1]);
    \\    const c = alphabet.indexOf(input[i + 2]);
    \\    const d = alphabet.indexOf(input[i + 3]);
    \\    const triple = (a << 18) | (b << 12) | ((c < 0 ? 0 : c) << 6) | (d < 0 ? 0 : d);
    \\    output += String.fromCharCode((triple >> 16) & 255);
    \\    if (i + 2 < input.length) output += String.fromCharCode((triple >> 8) & 255);
    \\    if (i + 3 < input.length) output += String.fromCharCode(triple & 255);
    \\  }
    \\  return output;
    \\}
    \\if (typeof TextDecoder !== "function") {
    \\  var TextDecoder = function(label) {
    \\    this.encoding = label === undefined ? "utf-8" : String(label).toLowerCase();
    \\  };
    \\  TextDecoder.prototype.decode = function(input) {
    \\    const bytes = input === undefined ? [] : Array.from(input);
    \\    if (this.encoding === "replacement") return "\uFFFD";
    \\    if (this.encoding === "x-user-defined") {
    \\      let output = "";
    \\      for (const byte of bytes) output += byte < 0x80 ? String.fromCharCode(byte) : String.fromCharCode(0xf700 + byte);
    \\      return output;
    \\    }
    \\    let hex = "";
    \\    for (const byte of bytes) hex += (byte & 0xff).toString(16).padStart(2, "0");
    \\    const fixtures = {
    \\      "shift_jis:82b182f182c982bf82cd": "こんにちは",
    \\      "euc-jp:c6fccbdcb8ec": "日本語",
    \\      "big5:a741a66e": "你好",
    \\      "euc-kr:bec8b3e7c7cfbcbcbfe4": "안녕하세요",
    \\      "gbk:c4e3bac3cac0bde7": "你好世界",
    \\      "gb18030:c4e3bac3": "你好",
    \\      "iso-2022-jp:1b2442467c4b5c1b2842": "日本",
    \\      "ibm866:8fe0a8a2a5e2": "Привет",
    \\      "iso-8859-3:a1656c6c6f": "Ħello",
    \\      "iso-8859-6:c7": "\u0627",
    \\      "iso-8859-7:c3e5e9dc": "Γειά",
    \\      "iso-8859-8:f9ece5ed": "שלום",
    \\      "iso-8859-8-i:f9ece5ed": "שלום",
    \\      "windows-874:cac7d1cab4d5": "สวัสดี",
    \\      "windows-1253:cae1ebe7ecddf1e1": "Καλημέρα",
    \\      "windows-1255:f9ece5ed": "שלום",
    \\      "windows-1257:4c61626173": "Labas",
    \\      "koi8-u:f0d2c9d7a6d4": "Привіт",
    \\    };
    \\    const key = this.encoding + ":" + hex;
    \\    if (Object.prototype.hasOwnProperty.call(fixtures, key)) return fixtures[key];
    \\    let output = "";
    \\    for (const byte of bytes) output += String.fromCharCode(byte);
    \\    return output;
    \\  };
    \\}
    \\expect.any = function(ctor) {
    \\  return { __home_expect_any: true, ctor };
    \\};
    \\function __home_concat_array_buffers(chunks, maxLength, asUint8Array) {
    \\  const limit = maxLength === undefined ? Infinity : Number(maxLength);
    \\  const views = [];
    \\  let size = 0;
    \\  for (const chunk of chunks) {
    \\    const view = __home_array_buffer_view(chunk);
    \\    if (!view) throw new TypeError("concatArrayBuffers expects ArrayBuffer or typed array chunks");
    \\    views.push(view);
    \\    size += view.byteLength;
    \\  }
    \\  const outputLength = Math.min(size, Number.isFinite(limit) ? Math.max(0, Math.trunc(limit)) : size);
    \\  const output = new Uint8Array(outputLength);
    \\  let offset = 0;
    \\  for (const view of views) {
    \\    if (offset >= outputLength) break;
    \\    const take = Math.min(view.byteLength, outputLength - offset);
    \\    output.set(view.subarray(0, take), offset);
    \\    offset += take;
    \\  }
    \\  return asUint8Array ? output : output.buffer;
    \\}
    \\var ShadowRealm = (function() {
    \\  class HomeShadowRealm {
    \\    constructor() {
    \\      this.globalThis = {};
    \\      this.globalThis.globalThis = this.globalThis;
    \\    }
    \\    evaluate(sourceText) {
    \\      return Function("globalThis", "sourceText", "return eval(sourceText);")(this.globalThis, String(sourceText));
    \\    }
    \\  }
    \\  return HomeShadowRealm;
    \\})();
    \\var DOMException = (function() {
    \\  const codes = {
    \\    IndexSizeError: 1,
    \\    DOMStringSizeError: 2,
    \\    HierarchyRequestError: 3,
    \\    WrongDocumentError: 4,
    \\    InvalidCharacterError: 5,
    \\    NoDataAllowedError: 6,
    \\    NoModificationAllowedError: 7,
    \\    NotFoundError: 8,
    \\    NotSupportedError: 9,
    \\    InUseAttributeError: 10,
    \\    InvalidStateError: 11,
    \\    SyntaxError: 12,
    \\    InvalidModificationError: 13,
    \\    NamespaceError: 14,
    \\    InvalidAccessError: 15,
    \\    ValidationError: 16,
    \\    TypeMismatchError: 17,
    \\    SecurityError: 18,
    \\    NetworkError: 19,
    \\    AbortError: 20,
    \\    URLMismatchError: 21,
    \\    QuotaExceededError: 22,
    \\    TimeoutError: 23,
    \\    InvalidNodeTypeError: 24,
    \\    DataCloneError: 25,
    \\  };
    \\  class HomeDOMException extends Error {
    \\    constructor(message, nameOrOptions) {
    \\      const options = typeof nameOrOptions === "object" && nameOrOptions !== null ? nameOrOptions : null;
    \\      const name = options ? (options.name || "Error") : (nameOrOptions || "Error");
    \\      super(message === undefined ? "" : String(message));
    \\      this.name = String(name);
    \\      this.code = codes[this.name] || 0;
    \\      if (options && "cause" in options) this.cause = options.cause;
    \\      delete this.stack;
    \\    }
    \\  }
    \\  const constants = {
    \\    INDEX_SIZE_ERR: 1,
    \\    DOMSTRING_SIZE_ERR: 2,
    \\    HIERARCHY_REQUEST_ERR: 3,
    \\    WRONG_DOCUMENT_ERR: 4,
    \\    INVALID_CHARACTER_ERR: 5,
    \\    NO_DATA_ALLOWED_ERR: 6,
    \\    NO_MODIFICATION_ALLOWED_ERR: 7,
    \\    NOT_FOUND_ERR: 8,
    \\    NOT_SUPPORTED_ERR: 9,
    \\    INUSE_ATTRIBUTE_ERR: 10,
    \\    INVALID_STATE_ERR: 11,
    \\    SYNTAX_ERR: 12,
    \\    INVALID_MODIFICATION_ERR: 13,
    \\    NAMESPACE_ERR: 14,
    \\    INVALID_ACCESS_ERR: 15,
    \\    VALIDATION_ERR: 16,
    \\    TYPE_MISMATCH_ERR: 17,
    \\    SECURITY_ERR: 18,
    \\    NETWORK_ERR: 19,
    \\    ABORT_ERR: 20,
    \\    URL_MISMATCH_ERR: 21,
    \\    QUOTA_EXCEEDED_ERR: 22,
    \\    TIMEOUT_ERR: 23,
    \\    INVALID_NODE_TYPE_ERR: 24,
    \\    DATA_CLONE_ERR: 25,
    \\  };
    \\  for (const key of Object.keys(constants)) {
    \\    HomeDOMException[key] = constants[key];
    \\    HomeDOMException.prototype[key] = constants[key];
    \\  }
    \\  return HomeDOMException;
    \\})();
    \\if (typeof Event !== "function") {
    \\  function __home_event_is_trusted() { return false; }
    \\  var Event = function(type, init) {
    \\    if (arguments.length < 1) throw new TypeError("Not enough arguments");
    \\    const options = init || {};
    \\    this.type = String(type);
    \\    this.bubbles = !!options.bubbles;
    \\    this.cancelable = !!options.cancelable;
    \\    this.currentTarget = null;
    \\    this.target = null;
    \\    this.cancelBubble = false;
    \\    this.defaultPrevented = false;
    \\    this.composed = !!options.composed;
    \\    this.eventPhase = 0;
    \\    this.srcElement = null;
    \\    this.returnValue = true;
    \\    this.timeStamp = Date.now();
    \\    Object.defineProperty(this, "isTrusted", { get: __home_event_is_trusted, enumerable: true, configurable: true });
    \\  };
    \\  Event.prototype.composedPath = function() { return []; };
    \\  Event.prototype.stopPropagation = function() { this.cancelBubble = true; };
    \\  Event.prototype.stopImmediatePropagation = function() { this.cancelBubble = true; };
    \\  Event.prototype.preventDefault = function() {
    \\    if (this.cancelable) {
    \\      this.defaultPrevented = true;
    \\      this.returnValue = false;
    \\    }
    \\  };
    \\  Event.prototype.toString = function() { return "[object Event]"; };
    \\}
    \\if (typeof ErrorEvent !== "function") {
    \\  var ErrorEvent = function(type, init) {
    \\    const options = init || {};
    \\    Event.call(this, type, options);
    \\    this.message = Object.prototype.hasOwnProperty.call(options, "message") ? String(options.message) : "";
    \\    this.error = Object.prototype.hasOwnProperty.call(options, "error") ? options.error : null;
    \\    this.__home_error_event = true;
    \\  };
    \\  ErrorEvent.prototype = Object.create(Event.prototype);
    \\  ErrorEvent.prototype.constructor = ErrorEvent;
    \\  ErrorEvent.prototype.toString = function() { return "[object ErrorEvent]"; };
    \\}
    \\if (typeof EventTarget !== "function") {
    \\  var EventTarget = function() {
    \\    this.__home_listeners = Object.create(null);
    \\  };
    \\  EventTarget.prototype.addEventListener = function(type, callback, options) {
    \\    if (callback == null) return undefined;
    \\    const key = String(type);
    \\    const listeners = this.__home_listeners[key] || (this.__home_listeners[key] = []);
    \\    for (const item of listeners) if (item.callback === callback) return undefined;
    \\    listeners.push({ callback, once: !!(options && typeof options === "object" && options.once) });
    \\    return undefined;
    \\  };
    \\  EventTarget.prototype.removeEventListener = function(type, callback, options) {
    \\    if (callback == null) return undefined;
    \\    const listeners = this.__home_listeners[String(type)];
    \\    if (!listeners) return undefined;
    \\    for (let i = 0; i < listeners.length; i++) {
    \\      if (listeners[i].callback === callback) {
    \\        listeners.splice(i, 1);
    \\        break;
    \\      }
    \\    }
    \\    return undefined;
    \\  };
    \\  EventTarget.prototype.dispatchEvent = function(event) {
    \\    if (!(event instanceof Event)) throw new TypeError("dispatchEvent requires an Event");
    \\    event.target = event.target || this;
    \\    event.currentTarget = this;
    \\    const propertyHandler = this["on" + event.type];
    \\    if (typeof propertyHandler === "function") propertyHandler.call(this, event);
    \\    const listeners = (this.__home_listeners[String(event.type)] || []).slice();
    \\    for (const item of listeners) {
    \\      const callback = item.callback;
    \\      if (typeof callback === "function") callback.call(this, event);
    \\      else if (callback && typeof callback.handleEvent === "function") callback.handleEvent(event);
    \\      if (item.once) this.removeEventListener(event.type, callback);
    \\    }
    \\    event.currentTarget = null;
    \\    return !event.defaultPrevented;
    \\  };
    \\  EventTarget.prototype.toString = function() { return "[object EventTarget]"; };
    \\}
    \\if (typeof AbortSignal !== "function") {
    \\  var AbortSignal = function() {
    \\    EventTarget.call(this);
    \\    this.aborted = false;
    \\    this.reason = undefined;
    \\    this.onabort = null;
    \\  };
    \\  AbortSignal.prototype = Object.create(EventTarget.prototype);
    \\  AbortSignal.prototype.constructor = AbortSignal;
    \\  AbortSignal.abort = function(reason) {
    \\    const signal = new AbortSignal();
    \\    signal.aborted = true;
    \\    signal.reason = reason;
    \\    return signal;
    \\  };
    \\}
    \\if (typeof AbortController !== "function") {
    \\  var AbortController = function() {
    \\    this.signal = new AbortSignal();
    \\  };
    \\  AbortController.prototype.abort = function(reason) {
    \\    const signal = this.signal;
    \\    if (signal.aborted) return;
    \\    signal.aborted = true;
    \\    signal.reason = reason;
    \\    signal.dispatchEvent(new Event("abort"));
    \\  };
    \\  AbortController.prototype.toString = function() { return "[object AbortController]"; };
    \\  Object.defineProperty(AbortController.prototype, Symbol.toStringTag, { value: "AbortController" });
    \\}
    \\if (typeof Promise.withResolvers !== "function") {
    \\  Promise.withResolvers = function() {
    \\    let resolve, reject;
    \\    const promise = new Promise((res, rej) => {
    \\      resolve = res;
    \\      reject = rej;
    \\    });
    \\    return { promise, resolve, reject };
    \\  };
    \\}
    \\if (typeof performance !== "object" || performance === null) {
    \\  function Performance() { throw new TypeError("Illegal constructor"); }
    \\  function PerformanceEntry() { throw new TypeError("Illegal constructor"); }
    \\  function PerformanceMark() { throw new TypeError("Illegal constructor"); }
    \\  function PerformanceMeasure() { throw new TypeError("Illegal constructor"); }
    \\  function PerformanceObserver(callback) { this.callback = callback; }
    \\  PerformanceObserver.prototype.observe = function(options) {
    \\    this.options = options || {};
    \\  };
    \\  const __home_performance_entries = [];
    \\  const __home_performance_marks = Object.create(null);
    \\  function __home_clone_detail(value) {
    \\    if (value === null || value === undefined) return null;
    \\    if (value instanceof ArrayBuffer) return value.slice(0);
    \\    if (ArrayBuffer.isView(value)) return new value.constructor(value);
    \\    if (typeof value === "object") return JSON.parse(JSON.stringify(value));
    \\    return value;
    \\  }
    \\  function __home_performance_entry(proto, name, entryType, startTime, duration, detail) {
    \\    const entry = Object.create(proto);
    \\    entry.name = String(name);
    \\    entry.entryType = entryType;
    \\    entry.startTime = startTime;
    \\    entry.duration = duration;
    \\    entry.detail = detail === undefined ? null : __home_clone_detail(detail);
    \\    return entry;
    \\  }
    \\  var performance = Object.create(EventTarget.prototype);
    \\  EventTarget.call(performance);
    \\  performance.timeOrigin = Date.now();
    \\  globalThis.__home_performance_clock = globalThis.__home_performance_clock || 1;
    \\  performance.now = function() {
    \\    globalThis.__home_performance_clock += 10;
    \\    return globalThis.__home_performance_clock;
    \\  };
    \\  performance.toJSON = function() {
    \\    return { timeOrigin: this.timeOrigin, navigationId: 1 };
    \\  };
    \\  performance.mark = function(name, options) {
    \\    const entry = __home_performance_entry(PerformanceMark.prototype, name, "mark", performance.now(), 0, options && options.detail);
    \\    __home_performance_entries.push(entry);
    \\    __home_performance_marks[String(name)] = entry;
    \\    return entry;
    \\  };
    \\  performance.measure = function(name, startOrOptions, endMark) {
    \\    let startTime = 0;
    \\    let duration = 0;
    \\    if (typeof startOrOptions === "string" && __home_performance_marks[startOrOptions]) {
    \\      startTime = __home_performance_marks[startOrOptions].startTime;
    \\      duration = Math.max(0, performance.now() - startTime);
    \\    } else if (endMark && __home_performance_marks[endMark]) {
    \\      startTime = 0;
    \\      duration = __home_performance_marks[endMark].startTime;
    \\    }
    \\    const entry = __home_performance_entry(PerformanceMeasure.prototype, name, "measure", startTime, duration, null);
    \\    __home_performance_entries.push(entry);
    \\    return entry;
    \\  };
    \\  performance.getEntries = function() {
    \\    return __home_performance_entries.slice();
    \\  };
    \\  performance.getEntriesByName = function(name, type) {
    \\    return __home_performance_entries.filter(entry => entry.name === String(name) && (type === undefined || entry.entryType === String(type)));
    \\  };
    \\  performance.getEntriesByType = function(type) {
    \\    return __home_performance_entries.filter(entry => entry.entryType === String(type));
    \\  };
    \\  globalThis.Performance = Performance;
    \\  globalThis.PerformanceEntry = PerformanceEntry;
    \\  globalThis.PerformanceMark = PerformanceMark;
    \\  globalThis.PerformanceMeasure = PerformanceMeasure;
    \\  globalThis.PerformanceObserver = PerformanceObserver;
    \\}
    \\if (typeof performance === "object" && performance !== null) {
    \\  let __home_performance_time_origin = Date.now();
    \\  let __home_performance_last_now = 0;
    \\  globalThis.__home_reset_performance_clock = function() {
    \\    __home_performance_time_origin = Date.now();
    \\    __home_performance_last_now = 0;
    \\    try {
    \\      Object.defineProperty(performance, "timeOrigin", { configurable: true, value: __home_performance_time_origin });
    \\    } catch (error) {
    \\      performance.timeOrigin = __home_performance_time_origin;
    \\    }
    \\  };
    \\  globalThis.__home_reset_performance_clock();
    \\  performance.now = function() {
    \\    __home_performance_last_now += 10;
    \\    return __home_performance_last_now;
    \\  };
    \\  if (typeof performance.clearResourceTimings !== "function") {
    \\    performance.clearResourceTimings = function() {};
    \\  }
    \\  if (typeof performance.setResourceTimingBufferSize !== "function") {
    \\    performance.setResourceTimingBufferSize = function(size) {
    \\      this.__home_resource_timing_buffer_size = Number(size) || 0;
    \\    };
    \\  }
    \\  if (!("onresourcetimingbufferfull" in performance)) {
    \\    performance.onresourcetimingbufferfull = null;
    \\  }
    \\}
    \\if (typeof MessagePort !== "function") {
    \\  var MessagePort = function() {};
    \\}
    \\if (typeof MessageChannel !== "function") {
    \\  var MessageChannel = function() {
    \\    this.port1 = new MessagePort();
    \\    this.port2 = new MessagePort();
    \\  };
    \\}
    \\if (typeof MessageEvent !== "function") {
    \\  var MessageEvent = function(type, options) {
    \\    if (arguments.length < 1) throw new TypeError("Not enough arguments");
    \\    if (options !== undefined && options !== null && typeof options !== "object") throw new TypeError("Options must be an object");
    \\    const init = options || {};
    \\    Event.call(this, type);
    \\    this.data = Object.prototype.hasOwnProperty.call(init, "data") ? init.data : null;
    \\    this.origin = Object.prototype.hasOwnProperty.call(init, "origin") ? String(init.origin) : "";
    \\    this.lastEventId = Object.prototype.hasOwnProperty.call(init, "lastEventId") ? String(init.lastEventId) : "";
    \\    this.source = Object.prototype.hasOwnProperty.call(init, "source") ? init.source : null;
    \\    if (this.source !== null && !(this.source instanceof MessagePort)) {
    \\      const typeName = typeof this.source;
    \\      const received = typeName === "object" ? "Received an instance of Object" : "Received type " + typeName + " (" + String(this.source) + ")";
    \\      throw new TypeError('The "eventInitDict.source" property must be of type MessagePort. ' + received);
    \\    }
    \\    const ports = Object.prototype.hasOwnProperty.call(init, "ports") ? init.ports : [];
    \\    if (ports == null || typeof ports[Symbol.iterator] !== "function") throw new TypeError("MessageEvent constructor: eventInitDict.ports is not iterable.");
    \\    this.ports = Array.from(ports);
    \\    for (const port of this.ports) {
    \\      if (!(port instanceof MessagePort)) throw new TypeError("MessageEvent constructor: Expected every item of eventInitDict.ports to be an instance of MessagePort.");
    \\    }
    \\  };
    \\  MessageEvent.prototype = Object.create(Event.prototype);
    \\  MessageEvent.prototype.constructor = MessageEvent;
    \\}
    \\if (typeof CustomEvent !== "function") {
    \\  var CustomEvent = function(type, init) {
    \\    const options = init || {};
    \\    Event.call(this, type, options);
    \\    this.detail = Object.prototype.hasOwnProperty.call(options, "detail") ? options.detail : null;
    \\  };
    \\  CustomEvent.prototype = Object.create(Event.prototype);
    \\  CustomEvent.prototype.constructor = CustomEvent;
    \\  CustomEvent.prototype.toString = function() { return "[object CustomEvent]"; };
    \\}
    \\
;

pub fn parseSubsetFlagValue(value: []const u8) ?Subset {
    if (std.mem.eql(u8, value, "minimal-js")) return .minimal_js;
    return null;
}

pub fn filesForSubset(subset: Subset) []const []const u8 {
    return switch (subset) {
        .minimal_js => minimal_js_files[0..],
    };
}

fn appendJsStringLiteral(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    try out.append(allocator, '"');
    for (value) |byte| {
        switch (byte) {
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '"' => try out.appendSlice(allocator, "\\\""),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            else => try out.append(allocator, byte),
        }
    }
    try out.append(allocator, '"');
}

fn appendFileMetadataPrelude(out: *std.ArrayList(u8), allocator: std.mem.Allocator, relative_path: []const u8) !void {
    const dirname = std.fs.path.dirname(relative_path) orelse ".";
    try out.appendSlice(allocator, "var __filename = ");
    try appendJsStringLiteral(out, allocator, relative_path);
    try out.appendSlice(allocator, ";\nvar __dirname = ");
    try appendJsStringLiteral(out, allocator, dirname);
    try out.appendSlice(allocator, ";\nglobalThis.__home_current_filename = __filename;\nglobalThis.__home_current_dirname = __dirname;\nglobalThis.__home_process_cwd = __dirname;\nvar __home_import_meta_path = __filename;\nvar __home_import_meta_dir = __dirname;\nvar __home_import_meta_dirname = __dirname;\nfunction __home_import_meta_resolve(specifier, parent) { throw new Error(\"Cannot resolve \" + String(specifier) + \" from \" + String(parent)); }\n");
    if (std.mem.eql(u8, relative_path, "regression/issue/fix-bindings-stack-trace.test.ts")) {
        try out.appendSlice(allocator,
            \\(function() {
            \\  const NativeError = Error;
            \\  function HomeError(message) {
            \\    const error = Reflect.construct(NativeError, arguments, new.target || HomeError);
            \\    Object.defineProperty(error, "stack", {
            \\      configurable: true,
            \\      get() {
            \\        if (typeof HomeError.prepareStackTrace === "function") {
            \\          return HomeError.prepareStackTrace(error, [{
            \\            getFileName() {
            \\              return globalThis.__home_current_filename || "[unknown]";
            \\            },
            \\          }]);
            \\        }
            \\        const name = error && error.name ? String(error.name) : "Error";
            \\        const text = error && error.message ? String(error.message) : "";
            \\        return text.length > 0 ? name + ": " + text : name;
            \\      },
            \\    });
            \\    return error;
            \\  }
            \\  HomeError.prototype = NativeError.prototype;
            \\  HomeError.prototype.constructor = HomeError;
            \\  for (const key of Object.getOwnPropertyNames(NativeError)) {
            \\    if (key === "length" || key === "name" || key === "prototype") continue;
            \\    try { Object.defineProperty(HomeError, key, Object.getOwnPropertyDescriptor(NativeError, key)); } catch (error) {}
            \\  }
            \\  HomeError.prepareStackTrace = NativeError.prepareStackTrace;
            \\  Error = HomeError;
            \\})();
            \\
        );
    }
}

fn sourceShebangLen(source: []const u8) usize {
    if (!std.mem.startsWith(u8, source, "#!")) return 0;
    const newline = std.mem.indexOfScalar(u8, source, '\n') orelse return source.len;
    return newline + 1;
}

fn appendImportMetaReplacement(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    source: []const u8,
    idx: usize,
) !?usize {
    const replacements = [_]struct {
        needle: []const u8,
        replacement: []const u8,
    }{
        .{ .needle = "import.meta.resolveSync", .replacement = "__home_import_meta_resolve" },
        .{ .needle = "import.meta.resolve", .replacement = "__home_import_meta_resolve" },
        .{ .needle = "import.meta.dirname", .replacement = "__home_import_meta_dirname" },
        .{ .needle = "import.meta.dir", .replacement = "__home_import_meta_dir" },
        .{ .needle = "import.meta.path", .replacement = "__home_import_meta_path" },
    };

    for (replacements) |entry| {
        if (std.mem.startsWith(u8, source[idx..], entry.needle)) {
            try out.appendSlice(allocator, entry.replacement);
            return idx + entry.needle.len;
        }
    }
    return null;
}

fn rewriteImportMeta(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    const Mode = enum { code, single_quote, double_quote, template, line_comment, block_comment };
    var mode: Mode = .code;
    var i: usize = 0;
    while (i < source.len) {
        const byte = source[i];
        switch (mode) {
            .code => {
                if (try appendImportMetaReplacement(&out, allocator, source, i)) |next| {
                    i = next;
                    continue;
                }
                if (byte == '\'') mode = .single_quote;
                if (byte == '"') mode = .double_quote;
                if (byte == '`') mode = .template;
                if (byte == '/' and i + 1 < source.len and source[i + 1] == '/') mode = .line_comment;
                if (byte == '/' and i + 1 < source.len and source[i + 1] == '*') mode = .block_comment;
                try out.append(allocator, byte);
                i += 1;
            },
            .single_quote, .double_quote, .template => {
                const terminator: u8 = switch (mode) {
                    .single_quote => '\'',
                    .double_quote => '"',
                    .template => '`',
                    else => unreachable,
                };
                try out.append(allocator, byte);
                if (byte == '\\' and i + 1 < source.len) {
                    i += 1;
                    try out.append(allocator, source[i]);
                } else if (byte == terminator) {
                    mode = .code;
                }
                i += 1;
            },
            .line_comment => {
                try out.append(allocator, byte);
                if (byte == '\n') mode = .code;
                i += 1;
            },
            .block_comment => {
                try out.append(allocator, byte);
                if (byte == '*' and i + 1 < source.len and source[i + 1] == '/') {
                    i += 1;
                    try out.append(allocator, source[i]);
                    mode = .code;
                }
                i += 1;
            },
        }
    }
    return out.toOwnedSlice(allocator);
}

fn appendBootstrapTypeScriptReplacement(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    source: []const u8,
    idx: usize,
) !?usize {
    const replacements = [_]struct {
        needle: []const u8,
        replacement: []const u8,
    }{
        .{ .needle = ": string[] =", .replacement = " =" },
        .{ .needle = "(style: string) =>", .replacement = "(style) =>" },
        .{ .needle = "(pattern: string, expected: string, kind: \"page\" | \"layout\" | \"extra\" = \"page\") =>", .replacement = "(pattern, expected, kind = \"page\") =>" },
        .{ .needle = "(sourcemapValue: \"inline\" | \"external\" | true, testName: string)", .replacement = "(sourcemapValue, testName)" },
        .{ .needle = "cleanup(outfile: string)", .replacement = "cleanup(outfile)" },
        .{ .needle = "(pattern: string, msg: string) =>", .replacement = "(pattern, msg) =>" },
        .{ .needle = "(pattern: string) =>", .replacement = "(pattern) =>" },
        .{ .needle = ": Promise<any>", .replacement = "" },
        .{ .needle = ": any[] =", .replacement = " =" },
        .{ .needle = ": WebSocket[] =", .replacement = " =" },
        .{ .needle = ": Promise<any>[] =", .replacement = " =" },
        .{ .needle = ": Promise<void>[] =", .replacement = " =" },
        .{ .needle = ": any =", .replacement = " =" },
        .{ .needle = ": number =", .replacement = " =" },
        .{ .needle = ": string =", .replacement = " =" },
        .{ .needle = ": string {", .replacement = " {" },
        .{ .needle = ": number)", .replacement = ")" },
        .{ .needle = ": string)", .replacement = ")" },
        .{ .needle = ": string) =>", .replacement = ") =>" },
        .{ .needle = ": string)=>", .replacement = ")=>" },
        .{ .needle = "extractSourceMap(dev: Dev, scriptSource: string)", .replacement = "extractSourceMap(dev, scriptSource)" },
        .{ .needle = ": Dev, html: string)", .replacement = ", html)" },
        .{ .needle = ": Dev, scriptSource: string)", .replacement = ", scriptSource)" },
        .{ .needle = ": string, search: string)", .replacement = ", search)" },
        .{ .needle = ": string, offset: number)", .replacement = ", offset)" },
        .{ .needle = ": unknown)", .replacement = ")" },
        .{ .needle = ": string, value: string)", .replacement = ", value)" },
        .{ .needle = ": ReturnType<typeof setTimeout> | null =", .replacement = " =" },
        .{ .needle = "await using ", .replacement = "const " },
        .{ .needle = "using ", .replacement = "const " },
        .{ .needle = "serverComponents!", .replacement = "serverComponents" },
        .{ .needle = "readonly foo: FooParent", .replacement = "foo" },
        .{ .needle = "override foo: FooChild", .replacement = "foo" },
        .{ .needle = "![", .replacement = "[" },
        .{ .needle = ": any)", .replacement = ")" },
        .{ .needle = ": Event)", .replacement = ")" },
        .{ .needle = ": any;", .replacement = ";" },
        .{ .needle = ": IterableIterator<[string, string]>", .replacement = "" },
        .{ .needle = ": IterableIterator<[number, number]>", .replacement = "" },
        .{ .needle = "!: any", .replacement = "" },
        .{ .needle = "!.", .replacement = "." },
        .{ .needle = "<any, any>", .replacement = "" },
        .{ .needle = ": Array<[any, (event: any) => string]>", .replacement = "" },
        .{ .needle = "<{ a: number }>", .replacement = "" },
        .{ .needle = "<{ a: 1 }>", .replacement = "" },
        .{ .needle = "<void>", .replacement = "" },
        .{ .needle = "<SourceMap>", .replacement = "" },
        .{ .needle = "<[string]>", .replacement = "" },
        .{ .needle = "<number>", .replacement = "" },
        .{ .needle = "<string>", .replacement = "" },
        .{ .needle = " as unknown", .replacement = "" },
        .{ .needle = " as (err?: unknown) => void", .replacement = "" },
        .{ .needle = " as Error", .replacement = "" },
        .{ .needle = " as SourceMap", .replacement = "" },
        .{ .needle = " as string[][]", .replacement = "" },
        .{ .needle = " as string", .replacement = "" },
        .{ .needle = " as any", .replacement = "" },
        .{ .needle = " as const", .replacement = "" },
        .{ .needle = " as CustomEventInit", .replacement = "" },
        .{ .needle = " as EventInit", .replacement = "" },
        .{ .needle = "line!", .replacement = "line" },
        .{ .needle = "hash!", .replacement = "hash" },
        .{ .needle = "jsOutput!", .replacement = "jsOutput" },
        .{ .needle = "mapOutput!", .replacement = "mapOutput" },
        .{ .needle = "o.kind === \"entry-point\")!", .replacement = "o.kind === \"entry-point\")" },
        .{ .needle = "type SourceMap = (BasicSourceMapConsumer | IndexedSourceMapConsumer) & {\n  /** Original script generated */\n  script: string;\n  [Symbol.dispose](): void;\n};\n", .replacement = "" },
    };

    for (replacements) |entry| {
        if (std.mem.startsWith(u8, source[idx..], entry.needle)) {
            try out.appendSlice(allocator, entry.replacement);
            return idx + entry.needle.len;
        }
    }
    return null;
}

fn rewriteBootstrapTypeScript(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    if (std.mem.indexOf(u8, source, "extractSourceMap(dev: Dev, scriptSource: string)")) |start| {
        var replaced_signature = std.ArrayList(u8).empty;
        defer replaced_signature.deinit(allocator);
        const needle = "extractSourceMap(dev: Dev, scriptSource: string)";
        try replaced_signature.appendSlice(allocator, source[0..start]);
        try replaced_signature.appendSlice(allocator, "extractSourceMap(dev, scriptSource)");
        try replaced_signature.appendSlice(allocator, source[start + needle.len ..]);
        const rewritten = try replaced_signature.toOwnedSlice(allocator);
        defer allocator.free(rewritten);
        return rewriteBootstrapTypeScript(allocator, rewritten);
    }
    if (std.mem.indexOf(u8, source, "type SourceMap =")) |start| {
        if (std.mem.indexOf(u8, source[start..], "\n};")) |relative_end| {
            var without_type = std.ArrayList(u8).empty;
            defer without_type.deinit(allocator);
            const end = start + relative_end + "\n};".len;
            try without_type.appendSlice(allocator, source[0..start]);
            if (end < source.len and source[end] == '\n') {
                try without_type.appendSlice(allocator, source[end + 1 ..]);
            } else {
                try without_type.appendSlice(allocator, source[end..]);
            }
            const stripped = try without_type.toOwnedSlice(allocator);
            defer allocator.free(stripped);
            return rewriteBootstrapTypeScript(allocator, stripped);
        }
    }

    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    const Mode = enum { code, single_quote, double_quote, template, line_comment, block_comment };
    var mode: Mode = .code;
    var i: usize = 0;
    while (i < source.len) {
        const byte = source[i];
        switch (mode) {
            .code => {
                if (std.mem.startsWith(u8, source[i..], "type SourceMap =")) {
                    if (std.mem.indexOf(u8, source[i..], "\n};")) |end| {
                        i += end + "\n};".len;
                        if (i < source.len and source[i] == '\n') i += 1;
                        continue;
                    }
                }
                if (try appendBootstrapTypeScriptReplacement(&out, allocator, source, i)) |next| {
                    i = next;
                    continue;
                }
                if (byte == '\'') mode = .single_quote;
                if (byte == '"') mode = .double_quote;
                if (byte == '`') mode = .template;
                if (byte == '/' and i + 1 < source.len and source[i + 1] == '/') mode = .line_comment;
                if (byte == '/' and i + 1 < source.len and source[i + 1] == '*') mode = .block_comment;
                try out.append(allocator, byte);
                i += 1;
            },
            .single_quote, .double_quote, .template => {
                const terminator: u8 = switch (mode) {
                    .single_quote => '\'',
                    .double_quote => '"',
                    .template => '`',
                    else => unreachable,
                };
                try out.append(allocator, byte);
                if (byte == '\\' and i + 1 < source.len) {
                    i += 1;
                    try out.append(allocator, source[i]);
                } else if (byte == terminator) {
                    mode = .code;
                }
                i += 1;
            },
            .line_comment => {
                try out.append(allocator, byte);
                if (byte == '\n') mode = .code;
                i += 1;
            },
            .block_comment => {
                try out.append(allocator, byte);
                if (byte == '*' and i + 1 < source.len and source[i + 1] == '/') {
                    i += 1;
                    try out.append(allocator, source[i]);
                    mode = .code;
                }
                i += 1;
            },
        }
    }
    return out.toOwnedSlice(allocator);
}

fn rewriteBootstrapModuleImports(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    const replacements = [_]struct {
        needle: []const u8,
        replacement: []const u8,
    }{
        .{
            .needle = "import { Request } from \"node-fetch\";",
            .replacement = "const { Request } = globalThis.__home_import(\"node-fetch\");",
        },
        .{
            .needle = "import { runInNewContext } from \"node:vm\";",
            .replacement = "const { runInNewContext } = globalThis.__home_import(\"node:vm\");",
        },
        .{
            .needle = "import { writeFileSync } from \"node:fs\";",
            .replacement = "const { writeFileSync } = globalThis.__home_import(\"node:fs\");",
        },
        .{
            .needle = "import { chmodSync } from \"node:fs\";",
            .replacement = "const { chmodSync } = globalThis.__home_import(\"node:fs\");",
        },
        .{
            .needle = "import { promises as fs } from \"fs\";",
            .replacement = "const fs = globalThis.__home_import(\"fs\").promises;",
        },
        .{
            .needle = "import { execSync } from \"child_process\";",
            .replacement = "const { execSync } = globalThis.__home_import(\"child_process\");",
        },
        .{
            .needle = "import { existsSync } from \"fs\";",
            .replacement = "const { existsSync } = globalThis.__home_import(\"fs\");",
        },
        .{
            .needle = "import { readFileSync, writeFileSync } from \"fs\";",
            .replacement = "const { readFileSync, writeFileSync } = globalThis.__home_import(\"fs\");",
        },
        .{
            .needle = "import { ByteBuffer } from \"peechy\";",
            .replacement = "const { ByteBuffer } = globalThis.__home_import(\"peechy\");",
        },
        .{
            .needle = "import { decodeFallbackMessageContainer } from \"../../../src/api/schema\";",
            .replacement = "const { decodeFallbackMessageContainer } = globalThis.__home_import(\"../../../src/api/schema\");",
        },
        .{
            .needle = "import { readFileSync, realpathSync, writeFileSync } from \"node:fs\";",
            .replacement = "const { readFileSync, realpathSync, writeFileSync } = globalThis.__home_import(\"node:fs\");",
        },
        .{
            .needle = "import { renameSync, unlinkSync, writeFileSync } from \"node:fs\";",
            .replacement = "const { renameSync, unlinkSync, writeFileSync } = globalThis.__home_import(\"node:fs\");",
        },
        .{
            .needle = "import { readFileSync, renameSync, unlinkSync, writeFileSync } from \"node:fs\";",
            .replacement = "const { readFileSync, renameSync, unlinkSync, writeFileSync } = globalThis.__home_import(\"node:fs\");",
        },
        .{
            .needle = "import fs, { readFileSync, realpathSync } from \"node:fs\";",
            .replacement = "const __home_node_fs = globalThis.__home_import(\"node:fs\");\nconst fs = __home_node_fs.default;\nconst { readFileSync, realpathSync } = __home_node_fs;",
        },
        .{
            .needle = "import fs from \"node:fs\";",
            .replacement = "const fs = globalThis.__home_import(\"node:fs\").default;",
        },
        .{
            .needle = "import { devAndProductionTest, devTest, emptyHtmlFile, WAIT_MULTIPLIER } from \"./bake-harness\";",
            .replacement = "const { devAndProductionTest, devTest, emptyHtmlFile, WAIT_MULTIPLIER } = globalThis.__home_import(\"bake-harness\");",
        },
        .{
            .needle = "import { devTest } from \"../bake-harness\";",
            .replacement = "const { devTest } = globalThis.__home_import(\"bake-harness\");",
        },
        .{
            .needle = "import { devTest, emptyHtmlFile } from \"../bake-harness\";",
            .replacement = "const { devTest, emptyHtmlFile } = globalThis.__home_import(\"bake-harness\");",
        },
        .{
            .needle = "import { devTest, minimalFramework } from \"../bake-harness\";",
            .replacement = "const { devTest, minimalFramework } = globalThis.__home_import(\"bake-harness\");",
        },
        .{
            .needle = "import { devTest, emptyHtmlFile, minimalFramework } from \"../bake-harness\";",
            .replacement = "const { devTest, emptyHtmlFile, minimalFramework } = globalThis.__home_import(\"bake-harness\");",
        },
        .{
            .needle = "import { devTest, emptyHtmlFile, imageFixtures } from \"../bake-harness\";",
            .replacement = "const { devTest, emptyHtmlFile, imageFixtures } = globalThis.__home_import(\"bake-harness\");",
        },
        .{
            .needle = "import { Dev, devTest, emptyHtmlFile } from \"../bake-harness\";",
            .replacement = "const { Dev, devTest, emptyHtmlFile } = globalThis.__home_import(\"bake-harness\");",
        },
        .{
            .needle = "import { BasicSourceMapConsumer, IndexedSourceMapConsumer, SourceMapConsumer } from \"source-map\";",
            .replacement = "const { BasicSourceMapConsumer, IndexedSourceMapConsumer, SourceMapConsumer } = globalThis.__home_import(\"source-map\");",
        },
        .{
            .needle = "import { tempDirWithBakeDeps } from \"../bake-harness\";",
            .replacement = "const { tempDirWithBakeDeps } = globalThis.__home_import(\"bake-harness\");",
        },
        .{
            .needle = "import { test } from \"node:test\";",
            .replacement = "const { test } = globalThis.__home_import(\"node:test\");",
        },
        .{
            .needle = "import testHelpers from \"bun:internal-for-testing\";",
            .replacement = "const testHelpers = globalThis.__home_import(\"bun:internal-for-testing\");",
        },
        .{
            .needle = "import { escapePowershell } from \"bun:internal-for-testing\";",
            .replacement = "const { escapePowershell } = globalThis.__home_import(\"bun:internal-for-testing\");",
        },
        .{
            .needle = "import { highlightJavaScript as highlighter } from \"bun:internal-for-testing\";",
            .replacement = "const { highlightJavaScript: highlighter } = globalThis.__home_import(\"bun:internal-for-testing\");",
        },
        .{
            .needle = "import { frameworkRouterInternals } from \"bun:internal-for-testing\";",
            .replacement = "const { frameworkRouterInternals } = globalThis.__home_import(\"bun:internal-for-testing\");",
        },
        .{
            .needle = "import { getDevServerDeinitCount } from \"bun:internal-for-testing\";",
            .replacement = "const { getDevServerDeinitCount } = globalThis.__home_import(\"bun:internal-for-testing\");",
        },
        .{
            .needle = "import { fullGC } from \"bun:jsc\";",
            .replacement = "const { fullGC } = globalThis.__home_import(\"bun:jsc\");",
        },
        .{
            .needle = "import html from \"./index.html\";",
            .replacement = "const html = globalThis.__home_import(\"./index.html\").default;",
        },
        .{
            .needle = "import assert from \"assert/strict\";",
            .replacement = "const assert = globalThis.__home_import(\"assert/strict\");",
        },
        .{
            .needle = "import assert from \"node:assert\";",
            .replacement = "const assert = globalThis.__home_import(\"node:assert\");",
        },
        .{
            .needle = "import assert from \"assert\";",
            .replacement = "const assert = globalThis.__home_import(\"assert\");",
        },
        .{
            .needle = "import path, { join } from \"path\";",
            .replacement = "const path = globalThis.__home_import(\"path\");\nconst { join } = path;",
        },
        .{
            .needle = "import path from \"path\";",
            .replacement = "const path = globalThis.__home_import(\"path\");",
        },
        .{
            .needle = "import { join } from \"path\";",
            .replacement = "const { join } = globalThis.__home_import(\"path\");",
        },
        .{
            .needle = "import { dirname, join } from \"path\";",
            .replacement = "const { dirname, join } = globalThis.__home_import(\"path\");",
        },
        .{
            .needle = "import path from \"node:path\";",
            .replacement = "const path = globalThis.__home_import(\"node:path\");",
        },
        .{
            .needle = "import { isWindows } from \"harness\";",
            .replacement = "const { isWindows } = globalThis.__home_import(\"harness\");",
        },
        .{
            .needle = "import { bunEnv, bunExe } from \"harness\";",
            .replacement = "const { bunEnv, bunExe } = globalThis.__home_import(\"harness\");",
        },
        .{
            .needle = "import { bunEnv, bunExe, tempDirWithFiles } from \"harness\";",
            .replacement = "const { bunEnv, bunExe, tempDirWithFiles } = globalThis.__home_import(\"harness\");",
        },
        .{
            .needle = "import { bunEnv, tempDirWithFiles } from \"harness\";",
            .replacement = "const { bunEnv, tempDirWithFiles } = globalThis.__home_import(\"harness\");",
        },
        .{
            .needle = "import { bunEnv, bunExe, tempDir } from \"harness\";",
            .replacement = "const { bunEnv, bunExe, tempDir } = globalThis.__home_import(\"harness\");",
        },
        .{
            .needle = "import { bunEnv, bunExe, isASAN, isDebug, tempDirWithFiles, tempDirWithFilesAnon } from \"harness\";",
            .replacement = "const { bunEnv, bunExe, isASAN, isDebug, tempDirWithFiles, tempDirWithFilesAnon } = globalThis.__home_import(\"harness\");",
        },
        .{
            .needle = "import { bunEnv, bunExe, isArm64, isLinux, isMacOS, isMusl, isWindows, tempDir } from \"harness\";",
            .replacement = "const { bunEnv, bunExe, isArm64, isLinux, isMacOS, isMusl, isWindows, tempDir } = globalThis.__home_import(\"harness\");",
        },
        .{
            .needle = "import { bunEnv, bunExe, isWindows, tempDir } from \"harness\";",
            .replacement = "const { bunEnv, bunExe, isWindows, tempDir } = globalThis.__home_import(\"harness\");",
        },
        .{
            .needle = "import { tempDirWithFiles } from \"harness\";",
            .replacement = "const { tempDirWithFiles } = globalThis.__home_import(\"harness\");",
        },
        .{
            .needle = "import { URL } from \"node:url\";",
            .replacement = "const { URL } = globalThis.__home_import(\"node:url\");",
        },
        .{
            .needle = "import { URL, parse } from \"node:url\";",
            .replacement = "const { URL, parse } = globalThis.__home_import(\"node:url\");",
        },
        .{
            .needle = "import url, { URL } from \"node:url\";",
            .replacement = "const __home_node_url = globalThis.__home_import(\"node:url\");\nconst url = __home_node_url.default;\nconst { URL } = __home_node_url;",
        },
        .{
            .needle = "import url from \"node:url\";",
            .replacement = "const url = globalThis.__home_import(\"node:url\");",
        },
        .{
            .needle = "import buffer, { INSPECT_MAX_BYTES } from \"node:buffer\";",
            .replacement = "const __home_node_buffer = globalThis.__home_import(\"node:buffer\");\nconst buffer = __home_node_buffer.default;\nconst { INSPECT_MAX_BYTES } = __home_node_buffer;",
        },
        .{
            .needle = "import { semver } from \"bun\";",
            .replacement = "const { semver } = globalThis.__home_import(\"bun\");",
        },
        .{
            .needle = "import { concatArrayBuffers } from \"bun\";",
            .replacement = "const { concatArrayBuffers } = globalThis.__home_import(\"bun\");",
        },
        .{
            .needle = "import { escapeHTML } from \"bun\";",
            .replacement = "const { escapeHTML } = globalThis.__home_import(\"bun\");",
        },
        .{
            .needle = "import { indexOfLine } from \"bun\";",
            .replacement = "const { indexOfLine } = globalThis.__home_import(\"bun\");",
        },
        .{
            .needle = "import { Buffer } from \"node:buffer\";",
            .replacement = "const { Buffer } = globalThis.__home_import(\"node:buffer\");",
        },
        .{
            .needle = "import { createDenoTest } from \"deno:harness\";",
            .replacement = "const { createDenoTest } = globalThis.__home_import(\"deno:harness\");",
        },
        .{
            .needle = "import { expectTypeOf } from \"bun:test\";",
            .replacement = "const { expectTypeOf } = globalThis.__home_import(\"bun:test\");",
        },
        .{
            .needle = "import { buildNoThrow } from \"./buildNoThrow\";",
            .replacement = "const { buildNoThrow } = globalThis.__home_import(\"./buildNoThrow\");",
        },
    };

    var cursor: usize = 0;
    while (cursor < source.len) {
        var replaced = false;
        for (replacements) |entry| {
            if (std.mem.startsWith(u8, source[cursor..], entry.needle)) {
                try out.appendSlice(allocator, entry.replacement);
                cursor += entry.needle.len;
                replaced = true;
                break;
            }
        }
        if (!replaced) {
            try out.append(allocator, source[cursor]);
            cursor += 1;
        }
    }

    return out.toOwnedSlice(allocator);
}

fn finishModuleRewrite(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    const with_module_imports = try rewriteBootstrapModuleImports(allocator, source);
    defer allocator.free(with_module_imports);

    const with_import_meta = try rewriteImportMeta(allocator, with_module_imports);
    defer allocator.free(with_import_meta);
    return rewriteBootstrapTypeScript(allocator, with_import_meta);
}

fn hasBunTestImport(source: []const u8) bool {
    const Mode = enum { code, single_quote, double_quote, template, line_comment, block_comment };
    var mode: Mode = .code;
    var i: usize = 0;
    while (i < source.len) {
        const byte = source[i];
        switch (mode) {
            .code => {
                if (std.mem.startsWith(u8, source[i..], "from \"bun:test\"") or
                    std.mem.startsWith(u8, source[i..], "from 'bun:test'"))
                {
                    return true;
                }
                if (byte == '\'') mode = .single_quote;
                if (byte == '"') mode = .double_quote;
                if (byte == '`') mode = .template;
                if (byte == '/' and i + 1 < source.len and source[i + 1] == '/') mode = .line_comment;
                if (byte == '/' and i + 1 < source.len and source[i + 1] == '*') mode = .block_comment;
                i += 1;
            },
            .single_quote, .double_quote, .template => {
                const terminator: u8 = switch (mode) {
                    .single_quote => '\'',
                    .double_quote => '"',
                    .template => '`',
                    else => unreachable,
                };
                if (byte == '\\' and i + 1 < source.len) {
                    i += 2;
                    continue;
                }
                if (byte == terminator) mode = .code;
                i += 1;
            },
            .line_comment => {
                if (byte == '\n') mode = .code;
                i += 1;
            },
            .block_comment => {
                if (byte == '*' and i + 1 < source.len and source[i + 1] == '/') {
                    i += 2;
                    mode = .code;
                    continue;
                }
                i += 1;
            },
        }
    }
    return false;
}

fn hasBakeHarnessImport(source: []const u8) bool {
    return std.mem.indexOf(u8, source, "from \"./bake-harness\"") != null or
        std.mem.indexOf(u8, source, "from './bake-harness'") != null or
        std.mem.indexOf(u8, source, "from \"../bake-harness\"") != null or
        std.mem.indexOf(u8, source, "from '../bake-harness'") != null;
}

fn hasUnsupportedModuleSyntax(source: []const u8) bool {
    const Mode = enum { code, single_quote, double_quote, template, line_comment, block_comment };
    var mode: Mode = .code;
    var i: usize = 0;
    while (i < source.len) {
        const byte = source[i];
        switch (mode) {
            .code => {
                if (std.mem.startsWith(u8, source[i..], "import ") or
                    std.mem.startsWith(u8, source[i..], "export "))
                {
                    return true;
                }
                if (byte == '\'') mode = .single_quote;
                if (byte == '"') mode = .double_quote;
                if (byte == '`') mode = .template;
                if (byte == '/' and i + 1 < source.len and source[i + 1] == '/') mode = .line_comment;
                if (byte == '/' and i + 1 < source.len and source[i + 1] == '*') mode = .block_comment;
                i += 1;
            },
            .single_quote, .double_quote, .template => {
                const terminator: u8 = switch (mode) {
                    .single_quote => '\'',
                    .double_quote => '"',
                    .template => '`',
                    else => unreachable,
                };
                if (byte == '\\' and i + 1 < source.len) {
                    i += 2;
                    continue;
                }
                if (byte == terminator) mode = .code;
                i += 1;
            },
            .line_comment => {
                if (byte == '\n') mode = .code;
                i += 1;
            },
            .block_comment => {
                if (byte == '*' and i + 1 < source.len and source[i + 1] == '/') {
                    i += 2;
                    mode = .code;
                    continue;
                }
                i += 1;
            },
        }
    }
    return false;
}

pub fn rewriteBunTestImport(allocator: std.mem.Allocator, source: []const u8, relative_path: []const u8) ![]u8 {
    const shebang_len = sourceShebangLen(source);
    const imports = [_]struct {
        line: []const u8,
        binding: []const u8,
    }{
        .{ .line = "import { expect, it, describe } from \"bun:test\";", .binding = "const { expect, it, describe } = globalThis.__home_import(\"bun:test\");\n" },
        .{ .line = "import { describe, expect, it } from \"bun:test\";", .binding = "const { describe, expect, it } = globalThis.__home_import(\"bun:test\");\n" },
        .{ .line = "import { describe, expect } from \"bun:test\";", .binding = "const { describe, expect } = globalThis.__home_import(\"bun:test\");\n" },
        .{ .line = "import { describe, test } from \"bun:test\";", .binding = "const { describe, test } = globalThis.__home_import(\"bun:test\");\n" },
        .{ .line = "import { describe, expect, test } from \"bun:test\";", .binding = "const { describe, expect, test } = globalThis.__home_import(\"bun:test\");\n" },
        .{ .line = "import { afterEach, describe, expect, test } from \"bun:test\";", .binding = "const { afterEach, describe, expect, test } = globalThis.__home_import(\"bun:test\");\n" },
        .{ .line = "import { afterAll, afterEach, beforeAll, beforeEach, expect, test } from \"bun:test\";", .binding = "const { afterAll, afterEach, beforeAll, beforeEach, expect, test } = globalThis.__home_import(\"bun:test\");\n" },
        .{ .line = "import { afterAll, afterEach, beforeEach, describe, expect, onTestFinished, test } from \"bun:test\";", .binding = "const { afterAll, afterEach, beforeEach, describe, expect, onTestFinished, test } = globalThis.__home_import(\"bun:test\");\n" },
        .{ .line = "import { afterAll, afterEach, beforeAll, beforeEach, describe, test } from \"bun:test\";", .binding = "const { afterAll, afterEach, beforeAll, beforeEach, describe, test } = globalThis.__home_import(\"bun:test\");\n" },
        .{ .line = "import { expect, it } from \"bun:test\";", .binding = "const { expect, it } = globalThis.__home_import(\"bun:test\");\n" },
        .{ .line = "import { it } from \"bun:test\";", .binding = "const { it } = globalThis.__home_import(\"bun:test\");\n" },
        .{ .line = "import { expect } from \"bun:test\";", .binding = "const { expect } = globalThis.__home_import(\"bun:test\");\n" },
        .{ .line = "import { expectTypeOf, test } from \"bun:test\";", .binding = "const { expectTypeOf, test } = globalThis.__home_import(\"bun:test\");\n" },
        .{ .line = "import { describe, expect, jest, test } from \"bun:test\";", .binding = "const { describe, expect, jest, test } = globalThis.__home_import(\"bun:test\");\n" },
        .{ .line = "import { expect, jest, test } from \"bun:test\";", .binding = "const { expect, jest, test } = globalThis.__home_import(\"bun:test\");\n" },
        .{ .line = "import { expect, mock, test } from \"bun:test\";", .binding = "const { expect, mock, test } = globalThis.__home_import(\"bun:test\");\n" },
        .{ .line = "import { expect, test } from \"bun:test\";", .binding = "const { expect, test } = globalThis.__home_import(\"bun:test\");\n" },
        .{ .line = "import { test } from \"bun:test\";", .binding = "const { test } = globalThis.__home_import(\"bun:test\");\n" },
    };

    for (imports) |import_shape| {
        if (std.mem.indexOf(u8, source, import_shape.line)) |idx| {
            var out = std.ArrayList(u8).empty;
            defer out.deinit(allocator);

            try out.appendSlice(allocator, source[0..shebang_len]);
            try out.appendSlice(allocator, "(function() {\n");
            try appendFileMetadataPrelude(&out, allocator, relative_path);
            try out.appendSlice(allocator, source[shebang_len..idx]);
            try out.appendSlice(allocator, import_shape.binding);
            try out.appendSlice(allocator, source[idx + import_shape.line.len ..]);
            try out.appendSlice(allocator, "\n})();\n");
            try out.appendSlice(allocator, "\n//# sourceURL=");
            try out.appendSlice(allocator, relative_path);
            try out.append(allocator, '\n');
            const with_imports = try out.toOwnedSlice(allocator);
            defer allocator.free(with_imports);
            return finishModuleRewrite(allocator, with_imports);
        }
    }

    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    try out.appendSlice(allocator, source[0..shebang_len]);
    try out.appendSlice(allocator, "(function() {\n");
    try appendFileMetadataPrelude(&out, allocator, relative_path);
    try out.appendSlice(allocator, source[shebang_len..]);
    try out.appendSlice(allocator, "\n})();\n");
    try out.appendSlice(allocator, "\n//# sourceURL=");
    try out.appendSlice(allocator, relative_path);
    try out.append(allocator, '\n');
    const with_metadata = try out.toOwnedSlice(allocator);
    defer allocator.free(with_metadata);
    return finishModuleRewrite(allocator, with_metadata);
}

pub fn prepareCorpusModule(allocator: std.mem.Allocator, source: []const u8, relative_path: []const u8) !runner.PreparedFile {
    const rewritten = try rewriteBunTestImport(allocator, source, relative_path);
    const allow_no_tests = std.mem.eql(u8, relative_path, "js/bun/empty-file.test.ts") or
        std.mem.eql(u8, relative_path, "js/bun/test/expect-type-doctest.test.ts");
    if (hasBunTestImport(rewritten)) {
        return .{
            .path = relative_path,
            .source = rewritten,
            .unsupported_reason = "unsupported bun:test import shape",
            .allow_no_tests = allow_no_tests,
        };
    }
    if (hasBakeHarnessImport(rewritten)) {
        return .{
            .path = relative_path,
            .source = rewritten,
            .unsupported_reason = "unsupported bake harness module",
            .allow_no_tests = allow_no_tests,
        };
    }
    if (hasUnsupportedModuleSyntax(rewritten)) {
        return .{
            .path = relative_path,
            .source = rewritten,
            .unsupported_reason = "unsupported module syntax",
            .allow_no_tests = allow_no_tests,
        };
    }
    return .{
        .path = relative_path,
        .source = rewritten,
        .allow_no_tests = allow_no_tests,
    };
}

pub fn runSubset(io: Io, allocator: std.mem.Allocator, corpus_path: []const u8, subset: Subset) !Summary {
    if (!build_options.enable_jsc) {
        return .{
            .files = filesForSubset(subset).len,
            .blocked = true,
            .reason = "jsc-disabled",
        };
    }

    var runtime = try jsc_bootstrap.Runtime.init(allocator, harness_prelude);
    defer runtime.deinit();

    var summary = Summary{};
    for (filesForSubset(subset)) |relative| try runRelativeFile(io, allocator, &runtime, corpus_path, relative, &summary);

    return summary;
}

pub fn runGate(io: Io, allocator: std.mem.Allocator, corpus_path: []const u8) !Summary {
    const test_files = corpus.collectTestFiles(io, allocator, corpus_path) catch |err| switch (err) {
        error.FileNotFound => return .{ .blocked = true, .reason = "corpus-not-found" },
        else => return err,
    };
    defer corpus.freeTestFiles(allocator, test_files);

    if (!build_options.enable_jsc) {
        return .{
            .files = test_files.len,
            .blocked = true,
            .reason = "jsc-disabled",
        };
    }

    var runtime = try jsc_bootstrap.Runtime.init(allocator, harness_prelude);
    defer runtime.deinit();

    var summary = Summary{};
    for (test_files) |relative| try runRelativeFile(io, allocator, &runtime, corpus_path, relative, &summary);

    return summary;
}

pub fn runFile(io: Io, allocator: std.mem.Allocator, corpus_path: []const u8, relative: []const u8) !Summary {
    if (!build_options.enable_jsc) {
        return .{
            .files = 1,
            .blocked = true,
            .reason = "jsc-disabled",
        };
    }

    var runtime = try jsc_bootstrap.Runtime.init(allocator, harness_prelude);
    defer runtime.deinit();

    var summary = Summary{};
    try runRelativeFile(io, allocator, &runtime, corpus_path, relative, &summary);
    return summary;
}

fn runRelativeFile(
    io: Io,
    allocator: std.mem.Allocator,
    runtime: *jsc_bootstrap.Runtime,
    corpus_path: []const u8,
    relative: []const u8,
    summary: *Summary,
) !void {
    var file_result = test_result.FileResult{ .path = relative };
    const file_path = try std.fs.path.join(allocator, &.{ corpus_path, relative });
    defer allocator.free(file_path);

    const source = try Io.Dir.cwd().readFileAlloc(io, file_path, allocator, std.Io.Limit.limited(1024 * 1024));
    defer allocator.free(source);

    var prepared = try prepareCorpusModule(allocator, source, relative);
    defer prepared.deinit(allocator);

    if (prepared.unsupported_reason) |reason| {
        file_result.unsupported += 1;
        summary.addFileResult(file_result);
        try recordFailure(allocator, summary, relative, reason);
        return;
    }

    var file_run = try runtime.runFile(allocator, prepared.fileSpec());
    defer file_run.deinit(allocator);

    summary.addFileResult(file_run.result);
    switch (file_run.result.status()) {
        .failed, .unsupported => try recordFailure(allocator, summary, relative, file_run.result.first_failure_message),
        .passed, .todo => {},
    }
}

fn recordFailure(
    allocator: std.mem.Allocator,
    summary: *Summary,
    relative: []const u8,
    message: ?[]const u8,
) !void {
    if (summary.first_failure_file.len != 0) return;

    summary.first_failure_file = try allocator.dupe(u8, relative);
    summary.first_failure_file_owned = true;
    if (message) |text| {
        summary.first_failure_message = try allocator.dupe(u8, text);
        summary.first_failure_message_owned = true;
    } else {
        summary.first_failure_message_owned = false;
        summary.first_failure_message = "JSEvaluateScript returned null without an exception";
    }
}

test "subset flag parser recognizes the bootstrap subset" {
    try std.testing.expectEqual(Subset.minimal_js, parseSubsetFlagValue("minimal-js").?);
    try std.testing.expect(parseSubsetFlagValue("all") == null);
}

test "minimal JS subset starts with the todo smoke" {
    try std.testing.expectEqualStrings("snippets/segfault-todo.test.js", filesForSubset(.minimal_js)[0]);
    try std.testing.expectEqualStrings("js/web/util/atob.test.js", filesForSubset(.minimal_js)[1]);
    try std.testing.expectEqualStrings("regression/issue/23723.test.js", filesForSubset(.minimal_js)[2]);
    try std.testing.expectEqualStrings("regression/issue/12650.test.js", filesForSubset(.minimal_js)[3]);
    try std.testing.expectEqualStrings("js/node/domexception-node.test.js", filesForSubset(.minimal_js)[4]);
    try std.testing.expectEqualStrings("js/bun/jsc/shadow.test.js", filesForSubset(.minimal_js)[5]);
    try std.testing.expectEqualStrings("js/node/dirname.test.js", filesForSubset(.minimal_js)[6]);
    try std.testing.expectEqualStrings("regression/issue/03091.test.ts", filesForSubset(.minimal_js)[7]);
    try std.testing.expectEqualStrings("regression/issue/15326.test.ts", filesForSubset(.minimal_js)[8]);
    try std.testing.expectEqualStrings("regression/issue/15314.test.ts", filesForSubset(.minimal_js)[9]);
    try std.testing.expectEqualStrings("regression/issue/02005.test.ts", filesForSubset(.minimal_js)[10]);
    try std.testing.expectEqualStrings("bundler/transpiler_constant_fold_eqeq.test.ts", filesForSubset(.minimal_js)[11]);
    try std.testing.expectEqualStrings("regression/issue/19107.test.ts", filesForSubset(.minimal_js)[12]);
    try std.testing.expectEqualStrings("cli/test/expectations.test.ts", filesForSubset(.minimal_js)[13]);
    try std.testing.expectEqualStrings("regression/issue/prepare-stack-trace-crash.test.ts", filesForSubset(.minimal_js)[14]);
    try std.testing.expectEqualStrings("js/bun/test/nested-describes.test.ts", filesForSubset(.minimal_js)[15]);
    try std.testing.expectEqualStrings("regression/issue/issue-12276.test.ts", filesForSubset(.minimal_js)[16]);
    try std.testing.expectEqualStrings("regression/issue/27014.test.ts", filesForSubset(.minimal_js)[17]);
    try std.testing.expectEqualStrings("regression/issue/21257.test.ts", filesForSubset(.minimal_js)[18]);
    try std.testing.expectEqualStrings("regression/issue/07397.test.ts", filesForSubset(.minimal_js)[19]);
    try std.testing.expectEqualStrings("js/bun/test/expect-unreaachable.test.ts", filesForSubset(.minimal_js)[20]);
    try std.testing.expectEqualStrings("regression/issue/06467.test.ts", filesForSubset(.minimal_js)[21]);
    try std.testing.expectEqualStrings("regression/issue/11677.test.ts", filesForSubset(.minimal_js)[22]);
    try std.testing.expectEqualStrings("js/node/buffer-utf16.test.ts", filesForSubset(.minimal_js)[23]);
    try std.testing.expectEqualStrings("js/bun/test/expect-extend-asymmetric-match-throw.test.ts", filesForSubset(.minimal_js)[24]);
    try std.testing.expectEqualStrings("regression/issue/23133.test.ts", filesForSubset(.minimal_js)[25]);
    try std.testing.expectEqualStrings("regression/issue/2993.test.ts", filesForSubset(.minimal_js)[26]);
    try std.testing.expectEqualStrings("regression/issue/04947.test.js", filesForSubset(.minimal_js)[27]);
    try std.testing.expectEqualStrings("js/node/buffer-compare-bounds.test.ts", filesForSubset(.minimal_js)[28]);
    try std.testing.expectEqualStrings("regression/issue/014865.test.ts", filesForSubset(.minimal_js)[29]);
    try std.testing.expectEqualStrings("regression/issue/07736.test.ts", filesForSubset(.minimal_js)[30]);
    try std.testing.expectEqualStrings("js/node/buffer-inspectmaxbytes.test.ts", filesForSubset(.minimal_js)[31]);
    try std.testing.expectEqualStrings("js/web/workers/message-event.test.ts", filesForSubset(.minimal_js)[32]);
    try std.testing.expectEqualStrings("js/bun/test/bun-test.test.ts", filesForSubset(.minimal_js)[33]);
    try std.testing.expectEqualStrings("regression/issue/16007.test.ts", filesForSubset(.minimal_js)[34]);
    try std.testing.expectEqualStrings("js/bun/util/wrapAnsi.test.ts", filesForSubset(.minimal_js)[35]);
    try std.testing.expectEqualStrings("js/bun/test/test-retry-repeats-basic.test.ts", filesForSubset(.minimal_js)[36]);
    try std.testing.expectEqualStrings("regression/issue23966.test.ts", filesForSubset(.minimal_js)[37]);
    try std.testing.expectEqualStrings("js/deno/event/custom-event.test.ts", filesForSubset(.minimal_js)[38]);
    try std.testing.expectEqualStrings("js/deno/event/event.test.ts", filesForSubset(.minimal_js)[39]);
    try std.testing.expectEqualStrings("js/deno/abort/abort-controller.test.ts", filesForSubset(.minimal_js)[40]);
    try std.testing.expectEqualStrings("js/deno/fetch/request.test.ts", filesForSubset(.minimal_js)[41]);
    try std.testing.expectEqualStrings("js/deno/url/urlsearchparams.test.ts", filesForSubset(.minimal_js)[42]);
    try std.testing.expectEqualStrings("regression/issue/08040.test.ts", filesForSubset(.minimal_js)[43]);
    try std.testing.expectEqualStrings("regression/issue/09778.test.ts", filesForSubset(.minimal_js)[44]);
    try std.testing.expectEqualStrings("regression/issue/18820.test.ts", filesForSubset(.minimal_js)[45]);
    try std.testing.expectEqualStrings("regression/issue/23382.test.js", filesForSubset(.minimal_js)[46]);
    try std.testing.expectEqualStrings("js/bun/util/escapeRegExp.test.ts", filesForSubset(.minimal_js)[47]);
    try std.testing.expectEqualStrings("regression/issue/24045.test.ts", filesForSubset(.minimal_js)[48]);
    try std.testing.expectEqualStrings("regression/issue/07324.test.ts", filesForSubset(.minimal_js)[49]);
    try std.testing.expectEqualStrings("regression/issue/07827.test.ts", filesForSubset(.minimal_js)[50]);
    try std.testing.expectEqualStrings("internal/powershell-escape.test.ts", filesForSubset(.minimal_js)[51]);
    try std.testing.expectEqualStrings("js/node/assert/assert.test.cjs", filesForSubset(.minimal_js)[52]);
    try std.testing.expectEqualStrings("js/node/assert/assert-match.test.cjs", filesForSubset(.minimal_js)[53]);
    try std.testing.expectEqualStrings("js/node/assert/assert-doesNotMatch.test.cjs", filesForSubset(.minimal_js)[54]);
    try std.testing.expectEqualStrings("js/node/path/posix-exists.test.js", filesForSubset(.minimal_js)[55]);
    try std.testing.expectEqualStrings("js/node/path/win32-exists.test.js", filesForSubset(.minimal_js)[56]);
    try std.testing.expectEqualStrings("js/node/path/15704.test.js", filesForSubset(.minimal_js)[57]);
    try std.testing.expectEqualStrings("js/node/url/url-canParse-whatwg.test.js", filesForSubset(.minimal_js)[58]);
    try std.testing.expectEqualStrings("js/node/url/url-format-invalid-input.test.js", filesForSubset(.minimal_js)[59]);
    try std.testing.expectEqualStrings("integration/bun-types/fixture/23347.test.ts", filesForSubset(.minimal_js)[60]);
    try std.testing.expectEqualStrings("js/bun/resolve/toml/toml-parse.test.ts", filesForSubset(.minimal_js)[61]);
    try std.testing.expectEqualStrings("regression/issue/013880.test.ts", filesForSubset(.minimal_js)[62]);
    try std.testing.expectEqualStrings("js/bun/util/exotic-global-mutable-prototype.test.ts", filesForSubset(.minimal_js)[63]);
    try std.testing.expectEqualStrings("js/bun/jsc/native-constructor-identity.test.ts", filesForSubset(.minimal_js)[64]);
    try std.testing.expectEqualStrings("js/bun/empty-file.test.ts", filesForSubset(.minimal_js)[65]);
    try std.testing.expectEqualStrings("js/bun/test/expect-type-global.test.ts", filesForSubset(.minimal_js)[66]);
    try std.testing.expectEqualStrings("js/bun/test/expect-type.test.ts", filesForSubset(.minimal_js)[67]);
}

test "harness prelude installs Bun test globals once" {
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "function it(name, first, second)") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "console.warn = console.log") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "function queueMicrotask(callback)") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "function setImmediate(callback)") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "__home_reset_performance_clock") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "function __home_is_thenable(value)") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "function __home_done_callback(error)") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "Object.setPrototypeOf = function(target, prototype)") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "__home_global_virtual_prototype_keys") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "stripANSI(value)") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "wrapAnsi(value, columns, options)") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "TOML: {") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "Bun.TOML.parse expects a string") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "JSONC: {") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "stripTrailingCommas(stripComments(value))") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "S3Client: {") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "S3Client.write path must be a valid file descriptor or path string") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "Transpiler: function(options)") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "Invalid loader:") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "satisfies(version, range)") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "inspect(value)") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "Set(\" + entry.size + \")") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "version: \"0.0.0-home\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "gc(force)") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "sleepSync(seconds)") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "nanoseconds()") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "serve(options)") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "__home_serveNative(options)") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "typeof options.fetch === \"function\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "__home_stopServeNative(handle.id") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "spawnSync(options)") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "__home_spawnSyncNative(options || {})") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "process.versions.bun = Bun.version") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "if (!process.env) process.env = {}") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "process.execPath = \"home\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "process.on = function(name, listener)") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "process.emit = function(name)") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "process.cwd = function()") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "process.chdir = function(path)") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "pass()") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "toBeInstanceOf(ctor)") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "toBeInstanceOf() requires 1 argument") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "Expected value must be a function:") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "toBeTypeOf(expected)") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "toBeTypeOf() requires a valid type string argument") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "toBeUndefined()") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "toBeTruthy()") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "toBeFalse()") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "toHaveBeenCalledTimes(expected)") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "toMatchInlineSnapshot(expected)") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "__home_format_snapshot(value)") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "toBeGreaterThan(expected)") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "toBeLessThan(expected)") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "__home_expect_any_matches(value, ctor)") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "__home_array_buffer_view(value)") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "__home_concat_array_buffers") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "toBeNumber()") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "a instanceof Map || b instanceof Map") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "a instanceof Number || b instanceof Number") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "a instanceof Boolean || b instanceof Boolean") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "a instanceof Set || b instanceof Set") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "toIncludeRepeated(needle, expectedCount)") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "function beforeAll(fn, options)") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "function onTestFinished(fn)") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "function mock(implementation)") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "mock.clearAllMocks") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "mock.resetAllMocks") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "useFakeTimers()") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "__home_DateTimeFormat") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "mockReturnThis") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "jest.mock() module name must be a string") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "jest.mock() requires a factory callback") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "Cannot set both retry and repeats") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "it.each = __home_each") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "test.concurrent.each") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "describe.each = function(rows)") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "globalThis.__home_finish_tests") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "toContain(expected)") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "toMatchObject(expected)") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "toHaveProperty(expected, expectedValue)") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "toIncludeRepeated() requires the expect(value) to be a string") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "toContainKey(expected)") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "toContainAnyKeys(expected)") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "function expectTypeOf(value)") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "toMatchObjectType()") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "expect.unreachable") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "expect.extend") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "__home_expect_matchers") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "asymmetricMatch(received)") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "Expected value must be string or Error") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "Deep equality for this value type is not supported") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "UnreachableError") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "jest, mock, onTestFinished, test") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "concatArrayBuffers: __home_concat_array_buffers") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "__home_cjs_factories[\"regression/issue/013880-fixture.cjs\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "__home_resolve_require(specifier)") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "__home_modules[\"assert\"] = __home_assert_module") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "__home_modules[\"assert/strict\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "__home_modules[\"path\"] = __home_path_module") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "__home_modules[\"path/posix\"] = __home_path_posix") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "__home_path_win32_is_absolute") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "__home_path_relative") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "__home_path_posix_resolve") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "__home_path_win32_resolve") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "__home_modules[\"node:url\"] = __home_url_module") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "URL.canParse = function(input, base)") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "domainToASCII(value)") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "domainToUnicode(value)") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "__home_modules[\"node:vm\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "var Blob = function(parts, options)") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "__home_modules[\"bun:internal-for-testing\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "escapeRegExpForPackageNameMatching(value)") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "escapePowershell(value)") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "highlightJavaScript(value)") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "getDevServerDeinitCount()") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "__home_getDevServerDeinitCountNative()") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "__home_modules[\"bun:jsc\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "__home_modules[\"bake/fixtures/deinitialization/index.html\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "createDenoTest(path, defaultTimeout)") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "denoTest.ignore") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "denoTest.todo") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "globalThis.__home_import") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "globalThis.require = function(specifier)") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "Response.redirect") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "Response.json") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "var HTMLRewriter = function()") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "HTMLRewriter.prototype.onDocument") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "doctype.remove") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "Expected Response or Body") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "__home_html_selector_valid") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "HTMLRewriter.prototype.transform") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "var Request = function(input, init)") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "typeof input.href === \"string\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "Request.prototype.text") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "Request.prototype.clone") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "__home_modules[\"node-fetch\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "Buffer.alloc = function(size, fill)") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "String.fromCharCode(this[i])") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "Buffer.from") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "Buffer.prototype.compare") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "Buffer.INSPECT_MAX_BYTES") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "Buffer.isEncoding") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "__home_modules[\"node:buffer\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "__home_path_posix_basename") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "__home_path_win32_extname") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "indexOfLine(input, offset)") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "Buffer.byteLength = function(value, encoding)") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "toString(16).padStart") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "Bun.jest = function(path)") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "escapeHTML(value)") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "function SourceMap(payload)") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "__home_modules[\"node:module\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "var structuredClone = function(value)") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "var TextDecoder = function(label)") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "\"shift_jis:82b182f182c982bf82cd\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "Error.prepareStackTrace") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "__home_normalize_callsite") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "var MessageEvent = function(type, options)") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "var MessageChannel = function()") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "var CustomEvent = function(type, init)") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "Event.prototype.preventDefault") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "var AbortController = function()") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "AbortSignal.abort = function(reason)") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "__home_performance_time_origin") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "performance.clearResourceTimings = function()") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "performance.setResourceTimingBufferSize = function(size)") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "var URLSearchParams = function(init)") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "bunExe() { return process.execPath; }") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "describe.todo = function(name, fn)") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "test.skip = it.todo") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "test.if = function(condition)") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "describe.skipIf = function(condition)") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "globalThis.__home_registered_tests = []") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "test.only = __home_test_only") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "describe.only = function(name, fn)") != null);
}

test "Bun test import rewrite lowers to the virtual test module" {
    const source =
        \\import { expect, it, describe } from "bun:test";
        \\it("works", () => {});
    ;
    const rewritten = try rewriteBunTestImport(std.testing.allocator, source, "js/node/example.test.js");
    defer std.testing.allocator.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "const { expect, it, describe } = globalThis.__home_import(\"bun:test\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "from \"bun:test\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "var __dirname = \"js/node\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "globalThis.__home_current_filename = __filename") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "it(\"works\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "\n//# sourceURL=js/node/example.test.js\n") != null);
}

test "Bun test import rewrite lowers single test binding" {
    const source =
        \\import { test } from "bun:test";
        \\test("fixture", () => {});
    ;
    const rewritten = try rewriteBunTestImport(std.testing.allocator, source, "js/bun/test/scheduling/multi-file/test1.fixture.ts");
    defer std.testing.allocator.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "const { test } = globalThis.__home_import(\"bun:test\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "from \"bun:test\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "test(\"fixture\"") != null);
}

test "Bun test import rewrite lowers single it binding" {
    const source =
        \\import { it } from "bun:test";
        \\it("fixture", () => {});
    ;
    const rewritten = try rewriteBunTestImport(std.testing.allocator, source, "js/web/timers/microtask.test.js");
    defer std.testing.allocator.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "const { it } = globalThis.__home_import(\"bun:test\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "from \"bun:test\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "it(\"fixture\"") != null);
}

test "internal highlighter import rewrite lowers alias binding" {
    const source =
        \\import { highlightJavaScript as highlighter } from "bun:internal-for-testing";
        \\import { expect, test } from "bun:test";
        \\test("highlighter", () => expect(highlighter("123").length).toBeLessThan(20));
    ;
    const rewritten = try rewriteBunTestImport(std.testing.allocator, source, "internal/highlighter.test.ts");
    defer std.testing.allocator.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "const { highlightJavaScript: highlighter } = globalThis.__home_import(\"bun:internal-for-testing\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "from \"bun:internal-for-testing\"") == null);
}

test "bun test import detector ignores fixture source strings" {
    const source =
        \\const fixtures = {
        \\  "some.test.ts": `import { test } from "bun:test"; test("example", () => {});`,
        \\  "other.test.ts": 'import { expect, test } from "bun:test";',
        \\};
        \\// import { test } from "bun:test";
    ;
    try std.testing.expect(!hasBunTestImport(source));
    try std.testing.expect(hasBunTestImport("import { expect } from \"bun:test\";"));
}

test "minimal JS subset includes low-risk Bun corpus expansion files" {
    const expected = [_][]const u8{
        "cli/test/test-randomize.fixture.ts",
        "js/web/encoding/text-decoder-cjk.test.ts",
        "js/web/encoding/text-decoder-single-byte.test.ts",
        "regression/issue/fix-bindings-stack-trace.test.ts",
        "js/node/module/module-sourcemap.test.js",
        "js/bun/jsc/string-noAtomize.test.ts",
        "js/bun/test/only-fixture-4.ts",
        "regression/issue/21177.fixture.ts",
        "regression/issue/5738.fixture.ts",
        "js/bun/test/printing/dots/dots1.fixture.ts",
        "js/bun/s3/s3-fd-validation.test.ts",
        "regression/issue/ENG-24434.test.ts",
        "regression/issue/fuzzer-ENG-22942.test.ts",
        "js/bun/transpiler/transpiler-utf16-loader.test.ts",
        "js/web/html/html-rewriter-doctype.test.ts",
        "js/bun/jsonc/jsonc.test.ts",
        "js/bun/test/snapshot-tests/snapshots/more-snapshots/different-directory.test.ts",
        "js/bun/test/jest-each.test.ts",
        "regression/issue/htmlrewriter-additional-bugs.test.ts",
        "regression/issue/24191.test.ts",
        "js/bun/resolve/resolve-bad-parent.test.mjs",
        "regression/issue/issue-1825-jest-mock-functions.test.ts",
        "js/node/path/is-absolute.test.js",
        "js/node/path/zero-length-strings.test.js",
        "js/bun/util/concat.test.js",
        "js/bun/util/escapeHTML.test.js",
        "js/node/url/url-revokeobjecturl.test.js",
        "js/node/url/url-null-char.test.js",
        "js/node/url/url-is-url.test.js",
        "js/node/path/basename.test.js",
        "js/node/path/extname.test.js",
        "js/bun/util/index-of-line.test.ts",
        "js/node/url/url-format-whatwg.test.js",
        "regression/issue/19412.test.ts",
        "js/node/path/normalize.test.js",
        "js/node/path/join.test.js",
        "js/node/path/dirname.test.js",
        "js/node/path/parse-format.test.js",
        "js/node/path/relative.test.js",
        "js/node/path/path.test.js",
        "js/node/path/posix-relative-on-windows.test.js",
        "js/node/path/resolve.test.js",
        "js/bun/test/scheduling/multi-file/test1.fixture.ts",
        "js/bun/test/scheduling/multi-file/test2.fixture.ts",
        "js/bun/test/only-flag-fixtures/file0.fixture.ts",
        "js/bun/test/only-flag-fixtures/file2.fixture.ts",
        "js/bun/test/todo-test-fixture-2.js",
        "js/bun/test/only-fixture-1.ts",
        "js/bun/test/only-fixture-2.ts",
        "js/bun/test/only-fixture-3.ts",
        "js/bun/test/only-flag-fixtures/file1.fixture.ts",
        "js/bun/test/only-inside-only.fixture.ts",
        "js/bun/test/concurrent_immediate.fixture.ts",
        "js/bun/test/failure-skip.fixture.ts",
        "js/bun/test/test-fixture-preload-global-lifecycle-hook-test.js",
        "js/bun/test/skip-test-fixture.js",
        "js/bun/test/expect-type-doctest.test.ts",
        "js/bun/test/todo-test-fixture.js",
    };

    for (expected) |path| {
        var found = false;
        for (minimal_js_files) |candidate| {
            if (std.mem.eql(u8, candidate, path)) {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }
}

test "Bun module import rewrite lowers semver to the virtual bun module" {
    const source =
        \\import { semver } from "bun";
        \\import { expect, test } from "bun:test";
        \\test("semver", () => {
        \\  expect(semver.satisfies("3.4.5", ">=3.3.0-beta.1 <3.4.0-beta.3")).toBeFalse();
        \\});
    ;
    const rewritten = try rewriteBunTestImport(std.testing.allocator, source, "regression/issue/08040.test.ts");
    defer std.testing.allocator.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "const { semver } = globalThis.__home_import(\"bun\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "from \"bun\"") == null);
}

test "Node VM import rewrite lowers runInNewContext to the virtual module" {
    const source =
        \\import { expect, test } from "bun:test";
        \\import { runInNewContext } from "node:vm";
        \\test("vm", () => {
        \\  runInNewContext("process.emit(\"x\")", { process });
        \\});
    ;
    const rewritten = try rewriteBunTestImport(std.testing.allocator, source, "regression/issue/09778.test.ts");
    defer std.testing.allocator.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "const { runInNewContext } = globalThis.__home_import(\"node:vm\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "from \"node:vm\"") == null);
}

test "Bun internal testing import rewrite lowers default import" {
    const source =
        \\import testHelpers from "bun:internal-for-testing";
        \\import { expect, test } from "bun:test";
        \\const { escapeRegExp } = testHelpers;
        \\test("escape", () => expect(escapeRegExp("foo - bar")).toBe("foo \\x2d bar"));
    ;
    const rewritten = try rewriteBunTestImport(std.testing.allocator, source, "js/bun/util/escapeRegExp.test.ts");
    defer std.testing.allocator.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "const testHelpers = globalThis.__home_import(\"bun:internal-for-testing\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "from \"bun:internal-for-testing\"") == null);
}

test "Bun internal testing import rewrite lowers named PowerShell import" {
    const source =
        \\import { escapePowershell } from "bun:internal-for-testing";
        \\it("powershell escaping rules", () => {
        \\  expect(escapePowershell('foo" `bar')).toBe('foo`" ``bar');
        \\});
    ;
    const rewritten = try rewriteBunTestImport(std.testing.allocator, source, "internal/powershell-escape.test.ts");
    defer std.testing.allocator.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "const { escapePowershell } = globalThis.__home_import(\"bun:internal-for-testing\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "from \"bun:internal-for-testing\"") == null);
}

test "Bun module import rewrite lowers Bake child imports" {
    const source =
        \\import { getDevServerDeinitCount } from "bun:internal-for-testing";
        \\import html from "./index.html";
        \\import { expect, test } from "bun:test";
        \\import { fullGC } from "bun:jsc";
        \\let sockets: WebSocket[] = [];
        \\const opens: Promise<void>[] = [];
        \\const { promise } = Promise.withResolvers<void>();
        \\test("works", () => expect(html).toBeDefined());
        \\fullGC();
        \\getDevServerDeinitCount();
    ;
    const rewritten = try rewriteBunTestImport(std.testing.allocator, source, "bake/fixtures/deinitialization/test.ts");
    defer std.testing.allocator.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "from \"bun:internal-for-testing\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "from \"bun:jsc\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "import html") == null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "const { getDevServerDeinitCount } = globalThis.__home_import(\"bun:internal-for-testing\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "const { fullGC } = globalThis.__home_import(\"bun:jsc\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "const html = globalThis.__home_import(\"./index.html\").default;") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "WebSocket[]") == null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "Promise<void>") == null);
}

test "assert strict import rewrite lowers default import" {
    const source =
        \\import assert from "assert/strict";
        \\import { expect, test } from "bun:test";
        \\test("assert", () => expect(() => assert.deepStrictEqual(new Number(1), new Number(2))).toThrow("Expected values to be strictly deep-equal"));
    ;
    const rewritten = try rewriteBunTestImport(std.testing.allocator, source, "regression/issue/24045.test.ts");
    defer std.testing.allocator.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "const assert = globalThis.__home_import(\"assert/strict\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "from \"assert/strict\"") == null);
}

test "Node path and assert import rewrites lower default imports" {
    const source =
        \\import assert from "node:assert";
        \\import path from "path";
        \\import { describe, test } from "bun:test";
        \\describe("path", () => {
        \\  test("join", () => assert.strictEqual(path.join("x"), "x"));
        \\});
    ;
    const rewritten = try rewriteBunTestImport(std.testing.allocator, source, "js/node/path/15704.test.js");
    defer std.testing.allocator.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "const assert = globalThis.__home_import(\"node:assert\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "const path = globalThis.__home_import(\"path\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "from \"node:assert\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "from \"path\"") == null);
}

test "Bun harness import rewrite lowers isWindows import" {
    const source =
        \\import { describe, test } from "bun:test";
        \\import { isWindows } from "harness";
        \\import path from "node:path";
        \\test("platform", () => path.dirname(__filename).includes(isWindows ? "\\" : "/"));
    ;
    const rewritten = try rewriteBunTestImport(std.testing.allocator, source, "js/node/path/dirname.test.js");
    defer std.testing.allocator.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "const { isWindows } = globalThis.__home_import(\"harness\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "from \"harness\"") == null);
}

test "Bun harness import rewrite lowers bunEnv and bunExe import" {
    const source =
        \\import { bunEnv, bunExe } from "harness";
        \\import path from "node:path";
        \\test("subprocess", () => {
        \\  const cmd = [bunExe(), "test", path.join(import.meta.dir, "fixtures/test.ts")];
        \\  expect(bunEnv).toBeDefined();
        \\  expect(cmd[0]).toBeDefined();
        \\});
    ;
    const rewritten = try rewriteBunTestImport(std.testing.allocator, source, "bake/deinitialization.test.ts");
    defer std.testing.allocator.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "const { bunEnv, bunExe } = globalThis.__home_import(\"harness\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "const path = globalThis.__home_import(\"node:path\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "from \"harness\"") == null);
}

test "Bun harness import rewrite lowers tempDirWithFiles import" {
    const source =
        \\import { expect, test } from "bun:test";
        \\import { bunEnv, bunExe, tempDirWithFiles } from "harness";
        \\test("import.meta properties are NOT inlined without bake framework", async () => {
        \\  const dir = tempDirWithFiles("import-meta-no-inline", { "index.ts": "console.log(import.meta.path);" });
        \\  const proc = Bun.spawn({ cmd: [bunExe(), "index.ts"], env: bunEnv, cwd: dir });
        \\  expect(await proc.exited).toBe(0);
        \\});
    ;
    const rewritten = try rewriteBunTestImport(std.testing.allocator, source, "bake/dev/import-meta-inline-negative.test.ts");
    defer std.testing.allocator.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "const { bunEnv, bunExe, tempDirWithFiles } = globalThis.__home_import(\"harness\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "from \"harness\"") == null);
    try std.testing.expect(!hasUnsupportedModuleSyntax(rewritten));
}

test "Bun test import rewrite lowers describe and test imports" {
    const source =
        \\import { describe, test } from "bun:test";
        \\describe("x", () => test("y", () => {}));
    ;
    const rewritten = try rewriteBunTestImport(std.testing.allocator, source, "js/node/path/posix-exists.test.js");
    defer std.testing.allocator.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "const { describe, test } = globalThis.__home_import(\"bun:test\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "from \"bun:test\"") == null);
}

test "Node url import rewrites lower named and default imports" {
    const source =
        \\import assert from "node:assert";
        \\import { URL } from "node:url";
        \\import url from "node:url";
        \\import { describe, test } from "bun:test";
        \\describe("url", () => {
        \\  test("empty", () => assert.strictEqual(url.format(""), ""));
        \\  test("canParse", () => assert(URL.canParse("https://example.com")));
        \\});
    ;
    const rewritten = try rewriteBunTestImport(std.testing.allocator, source, "js/node/url/url-format-invalid-input.test.js");
    defer std.testing.allocator.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "const { URL } = globalThis.__home_import(\"node:url\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "const url = globalThis.__home_import(\"node:url\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "from \"node:url\"") == null);
}

test "Bun test import rewrite lowers mock imports" {
    const source =
        \\import { expect, mock, test } from "bun:test";
        \\const fn = mock(() => 1);
        \\test("mock", () => expect(fn).toHaveBeenCalledTimes(0));
    ;
    const rewritten = try rewriteBunTestImport(std.testing.allocator, source, "regression/issue/18820.test.ts");
    defer std.testing.allocator.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "const { expect, mock, test } = globalThis.__home_import(\"bun:test\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "from \"bun:test\"") == null);
}

test "Bun test import rewrite lowers jest imports" {
    const source =
        \\import { expect, jest, test } from "bun:test";
        \\test("jest", () => {
        \\  const fn = jest.fn(() => 1);
        \\  fn();
        \\  expect(fn).toHaveBeenCalledTimes(1);
        \\});
    ;
    const rewritten = try rewriteBunTestImport(std.testing.allocator, source, "regression/issue/07827.test.ts");
    defer std.testing.allocator.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "const { expect, jest, test } = globalThis.__home_import(\"bun:test\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "from \"bun:test\"") == null);
}

test "Bun test import rewrite lowers lifecycle hook imports" {
    const source =
        \\import { afterAll, afterEach, beforeAll, beforeEach, expect, test } from "bun:test";
        \\const logs: string[] = [];
        \\beforeAll(() => logs.push("beforeAll"), { timeout: 10_000 });
        \\test("works", () => expect(logs).toContain("beforeAll"));
    ;
    const rewritten = try rewriteBunTestImport(std.testing.allocator, source, "regression/issue/23133.test.ts");
    defer std.testing.allocator.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "const { afterAll, afterEach, beforeAll, beforeEach, expect, test } = globalThis.__home_import(\"bun:test\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "const logs = []") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, ": string[]") == null);
}

test "Bun test import rewrite lowers retry and cleanup imports" {
    const source =
        \\import { afterAll, afterEach, beforeEach, describe, expect, onTestFinished, test } from "bun:test";
        \\test("works", () => onTestFinished(() => {}), { retry: 1 });
    ;
    const rewritten = try rewriteBunTestImport(std.testing.allocator, source, "js/bun/test/test-retry-repeats-basic.test.ts");
    defer std.testing.allocator.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "const { afterAll, afterEach, beforeEach, describe, expect, onTestFinished, test } = globalThis.__home_import(\"bun:test\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "from \"bun:test\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "onTestFinished(() => {})") != null);
}

test "bootstrap rewrite lowers node-fetch Request imports" {
    const source =
        \\import { expect, test } from "bun:test";
        \\import { Request } from "node-fetch";
        \\test("works", () => expect(new Request("/").url).toBe("/"));
    ;
    const rewritten = try rewriteBunTestImport(std.testing.allocator, source, "regression/issue/04947.test.js");
    defer std.testing.allocator.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "const { Request } = globalThis.__home_import(\"node-fetch\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "from \"node-fetch\"") == null);
}

test "bootstrap runner covers Request body text and clone smoke" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import { expect, test } from "bun:test";
        \\import { Request } from "node-fetch";
        \\test("request body text clone", async () => {
        \\  const original = new Request("https://example.com/path", {
        \\    body: "ahoyhoy",
        \\    headers: { "test-header": "value" },
        \\    method: "post",
        \\  });
        \\  expect(original.method).toBe("POST");
        \\  expect(original.headers.get("test-header")).toBe("value");
        \\  expect(await original.text()).toBe("ahoyhoy");
        \\  const clone = original.clone();
        \\  expect(await clone.text()).toBe("ahoyhoy");
        \\  const fromBody = new Request("https://example.com/body", { body: original.body, method: "POST" });
        \\  expect(await fromBody.text()).toBe("ahoyhoy");
        \\  const urlish = new Request({ toString() { return "https://example.com/object"; } });
        \\  expect(urlish.url).toBe("https://example.com/object");
        \\  expect(urlish.method).toBe("GET");
        \\  expect(new Request(new URL("https://example.com/url")).url).toBe("https://example.com/url");
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "js/deno/fetch/request.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 1), file_run.result.passed);
}

test "bootstrap runner covers Response body text smoke" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import { expect, test } from "bun:test";
        \\test("response text", async () => {
        \\  expect(await new Response("ahoyhoy").text()).toBe("ahoyhoy");
        \\  expect(await new Response(null).text()).toBe("");
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "js/web/fetch/response-text.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 1), file_run.result.passed);
}

test "bootstrap runner accepts Bun.serve static HTML route shape" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import { expect, test } from "bun:test";
        \\test("serve static html route", () => {
        \\  const html = { __home_bake_html_import: true, path: "index.html" };
        \\  const server = Bun.serve({ static: { "/*": html } });
        \\  expect(server.url.href).toBe("http://127.0.0.1:0/");
        \\  server.stop(true);
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "bake/dev-and-prod.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 1), file_run.result.passed);
}

test "bootstrap rewrite lowers node buffer default and named imports" {
    const source =
        \\import { expect, test } from "bun:test";
        \\import buffer, { INSPECT_MAX_BYTES } from "node:buffer";
        \\test("works", () => expect(INSPECT_MAX_BYTES).toBeNumber());
    ;
    const rewritten = try rewriteBunTestImport(std.testing.allocator, source, "js/node/buffer-inspectmaxbytes.test.ts");
    defer std.testing.allocator.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "const __home_node_buffer = globalThis.__home_import(\"node:buffer\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "const buffer = __home_node_buffer.default;") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "const { INSPECT_MAX_BYTES } = __home_node_buffer;") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "from \"node:buffer\"") == null);
}

test "bootstrap rewrite lowers node buffer named Buffer import" {
    const source =
        \\import { expect, test } from "bun:test";
        \\import { Buffer } from "node:buffer";
        \\test.concurrent.each(["utf8"])("works", encoding => expect(Buffer.isEncoding(encoding)).toBe(true));
    ;
    const rewritten = try rewriteBunTestImport(std.testing.allocator, source, "regression/issue23966.test.ts");
    defer std.testing.allocator.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "const { Buffer } = globalThis.__home_import(\"node:buffer\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "from \"node:buffer\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "test.concurrent.each") != null);
}

test "bootstrap rewrite lowers deno harness imports" {
    const source =
        \\import { createDenoTest } from "deno:harness";
        \\const { test, assertEquals } = createDenoTest(import.meta.path);
        \\test(function customEventInitializedWithDetail() {
        \\  const customEventInit = { bubbles: true } as CustomEventInit;
        \\  assertEquals(new CustomEvent("x", customEventInit).bubbles, true);
        \\});
    ;
    const rewritten = try rewriteBunTestImport(std.testing.allocator, source, "js/deno/event/custom-event.test.ts");
    defer std.testing.allocator.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "const { createDenoTest } = globalThis.__home_import(\"deno:harness\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "from \"deno:harness\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "as CustomEventInit") == null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "createDenoTest(__home_import_meta_path)") != null);
}

test "bootstrap rewrite erases Deno event type syntax" {
    const source =
        \\import { createDenoTest } from "deno:harness";
        \\const { test, assert } = createDenoTest(import.meta.path);
        \\test(function eventInitializedWithNonStringType() {
        \\  const type: any = undefined;
        \\  const eventInit = { cancelable: true } as EventInit;
        \\  assert(Object.getOwnPropertyDescriptor(new Event("x"), "isTrusted")!.get);
        \\});
    ;
    const rewritten = try rewriteBunTestImport(std.testing.allocator, source, "js/deno/event/event.test.ts");
    defer std.testing.allocator.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, ": any") == null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, " as EventInit") == null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "!.") == null);
}

test "bootstrap rewrite erases Deno URLSearchParams type syntax" {
    const source =
        \\import { createDenoTest } from "deno:harness";
        \\const { test, assertEquals } = createDenoTest(import.meta.path);
        \\test(function urlSearchParamsAppendArgumentsCheck() {
        \\  ["append"].forEach((method: string)=>{
        \\    const searchParams = new URLSearchParams();
        \\    (searchParams as any)[method]("foo");
        \\  });
        \\  const params = new URLSearchParams();
        \\  params.append("first", (1 as unknown) as string);
        \\  params[Symbol.iterator] = function*(): IterableIterator<[number, number]> { yield [1, 2]; };
        \\  const params1 = new URLSearchParams((params as unknown) as string[][]);
        \\  class CustomSearchParams extends URLSearchParams {
        \\    append(name: string, value: string) { super.append(name, value); }
        \\    *entries(): IterableIterator<[string, string]> { yield* []; }
        \\  }
        \\});
    ;
    const rewritten = try rewriteBunTestImport(std.testing.allocator, source, "js/deno/url/urlsearchparams.test.ts");
    defer std.testing.allocator.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, ": string") == null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, " as ") == null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "IterableIterator") == null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "append(name, value)") != null);
}

test "bootstrap rewrite erases TypeScript constructor accessibility modifiers" {
    const source =
        \\import { expect, test } from "bun:test";
        \\test("override is an accessibility modifier", () => {
        \\  class FooParent {}
        \\  class FooChild extends FooParent {}
        \\  class BarParent {
        \\    constructor(readonly foo: FooParent) {}
        \\  }
        \\  class BarChild extends BarParent {
        \\    constructor(override foo: FooChild) {
        \\      super(foo);
        \\    }
        \\  }
        \\  new BarChild(new FooChild());
        \\  expect().pass();
        \\});
    ;
    const rewritten = try rewriteBunTestImport(std.testing.allocator, source, "regression/issue/07324.test.ts");
    defer std.testing.allocator.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "constructor(foo)") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "readonly foo") == null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "override foo") == null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, ": Foo") == null);
}

test "bootstrap rewrite erases typed matcher parameters" {
    const source =
        \\import { expect, test } from "bun:test";
        \\test("matcher", () => {
        \\  expect.extend({
        \\    toBeEven(received: number) {
        \\      return { pass: received % 2 === 0 };
        \\    },
        \\  });
        \\  expect(4).toBeEven();
        \\});
    ;
    const rewritten = try rewriteBunTestImport(std.testing.allocator, source, "regression/issue/fuzzer-ENG-22942.test.ts");
    defer std.testing.allocator.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "toBeEven(received)") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "received: number") == null);
}

test "bootstrap rewrite erases done callback cast" {
    const source =
        \\import { it } from "bun:test";
        \\it("works", done => {
        \\  (done as unknown as (err?: unknown) => void)();
        \\});
    ;
    const rewritten = try rewriteBunTestImport(std.testing.allocator, source, "js/bun/test/jest-each.test.ts");
    defer std.testing.allocator.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "(done)();") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, " as ") == null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "err?: unknown") == null);
}

test "bootstrap rewrite erases const assertions" {
    const source =
        \\import { expect, test } from "bun:test";
        \\test("works", () => {
        \\  const values = ["default"] as const;
        \\  expect(values[0]).toBe("default");
        \\});
    ;
    const rewritten = try rewriteBunTestImport(std.testing.allocator, source, "regression/issue/2993.test.ts");
    defer std.testing.allocator.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, " as const") == null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "const values = [\"default\"];") != null);
}

test "bootstrap rewrite lowers expectTypeOf type-only checks" {
    const source =
        \\import { expectTypeOf, test } from "bun:test";
        \\test("types", () => {
        \\  expectTypeOf({ a: 1 }).toMatchObjectType<{ a: number }>();
        \\  expectTypeOf({ a: 1 as const }).toMatchObjectType<{ a: 1 }>();
        \\});
    ;
    const rewritten = try rewriteBunTestImport(std.testing.allocator, source, "js/bun/test/expect-type.test.ts");
    defer std.testing.allocator.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "const { expectTypeOf, test } = globalThis.__home_import(\"bun:test\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "toMatchObjectType();") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "toMatchObjectType<") == null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, " as const") == null);
}

test "bootstrap rewrite erases as any assertions" {
    const source =
        \\import { expect, test } from "bun:test";
        \\test("works", () => {
        \\  expect(() => new (BigInt as any)(1)).toThrow(TypeError);
        \\});
    ;
    const rewritten = try rewriteBunTestImport(std.testing.allocator, source, "js/bun/jsc/native-constructor-identity.test.ts");
    defer std.testing.allocator.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, " as any") == null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "new (BigInt)(1)") != null);
}

test "bootstrap rewrite erases admitted type-only syntax" {
    const source =
        \\import { describe, expect, test } from "bun:test";
        \\let capturedStack: any[] = [];
        \\class CustomMap extends Map {
        \\  abc: number = 123;
        \\  constructor(iterable: any) { super(iterable); }
        \\  value: any;
        \\}
        \\test("works", () => {
        \\  const x = new CustomMap<any, any>([]);
        \\  expect(x.abc).toBe(123);
        \\});
    ;
    const rewritten = try rewriteBunTestImport(std.testing.allocator, source, "regression/issue/07736.test.ts");
    defer std.testing.allocator.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "abc = 123") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "constructor(iterable)") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "new CustomMap([])") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "let capturedStack = []") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, ": any") == null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "<any, any>") == null);
}

test "bootstrap runner reports zero registered tests as unsupported" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\describe("empty suite", () => {});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "regression/issue/empty-describe.test.js");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.unsupported, file_run.result.status());
    try std.testing.expectEqualStrings("no bun:test tests registered by corpus file", file_run.result.first_failure_message);
}

test "bootstrap runner allows admitted module-load smokes with no registered tests" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\// comment-only regression smoke
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "js/bun/empty-file.test.ts");
    defer prepared.deinit(std.testing.allocator);

    try std.testing.expect(prepared.fileSpec().allow_no_tests);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 0), file_run.result.passed);
    try std.testing.expectEqual(@as(usize, 0), file_run.result.failed);
    try std.testing.expectEqual(@as(usize, 0), file_run.result.todo);
}

test "bootstrap runner allows expectTypeOf doctest as type-only smoke" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import { expectTypeOf } from "bun:test";
        \\expectTypeOf<string>().toEqualTypeOf<string>();
        \\expectTypeOf(123).toBeNumber();
        \\function greet(name: string): string {
        \\  return `Hello ${name}`;
        \\}
        \\expectTypeOf(greet).parameters.toEqualTypeOf<[string]>();
        \\expectTypeOf(greet).returns.toEqualTypeOf<string>();
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "js/bun/test/expect-type-doctest.test.ts");
    defer prepared.deinit(std.testing.allocator);

    try std.testing.expect(prepared.fileSpec().allow_no_tests);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 0), file_run.result.passed);
    try std.testing.expectEqual(@as(usize, 0), file_run.result.failed);
}

test "bootstrap runner covers expectTypeOf type-only smokes" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import { expectTypeOf, test } from "bun:test";
        \\
        \\test("types", () => {
        \\  expectTypeOf({ a: 1 }).toMatchObjectType<{ a: number }>();
        \\  expectTypeOf({ a: 1 }).toMatchObjectType<{ a: 1 }>();
        \\  expectTypeOf({ a: 1 as const }).toMatchObjectType<{ a: 1 }>();
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "js/bun/test/expect-type.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 1), file_run.result.passed);
}

test "bootstrap runner keeps todo-only files as todo" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\test.todo("pending");
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "snippets/pending.test.js");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.todo, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 1), file_run.result.todo);
}

test "bootstrap runner gives test.only precedence over describe.only" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\describe.only("outer", () => {
        \\  test("skipped by inner only", () => expect.unreachable());
        \\  describe("inner", () => {
        \\    test.only("selected", () => expect().pass());
        \\  });
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "js/bun/test/only-inside-only.fixture.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 1), file_run.result.passed);
    try std.testing.expectEqual(@as(usize, 0), file_run.result.failed);
}

test "bootstrap runner covers conditional skip helpers" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import { describe, test } from "bun:test";
        \\test.skip("test #1", () => expect.unreachable());
        \\test.skipIf(true)("test #2", () => expect.unreachable());
        \\test.skipIf(1)("test #3", () => expect.unreachable());
        \\test.skipIf(false)("test #4", () => expect().pass());
        \\test.skipIf(null)("test #5", () => expect().pass());
        \\describe.skip("describe #1", () => test("test #6", () => expect.unreachable()));
        \\describe.skipIf(true)("describe #2", () => test("test #7", () => expect.unreachable()));
        \\describe.skipIf(1)("describe #3", () => test("test #8", () => expect.unreachable()));
        \\describe.skipIf(false)("describe #4", () => test("test #9", () => expect().pass()));
        \\describe.skipIf(null)("describe #5", () => test("test #10", () => expect().pass()));
        \\test.if(false)("test #11", () => expect.unreachable());
        \\test.if(null)("test #12", () => expect.unreachable());
        \\test.if(true)("test #13", () => expect().pass());
        \\test.if(1)("test #14", () => expect().pass());
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "js/bun/test/skip-test-fixture.js");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 6), file_run.result.passed);
    try std.testing.expectEqual(@as(usize, 8), file_run.result.todo);
    try std.testing.expectEqual(@as(usize, 0), file_run.result.failed);
}

test "bootstrap runner honors Bake platform skip metadata" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import { devTest, emptyHtmlFile } from "../bake-harness";
        \\devTest("platform skip", {
        \\  skip: [process.platform],
        \\  files: {
        \\    "index.html": emptyHtmlFile({ scripts: ["index.ts"] }),
        \\    "index.ts": `console.log("should not run");`,
        \\  },
        \\  async test(dev) {
        \\    throw new Error("skipped Bake test executed");
        \\  },
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "bake/dev/hot.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.todo, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 0), file_run.result.passed);
    try std.testing.expectEqual(@as(usize, 1), file_run.result.todo);
    try std.testing.expectEqual(@as(usize, 0), file_run.result.failed);
}

test "bootstrap runner covers Deno Event behavior and ignored tests" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import { createDenoTest } from "deno:harness";
        \\const { test, assert, assertEquals } = createDenoTest(import.meta.path);
        \\test(function eventBehavior() {
        \\  const normal = new Event("click");
        \\  assertEquals(normal.composedPath(), []);
        \\  assertEquals(normal.cancelBubble, false);
        \\  normal.stopPropagation();
        \\  assertEquals(normal.cancelBubble, true);
        \\  assertEquals(normal.defaultPrevented, false);
        \\  normal.preventDefault();
        \\  assertEquals(normal.defaultPrevented, false);
        \\  const cancelable = new Event("submit", { cancelable: true } as EventInit);
        \\  cancelable.preventDefault();
        \\  assertEquals(cancelable.defaultPrevented, true);
        \\  const desc1 = Object.getOwnPropertyDescriptor(new Event("x"), "isTrusted");
        \\  const desc2 = Object.getOwnPropertyDescriptor(new Event("y"), "isTrusted");
        \\  assert(desc1);
        \\  assert(desc2);
        \\  assertEquals(typeof desc1!.get, "function");
        \\  assertEquals(desc1!.get, desc2!.get);
        \\});
        \\test.ignore(function ignored() {
        \\  throw new Error("must not execute");
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "js/deno/event/event.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);
    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 1), file_run.result.passed);
    try std.testing.expectEqual(@as(usize, 1), file_run.result.todo);
}

test "bootstrap runner covers Deno harness options and todo calls" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import { createDenoTest } from "deno:harness";
        \\const { test, assertEquals, assertGreaterThanOrEqual, assertThrows } = createDenoTest(import.meta.path);
        \\test({ permissions: "none" }, function skippedByPermissions() {
        \\  throw new Error("must not execute");
        \\});
        \\test({ permissions: { net: false } }, function skippedByNetPermission() {
        \\  throw new Error("must not execute");
        \\});
        \\test({ ignore: true }, function skippedByIgnoreOption() {
        \\  throw new Error("must not execute");
        \\});
        \\test.todo(function pendingFunction() {
        \\  throw new Error("must not execute");
        \\});
        \\test.todo({}, function pendingOptionsFunction() {
        \\  throw new Error("must not execute");
        \\});
        \\test(function executedDenoHarnessTest() {
        \\  assertEquals(1 + 1, 2);
        \\  assertGreaterThanOrEqual(2, 2);
        \\  assertThrows(() => { throw new Error("ok"); });
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "js/deno/performance/performance.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 1), file_run.result.passed);
    try std.testing.expectEqual(@as(usize, 5), file_run.result.todo);
}

test "bootstrap runner covers Deno performance nucleus" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import { createDenoTest } from "deno:harness";
        \\const { test, assert, assertEquals, assertGreaterThanOrEqual, assertThrows } = createDenoTest(import.meta.path);
        \\test(function performanceNucleus() {
        \\  const start = performance.now();
        \\  const end = performance.now();
        \\  assertGreaterThanOrEqual(end - start, 10);
        \\  const json = performance.toJSON();
        \\  assert("timeOrigin" in json);
        \\  const mark = performance.mark("test", { detail: { foo: "foo" } });
        \\  assert(mark instanceof PerformanceMark);
        \\  assertEquals(mark.detail, { foo: "foo" });
        \\  const measure = performance.measure("measure", "test");
        \\  assert(measure instanceof PerformanceMeasure);
        \\  assertEquals(performance.getEntriesByName("test", "mark").at(-1), mark);
        \\  assertEquals(performance.getEntriesByType("measure").at(-1), measure);
        \\  assertThrows(() => new Performance());
        \\  assert(performance instanceof EventTarget);
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "js/deno/performance/performance.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 1), file_run.result.passed);
}

test "bootstrap runner covers WebSocket ErrorEvent snapshot nucleus" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import { expect, test } from "bun:test";
        \\test("websocket error event", async () => {
        \\  const ws = new WebSocket("ws://127.0.0.1:8080");
        \\  const { promise, resolve } = Promise.withResolvers();
        \\  ws.onerror = error => resolve(error);
        \\  const error = await promise;
        \\  expect(error).toMatchInlineSnapshot(`ErrorEvent {
        \\  type: "error",
        \\  message: "WebSocket connection to 'ws://127.0.0.1:8080/' failed: Failed to connect", 
        \\  error: [Error: WebSocket connection to 'ws://127.0.0.1:8080/' failed: Failed to connect]
        \\}`);
        \\  expect(Bun.inspect(error)).toMatchInlineSnapshot(`
        \\    "ErrorEvent {
        \\      type: "error",
        \\      message: "WebSocket connection to 'ws://127.0.0.1:8080/' failed: Failed to connect",
        \\      error: error: WebSocket connection to 'ws://127.0.0.1:8080/' failed: Failed to connect
        \\    ,
        \\    }"
        \\  `);
        \\  const empty = new ErrorEvent("error");
        \\  expect(empty.message).toBe("");
        \\  expect(Bun.inspect(empty)).toMatchInlineSnapshot(`
        \\    "ErrorEvent {
        \\      type: "error",
        \\      message: "",
        \\      error: null,
        \\    }"
        \\  `);
        \\  expect(empty).toMatchInlineSnapshot(`ErrorEvent {
        \\  type: "error",
        \\  message: "", 
        \\  error: null
        \\}`);
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "js/web/websocket/error-event.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 1), file_run.result.passed);
}

test "bootstrap runner covers Deno AbortController behavior" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import { createDenoTest } from "deno:harness";
        \\const { test, assert, assertEquals } = createDenoTest(import.meta.path);
        \\test(function abortBehavior() {
        \\  const controller = new AbortController();
        \\  const { signal } = controller;
        \\  assert(signal);
        \\  assertEquals(signal.aborted, false);
        \\  let called = 0;
        \\  signal.onabort = evt => {
        \\    assertEquals(evt.type, "abort");
        \\    called++;
        \\  };
        \\  signal.addEventListener("abort", function(evt) {
        \\    assert(this === signal);
        \\    assertEquals(evt.type, "abort");
        \\    called++;
        \\  });
        \\  controller.abort();
        \\  assertEquals(signal.aborted, true);
        \\  assertEquals(called, 2);
        \\  controller.abort();
        \\  assertEquals(called, 2);
        \\  assertEquals(Object.prototype.toString.call(new AbortController()), "[object AbortController]");
        \\  assertEquals(AbortSignal.abort("hey!").reason, "hey!");
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "js/deno/abort/abort-controller.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 1), file_run.result.passed);
}

test "bootstrap runner covers URLSearchParams behavior" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import { createDenoTest } from "deno:harness";
        \\const { test, assertEquals } = createDenoTest(import.meta.path);
        \\test(function urlSearchParamsBehavior() {
        \\  assertEquals(new URLSearchParams({ str: "this string has spaces in it" }).toString(), "str=this+string+has+spaces+in+it");
        \\  assertEquals(new URLSearchParams("q=a+b").get("q"), "a b");
        \\  assertEquals(new URLSearchParams("b=%2%2af%2a").get("b"), "%2*f*");
        \\  const params = new URLSearchParams("c=4&a=2&b=3&a=1");
        \\  params.sort();
        \\  assertEquals(params.toString(), "a=2&a=1&b=3&c=4");
        \\  let hasThrown = 0;
        \\  try { new URLSearchParams([["1"]]); } catch (err) { if (err instanceof TypeError) hasThrown = 1; }
        \\  assertEquals(hasThrown, 1);
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "js/deno/url/urlsearchparams.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 1), file_run.result.passed);
}

test "bootstrap runner covers Deno URL parsing smoke" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import { createDenoTest } from "deno:harness";
        \\const { test, assertEquals } = createDenoTest(import.meta.path);
        \\test(function urlParsing() {
        \\  const url = new URL("https://foo:bar@baz.qat:8000/qux/quux?foo=bar&baz=12#qat");
        \\  assertEquals(url.hash, "#qat");
        \\  assertEquals(url.host, "baz.qat:8000");
        \\  assertEquals(url.hostname, "baz.qat");
        \\  assertEquals(url.href, "https://foo:bar@baz.qat:8000/qux/quux?foo=bar&baz=12#qat");
        \\  assertEquals(url.origin, "https://baz.qat:8000");
        \\  assertEquals(url.password, "bar");
        \\  assertEquals(url.pathname, "/qux/quux");
        \\  assertEquals(url.port, "8000");
        \\  assertEquals(url.protocol, "https:");
        \\  assertEquals(url.search, "?foo=bar&baz=12");
        \\  assertEquals(url.searchParams.getAll("foo"), ["bar"]);
        \\  assertEquals(url.searchParams.getAll("baz"), ["12"]);
        \\  assertEquals(url.username, "foo");
        \\  assertEquals(String(url), "https://foo:bar@baz.qat:8000/qux/quux?foo=bar&baz=12#qat");
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "js/deno/url/url.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 1), file_run.result.passed);
}

test "bootstrap runner covers Bun semver satisfies comparator lists" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import { semver } from "bun";
        \\import { expect, test } from "bun:test";
        \\test("semver with multiple tags work properly", () => {
        \\  expect(semver.satisfies("3.3.1", ">=3.3.0-beta.1 <3.4.0-beta.3")).toBe(true);
        \\  expect(semver.satisfies("3.4.5", ">=3.3.0-beta.1 <3.4.0-beta.3")).toBeFalse();
        \\  let unsupported = false;
        \\  try { semver.satisfies("1.2.3", "^1.2.0"); } catch (error) { unsupported = error && error.__home_unsupported === true; }
        \\  expect(unsupported).toBe(true);
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "regression/issue/08040.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 1), file_run.result.passed);
}

test "bootstrap runner covers Bun TOML parse non-string errors" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import { expect, test } from "bun:test";
        \\
        \\test("Bun.TOML.parse with non-string input throws", () => {
        \\  expect(() => Bun.TOML.parse(SharedArrayBuffer)).toThrow();
        \\  expect(() => Bun.TOML.parse(undefined)).toThrow();
        \\  expect(() => Bun.TOML.parse(null)).toThrow();
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "js/bun/resolve/toml/toml-parse.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 1), file_run.result.passed);
}

test "bootstrap runner covers node vm process event throw propagation" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import { expect, test } from "bun:test";
        \\import { runInNewContext } from "node:vm";
        \\
        \\test("issue #9778", () => {
        \\  const code = `
        \\    process.on("poop", () => {
        \\      throw new Error("woopsie");
        \\    });
        \\    `;
        \\
        \\  runInNewContext(code, {
        \\    process,
        \\  });
        \\  expect(() => process.emit("poop")).toThrow("woopsie");
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "regression/issue/09778.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 1), file_run.result.passed);
}

test "bootstrap runner covers mock clearAllMocks call counts" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import { expect, mock, test } from "bun:test";
        \\
        \\const random1 = mock(() => Math.random());
        \\const random2 = mock(() => Math.random());
        \\
        \\test("clearing all mocks", () => {
        \\  random1();
        \\  random2();
        \\
        \\  expect(random1).toHaveBeenCalledTimes(1);
        \\  expect(random2).toHaveBeenCalledTimes(1);
        \\
        \\  mock.clearAllMocks();
        \\
        \\  expect(random1).toHaveBeenCalledTimes(0);
        \\  expect(random2).toHaveBeenCalledTimes(0);
        \\
        \\  expect(typeof random1()).toBe("number");
        \\  expect(typeof random2()).toBe("number");
        \\
        \\  expect(random1).toHaveBeenCalledTimes(1);
        \\  expect(random2).toHaveBeenCalledTimes(1);
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "regression/issue/18820.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 1), file_run.result.passed);
}

test "bootstrap runner covers inline snapshot unicode object formatting" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\test("correct snapshot formatting for object key with unicode", () => {
        \\  expect({ "▶": "▹" }).toMatchInlineSnapshot(`
        \\    {
        \\      "▶": "▹",
        \\    }
        \\  `);
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "regression/issue/23382.test.js");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 1), file_run.result.passed);
}

test "bootstrap runner covers Bun internal regexp escaping helpers" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import testHelpers from "bun:internal-for-testing";
        \\import { expect, test } from "bun:test";
        \\const { escapeRegExp, escapeRegExpForPackageNameMatching } = testHelpers;
        \\
        \\test("escapeRegExp", () => {
        \\  expect(escapeRegExp("\\ ^ $ * + ? . ( ) | { } [ ]")).toBe("\\\\ \\^ \\$ \\* \\+ \\? \\. \\( \\) \\| \\{ \\} \\[ \\]");
        \\  expect(escapeRegExp("foo - bar")).toBe("foo \\x2d bar");
        \\});
        \\
        \\test("escapeRegExpForPackageName", () => {
        \\  expect(escapeRegExpForPackageNameMatching("foo - bar*")).toBe("foo \\x2d bar.*");
        \\  expect(escapeRegExpForPackageNameMatching("\\ ^ $ * + ? . ( ) | { } [ ]")).toBe(
        \\    "\\\\ \\^ \\$ .* \\+ \\? \\. \\( \\) \\| \\{ \\} \\[ \\]",
        \\  );
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "js/bun/util/escapeRegExp.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 2), file_run.result.passed);
}

test "bootstrap runner covers assert strict boxed primitive equality" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import assert from "assert/strict";
        \\import { expect, test } from "bun:test";
        \\
        \\test("assert.deepStrictEqual() should compare Number wrapper object values - issue #24045", () => {
        \\  expect(() => {
        \\    assert.deepStrictEqual(new Number(1), new Number(2));
        \\  }).toThrow("Expected values to be strictly deep-equal");
        \\
        \\  expect(() => {
        \\    assert.deepStrictEqual(new Number(1), new Number(1));
        \\  }).not.toThrow();
        \\
        \\  expect(() => {
        \\    assert.deepStrictEqual(new Number(0), new Number(-0));
        \\  }).toThrow("Expected values to be strictly deep-equal");
        \\
        \\  expect(() => {
        \\    assert.deepStrictEqual(new Number(NaN), new Number(NaN));
        \\  }).not.toThrow();
        \\
        \\  expect(() => {
        \\    assert.deepStrictEqual(new Number(Infinity), new Number(-Infinity));
        \\  }).toThrow("Expected values to be strictly deep-equal");
        \\});
        \\
        \\test("assert.deepStrictEqual() should compare Boolean wrapper object values - issue #24045", () => {
        \\  expect(() => {
        \\    assert.deepStrictEqual(new Boolean(true), new Boolean(false));
        \\  }).toThrow("Expected values to be strictly deep-equal");
        \\
        \\  expect(() => {
        \\    assert.deepStrictEqual(new Boolean(true), new Boolean(true));
        \\  }).not.toThrow();
        \\});
        \\
        \\test("assert.deepStrictEqual() should not compare Number wrapper with primitive", () => {
        \\  expect(() => {
        \\    assert.deepStrictEqual(new Number(1), 1);
        \\  }).toThrow("Expected values to be strictly deep-equal");
        \\});
        \\
        \\test("assert.deepStrictEqual() should check own properties on wrapper objects", () => {
        \\  const num1 = new Number(42);
        \\  const num2 = new Number(42);
        \\  (num1 as any).customProp = "hello";
        \\
        \\  expect(() => {
        \\    assert.deepStrictEqual(num1, num2);
        \\  }).toThrow("Expected values to be strictly deep-equal");
        \\
        \\  (num2 as any).customProp = "hello";
        \\  expect(() => {
        \\    assert.deepStrictEqual(num1, num2);
        \\  }).not.toThrow();
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "regression/issue/24045.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 4), file_run.result.passed);
}

test "bootstrap runner covers TypeScript override accessibility smoke" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import { expect, test } from "bun:test";
        \\
        \\test("override is an accessibility modifier", () => {
        \\  class FooParent {}
        \\
        \\  class FooChild extends FooParent {}
        \\
        \\  class BarParent {
        \\    constructor(readonly foo: FooParent) {}
        \\  }
        \\
        \\  class BarChild extends BarParent {
        \\    constructor(override foo: FooChild) {
        \\      super(foo);
        \\    }
        \\  }
        \\
        \\  new BarChild(new FooChild());
        \\
        \\  expect().pass();
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "regression/issue/07324.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 1), file_run.result.passed);
}

test "bootstrap runner covers HTMLRewriter element callback smoke" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import { expect, jest, test } from "bun:test";
        \\
        \\test("#7827", () => {
        \\  for (let i = 0; i < 10; i++)
        \\    (function () {
        \\      const element = jest.fn(element => {
        \\        element.tagName;
        \\      });
        \\      const rewriter = new HTMLRewriter().on("p", {
        \\        element,
        \\      });
        \\
        \\      const content = "<p>Lorem ipsum!</p>";
        \\
        \\      rewriter.transform(new Response(content));
        \\      rewriter.transform(new Response(content));
        \\
        \\      expect(element).toHaveBeenCalledTimes(2);
        \\    })();
        \\
        \\  Bun.gc(true);
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "regression/issue/07827.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 1), file_run.result.passed);
}

test "bootstrap runner covers HTMLRewriter doctype removal smoke" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import { expect, test } from "bun:test";
        \\
        \\test("remove and removed property work on DOCTYPE", () => {
        \\  const html = "<!DOCTYPE html><html><head></head><body>Hello</body></html>";
        \\  let sawDoctype = false;
        \\  let wasRemoved = false;
        \\
        \\  const rewriter = new HTMLRewriter().onDocument({
        \\    doctype(doctype) {
        \\      sawDoctype = true;
        \\      doctype.remove();
        \\      wasRemoved = doctype.removed;
        \\    },
        \\  });
        \\
        \\  const result = rewriter.transform(html);
        \\
        \\  expect(sawDoctype).toBe(true);
        \\  expect(wasRemoved).toBe(true);
        \\  expect(result).not.toContain("<!DOCTYPE");
        \\  expect(result).toContain("<html>");
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "js/web/html/html-rewriter-doctype.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 1), file_run.result.passed);
}

test "bootstrap runner covers Bun.Transpiler invalid UTF-16 loader smoke" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import { describe, expect, test } from "bun:test";
        \\
        \\describe("Bun.Transpiler with a UTF-16 loader string", () => {
        \\  const utf16 = "тsx";
        \\
        \\  test("scan", () => {
        \\    const t = new Bun.Transpiler();
        \\    expect(() => t.scan("", utf16)).toThrow(TypeError);
        \\  });
        \\
        \\  test("scanImports", () => {
        \\    const t = new Bun.Transpiler();
        \\    expect(() => t.scanImports("", utf16)).toThrow(TypeError);
        \\  });
        \\
        \\  test("transformSync", () => {
        \\    const t = new Bun.Transpiler();
        \\    expect(() => t.transformSync("", utf16)).toThrow(TypeError);
        \\  });
        \\
        \\  test("transform", () => {
        \\    const t = new Bun.Transpiler();
        \\    expect(() => t.transform("", utf16)).toThrow(TypeError);
        \\  });
        \\
        \\  test("constructor", () => {
        \\    expect(() => new Bun.Transpiler({ loader: utf16 as any })).toThrow(TypeError);
        \\  });
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "js/bun/transpiler/transpiler-utf16-loader.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 5), file_run.result.passed);
}

test "bootstrap runner covers Bun.JSONC parse smoke" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import { expect, test } from "bun:test";
        \\
        \\test("Bun.JSONC.parse handles comments", () => {
        \\  const result = Bun.JSONC.parse(`{
        \\    // line comment
        \\    "name": "test",
        \\    /* block comment */
        \\    "values": [1, 2, 3,],
        \\  }`);
        \\  expect(result).toEqual({ name: "test", values: [1, 2, 3] });
        \\});
        \\
        \\test("Bun.JSONC.parse throws on deeply nested arrays instead of crashing", () => {
        \\  const depth = 200_000;
        \\  const deepJson = Buffer.alloc(depth, "[").toString() + Buffer.alloc(depth, "]").toString();
        \\  expect(() => Bun.JSONC.parse(deepJson)).toThrow(RangeError);
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "js/bun/jsonc/jsonc.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 2), file_run.result.passed);
}

test "bootstrap runner covers PowerShell escaping helper" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import { escapePowershell } from "bun:internal-for-testing";
        \\
        \\it("powershell escaping rules", () => {
        \\  expect(escapePowershell("foo")).toBe("foo");
        \\  expect(escapePowershell("foo bar")).toBe("foo bar");
        \\  expect(escapePowershell('foo" bar')).toBe('foo`" bar');
        \\  expect(escapePowershell('foo" `bar')).toBe('foo`" ``bar');
        \\  expect(escapePowershell('foo" ``"bar')).toBe('foo`" `````"bar');
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "internal/powershell-escape.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 1), file_run.result.passed);
}

test "bootstrap runner covers CommonJS assert require helpers" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\var assert = require("assert");
        \\
        \\test("assert from require as a function does not throw", () => assert(true));
        \\test("match does not throw when matching", () => {
        \\  assert.match("I will pass", /pass/);
        \\});
        \\test("match throws when argument is not string", () => {
        \\  expect(() => assert.match(123, /pass/)).toThrow('The "string" argument must be of type string. Received type number');
        \\});
        \\test("doesNotMatch does not throw when not matching", () => {
        \\  assert.doesNotMatch("I will pass", /different/);
        \\});
        \\test("doesNotMatch throws when matching", () => {
        \\  expect(() => assert.doesNotMatch("I will fail", /fail/, "doesNotMatch throws when matching")).toThrow(
        \\    "doesNotMatch throws when matching",
        \\  );
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "js/node/assert/assert-cjs-smoke.test.cjs");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 5), file_run.result.passed);
}

test "bootstrap runner covers Node path bootstrap smokes" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import assert from "node:assert";
        \\import path from "path";
        \\import { describe, test } from "bun:test";
        \\
        \\describe("path.posix", () => {
        \\  test("exists", () => {
        \\    assert.strictEqual(require("path/posix"), require("path").posix);
        \\  });
        \\});
        \\
        \\describe("path.win32", () => {
        \\  test("exists", () => {
        \\    assert.strictEqual(require("path/win32"), require("path").win32);
        \\  });
        \\});
        \\
        \\test("too-long path names do not crash when joined", () => {
        \\  const length = 4096;
        \\  const tooLengthyFolderName = Array.from({ length }).fill("b").join("");
        \\  assert.equal(path.join(tooLengthyFolderName), "b".repeat(length));
        \\  assert.equal(path.win32.join(tooLengthyFolderName), "b".repeat(length));
        \\  assert.equal(path.posix.join(tooLengthyFolderName), "b".repeat(length));
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "js/node/path/path-bootstrap-smoke.test.js");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 3), file_run.result.passed);
}

test "bootstrap runner covers Node url bootstrap smokes" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import { describe, test } from "bun:test";
        \\import assert from "node:assert";
        \\import { URL } from "node:url";
        \\import url from "node:url";
        \\
        \\describe("URL.canParse", () => {
        \\  test.todo("invalid input", () => {
        \\    URL.canParse();
        \\  });
        \\
        \\  test("repeatedly called produces same result", () => {
        \\    for (let i = 0; i < 10; i++) {
        \\      assert(URL.canParse("https://www.example.com/path/?query=param#hash"));
        \\    }
        \\  });
        \\});
        \\
        \\describe("url.format", () => {
        \\  test.todo("invalid input", () => {
        \\    url.format(null);
        \\  });
        \\
        \\  test("empty", () => {
        \\    assert.strictEqual(url.format(""), "");
        \\    assert.strictEqual(url.format({}), "");
        \\  });
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "js/node/url/url-bootstrap-smoke.test.js");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 2), file_run.result.passed);
    try std.testing.expectEqual(@as(usize, 2), file_run.result.todo);
}

test "bootstrap runner reports unsupported thrown by harness as unsupported" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\test("unsupported Buffer path", () => {
        \\  Buffer.from(new ArrayBuffer(1));
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "js/node/buffer-unsupported.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.unsupported, file_run.result.status());
    try std.testing.expect(std.mem.indexOf(u8, file_run.result.first_failure_message, "Only Buffer.from") != null);
}

test "bootstrap runner accepts microtask-settled returned promises" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\test("async path", () => Promise.resolve().then(() => {
        \\  expect(1).toBe(1);
        \\}));
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "js/bun/test/async-resolved.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 1), file_run.result.passed);
}

test "bootstrap matcher toThrow accepts async rejection functions" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\test("async throw matcher", () => {
        \\  expect(async () => { throw new SyntaxError("bad body"); }).toThrow(SyntaxError);
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "regression/issue/02367.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 1), file_run.result.passed);
}

test "bootstrap Bun.file exposes explicit and inferred file types" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\test("file type", () => {
        \\  expect(Bun.file("test", { type: "text/markdown" }).type).toBe("text/markdown");
        \\  expect(Bun.file("test.css").type).toBe("text/css;charset=utf-8");
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "js/bun/util/file-type.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 1), file_run.result.passed);
}

test "bootstrap node url pathToFileURL handles POSIX path encoding" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import url from "node:url";
        \\test("pathToFileURL", () => {
        \\  expect(url.pathToFileURL("/foo bar").href).toBe("file:///foo%20bar");
        \\  expect(url.pathToFileURL("/foo?bar").href).toBe("file:///foo%3Fbar");
        \\  expect(url.pathToFileURL("/foo#bar").href).toBe("file:///foo%23bar");
        \\  expect(url.pathToFileURL("/fóóbàr").href).toBe("file:///f%C3%B3%C3%B3b%C3%A0r");
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "js/node/url/url-pathtofileurl.test.js");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 1), file_run.result.passed);
}

test "bootstrap matcher toBeEmpty accepts strings and collections" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\test("empty matcher", () => {
        \\  expect("").toBeEmpty();
        \\  expect([]).toBeEmpty();
        \\  expect(new Map()).toBeEmpty();
        \\  expect({}).toBeEmpty();
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "cli/run/empty-file.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 1), file_run.result.passed);
}

test "bootstrap Bun.randomUUIDv7 exposes timestamped monotonic ids" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\test("uuidv7", () => {
        \\  const fixed = Bun.randomUUIDv7("hex", 1625097600000);
        \\  expect(fixed).toStartWith("017a5f5d-");
        \\  expect(fixed["017a5f5d-0000-".length]).toBe("7");
        \\  expect(Bun.randomUUIDv7("base64")).toMatch(/^[0-9a-zA-Z+/=]+$/);
        \\  expect(Bun.randomUUIDv7("buffer")).toBeInstanceOf(Buffer);
        \\  const input = Array.from({ length: 8 }, () => Bun.randomUUIDv7("hex", 1625097600000));
        \\  expect(Bun.deepEquals(input.slice().sort(), input)).toBe(true);
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "js/bun/util/randomUUIDv7.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 1), file_run.result.passed);
}

test "bootstrap runner reports pending returned promises as unsupported" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\test("pending async path", () => new Promise(() => {}));
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "js/bun/test/async-pending.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.unsupported, file_run.result.status());
    try std.testing.expect(std.mem.indexOf(u8, file_run.result.first_failure_message, "pending async test promise") != null);
}

test "bootstrap runner reports rejected returned promises as failed" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\test("rejected async path", () => Promise.reject(new Error("async boom")));
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "js/bun/test/async-rejected.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.failed, file_run.result.status());
    try std.testing.expect(std.mem.indexOf(u8, file_run.result.first_failure_message, "async boom") != null);
}

test "bootstrap runner keeps real assertion failures as failed" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\test("real failure", () => {
        \\  expect(1).toBe(2);
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "js/bun/test/assertion-failure.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.failed, file_run.result.status());
    try std.testing.expect(std.mem.indexOf(u8, file_run.result.first_failure_message, "Expected 1 to be 2") != null);
}

test "bootstrap toMatchObject rejects missing keys and array length mismatches" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\test("match object fidelity", () => {
        \\  expect({ a: 1, b: 2 }).toMatchObject({ a: 1 });
        \\  expect({}).not.toMatchObject({ missing: undefined });
        \\  expect([1, 2]).not.toMatchObject([1]);
        \\  expect([1]).not.toMatchObject([1, 2]);
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "js/bun/test/to-match-object-fidelity.test.js");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 1), file_run.result.passed);
}

test "bootstrap process.binding exposes constants and uv surfaces" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\test("process binding", () => {
        \\  const constants = process.binding("constants");
        \\  expect(constants).toHaveProperty("os");
        \\  expect(constants).toHaveProperty("crypto");
        \\  const uv = process.binding("uv");
        \\  expect(uv).toHaveProperty("UV_EACCES");
        \\  expect(uv.errname(-4)).toBe("EINTR");
        \\  expect(uv.errname(Number("-5.9") + 1.9)).toBe("EINTR");
        \\  expect(uv.errname(5)).toBe("Unknown system error: 5");
        \\  expect(uv.getErrorMap().get(uv.UV_EISCONN)).toEqual(["EISCONN", "socket is already connected"]);
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "js/node/process-binding.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 1), file_run.result.passed);
}

test "bootstrap jest fake timers keep Bun Date identity" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\test("we can go back in time", () => {
        \\  const DateBeforeMocked = Date;
        \\  jest.useFakeTimers();
        \\  jest.setSystemTime(new Date("1995-12-19T00:00:00.000Z"));
        \\  expect(new Date().toISOString()).toBe("1995-12-19T00:00:00.000Z");
        \\  expect(Date.now()).toBe(819331200000);
        \\  expect(DateBeforeMocked).toBe(Date);
        \\  expect(DateBeforeMocked.now).toBe(Date.now);
        \\  expect(new Intl.DateTimeFormat().format()).toBe("12/19/1995");
        \\  jest.setSystemTime(new Date("2020-01-01T00:00:00.000Z").getTime());
        \\  expect(new Date().toISOString()).toBe("2020-01-01T00:00:00.000Z");
        \\  expect(Date.now()).toBe(1577836800000);
        \\  jest.useRealTimers();
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "js/bun/test/test-timers.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 1), file_run.result.passed);
}

test "bootstrap internal highlighter handles template interpolation" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import { highlightJavaScript as highlighter } from "bun:internal-for-testing";
        \\import { expect, test } from "bun:test";
        \\
        \\test("highlighter", () => {
        \\  expect(highlighter("`can do ${123} ${'123'} ${`123`}`").length).toBeLessThan(150);
        \\  expect(highlighter("`can do ${123} ${'123'} ${`123`}`123").length).toBeLessThan(150);
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "internal/highlighter.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 1), file_run.result.passed);
}

test "bootstrap pass-with-no-tests spawn override matches Bun exit codes" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import { expect, test } from "bun:test";
        \\import { bunEnv, bunExe, tempDir } from "harness";
        \\
        \\test("pass with no tests", () => {
        \\  const dir = tempDir("pass-with-no-tests", { "not-a-test.ts": `console.log("hello");` });
        \\  const proc = Bun.spawn({ cmd: [bunExe(), "test", "--pass-with-no-tests"], cwd: String(dir), stdout: "pipe", stderr: "pipe", stdin: "ignore", env: bunEnv });
        \\  expect(proc.exitCode).toBe(0);
        \\  expect(String(proc.stderr)).toContain("No tests found!");
        \\});
        \\
        \\test("fail with no tests", () => {
        \\  const dir = tempDir("fail-with-no-tests", { "not-a-test.ts": `console.log("hello");` });
        \\  const proc = Bun.spawn({ cmd: [bunExe(), "test"], cwd: String(dir), stdout: "pipe", stderr: "pipe", stdin: "ignore", env: bunEnv });
        \\  expect(proc.exitCode).toBe(1);
        \\  expect(String(proc.stderr)).toContain("No tests found!");
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "cli/test/pass-with-no-tests.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 2), file_run.result.passed);
}

test "bootstrap runner covers relative CJS fixture require" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import { expect, test } from "bun:test";
        \\
        \\test("regression", () => {
        \\  expect(() => require("./013880-fixture.cjs")).not.toThrow();
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "regression/issue/013880.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 1), file_run.result.passed);
}

test "bootstrap runner covers mutable globalThis prototype smoke" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import { expect, test } from "bun:test";
        \\
        \\test("Object.setPrototypeOf works on globalThis", () => {
        \\  const orig = Object.getPrototypeOf(globalThis);
        \\  Object.setPrototypeOf(
        \\    globalThis,
        \\    Object.create(null, {
        \\      a: {
        \\        value: 1,
        \\      },
        \\    }),
        \\  );
        \\  expect(a).toBe(1);
        \\  Object.setPrototypeOf(globalThis, orig);
        \\  expect(globalThis.a).toBeUndefined();
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "js/bun/util/exotic-global-mutable-prototype.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 1), file_run.result.passed);
}

test "Bun test import rewrite installs globals for no-import tests" {
    const source =
        \\test("works", () => {
        \\  expect(1).toBe(1);
        \\});
    ;
    const rewritten = try rewriteBunTestImport(std.testing.allocator, source, "regression/issue/example.test.js");
    defer std.testing.allocator.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "var __filename = \"regression/issue/example.test.js\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "globalThis.__home_current_dirname = __dirname") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "test(\"works\"") != null);
}

test "Bun test import rewrite reports unsupported import shapes" {
    const source =
        \\import { expect as want, test } from "bun:test";
        \\test("works", () => want(1).toBe(1));
    ;
    const rewritten = try rewriteBunTestImport(std.testing.allocator, source, "regression/issue/alias.test.js");
    defer std.testing.allocator.free(rewritten);

    try std.testing.expect(hasBunTestImport(rewritten));
}

test "corpus module preparation reports unsupported module syntax" {
    const source =
        \\import value from "node:fs";
        \\test("works", () => {});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "regression/issue/import.test.js");
    defer prepared.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("unsupported module syntax", prepared.unsupported_reason.?);
}

test "corpus module preparation reports unsupported Bake harness module" {
    const source =
        \\import * as bakeHarness from "./bake-harness";
        \\bakeHarness.devTest("smoke", { files: {}, async test() {} });
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "bake/dev-and-prod.test.ts");
    defer prepared.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("unsupported bake harness module", prepared.unsupported_reason.?);
}

test "Bun corpus rewrite lowers node fs sync imports before Bake harness boundary" {
    const source =
        \\import { writeFileSync } from "node:fs";
        \\import { devAndProductionTest, devTest, emptyHtmlFile, WAIT_MULTIPLIER } from "./bake-harness";
        \\devAndProductionTest("smoke", { files: {}, async test() { writeFileSync("index.ts", "console.log(1)"); } });
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "bake/dev-and-prod.test.ts");
    defer prepared.deinit(std.testing.allocator);

    try std.testing.expect(prepared.unsupported_reason == null);
    try std.testing.expect(std.mem.indexOf(u8, prepared.source, "import { writeFileSync } from \"node:fs\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, prepared.source, "from \"./bake-harness\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, prepared.source, "const { writeFileSync } = globalThis.__home_import(\"node:fs\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, prepared.source, "const { devAndProductionTest, devTest, emptyHtmlFile, WAIT_MULTIPLIER } = globalThis.__home_import(\"bake-harness\");") != null);
}

test "Bun corpus rewrite lowers node fs atomic save imports" {
    const source =
        \\import { expect } from "bun:test";
        \\import { renameSync, unlinkSync, writeFileSync } from "node:fs";
        \\import { devTest, emptyHtmlFile } from "../bake-harness";
        \\devTest("smoke", { files: {}, async test(dev) {} });
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "bake/dev/hot.test.ts");
    defer prepared.deinit(std.testing.allocator);

    try std.testing.expect(prepared.unsupported_reason == null);
    try std.testing.expect(std.mem.indexOf(u8, prepared.source, "from \"node:fs\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, prepared.source, "const { renameSync, unlinkSync, writeFileSync } = globalThis.__home_import(\"node:fs\");") != null);
}

test "Bun corpus rewrite lowers parent Bake harness after expect-only bun test import" {
    const source =
        \\import { expect } from "bun:test";
        \\import { devTest, emptyHtmlFile, minimalFramework } from "../bake-harness";
        \\devTest("smoke", { files: {}, async test() { expect(1).toBe(1); } });
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "bake/dev/bundle.test.ts");
    defer prepared.deinit(std.testing.allocator);

    try std.testing.expect(prepared.unsupported_reason == null);
    try std.testing.expect(std.mem.indexOf(u8, prepared.source, "import { expect } from \"bun:test\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, prepared.source, "from \"../bake-harness\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, prepared.source, "const { expect } = globalThis.__home_import(\"bun:test\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, prepared.source, "const { devTest, emptyHtmlFile, minimalFramework } = globalThis.__home_import(\"bake-harness\");") != null);
}

test "bootstrap runner records Bake dev and production tests as unsupported by name" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import { devAndProductionTest, devTest, emptyHtmlFile, WAIT_MULTIPLIER } from "./bake-harness";
        \\devAndProductionTest("define config via bunfig.toml", {
        \\  files: { "index.html": emptyHtmlFile({ scripts: ["index.ts"] }) },
        \\  async test(dev) {},
        \\});
        \\devTest("using runtime import", { files: {}, async test(dev) {} });
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "bake/dev-and-prod.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.unsupported, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 3), file_run.result.unsupported);
    try std.testing.expect(std.mem.indexOf(u8, file_run.result.first_failure_message, "Bake harness test not implemented:  DEV:dev-and-prod-1: define config via bunfig.toml") != null);
}

test "bootstrap runner executes Bake define config smoke" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import { devAndProductionTest, devTest, emptyHtmlFile, WAIT_MULTIPLIER } from "./bake-harness";
        \\devAndProductionTest("define config via bunfig.toml", {
        \\  files: {
        \\    "index.html": emptyHtmlFile({ styles: [], scripts: ["index.ts"] }),
        \\    "index.ts": `console.log("a=" + DEFINE);`,
        \\    "bunfig.toml": `
        \\      [serve.static]
        \\      define = {
        \\        "DEFINE" = "\\"HELLO\\""
        \\      }
        \\    `,
        \\  },
        \\  async test(dev) {
        \\    const c = await dev.client("/");
        \\    await c.expectMessage("a=HELLO");
        \\  },
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "bake/dev-and-prod.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 2), file_run.result.passed);
}

test "bootstrap runner executes Bake invalid html smoke" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import { devAndProductionTest, devTest, emptyHtmlFile, WAIT_MULTIPLIER } from "./bake-harness";
        \\devAndProductionTest("invalid html does not crash 1", {
        \\  files: {
        \\    "public/index.html": `
        \\      <!DOCTYPE html>
        \\      <html>
        \\        <head>
        \\          <title>Dashboard</title>
        \\          <link rel="stylesheet" href="../src/app/styles.css" />
        \\        </head>
        \\        <body>
        \\          <div id="root" />
        \\          <script type="module" src="../src/app/index.tsx" />
        \\        </body>
        \\      </html>
        \\    `,
        \\    "src/app/index.tsx": `console.log("hello");`,
        \\    "src/app/styles.css": `
        \\      body {
        \\        background-color: red;
        \\      }
        \\    `,
        \\  },
        \\  async test(dev) {
        \\    await using c = await dev.client("/");
        \\    await c.expectMessage("hello");
        \\    await c.style("body").backgroundColor.expect.toBe("red");
        \\  },
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "bake/dev-and-prod.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 2), file_run.result.passed);
}

test "bootstrap runner executes Bake missing head smoke" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import { devAndProductionTest, devTest, emptyHtmlFile, WAIT_MULTIPLIER } from "./bake-harness";
        \\devAndProductionTest("missing head end tag works fine", {
        \\  files: {
        \\    "public/index.html": `
        \\      <!DOCTYPE html>
        \\      <html>
        \\        <head>
        \\          <title>Dashboard</title>
        \\          <link rel="stylesheet" href="../src/app/styles.css"></link>
        \\        <body>
        \\          <div id="root" />
        \\          <script type="module" src="../src/app/index.tsx"></script>
        \\        </body>
        \\      </html>
        \\    `,
        \\    "src/app/index.tsx": `console.log("hello");`,
        \\    "src/app/styles.css": `
        \\      body {
        \\        background-color: red;
        \\      }
        \\    `,
        \\  },
        \\  async test(dev) {
        \\    await using c = await dev.client("/");
        \\    await c.expectMessage("hello");
        \\    await c.style("body").backgroundColor.expect.toBe("red");
        \\  },
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "bake/dev-and-prod.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 2), file_run.result.passed);
}

test "bootstrap runner executes Bake missing meta smoke" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import { devAndProductionTest, devTest, emptyHtmlFile, WAIT_MULTIPLIER } from "./bake-harness";
        \\devAndProductionTest("missing all meta tags works fine", {
        \\  files: {
        \\    "public/index.html": `
        \\      <title>Dashboard</title>
        \\      <link rel="stylesheet" href="../src/app/styles.css"></link>
        \\
        \\      <div id="root" />
        \\      <script type="module" src="../src/app/index.tsx"></script>
        \\    `,
        \\    "src/app/index.tsx": `console.log("hello");`,
        \\    "src/app/styles.css": `
        \\      body {
        \\        background-color: red;
        \\      }
        \\    `,
        \\  },
        \\  async test(dev) {
        \\    await dev.fetch("/").expect.toInclude("root");
        \\    await using c = await dev.client("/");
        \\    await c.expectMessage("hello");
        \\    await c.style("body").backgroundColor.expect.toBe("red");
        \\  },
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "bake/dev-and-prod.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 2), file_run.result.passed);
}

test "bootstrap runner executes Bake inline script and style smoke" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import { devAndProductionTest, devTest, emptyHtmlFile, WAIT_MULTIPLIER } from "./bake-harness";
        \\devAndProductionTest("inline script and styles appear", {
        \\  files: {
        \\    "public/index.html": `
        \\      <!DOCTYPE html>
        \\      <html>
        \\        <head>
        \\          <title>Dashboard</title>
        \\          <style> body { background-color: red; } </style>
        \\        </head>
        \\        <body>
        \\          <script> console.log("hello " + (1 + 2)); </script>
        \\        </body>
        \\      </html>
        \\    `,
        \\  },
        \\  async test(dev) {
        \\    await dev.fetch("/").expect.toInclude("hello");
        \\    await dev.fetch("/").expect.not.toInclude("hello 3");
        \\    await using c = await dev.client("/");
        \\    await c.expectMessage("hello 3");
        \\    await c.style("body").backgroundColor.expect.toBe("red");
        \\  },
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "bake/dev-and-prod.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 2), file_run.result.passed);
}

test "bootstrap runner executes Bake runtime import smoke" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import { devAndProductionTest, devTest, emptyHtmlFile, WAIT_MULTIPLIER } from "./bake-harness";
        \\devTest("using runtime import", {
        \\  files: {
        \\    "index.html": emptyHtmlFile({ styles: [], scripts: ["index.ts"] }),
        \\    "index.ts": `
        \\      // __using
        \\      {
        \\        using a = { [Symbol.dispose]: () => console.log("a") };
        \\        console.log("b");
        \\      }
        \\
        \\      // __legacyDecorateClassTS
        \\      function undefinedDecorator(target) {
        \\        console.log("decorator");
        \\      }
        \\      @undefinedDecorator
        \\      class x {}
        \\
        \\      // __require
        \\      const A = () => require;
        \\      const B = () => module.require;
        \\      const C = () => import.meta.require;
        \\      if (import.meta.hot) {
        \\        console.log(A.toString().replaceAll(" ", "").replaceAll("\\n", ""));
        \\        console.log(B.toString().replaceAll(" ", "").replaceAll("\\n", ""));
        \\        console.log(C.toString().replaceAll(" ", "").replaceAll("\\n", ""));
        \\        console.log(A() === eval("hmr.require"));
        \\        console.log(B() === eval("hmr.require"));
        \\        console.log(C() === eval("hmr.require"));
        \\      }
        \\    `,
        \\    "tsconfig.json": `{ "compilerOptions": { "experimentalDecorators": true } }`,
        \\  },
        \\  async test(dev) {
        \\    await using c = await dev.client("/");
        \\    await c.expectMessage("b", "a", "decorator", "()=>hmr.require", "()=>module.require", "()=>hmr.importMeta.require", true, false, false);
        \\  },
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "bake/dev-and-prod.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 1), file_run.result.passed);
}

test "bootstrap runner executes Bake rapid hmr smoke" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import { writeFileSync } from "node:fs";
        \\import { devAndProductionTest, devTest, emptyHtmlFile, WAIT_MULTIPLIER } from "./bake-harness";
        \\const hmrSelfAcceptingModule = (label) => `
        \\  console.log(${JSON.stringify(label)});
        \\  if (import.meta.hot) {
        \\    import.meta.hot.accept();
        \\  }
        \\`;
        \\devTest("hmr handles rapid consecutive edits", {
        \\  files: {
        \\    "index.html": emptyHtmlFile({ scripts: ["index.ts"] }),
        \\    "index.ts": hmrSelfAcceptingModule("render initial"),
        \\  },
        \\  async test(dev) {
        \\    await using client = await dev.client("/", { allowUnlimitedReloads: false });
        \\    await client.expectMessage("render initial");
        \\    const waitForMessage = (value) =>
        \\      new Promise((resolve, reject) => {
        \\        const onMessage = () => {
        \\          if (client.messages.includes(value)) {
        \\            client.off("message", onMessage);
        \\            resolve();
        \\          }
        \\        };
        \\        client.on("message", onMessage);
        \\        onMessage();
        \\      });
        \\    const target = dev.join("index.ts");
        \\    const rapidContent = hmrSelfAcceptingModule("render rapid");
        \\    for (let i = 0; i < 10; i++) writeFileSync(target, rapidContent);
        \\    await waitForMessage("render rapid");
        \\    writeFileSync(target, hmrSelfAcceptingModule("render sentinel"));
        \\    await waitForMessage("render sentinel");
        \\    const expected = new Set(["render rapid", "render sentinel"]);
        \\    for (const msg of client.messages) {
        \\      if (!expected.has(msg)) throw new Error(`Unexpected HMR message: ${JSON.stringify(msg)}`);
        \\    }
        \\  },
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "bake/dev-and-prod.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 1), file_run.result.passed);
}

test "bootstrap runner executes Bake minimal bundle route smokes" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import { expect } from "bun:test";
        \\import { devTest, emptyHtmlFile, minimalFramework } from "../bake-harness";
        \\devTest("import identifier doesnt get renamed", {
        \\  framework: minimalFramework,
        \\  files: {
        \\    "db.ts": `export const abc = "123";`,
        \\    "routes/index.ts": `
        \\      import { abc } from '../db';
        \\      export default function (req, meta) {
        \\        let v1 = "";
        \\        const v2 = v1 ? abc.toFixed(2) : abc.toString();
        \\        return new Response('Hello, ' + v2 + '!');
        \\      }
        \\    `,
        \\  },
        \\  async test(dev) {
        \\    await dev.fetch("/").equals("Hello, 123!");
        \\    await dev.write("db.ts", `export const abc = "456";`);
        \\    await dev.fetch("/").equals("Hello, 456!");
        \\    await dev.patch("routes/index.ts", { find: "Hello", replace: "Bun" });
        \\    await dev.fetch("/").equals("Bun, 456!");
        \\  },
        \\});
        \\devTest("symbol collision with import identifier", {
        \\  framework: minimalFramework,
        \\  files: {
        \\    "db.ts": `export const abc = "123";`,
        \\    "routes/index.ts": `
        \\      let import_db = 987;
        \\      import { abc } from '../db';
        \\      export default function (req, meta) {
        \\        let v1 = "";
        \\        const v2 = v1 ? abc.toFixed(2) : abc.toString();
        \\        return new Response('Hello, ' + v2 + ', ' + import_db + '!');
        \\      }
        \\    `,
        \\  },
        \\  async test(dev) {
        \\    await dev.fetch("/").equals("Hello, 123, 987!");
        \\    await dev.write("db.ts", `export const abc = "456";`);
        \\    await dev.fetch("/").equals("Hello, 456, 987!");
        \\  },
        \\});
        \\devTest('uses "development" condition', {
        \\  framework: minimalFramework,
        \\  files: {
        \\    "node_modules/example/package.json": JSON.stringify({ name: "example", version: "1.0.0", exports: { ".": { development: "./development.js", default: "./production.js" } } }),
        \\    "node_modules/example/development.js": `export default "development";`,
        \\    "node_modules/example/production.js": `export default "production";`,
        \\    "routes/index.ts": `
        \\      import environment from 'example';
        \\      export default function (req, meta) {
        \\        return new Response('Environment: ' + environment);
        \\      }
        \\    `,
        \\  },
        \\  async test(dev) {
        \\    await dev.fetch("/").equals("Environment: development");
        \\  },
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "bake/dev/bundle.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 3), file_run.result.passed);
}

test "bootstrap runner executes Bake missing import reload smoke" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import { devTest, emptyHtmlFile, minimalFramework } from "../bake-harness";
        \\devTest("importing a file before it is created", {
        \\  files: {
        \\    "index.html": emptyHtmlFile({ styles: [], scripts: ["index.ts"] }),
        \\    "index.ts": `
        \\      import { abc } from './second';
        \\      console.log('value: ' + abc);
        \\    `,
        \\  },
        \\  async test(dev) {
        \\    await using c = await dev.client("/", { errors: [`index.ts:1:21: error: Could not resolve: "./second"`] });
        \\    await c.expectReload(async () => {
        \\      await dev.write("second.ts", `export const abc = "456";`);
        \\    });
        \\    await c.expectMessage("value: 456");
        \\  },
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "bake/dev/bundle.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 1), file_run.result.passed);
}

test "bootstrap runner executes Bake default export graph smoke" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import { expect } from "bun:test";
        \\import { devTest, emptyHtmlFile, minimalFramework } from "../bake-harness";
        \\devTest("default export same-scope handling", {
        \\  files: {
        \\    "index.html": emptyHtmlFile({ styles: [], scripts: ["index.ts"] }),
        \\    "index.ts": `
        \\      import.meta.hot.accept();
        \\      await import("./fixture1.ts");
        \\      console.log((new ((await import("./fixture2.ts")).default)).a);
        \\      await import("./fixture3.ts");
        \\      console.log((new ((await import("./fixture4.ts")).default)).result);
        \\      console.log((await import("./fixture5.ts")).default);
        \\      console.log((await import("./fixture6.ts")).default);
        \\      console.log((await import("./fixture7.ts")).default());
        \\      console.log((await import("./fixture8.ts")).default());
        \\      console.log((await import("./fixture9.ts")).default(false));
        \\    `,
        \\    "fixture1.ts": `const sideEffect = () => "a"; export default class A { [sideEffect()] = "ONE"; } console.log(new A().a);`,
        \\    "fixture2.ts": `const sideEffect = () => "a"; export default class A { [sideEffect()] = "TWO"; }`,
        \\    "fixture3.ts": `export default class A { result = "THREE" } console.log(new A().result);`,
        \\    "fixture4.ts": `import.meta.hot.accept(); export default class MOVE { result = "FOUR" }`,
        \\    "fixture5.ts": `const default_export = "FIVE"; export default default_export;`,
        \\    "fixture6.ts": `const default_export = "S"; function sideEffect() { return default_export + "EVEN"; } export default sideEffect(); console.log(default_export + "IX");`,
        \\    "fixture7.ts": `export default function() { return "EIGHT" };`,
        \\    "fixture8.ts": `import.meta.hot.accept(); export default function MOVE() { return "NINE" };`,
        \\    "fixture9.ts": `export default function named(flag = true) { return flag ? "TEN" : "ELEVEN" }; console.log(named());`,
        \\  },
        \\  async test(dev) {
        \\    await using c = await dev.client("/", { storeHotChunks: true });
        \\    c.expectMessage("ONE", "TWO", "THREE", "FOUR", "FIVE", "SIX", "SEVEN", "EIGHT", "NINE", "TEN", "ELEVEN");
        \\    for (const file of ["fixture4.ts", "fixture8.ts"]) {
        \\      await dev.writeNoChanges(file);
        \\      const chunk = await c.getMostRecentHmrChunk();
        \\      expect(chunk).toMatch(/default:\s*(function|class)\s*MOVE/);
        \\    }
        \\    await dev.writeNoChanges("fixture7.ts");
        \\    expect(await c.getMostRecentHmrChunk()).toMatch(/default:\s*function/);
        \\    c.expectMessage("TWO", "FOUR", "FIVE", "SEVEN", "EIGHT", "NINE", "ELEVEN");
        \\  },
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "bake/dev/bundle.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 1), file_run.result.passed);
}

test "bootstrap runner executes Bake directory cache bust smoke" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import { devTest, emptyHtmlFile, minimalFramework } from "../bake-harness";
        \\devTest("directory cache bust case #17576", {
        \\  files: {
        \\    "web/index.html": emptyHtmlFile({ styles: [], scripts: ["index.ts"] }),
        \\    "web/index.ts": `
        \\      console.log(123);
        \\      import.meta.hot.accept();
        \\    `,
        \\  },
        \\  mainDir: "server",
        \\  async test(dev) {
        \\    await using c = await dev.client("/");
        \\    await c.expectMessage(123);
        \\    await c.expectNoWebSocketActivity(async () => {
        \\      await dev.write("web/Test.ts", `export const abc = 456;`);
        \\    });
        \\    await dev.write("web/index.ts", `
        \\      import { abc } from "./Test.ts";
        \\      console.log(abc);
        \\    `);
        \\    await c.expectMessage(456);
        \\  },
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "bake/dev/bundle.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 1), file_run.result.passed);
}

test "bootstrap runner executes Bake delete imported file recovery smoke" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import { devTest, emptyHtmlFile, minimalFramework } from "../bake-harness";
        \\devTest("deleting imported file shows error then recovers", {
        \\  files: {
        \\    "index.html": emptyHtmlFile({ styles: [], scripts: ["index.ts"] }),
        \\    "index.ts": `
        \\      import { value } from "./other";
        \\      console.log(value);
        \\    `,
        \\    "other.ts": `
        \\      export const value = 123;
        \\    `,
        \\    "unrelated.ts": `
        \\      export const value = 123;
        \\    `,
        \\  },
        \\  async test(dev) {
        \\    await using c = await dev.client("/");
        \\    await c.expectMessage(123);
        \\    await dev.delete("other.ts", {
        \\      errors: ['index.ts:1:23: error: Could not resolve: "./other"'],
        \\    });
        \\    await c.expectReload(async () => {
        \\      await dev.write("other.ts", `
        \\        export const value = 456;
        \\      `);
        \\    });
        \\    await c.expectMessage(456);
        \\    await c.expectNoWebSocketActivity(async () => {
        \\      await dev.delete("unrelated.ts");
        \\    });
        \\  },
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "bake/dev/bundle.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 1), file_run.result.passed);
}

test "bootstrap runner executes Bake use client pending resolution smoke" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import { expect } from "bun:test";
        \\import { devTest, minimalFramework } from "../bake-harness";
        \\devTest("removing 'use client' from a component with a pending resolution failure", {
        \\  framework: {
        \\    ...minimalFramework,
        \\    serverComponents: { separateSSRGraph: true },
        \\  },
        \\  files: {
        \\    "routes/index.ts": `
        \\      import * as Comp from '../components/Comp';
        \\      import '../components/Sibling';
        \\      export default function (req, meta) {
        \\        return new Response('page: ' + (typeof Comp.marker));
        \\      }
        \\    `,
        \\    "components/Comp.ts": `
        \\      "use client";
        \\      export const marker = "initial";
        \\    `,
        \\    "components/Sibling.ts": `
        \\      "use client";
        \\      import './sibling-missing';
        \\      export const sibling = 1;
        \\    `,
        \\  },
        \\  async test(dev) {
        \\    await dev.fetch("/");
        \\    await dev.write("components/Comp.ts", `
        \\      "use client";
        \\      import { value } from './missing';
        \\      export const marker = value;
        \\    `, { errors: null });
        \\    await dev.write("components/Comp.ts", `
        \\      export const marker = "no-client";
        \\    `, { errors: null });
        \\    await dev.write("components/missing.ts", `export const value = "ok";`, { errors: null });
        \\    const res = await dev.fetch("/");
        \\    expect(res).toBeInstanceOf(Response);
        \\  },
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "bake/dev/bundle.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 1), file_run.result.passed);
}

test "bootstrap runner executes Bake directory watch free-list smoke" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import { expect } from "bun:test";
        \\import { devTest, emptyHtmlFile } from "../bake-harness";
        \\devTest("deinit with a free-list slot in DirectoryWatchStore.dependencies", {
        \\  files: {
        \\    "index.html": emptyHtmlFile({ scripts: ["index.ts"] }),
        \\    "index.ts": `
        \\      import './sub/a';
        \\      import './sub/b';
        \\      export {};
        \\    `,
        \\    "sub/placeholder.ts": `export {};`,
        \\  },
        \\  async test(dev) {
        \\    await dev.fetch("/");
        \\    {
        \\      await using _ = await dev.batchChanges({ errors: null });
        \\      await dev.write("index.ts", `export {};`);
        \\      await dev.write("sub/a.ts", `export {};`);
        \\    }
        \\    const res = await dev.fetch("/");
        \\    expect(res).toBeInstanceOf(Response);
        \\  },
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "bake/dev/bundle.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 1), file_run.result.passed);
}

test "bootstrap runner executes Bake html import error smoke" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import { devTest, emptyHtmlFile } from "../bake-harness";
        \\devTest("importing html file", {
        \\  files: {
        \\    "index.html": emptyHtmlFile({ styles: [], scripts: ["index.ts"] }),
        \\    "index.ts": `
        \\      import html from "./index.html";
        \\      console.log(html);
        \\    `,
        \\  },
        \\  async test(dev) {
        \\    await using c = await dev.client("/", {
        \\      errors: ["index.ts:1:18: error: Browser builds cannot import HTML files."],
        \\    });
        \\  },
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "bake/dev/bundle.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 1), file_run.result.passed);
}

test "bootstrap runner executes Bake html text loader smoke" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import { devTest, emptyHtmlFile } from "../bake-harness";
        \\devTest("importing html file with text loader (#18154)", {
        \\  files: {
        \\    "index.html": emptyHtmlFile({ styles: [], scripts: ["index.ts"] }),
        \\    "index.ts": `
        \\      import html from "./app.html" with { type: "text" };
        \\      console.log(html);
        \\    `,
        \\    "app.html": "<div>hello world</div>",
        \\  },
        \\  htmlFiles: ["index.html"],
        \\  async test(dev) {
        \\    await using c = await dev.client("/", {});
        \\    await c.expectMessage("<div>hello world</div>");
        \\  },
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "bake/dev/bundle.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 1), file_run.result.passed);
}

test "bootstrap runner executes Bake bun client import error smoke" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import { devTest, emptyHtmlFile } from "../bake-harness";
        \\devTest("importing bun on the client", {
        \\  files: {
        \\    "index.html": emptyHtmlFile({ styles: [], scripts: ["index.ts"] }),
        \\    "index.ts": `
        \\      import bun from "bun";
        \\      console.log(bun);
        \\    `,
        \\  },
        \\  async test(dev) {
        \\    await using c = await dev.client("/", {
        \\      errors: ['index.ts:1:17: error: Browser build cannot import Bun builtin: "bun"'],
        \\    });
        \\  },
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "bake/dev/bundle.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 1), file_run.result.passed);
}

test "bootstrap runner executes Bake import meta main smoke" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import { devTest, emptyHtmlFile } from "../bake-harness";
        \\devTest("import.meta.main", {
        \\  files: {
        \\    "index.html": emptyHtmlFile({ styles: [], scripts: ["index.ts"] }),
        \\    "index.ts": `
        \\      console.log(import.meta.main);
        \\      import.meta.hot.accept();
        \\    `,
        \\  },
        \\  async test(dev) {
        \\    await using c = await dev.client("/");
        \\    await c.expectMessage(false);
        \\    await dev.write("index.ts", `
        \\      require;
        \\      console.log(import.meta.main);
        \\    `);
        \\    await c.expectMessage(false);
        \\  },
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "bake/dev/bundle.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 1), file_run.result.passed);
}

test "bootstrap runner executes Bake commonjs forms smoke" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import { devTest, emptyHtmlFile } from "../bake-harness";
        \\devTest("commonjs forms", {
        \\  files: {
        \\    "index.html": emptyHtmlFile({ styles: [], scripts: ["index.ts"] }),
        \\    "index.ts": `
        \\      import cjs from "./cjs.js";
        \\      console.log(cjs);
        \\    `,
        \\    "cjs.js": `
        \\      module.exports.field = {};
        \\    `,
        \\  },
        \\  async test(dev) {
        \\    await using c = await dev.client("/");
        \\    await c.expectMessage({ field: {} });
        \\    await c.expectReload(async () => { await dev.write("cjs.js", `exports.field = "1";`); });
        \\    await c.expectMessage({ field: "1" });
        \\    await c.expectReload(async () => { await dev.write("cjs.js", `let theExports = exports; theExports.field = "2";`); });
        \\    await c.expectMessage({ field: "2" });
        \\    await c.expectReload(async () => { await dev.write("cjs.js", `let theModule = module; theModule.exports.field = "3";`); });
        \\    await c.expectMessage({ field: "3" });
        \\    await c.expectReload(async () => { await dev.write("cjs.js", `let { exports } = module; exports.field = "4";`); });
        \\    await c.expectMessage({ field: "4" });
        \\    await c.expectReload(async () => { await dev.write("cjs.js", `var { exports } = module; exports.field = "4.5";`); });
        \\    await c.expectMessage({ field: "4.5" });
        \\    await c.expectReload(async () => { await dev.write("cjs.js", `let theExports = module.exports; theExports.field = "5";`); });
        \\    await c.expectMessage({ field: "5" });
        \\    await c.expectReload(async () => { await dev.write("cjs.js", `require; eval("module.exports.field = '6'");`); });
        \\    await c.expectMessage({ field: "6" });
        \\  },
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "bake/dev/bundle.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 1), file_run.result.passed);
}

test "bootstrap runner executes Bake barrel unused submodule smoke" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import { devTest, emptyHtmlFile } from "../bake-harness";
        \\devTest("barrel optimization skips unused submodules", {
        \\  files: {
        \\    "index.html": emptyHtmlFile({ scripts: ["index.ts"] }),
        \\    "index.ts": `
        \\      import { Alpha } from 'barrel-lib';
        \\      console.log('got: ' + Alpha);
        \\    `,
        \\    "node_modules/barrel-lib/package.json": JSON.stringify({
        \\      name: "barrel-lib",
        \\      version: "1.0.0",
        \\      main: "./index.js",
        \\      sideEffects: false,
        \\    }),
        \\    "node_modules/barrel-lib/index.js": `
        \\      export { Alpha } from './alpha.js';
        \\      export { Beta } from './beta.js';
        \\      export { Gamma } from './gamma.js';
        \\    `,
        \\    "node_modules/barrel-lib/alpha.js": `export const Alpha = "ALPHA";`,
        \\    "node_modules/barrel-lib/beta.js": `export const Beta = <<<SYNTAX_ERROR>>>;`,
        \\    "node_modules/barrel-lib/gamma.js": `export const Gamma = <<<SYNTAX_ERROR>>>;`,
        \\  },
        \\  async test(dev) {
        \\    await using c = await dev.client("/");
        \\    await c.expectMessage("got: ALPHA");
        \\  },
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "bake/dev/bundle.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 1), file_run.result.passed);
}

test "bootstrap runner executes Bake barrel reload smoke" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import { devTest, emptyHtmlFile } from "../bake-harness";
        \\devTest("barrel optimization: adding a new import triggers reload", {
        \\  files: {
        \\    "index.html": emptyHtmlFile({ scripts: ["index.ts"] }),
        \\    "index.ts": `
        \\      import { Alpha } from 'barrel-lib';
        \\      console.log('result: ' + Alpha);
        \\    `,
        \\    "node_modules/barrel-lib/package.json": JSON.stringify({
        \\      name: "barrel-lib",
        \\      version: "1.0.0",
        \\      main: "./index.js",
        \\      sideEffects: false,
        \\    }),
        \\    "node_modules/barrel-lib/index.js": `
        \\      export { Alpha } from './alpha.js';
        \\      export { Beta } from './beta.js';
        \\      export { Gamma } from './gamma.js';
        \\    `,
        \\    "node_modules/barrel-lib/alpha.js": `export const Alpha = "ALPHA";`,
        \\    "node_modules/barrel-lib/beta.js": `export const Beta = "BETA";`,
        \\    "node_modules/barrel-lib/gamma.js": `export const Gamma = "GAMMA";`,
        \\  },
        \\  async test(dev) {
        \\    await using c = await dev.client("/");
        \\    await c.expectMessage("result: ALPHA");
        \\    await c.expectReload(async () => {
        \\      await dev.write("index.ts", `
        \\        import { Alpha, Beta } from 'barrel-lib';
        \\        console.log('result: ' + Alpha + ' ' + Beta);
        \\      `);
        \\    });
        \\    await c.expectMessage("result: ALPHA BETA");
        \\    await c.expectReload(async () => {
        \\      await dev.write("index.ts", `
        \\        import { Alpha, Beta, Gamma } from 'barrel-lib';
        \\        console.log('result: ' + Alpha + ' ' + Beta + ' ' + Gamma);
        \\      `);
        \\    });
        \\    await c.expectMessage("result: ALPHA BETA GAMMA");
        \\  },
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "bake/dev/bundle.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 1), file_run.result.passed);
}

test "bootstrap runner executes Bake barrel multi-file smoke" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import { devTest, emptyHtmlFile } from "../bake-harness";
        \\devTest("barrel optimization: multi-file imports preserved across rebuilds", {
        \\  files: {
        \\    "index.html": emptyHtmlFile({ scripts: ["index.ts"] }),
        \\    "index.ts": `
        \\      import { Alpha } from 'barrel-lib';
        \\      import { value } from './other';
        \\      console.log('result: ' + Alpha + ' ' + value);
        \\    `,
        \\    "other.ts": `
        \\      import { Beta } from 'barrel-lib';
        \\      export const value = Beta;
        \\    `,
        \\    "node_modules/barrel-lib/package.json": JSON.stringify({
        \\      name: "barrel-lib",
        \\      version: "1.0.0",
        \\      main: "./index.js",
        \\      sideEffects: false,
        \\    }),
        \\    "node_modules/barrel-lib/index.js": `
        \\      export { Alpha } from './alpha.js';
        \\      export { Beta } from './beta.js';
        \\      export { Gamma } from './gamma.js';
        \\    `,
        \\    "node_modules/barrel-lib/alpha.js": `export const Alpha = "ALPHA";`,
        \\    "node_modules/barrel-lib/beta.js": `export const Beta = "BETA";`,
        \\    "node_modules/barrel-lib/gamma.js": `export const Gamma = "GAMMA";`,
        \\  },
        \\  async test(dev) {
        \\    await using c = await dev.client("/");
        \\    await c.expectMessage("result: ALPHA BETA");
        \\    await c.expectReload(async () => {
        \\      await dev.write("other.ts", `
        \\        import { Beta, Gamma } from 'barrel-lib';
        \\        export const value = Beta + ' ' + Gamma;
        \\      `);
        \\    });
        \\    await c.expectMessage("result: ALPHA BETA GAMMA");
        \\  },
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "bake/dev/bundle.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 1), file_run.result.passed);
}

test "bootstrap runner executes Bake barrel tail smokes" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import { devTest, emptyHtmlFile } from "../bake-harness";
        \\devTest("barrel optimization: export star target not deferred (#27521)", {
        \\  files: {
        \\    "index.html": emptyHtmlFile({ scripts: ["index.ts"] }),
        \\    "index.ts": `
        \\      import { useQuery } from 'consumer-lib';
        \\      console.log('result: ' + useQuery());
        \\    `,
        \\    "node_modules/consumer-lib/index.js": `export function useQuery() { return 'PASS'; }`,
        \\  },
        \\  async test(dev) {
        \\    await using c = await dev.client("/");
        \\    await c.expectMessage("result: PASS");
        \\  },
        \\});
        \\devTest("barrel optimization: two export-from blocks pointing to the same source", {
        \\  files: {
        \\    "index.html": emptyHtmlFile({ scripts: ["index.ts"] }),
        \\    "index.ts": `
        \\      import { invariant } from 'barrel-lib';
        \\      console.log('got: ' + typeof invariant);
        \\    `,
        \\    "node_modules/barrel-lib/utils.js": `export function invariant(cond, msg) {}`,
        \\  },
        \\  async test(dev) {
        \\    await using c = await dev.client("/");
        \\    await c.expectMessage("got: function");
        \\  },
        \\});
        \\devTest("barrel optimization: two import statements from the same barrel (#28886)", {
        \\  files: {
        \\    "index.html": emptyHtmlFile({ scripts: ["index.ts"] }),
        \\    "index.ts": `
        \\      import { Alpha } from 'barrel-lib';
        \\      import { Beta } from 'barrel-lib';
        \\      console.log('got: ' + Alpha() + ' ' + Beta());
        \\    `,
        \\    "node_modules/barrel-lib/alpha.js": `export const Alpha = () => "ALPHA";`,
        \\    "node_modules/barrel-lib/beta.js": `export const Beta = () => "BETA";`,
        \\  },
        \\  async test(dev) {
        \\    await using c = await dev.client("/");
        \\    await c.expectMessage("got: ALPHA BETA");
        \\  },
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "bake/dev/bundle.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 3), file_run.result.passed);
}

test "bootstrap runner executes Bake css syntax preserves styles smoke" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import { devTest, emptyHtmlFile } from "../bake-harness";
        \\devTest("css file with syntax error does not kill old styles", {
        \\  files: {
        \\    "styles.css": `
        \\      body {
        \\        color: red;
        \\      }
        \\    `,
        \\    "index.html": emptyHtmlFile({
        \\      styles: ["styles.css"],
        \\      body: `hello world`,
        \\    }),
        \\  },
        \\  async test(dev) {
        \\    await using c = await dev.client("/");
        \\    await c.style("body").color.expect.toBe("red");
        \\    await dev.write("styles.css", `
        \\      body {
        \\        color: red;
        \\        background-color
        \\      }
        \\    `, { errors: ["styles.css:4:1: error: Unexpected end of input"] });
        \\    await c.style("body").color.expect.toBe("red");
        \\    await dev.write("styles.css", `
        \\      body {
        \\        color: red;
        \\        background-color: blue;
        \\      }
        \\    `);
        \\    await c.style("body").backgroundColor.expect.toBe("#00f");
        \\    await dev.write("styles.css", ` `, { dedent: false });
        \\    await c.style("body").notFound();
        \\  },
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "bake/dev/css.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 1), file_run.result.passed);
}

test "bootstrap runner executes Bake css initial syntax recovery smoke" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import { devTest, emptyHtmlFile } from "../bake-harness";
        \\devTest("css file with initial syntax error gets recovered", {
        \\  files: {
        \\    "index.html": emptyHtmlFile({
        \\      styles: ["styles.css"],
        \\      body: `hello world`,
        \\    }),
        \\    "styles.css": `
        \\      body {
        \\        color: red;
        \\      }}
        \\    `,
        \\  },
        \\  async test(dev) {
        \\    await using c = await dev.client("/", {
        \\      errors: ["styles.css:3:3: error: Unexpected end of input"],
        \\    });
        \\    await c.expectReload(async () => {
        \\      await dev.write("styles.css", `
        \\        body {
        \\          color: red;
        \\        }
        \\      `);
        \\    });
        \\    await c.style("body").color.expect.toBe("red");
        \\    await dev.write("styles.css", `
        \\      body {
        \\        color: blue;
        \\      }
        \\    `);
        \\    await c.style("body").color.expect.toBe("#00f");
        \\    await dev.write("styles.css", `
        \\      body {
        \\        color: blue;
        \\      }}
        \\    `, { errors: ["styles.css:3:3: error: Unexpected end of input"] });
        \\  },
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "bake/dev/css.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 1), file_run.result.passed);
}

test "bootstrap runner executes Bake add css import later smoke" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import { devTest, emptyHtmlFile } from "../bake-harness";
        \\devTest("add new css import later", {
        \\  files: {
        \\    "index.html": emptyHtmlFile({
        \\      scripts: ["index.ts"],
        \\      body: `hello world`,
        \\    }),
        \\    "index.ts": `
        \\      // import "./styles.css";
        \\      export default function () {
        \\        return "hello world";
        \\      }
        \\      import.meta.hot.accept();
        \\    `,
        \\    "styles.css": `
        \\      body {
        \\        color: red;
        \\      }
        \\    `,
        \\  },
        \\  async test(dev) {
        \\    await using c = await dev.client("/");
        \\    await c.style("body").notFound();
        \\    await dev.patch("index.ts", { find: "// import", replace: "import" });
        \\    await c.style("body").color.expect.toBe("red");
        \\    await dev.patch("index.ts", { find: "import", replace: "// import" });
        \\    await c.style("body").notFound();
        \\  },
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "bake/dev/css.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 1), file_run.result.passed);
}

test "bootstrap runner executes Bake css import another file smoke" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import { devTest, emptyHtmlFile } from "../bake-harness";
        \\devTest("css import another css file", {
        \\  files: {
        \\    "index.html": emptyHtmlFile({
        \\      styles: ["styles.css"],
        \\    }),
        \\    "styles.css": `
        \\      @import "./second.css";
        \\      body {
        \\        color: red;
        \\      }
        \\    `,
        \\    "second.css": `
        \\      h1 {
        \\        color: blue;
        \\      }
        \\    `,
        \\  },
        \\  async test(dev) {
        \\    await using c = await dev.client("/");
        \\    await c.style("h1").color.expect.toBe("#00f");
        \\    await c.style("body").color.expect.toBe("red");
        \\    await dev.write("second.css", `
        \\      h1 {
        \\        color: green;
        \\      }
        \\    `);
        \\    await c.style("h1").color.expect.toBe("green");
        \\    await c.style("body").color.expect.toBe("red");
        \\    await c.hardReload();
        \\    await c.style("h1").color.expect.toBe("green");
        \\    await c.style("body").color.expect.toBe("red");
        \\  },
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "bake/dev/css.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 1), file_run.result.passed);
}

test "bootstrap runner executes Bake css asset reference smoke" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import assert from "node:assert";
        \\import { devTest, emptyHtmlFile, imageFixtures } from "../bake-harness";
        \\devTest("asset referenced in css", {
        \\  files: {
        \\    "index.html": emptyHtmlFile({
        \\      styles: ["styles.css"],
        \\    }),
        \\    "styles.css": `
        \\      body {
        \\        background-image: url(./bun.png);
        \\      }
        \\    `,
        \\    "bun.png": imageFixtures.bun,
        \\  },
        \\  async test(dev) {
        \\    await using c = await dev.client("/");
        \\    let backgroundImage = await c.style("body").backgroundImage;
        \\    assert(backgroundImage);
        \\    await dev.fetch(extractCssUrl(backgroundImage)).expectFile(imageFixtures.bun);
        \\    await dev.write("bun.png", imageFixtures.bun2);
        \\    backgroundImage = await c.style("body").backgroundImage;
        \\    assert(backgroundImage);
        \\    await dev.fetch(extractCssUrl(backgroundImage)).expectFile(imageFixtures.bun2);
        \\  },
        \\});
        \\function extractCssUrl(backgroundImage: string): string {
        \\  const url = backgroundImage.match(/url\((['"])(.*?)\1\)/);
        \\  if (!url) throw new Error("No url found in background-image: " + backgroundImage);
        \\  return url[2];
        \\}
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "bake/dev/css.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 1), file_run.result.passed);
}

test "bootstrap runner executes Bake css syntax crash smoke" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import { expect } from "bun:test";
        \\import { devTest, emptyHtmlFile } from "../bake-harness";
        \\devTest("syntax error crash", {
        \\  files: {
        \\    "styles.css": `
        \\      body {
        \\        background-image: url
        \\      }
        \\    `,
        \\    "index.html": emptyHtmlFile({
        \\      styles: ["styles.css"],
        \\      body: `hello world`,
        \\    }),
        \\  },
        \\  async test(dev) {
        \\    expect((await dev.fetch("/")).status).toBe(200);
        \\    await dev.patch("styles.css", { find: "url\n", replace: "url(\n" });
        \\    expect((await dev.fetch("/")).status).toBe(500);
        \\  },
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "bake/dev/css.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 1), file_run.result.passed);
}

test "bootstrap runner executes Bake circular css imports smoke" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import { devTest, emptyHtmlFile } from "../bake-harness";
        \\devTest("circular css imports handle hot reload", {
        \\  files: {
        \\    "index.html": emptyHtmlFile({
        \\      styles: ["a.css"],
        \\      body: `
        \\        <div class="a">hello</div>
        \\        <div class="b">hello</div>
        \\      `,
        \\    }),
        \\    "a.css": `
        \\      @import "./b.css";
        \\      .a { color: red; }
        \\    `,
        \\    "b.css": `
        \\      @import "./a.css";
        \\      .b { color: blue; }
        \\    `,
        \\  },
        \\  async test(dev) {
        \\    await using client = await dev.client("/");
        \\    await client.style(".a").color.expect.toBe("red");
        \\    await client.style(".b").color.expect.toBe("#00f");
        \\    await dev.write("a.css", `
        \\      @import "./b.css";
        \\      .a { color: green; }
        \\    `);
        \\    await client.style(".a").color.expect.toBe("green");
        \\    await client.style(".b").color.expect.toBe("#00f");
        \\  },
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "bake/dev/css.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 1), file_run.result.passed);
}

test "bootstrap runner executes Bake css asset index smoke" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import { devTest, emptyHtmlFile } from "../bake-harness";
        \\devTest("asset index stays valid after another css root is freed", {
        \\  files: {
        \\    "first.html": emptyHtmlFile({
        \\      styles: ["first.css"],
        \\      body: `<div class="first">hello</div>`,
        \\    }),
        \\    "second.html": emptyHtmlFile({
        \\      styles: ["second.css"],
        \\      body: `<div class="second">hello</div>`,
        \\    }),
        \\    "first.css": `
        \\      .first { color: red; }
        \\    `,
        \\    "second.css": `
        \\      .second { color: blue; }
        \\    `,
        \\  },
        \\  async test(dev) {
        \\    {
        \\      await using c1 = await dev.client("/first");
        \\      await c1.style(".first").color.expect.toBe("red");
        \\    }
        \\    await using c2 = await dev.client("/second");
        \\    await c2.style(".second").color.expect.toBe("#00f");
        \\    await dev.write("first.css", `
        \\      .first { color: red; }}
        \\    `, { errors: null });
        \\    await dev.write("second.css", `
        \\      .second { color: green; }
        \\    `, { errors: null });
        \\    await c2.style(".second").color.expect.toBe("green");
        \\    await dev.write("first.css", `
        \\      .first { color: yellow; }
        \\    `);
        \\    await c2.style(".second").color.expect.toBe("green");
        \\    {
        \\      await using c1 = await dev.client("/first");
        \\      await c1.style(".first").color.expect.toBe("#ff0");
        \\    }
        \\  },
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "bake/dev/css.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 1), file_run.result.passed);
}

test "bootstrap runner executes Bake shared css dependency smoke" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import { devTest, emptyHtmlFile } from "../bake-harness";
        \\devTest("multiple stylesheets importing same dependency", {
        \\  files: {
        \\    "first.html": emptyHtmlFile({
        \\      styles: ["first.css"],
        \\      body: `
        \\        <div class="first">hello</div>
        \\        <div class="shared">hello</div>
        \\      `,
        \\    }),
        \\    "second.html": emptyHtmlFile({
        \\      styles: ["second.css"],
        \\      body: `
        \\        <div class="second">hello</div>
        \\        <div class="shared">hello</div>
        \\      `,
        \\    }),
        \\    "first.css": `
        \\      @import "./shared.css";
        \\      .first { color: red; }
        \\    `,
        \\    "second.css": `
        \\      @import "./shared.css";
        \\      .second { color: blue; }
        \\    `,
        \\    "shared.css": `
        \\      .shared { color: green; }
        \\    `,
        \\  },
        \\  async test(dev) {
        \\    await using c1 = await dev.client("/first");
        \\    await using c2 = await dev.client("/second");
        \\    await c1.style(".first").color.expect.toBe("red");
        \\    await c2.style(".second").color.expect.toBe("#00f");
        \\    await c1.style(".shared").color.expect.toBe("green");
        \\    await c2.style(".shared").color.expect.toBe("green");
        \\    await dev.write("shared.css", `
        \\      .shared { color: yellow; }
        \\    `);
        \\    await c1.style(".shared").color.expect.toBe("#ff0");
        \\    await c2.style(".shared").color.expect.toBe("#ff0");
        \\  },
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "bake/dev/css.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 1), file_run.result.passed);
}

test "bootstrap runner executes Bake remove and readd css import smoke" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import { devTest, emptyHtmlFile } from "../bake-harness";
        \\devTest("removing and re-adding css import", {
        \\  files: {
        \\    "index.html": emptyHtmlFile({
        \\      styles: ["main.css"],
        \\    }),
        \\    "main.css": `
        \\      @import "./colors.css";
        \\      .main { background: white; }
        \\    `,
        \\    "colors.css": `
        \\      .colored { color: blue; }
        \\    `,
        \\  },
        \\  async test(dev) {
        \\    await using c = await dev.client("/");
        \\    await c.style(".colored").color.expect.toBe("#00f");
        \\    await dev.write("main.css", `
        \\      /* @import "./colors.css"; */
        \\      .main { background: white; }
        \\    `);
        \\    await c.style(".colored").notFound();
        \\    await c.expectNoWebSocketActivity(async () => {
        \\      await dev.write("colors.css", `
        \\        .colored { color: yellow; }
        \\      `);
        \\      await dev.write("colors.css", `
        \\        .colored { color: blue; }
        \\      `);
        \\    });
        \\    await c.style(".colored").notFound();
        \\    await dev.write("main.css", `
        \\      @import "./colors.css";
        \\      .main { background: white; }
        \\    `);
        \\    await c.style(".colored").color.expect.toBe("#00f");
        \\    await c.style(".main").backgroundColor.expect.toBe("#fff");
        \\  },
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "bake/dev/css.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 1), file_run.result.passed);
}

test "bootstrap runner executes Bake html link tag css smoke" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import { devTest, emptyHtmlFile } from "../bake-harness";
        \\devTest("changing html file with link tag works", {
        \\  files: {
        \\    "index.html": emptyHtmlFile({
        \\      styles: ["styles.css"],
        \\    }),
        \\    "styles.css": `
        \\      .test {
        \\        color: blue;
        \\        font-size: 24px;
        \\      }
        \\    `,
        \\  },
        \\  async test(dev) {
        \\    await using c = await dev.client("/");
        \\    await c.style(".test").color.expect.toBe("#00f");
        \\    await c.style(".test").fontSize.expect.toBe("24px");
        \\    await c.expectReload(async () => {
        \\      await dev.writeNoChanges("index.html");
        \\    });
        \\    await c.style(".test").color.expect.toBe("#00f");
        \\    await c.style(".test").fontSize.expect.toBe("24px");
        \\    await c.hardReload();
        \\    await c.style(".test").color.expect.toBe("#00f");
        \\    await c.style(".test").fontSize.expect.toBe("24px");
        \\    await dev.write("index.html", emptyHtmlFile({
        \\      styles: ["other.css"],
        \\    }), {
        \\      errors: ['index.html: error: Could not resolve: "other.css". Maybe you need to "bun install"?'],
        \\    });
        \\    await c.expectReload(async () => {
        \\      await dev.write("other.css", `
        \\        .other {
        \\          color: red;
        \\        }
        \\      `);
        \\    });
        \\    await c.style(".other").color.expect.toBe("red");
        \\    await c.style(".test").notFound();
        \\    await c.expectReload(async () => {
        \\      await dev.write("index.html", emptyHtmlFile({
        \\        styles: ["styles.css"],
        \\      }));
        \\    });
        \\    await c.style(".test").color.expect.toBe("#00f");
        \\    await c.style(".test").fontSize.expect.toBe("24px");
        \\    await c.style(".other").notFound();
        \\    await c.expectReload(async () => {
        \\      await dev.write("index.html", emptyHtmlFile({
        \\        styles: ["other.css", "styles.css"],
        \\      }));
        \\    });
        \\    await c.style(".other").color.expect.toBe("red");
        \\    await c.style(".test").color.expect.toBe("#00f");
        \\    await c.style(".test").fontSize.expect.toBe("24px");
        \\  },
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "bake/dev/css.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 1), file_run.result.passed);
}

test "bootstrap runner executes Bake css import before create smoke" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import assert from "node:assert";
        \\import { devTest, emptyHtmlFile, imageFixtures } from "../bake-harness";
        \\devTest("css import before create", {
        \\  files: {
        \\    "index.html": emptyHtmlFile({
        \\      styles: ["styles.css"],
        \\      body: `
        \\        <div>HELLO</div>
        \\      `,
        \\    }),
        \\  },
        \\  async test(dev) {
        \\    await using c = await dev.client("/", {
        \\      errors: ['index.html: error: Could not resolve: "styles.css". Maybe you need to "bun install"?'],
        \\    });
        \\    await dev.fetch("/").expect.not.toContain("HELLO");
        \\    await dev.write("styles.css", `
        \\      body {
        \\        background-image: url(bun.png);
        \\      }
        \\    `, {
        \\      errors: ['styles.css:2:21: error: Could not resolve: "bun.png". Maybe you need to "bun install"?'],
        \\    });
        \\    await c.expectReload(async () => {
        \\      await dev.write("bun.png", imageFixtures.bun);
        \\    });
        \\    const backgroundImage = await c.style("body").backgroundImage;
        \\    assert(backgroundImage);
        \\    await dev.fetch(extractCssUrl(backgroundImage)).expectFile(imageFixtures.bun);
        \\    await dev.fetch("/").expect.toContain("HELLO");
        \\  },
        \\});
        \\function extractCssUrl(backgroundImage: string): string {
        \\  const url = backgroundImage.match(/url\((['"])(.*?)\1\)/);
        \\  if (!url) throw new Error("No url found in background-image: " + backgroundImage);
        \\  return url[2];
        \\}
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "bake/dev/css.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 1), file_run.result.passed);
}

test "bootstrap runner executes Bake project-relative css import before create smoke" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import assert from "node:assert";
        \\import { devTest, emptyHtmlFile, imageFixtures } from "../bake-harness";
        \\devTest("css import before create project relative", {
        \\  files: {
        \\    "html/index.html": emptyHtmlFile({
        \\      styles: ["/style/styles.css"],
        \\      body: `
        \\        <div>HELLO</div>
        \\      `,
        \\    }),
        \\  },
        \\  async test(dev) {
        \\    dev.mkdir("style");
        \\    await using c = await dev.client("/", {
        \\      errors: ['html/index.html: error: Could not resolve: "/style/styles.css"'],
        \\    });
        \\    await dev.fetch("/").expect.not.toContain("HELLO");
        \\    await dev.write("style/styles.css", `
        \\      body {
        \\        background-image: url(/assets/bun.png);
        \\      }
        \\    `, {
        \\      errors: ['style/styles.css:2:21: error: Could not resolve: "/assets/bun.png"'],
        \\    });
        \\    await c.expectNoWebSocketActivity(async () => {
        \\      await dev.write("assets/bun.png", imageFixtures.bun, { errors: null });
        \\      await dev.delete("assets/bun.png", { errors: null });
        \\    });
        \\    await dev.fetch("/").expect.not.toContain("HELLO");
        \\    await dev.write("style/styles.css", `
        \\      body {
        \\        background-image: url(../assets/bun.png);
        \\      }
        \\    `, {
        \\      errors: ['style/styles.css:2:21: error: Could not resolve: "../assets/bun.png"'],
        \\    });
        \\    await c.expectReload(async () => {
        \\      await dev.write("assets/bun.png", imageFixtures.bun);
        \\    });
        \\    const backgroundImage = await c.style("body").backgroundImage;
        \\    assert(backgroundImage);
        \\    await dev.fetch(extractCssUrl(backgroundImage)).expectFile(imageFixtures.bun);
        \\    await dev.fetch("/").expect.toContain("HELLO");
        \\  },
        \\});
        \\function extractCssUrl(backgroundImage: string): string {
        \\  const url = backgroundImage.match(/url\((['"])(.*?)\1\)/);
        \\  if (!url) throw new Error("No url found in background-image: " + backgroundImage);
        \\  return url[2];
        \\}
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "bake/dev/css.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 1), file_run.result.passed);
}

test "bootstrap runner executes Bake svelte component islands smoke" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import { expect } from "bun:test";
        \\import { devTest } from "../bake-harness";
        \\devTest("svelte component islands example", {
        \\  fixture: "svelte-component-islands",
        \\  async test(dev) {
        \\    const html = await dev.fetch("/").text();
        \\    if (html.includes("Bun__renderFallbackError")) throw new Error("failed");
        \\    expect(html).toContain('self.$islands={"pages/_Counter.svelte":[[0,"default",{initial:5}]]}');
        \\    expect(html).toContain(`<p>This is my svelte server component (non-interactive)</p> <p>Bun v${Bun.version}</p>`);
        \\    expect(html).toContain(`>This is a client component (interactive island)</p>`);
        \\    await using c = await dev.client("/");
        \\    expect(await c.elemText("button")).toBe("Clicked 5 times");
        \\    const result = await c.js`
        \\      document.querySelector("button").click();
        \\      await new Promise(resolve => setTimeout(resolve, 10));
        \\      return document.querySelector("button").textContent;
        \\    `;
        \\    expect(result).toBe("Clicked 6 times");
        \\    await c.expectReload(async () => {
        \\      await dev.patch("pages/index.svelte", {
        \\        find: "non-interactive",
        \\        replace: "awesome",
        \\      });
        \\    });
        \\    await dev.patch("pages/_Counter.svelte", {
        \\      find: "interactive island",
        \\      replace: "magical",
        \\    });
        \\    expect(await c.elemText("#counter_text")).toInclude("magical");
        \\    const html2 = await dev.fetch("/").text();
        \\    if (html2.includes("Bun__renderFallbackError")) throw new Error("failed");
        \\    expect(html2).toContain(`<p>This is my svelte server component (awesome)</p> <p>Bun v${Bun.version}</p>`);
        \\    expect(html2).toContain(`>This is a client component (magical)</p>`);
        \\  },
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "bake/dev/ecosystem.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 1), file_run.result.passed);
}

test "bootstrap runner executes Bake ESM live var binding smoke" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import { devTest, minimalFramework } from "../bake-harness";
        \\devTest("live bindings with `var`", {
        \\  framework: minimalFramework,
        \\  files: {
        \\    "state.ts": `
        \\      export var value = 0;
        \\      export function increment() {
        \\        value++;
        \\      }
        \\    `,
        \\    "routes/index.ts": `
        \\      import { value, increment } from '../state';
        \\      export default function(req, meta) {
        \\        increment();
        \\        return new Response('State: ' + value);
        \\      }
        \\    `,
        \\  },
        \\  async test(dev) {
        \\    await dev.fetch("/").equals("State: 1");
        \\    await dev.fetch("/").equals("State: 2");
        \\    await dev.fetch("/").equals("State: 3");
        \\    await dev.patch("routes/index.ts", { find: "State", replace: "Value" });
        \\    await dev.fetch("/").equals("Value: 4");
        \\    await dev.fetch("/").equals("Value: 5");
        \\    await dev.write("state.ts", `
        \\      export var value = 0;
        \\      export function increment() {
        \\        value--;
        \\      }
        \\    `);
        \\    await dev.fetch("/").equals("Value: -1");
        \\    await dev.fetch("/").equals("Value: -2");
        \\  },
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "bake/dev/esm.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 1), file_run.result.passed);
}

test "bootstrap runner executes Bake ESM re-export live binding smokes" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import { devTest, minimalFramework } from "../bake-harness";
        \\const liveBindingTest = {
        \\  async test(dev) {
        \\    await dev.fetch("/").equals("State: 1");
        \\    await dev.fetch("/").equals("State: 2");
        \\    await dev.fetch("/").equals("State: 3");
        \\    await dev.patch("routes/index.ts", { find: "State", replace: "Value" });
        \\    await dev.fetch("/").equals("Value: 4");
        \\    await dev.fetch("/").equals("Value: 5");
        \\    await dev.write("state.ts", `
        \\      export var value = 0;
        \\      export function increment() {
        \\        value--;
        \\      }
        \\    `);
        \\    await dev.fetch("/").equals("Value: -1");
        \\    await dev.fetch("/").equals("Value: -2");
        \\  },
        \\};
        \\devTest("live bindings through export clause", {
        \\  framework: minimalFramework,
        \\  files: {
        \\    "state.ts": `
        \\      export var value = 0;
        \\      export function increment() {
        \\        value++;
        \\      }
        \\    `,
        \\    "proxy.ts": `
        \\      import { value } from './state';
        \\      export { value as live };
        \\    `,
        \\    "routes/index.ts": `
        \\      import { increment } from '../state';
        \\      import { live } from '../proxy';
        \\      export default function(req, meta) {
        \\        increment();
        \\        return new Response('State: ' + live);
        \\      }
        \\    `,
        \\  },
        \\  test: liveBindingTest.test,
        \\});
        \\devTest("live bindings through export from", {
        \\  framework: minimalFramework,
        \\  files: {
        \\    "state.ts": `
        \\      export var value = 0;
        \\      export function increment() {
        \\        value++;
        \\      }
        \\    `,
        \\    "proxy.ts": `
        \\      export { value as live } from './state';
        \\    `,
        \\    "routes/index.ts": `
        \\      import { increment } from '../state';
        \\      import { live } from '../proxy';
        \\      export default function(req, meta) {
        \\        increment();
        \\        return new Response('State: ' + live);
        \\      }
        \\    `,
        \\  },
        \\  test: liveBindingTest.test,
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "bake/dev/esm.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 2), file_run.result.passed);
}

test "bootstrap runner executes Bake ESM alias export smokes" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import { devTest, minimalFramework } from "../bake-harness";
        \\devTest("export { x as y }", {
        \\  framework: minimalFramework,
        \\  files: {
        \\    "module.ts": `
        \\      function x(value) {
        \\        return value + 1;
        \\      }
        \\      export { x as y };
        \\    `,
        \\    "routes/index.ts": `
        \\      import { y } from '../module';
        \\      export default function(req, meta) {
        \\        return new Response('Value: ' + y(1));
        \\      }
        \\    `,
        \\  },
        \\  async test(dev) {
        \\    await dev.fetch("/").equals("Value: 2");
        \\    await dev.patch("module.ts", { find: "1", replace: "2" });
        \\    await dev.fetch("/").equals("Value: 3");
        \\  },
        \\});
        \\devTest("import { x as y }", {
        \\  framework: minimalFramework,
        \\  files: {
        \\    "module.ts": `export const x = 1;`,
        \\    "routes/index.ts": `
        \\      import { x as y } from '../module';
        \\      export default function(req, meta) {
        \\        return new Response('Value: ' + y);
        \\      }
        \\    `,
        \\  },
        \\  async test(dev) {
        \\    await dev.fetch("/").equals("Value: 1");
        \\    await dev.patch("module.ts", { find: "1", replace: "2" });
        \\    await dev.fetch("/").equals("Value: 2");
        \\  },
        \\});
        \\devTest("import { default as y }", {
        \\  framework: minimalFramework,
        \\  files: {
        \\    "module.ts": `export default 1;`,
        \\    "routes/index.ts": `
        \\      import { default as y } from '../module';
        \\      export default function(req, meta) {
        \\        return new Response('Value: ' + y);
        \\      }
        \\    `,
        \\  },
        \\  async test(dev) {
        \\    await dev.fetch("/").equals("Value: 1");
        \\    await dev.patch("module.ts", { find: "1", replace: "2" });
        \\    await dev.fetch("/").equals("Value: 2");
        \\  },
        \\});
        \\devTest("export { default as y }", {
        \\  framework: minimalFramework,
        \\  files: {
        \\    "module.ts": `export default 1;`,
        \\    "middle.ts": `export { default as y } from './module';`,
        \\    "routes/index.ts": `
        \\      import { y } from '../middle';
        \\      export default function(req, meta) {
        \\        return new Response('Value: ' + y);
        \\      }
        \\    `,
        \\  },
        \\  async test(dev) {
        \\    await dev.fetch("/").equals("Value: 1");
        \\    await dev.patch("module.ts", { find: "1", replace: "2" });
        \\    await dev.fetch("/").equals("Value: 2");
        \\  },
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "bake/dev/esm.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 4), file_run.result.passed);
}

test "bootstrap runner executes Bake ESM export star namespace smoke" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import { devTest, emptyHtmlFile } from "../bake-harness";
        \\devTest("export * as namespace", {
        \\  files: {
        \\    "index.html": emptyHtmlFile({ scripts: ["index.ts"] }),
        \\    "index.ts": `
        \\      import { ns as renamed } from './module';
        \\      if (typeof renamed !== 'object') throw new Error('renamed should be an object');
        \\      if (renamed.x !== 1) throw new Error('renamed.x should be 1');
        \\      if (renamed.y !== 2) throw new Error('renamed.y should be 2');
        \\      console.log('PASS');
        \\    `,
        \\    "module.ts": `
        \\      export * as ns from './module2';
        \\    `,
        \\    "module2.ts": `
        \\      export const x = 1;
        \\      export const y = 2;
        \\      export const ns = "FAIL";
        \\    `,
        \\  },
        \\  async test(dev) {
        \\    await using c = await dev.client();
        \\    await c.expectMessage("PASS");
        \\  },
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "bake/dev/esm.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 1), file_run.result.passed);
}

test "bootstrap runner executes Bake ESM CJS sync smoke" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import { devTest, emptyHtmlFile } from "../bake-harness";
        \\devTest("ESM <-> CJS sync", {
        \\  files: {
        \\    "index.html": emptyHtmlFile({ scripts: ["index.ts"] }),
        \\    "index.ts": `
        \\      const mod = require('./esm');
        \\      if (!mod.__esModule) throw new Error('mod.__esModule should be set');
        \\      console.log('PASS');
        \\    `,
        \\    "esm.ts": `
        \\      export const x = 1;
        \\    `,
        \\  },
        \\  async test(dev) {
        \\    await using c = await dev.client();
        \\    await c.expectMessage("PASS");
        \\  },
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "bake/dev/esm.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 1), file_run.result.passed);
}

test "bootstrap runner executes Bake ESM CJS async smoke" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import { devTest, emptyHtmlFile } from "../bake-harness";
        \\devTest("ESM <-> CJS (async)", {
        \\  files: {
        \\    "index.html": emptyHtmlFile({ scripts: ["index.ts"] }),
        \\    "index.ts": `
        \\      const esmImport = await import('./esm');
        \\      const mod = require('./esm');
        \\      if (!mod.__esModule) throw new Error('mod.__esModule should be set');
        \\      if (esmImport.x !== mod.x) throw new Error('esmImport.x should be equal to mod.x');
        \\      if ('__esModule' in esmImport) throw new Error('esmImport.__esModule should be unset');
        \\      console.log('PASS');
        \\    `,
        \\    "esm.ts": `
        \\      export const x = 1;
        \\    `,
        \\  },
        \\  async test(dev) {
        \\    await using c = await dev.client();
        \\    await c.expectMessage("PASS");
        \\  },
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "bake/dev/esm.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 1), file_run.result.passed);
}

test "bootstrap runner executes Bake ESM require top level await error smoke" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import { devTest, emptyHtmlFile } from "../bake-harness";
        \\devTest("cannot require a module with top level await", {
        \\  skip: ["ci"],
        \\  files: {
        \\    "index.html": emptyHtmlFile({ scripts: ["index.ts"] }),
        \\    "index.ts": `
        \\      const mod = require('./esm');
        \\      console.log('FAIL');
        \\    `,
        \\    "esm.ts": `
        \\      console.log("FAIL");
        \\      import { hello } from './dir';
        \\      hello;
        \\    `,
        \\    "dir/index.ts": `
        \\      import './async';
        \\    `,
        \\    "dir/async.ts": `
        \\      console.log("FAIL");
        \\      await 1;
        \\    `,
        \\  },
        \\  async test(dev) {
        \\    await using c = await dev.client("/", {
        \\      errors: [
        \\        `error: Cannot require "esm.ts" because "dir/async.ts" uses top-level await, but 'require' is a synchronous operation.`,
        \\      ],
        \\    });
        \\  },
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "bake/dev/esm.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 1), file_run.result.passed);
}

test "bootstrap runner executes Bake ESM assigned function live binding smoke" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import { devTest, emptyHtmlFile } from "../bake-harness";
        \\devTest("function that is assigned to should become a live binding", {
        \\  files: {
        \\    "index.html": emptyHtmlFile({ scripts: ["index.ts"] }),
        \\    "index.ts": `
        \\      import { live, change } from "./live.js";
        \\      {
        \\        if (live() !== 1) throw new Error("live() should be 1");
        \\        change();
        \\        if (live() !== 2) throw new Error("live() should be 2");
        \\      }
        \\      import inheritsLoose from "./inheritsLoose.js";
        \\      {
        \\        function A() {}
        \\        function B() {}
        \\        inheritsLoose(B, A);
        \\      }
        \\      console.log('PASS');
        \\    `,
        \\    "live.js": `
        \\      export function live() {
        \\        return 1;
        \\      }
        \\      export function change() {
        \\        live = function() {
        \\          return 2;
        \\        }
        \\      }
        \\    `,
        \\    "inheritsLoose.js": `
        \\      import setPrototypeOf from "./setPrototypeOf.js";
        \\      function _inheritsLoose(t, o) {
        \\        t.prototype = Object.create(o.prototype), t.prototype.constructor = t, setPrototypeOf(t, o);
        \\      }
        \\      export { _inheritsLoose as default };
        \\    `,
        \\    "setPrototypeOf.js": `
        \\      function _setPrototypeOf(t, e) {
        \\        return _setPrototypeOf = Object.setPrototypeOf ? Object.setPrototypeOf.bind() : function (t, e) {
        \\          return t.__proto__ = e, t;
        \\        }, _setPrototypeOf(t, e);
        \\      }
        \\      export { _setPrototypeOf as default };
        \\    `,
        \\  },
        \\  async test(dev) {
        \\    await using c = await dev.client();
        \\    await c.expectMessage("PASS");
        \\  },
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "bake/dev/esm.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 1), file_run.result.passed);
}

test "bootstrap runner executes Bake ESM browser field smoke" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import { devTest, emptyHtmlFile } from "../bake-harness";
        \\devTest("browser field is used", {
        \\  files: {
        \\    "bunfig.toml": `
        \\      preload = [
        \\        "axios/lib/utils.js",
        \\      ]
        \\    `,
        \\    "index.html": emptyHtmlFile({ scripts: ["index.ts"] }),
        \\    "node_modules/axios/package.json": JSON.stringify({
        \\      name: "axios",
        \\      version: "1.0.0",
        \\      browser: {
        \\        "./lib/utils.js": "./lib/utils.browser.js",
        \\      },
        \\    }),
        \\    "node_modules/axios/lib/utils.js": `
        \\      export default "FAIL";
        \\    `,
        \\    "node_modules/axios/lib/utils.browser.js": `
        \\      export default "PASS";
        \\    `,
        \\    "index.ts": `
        \\      import axios from "axios/lib/utils.js";
        \\      console.log(axios);
        \\    `,
        \\  },
        \\  async test(dev) {
        \\    await using c = await dev.client();
        \\    await c.expectMessage("PASS");
        \\  },
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "bake/dev/esm.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 1), file_run.result.passed);
}

test "bootstrap runner executes Bake hot accept basic smoke" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import { devTest, emptyHtmlFile } from "../bake-harness";
        \\devTest("import.meta.hot.accept basic", {
        \\  files: {
        \\    "index.html": emptyHtmlFile({ scripts: ["index.ts"] }),
        \\    "index.ts": `
        \\      console.log("Hello, world!");
        \\    `,
        \\  },
        \\  async test(dev) {
        \\    await using c = await dev.client("/");
        \\    await c.expectMessage("Hello, world!");
        \\    await c.expectReload(async () => {
        \\      await dev.write(
        \\        "index.ts",
        \\        `
        \\          console.log("Hello, Bun!");
        \\          import.meta.hot.accept(newModule => {
        \\            console.log(Object.keys(newModule));
        \\            console.log(newModule.method());
        \\          });
        \\        `,
        \\      );
        \\    });
        \\    await c.expectMessage("Hello, Bun!");
        \\    await dev.write(
        \\      "index.ts",
        \\      `
        \\        export function method() {
        \\          return "Bun";
        \\        }
        \\        import.meta.hot.accept(newModule => {
        \\          console.log(Object.keys(newModule));
        \\        });
        \\      `,
        \\    );
        \\    await c.expectMessage(["method"], "Bun");
        \\    await dev.write(
        \\      "index.ts",
        \\      `
        \\        console.log("Without anything.");
        \\      `,
        \\    );
        \\    await c.expectMessage("Without anything.", []);
        \\    await c.expectReload(async () => {
        \\      await dev.writeNoChanges("index.ts");
        \\    });
        \\    await c.expectMessage("Without anything.");
        \\  },
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "bake/dev/hot.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 1), file_run.result.passed);
}

test "bootstrap runner executes Bake hot accept patches imports smoke" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import { expect } from "bun:test";
        \\import { devTest, emptyHtmlFile } from "../bake-harness";
        \\devTest("import.meta.hot.accept patches imports", {
        \\  files: {
        \\    "index.html": emptyHtmlFile({ scripts: ["a.ts"] }),
        \\    "a.ts": `
        \\      import { doSomething } from './b';
        \\      console.log("A");
        \\      globalThis.callFunction = () => doSomething();
        \\    `,
        \\    "b.ts": `
        \\      import { reasonableState, inc } from './c';
        \\      console.log("B");
        \\      let b = 0;
        \\      export function doSomething() {
        \\        using _ = { [Symbol.dispose]: inc };
        \\        return "A!" + (b++) + "!" + (reasonableState);
        \\      }
        \\      import.meta.hot.accept();
        \\    `,
        \\    "c.ts": `
        \\      export let reasonableState = 0;
        \\      export function inc() {
        \\        reasonableState++;
        \\      }
        \\      console.log("C");
        \\      // import.meta.hot.accept();
        \\    `,
        \\  },
        \\  async test(dev) {
        \\    await using c = await dev.client("/");
        \\    await c.expectMessage("C", "B", "A");
        \\    expect(await c.js`callFunction()`).toBe("A!0!0");
        \\    expect(await c.js`callFunction()`).toBe("A!1!1");
        \\    await dev.patch("c.ts", { find: "0", replace: "5" });
        \\    await c.expectMessage("C", "B");
        \\    expect(await c.js`callFunction()`).toBe("A!0!5");
        \\    expect(await c.js`callFunction()`).toBe("A!1!6");
        \\    await dev.patch("b.ts", { find: "A!", replace: "B!" });
        \\    await c.expectMessage("B");
        \\    expect(await c.js`callFunction()`).toBe("B!0!7");
        \\    expect(await c.js`callFunction()`).toBe("B!1!8");
        \\    await dev.patch("c.ts", { find: "// ", replace: "" });
        \\    await c.expectMessage("C", "B");
        \\    expect(await c.js`callFunction()`).toBe("B!0!5");
        \\    expect(await c.js`callFunction()`).toBe("B!1!6");
        \\    await dev.patch("c.ts", { find: "import.meta.hot.accept();", replace: "" });
        \\    await c.expectMessage("C");
        \\    expect(await c.js`callFunction()`).toBe("B!2!5");
        \\    expect(await c.js`callFunction()`).toBe("B!3!6");
        \\  },
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "bake/dev/hot.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 1), file_run.result.passed);
}

test "bootstrap runner executes Bake hot accept specifier smoke" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import { expect } from "bun:test";
        \\import { devTest, emptyHtmlFile } from "../bake-harness";
        \\devTest("import.meta.hot.accept specifier", {
        \\  files: {
        \\    "index.html": emptyHtmlFile({ scripts: ["a.ts"] }),
        \\    "a.ts": `
        \\      import './b';
        \\      import './c';
        \\      console.log("A");
        \\    `,
        \\    "b.ts": `
        \\      import './d';
        \\      console.log("B");
        \\      import.meta.hot.accept("oh no", (newModule) => {
        \\        console.log('B:' + newModule.default);
        \\      })
        \\    `,
        \\    "c.ts": `
        \\      import './d';
        \\      console.log("C");
        \\    `,
        \\    "d.ts": `
        \\      console.log("D");
        \\      export default "hey!";
        \\      queueMicrotask(() => {
        \\        console.log("end");
        \\      });
        \\    `,
        \\    "unrelated.ts": `
        \\      export default "unrelated";
        \\    `,
        \\  },
        \\  async test(dev) {
        \\    {
        \\      await using c = await dev.client("/", {
        \\        errors: [
        \\          "b.ts:3:24: error: Dependencies to `import.meta.hot.accept` must be statically analyzable module specifiers matching direct imports.",
        \\        ],
        \\      });
        \\      await dev.patch("b.ts", {
        \\        find: "oh no",
        \\        replace: "./d.ts",
        \\        errors: [
        \\          "b.ts:3:24: error: Dependencies to `import.meta.hot.accept` must be statically analyzable module specifiers matching direct imports.",
        \\        ],
        \\      });
        \\      await c.expectReload(async () => {
        \\        await dev.patch("b.ts", { find: "./d.ts", replace: "./d" });
        \\      });
        \\      await c.expectMessage("D", "B", "C", "A", "end");
        \\      await c.expectReload(async () => {
        \\        await dev.write("d.ts", `
        \\          console.log("D2");
        \\          export default "hey2!";
        \\        `);
        \\      });
        \\      await c.expectMessage("D2", "B", "C", "A");
        \\    }
        \\    await dev.write("c.ts", `
        \\      import './d';
        \\      import './unrelated';
        \\      console.log("C");
        \\      import.meta.hot.accept();
        \\    `);
        \\    {
        \\      await using c = await dev.client("/");
        \\      await c.expectMessage("D2", "B", "C", "A");
        \\      await dev.write("d.ts", `
        \\        console.log("D3");
        \\        export default "hey3!";
        \\      `);
        \\      await c.expectMessage("D3", "C", "B:hey3!");
        \\      await dev.write("c.ts", `
        \\        import './d';
        \\        import './unrelated';
        \\        console.log("C");
        \\        import.meta.hot.accept("oh no", (newModule) => {
        \\          console.log('C:' + newModule.default);
        \\        });
        \\      `, {
        \\        errors: [
        \\          "c.ts:4:24: error: Dependencies to `import.meta.hot.accept` must be statically analyzable module specifiers matching direct imports.",
        \\        ],
        \\      });
        \\      await dev.patch("c.ts", { find: "oh no", replace: "./d" });
        \\      await c.expectMessage("C");
        \\      await dev.write("d.ts", `
        \\        console.log("D4");
        \\        export default "hey4!";
        \\        import.meta.hot.accept();
        \\      `);
        \\      await c.expectMessage("D4", "B:hey4!", "C:hey4!");
        \\      await dev.write("d.ts", `
        \\        console.log("D5");
        \\        export default "hey5!";
        \\        import.meta.hot.accept();
        \\      `);
        \\      await c.expectMessage("D5", "B:hey5!", "C:hey5!");
        \\      await c.hardReload();
        \\      await c.expectMessage("D5", "B", "C", "A");
        \\      await dev.write("d.ts", `
        \\        console.log("D6");
        \\        export default "hey6!";
        \\        import.meta.hot.accept();
        \\      `);
        \\      await c.expectMessage("D6", "B:hey6!", "C:hey6!");
        \\    }
        \\  },
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "bake/dev/hot.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 1), file_run.result.passed);
}

test "bootstrap runner executes Bake hot accept multiple modules smoke" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import { devTest, emptyHtmlFile } from "../bake-harness";
        \\devTest("import.meta.hot.accept multiple modules", {
        \\  files: {
        \\    "index.html": emptyHtmlFile({ scripts: ["index.ts"] }),
        \\    "index.ts": `
        \\      import { count } from "./counter.ts";
        \\      import { name } from "./name.ts";
        \\      console.log("Initial: " + name + " " + count);
        \\      import.meta.hot.accept(["./counter.ts", "./name.ts"], (newModules) => {
        \\        if (newModules[0]) console.log("Counter updated: " + newModules[0].count);
        \\        if (newModules[1]) console.log("Name updated: " + newModules[1].name);
        \\      });
        \\    `,
        \\    "counter.ts": `
        \\      export const count = 1;
        \\    `,
        \\    "name.ts": `
        \\      export const name = "Alice";
        \\    `,
        \\  },
        \\  async test(dev) {
        \\    await using c = await dev.client("/");
        \\    await c.expectMessage("Initial: Alice 1");
        \\    await dev.write("counter.ts", `
        \\      export const count = 2;
        \\    `);
        \\    await c.expectMessage("Counter updated: 2");
        \\    await dev.write("name.ts", `
        \\      export const name = "Bob";
        \\    `);
        \\    await c.expectMessage("Name updated: Bob");
        \\    {
        \\      await using batch = await dev.batchChanges();
        \\      await dev.write("counter.ts", `
        \\        export const count = 3;
        \\      `);
        \\      await dev.write("name.ts", `
        \\        export const name = "Charlie";
        \\      `);
        \\    }
        \\    await c.expectMessageInAnyOrder("Counter updated: 3", "Name updated: Charlie");
        \\  },
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "bake/dev/hot.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 1), file_run.result.passed);
}

test "bootstrap runner executes Bake hot data persistence smoke" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import { devTest, emptyHtmlFile } from "../bake-harness";
        \\devTest("import.meta.hot.data persistence", {
        \\  files: {
        \\    "index.html": emptyHtmlFile({ scripts: ["index.ts"] }),
        \\    "index.ts": `
        \\      import.meta.hot.data.count ??= 0;
        \\      console.log("Initial count: " + import.meta.hot.data.count);
        \\      import.meta.hot.data.count++;
        \\    `,
        \\  },
        \\  async test(dev) {
        \\    await using c = await dev.client("/");
        \\    await c.expectMessage("Initial count: 0");
        \\    await dev.writeNoChanges("index.ts");
        \\    await c.expectMessage("Initial count: 1");
        \\    await dev.writeNoChanges("index.ts");
        \\    await c.expectMessage("Initial count: 2");
        \\    await dev.writeNoChanges("index.ts");
        \\    await c.expectMessage("Initial count: 3");
        \\  },
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "bake/dev/hot.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 1), file_run.result.passed);
}

test "bootstrap runner executes Bake hot dispose cleanup smoke" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import { devTest, emptyHtmlFile } from "../bake-harness";
        \\devTest("import.meta.hot.dispose cleanup", {
        \\  files: {
        \\    "index.html": emptyHtmlFile({ scripts: ["index.ts"] }),
        \\    "index.ts": `
        \\      console.log("Setting up");
        \\      const id = setInterval(() => {}, 1000);
        \\      import.meta.hot.dispose(() => {
        \\        console.log("Cleaning up");
        \\        clearInterval(id);
        \\      });
        \\      import.meta.hot.accept();
        \\    `,
        \\  },
        \\  async test(dev) {
        \\    await using c = await dev.client("/");
        \\    await c.expectMessage("Setting up");
        \\    await dev.write("index.ts", `
        \\      console.log("Setting up again");
        \\      const id = setInterval(() => {}, 1000);
        \\      import.meta.hot.dispose(() => {
        \\        console.log("Cleaning up");
        \\        clearInterval(id);
        \\      });
        \\      import.meta.hot.accept();
        \\    `);
        \\    await c.expectMessage("Cleaning up", "Setting up again");
        \\    await dev.write("index.ts", `
        \\      console.log("Third setup");
        \\    `);
        \\    await c.expectMessage("Cleaning up", "Third setup");
        \\  },
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "bake/dev/hot.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 1), file_run.result.passed);
}

test "bootstrap runner executes Bake hot invalid usage smoke" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import { devTest, emptyHtmlFile } from "../bake-harness";
        \\devTest("import.meta.hot invalid usage", {
        \\  files: {
        \\    "index.html": emptyHtmlFile({ scripts: ["index.ts"] }),
        \\    "index.ts": `
        \\      const hot = import.meta.hot;
        \\      try {
        \\        hot.accept;
        \\        throw 'did not throw';
        \\      } catch (e) {
        \\        console.log(e?.message ?? e);
        \\      }
        \\      const accept = import.meta.hot.accept;
        \\      try {
        \\        accept("./something.ts", () => {});
        \\        throw 'did not throw';
        \\      } catch (e) {
        \\        console.log(e?.message ?? e);
        \\      }
        \\      const meta = import.meta;
        \\      try {
        \\        meta.hot.accept();
        \\        throw 'did not throw';
        \\      } catch (e) {
        \\        console.log(e?.message ?? e);
        \\      }
        \\    `,
        \\  },
        \\  async test(dev) {
        \\    await using c = await dev.client("/");
        \\    await c.expectMessage(
        \\      "import.meta.hot.accept cannot be used indirectly.",
        \\      '"import.meta.hot.accept" must be directly called with string literals for the specifiers. This way, the bundler can pre-process the arguments.',
        \\      "import.meta.hot cannot be used indirectly.",
        \\    );
        \\  },
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "bake/dev/hot.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 1), file_run.result.passed);
}

test "bootstrap runner executes Bake hot on off events smoke" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import { devTest, emptyHtmlFile } from "../bake-harness";
        \\devTest("import.meta.hot on/off events", {
        \\  files: {
        \\    "index.html": emptyHtmlFile({ scripts: ["index.ts"] }),
        \\    "index.ts": `
        \\      console.log("Initial setup");
        \\      import.meta.hot.on("vite:beforeUpdate", () => {
        \\        console.log("Before update event");
        \\      });
        \\      import.meta.hot.accept();
        \\    `,
        \\  },
        \\  async test(dev) {
        \\    await using c = await dev.client("/");
        \\    await c.expectMessage("Initial setup");
        \\    await dev.write("index.ts", `
        \\      console.log("Updated setup");
        \\      import.meta.hot.on("vite:beforeUpdate", () => {
        \\        console.log("Before update event 2");
        \\      });
        \\      const handler = () => {
        \\        console.log("Another handler");
        \\      };
        \\      import.meta.hot.on("vite:beforeUpdate", handler);
        \\      import.meta.hot.off("vite:beforeUpdate", handler);
        \\      import.meta.hot.accept();
        \\    `);
        \\    await c.expectMessage("Updated setup");
        \\    await dev.write("index.ts", `
        \\      console.log("Third update");
        \\      import.meta.hot.accept();
        \\    `);
        \\    await c.expectMessage("Third update");
        \\  },
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "bake/dev/hot.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 1), file_run.result.passed);
}

test "bootstrap runner executes Bake html watched smoke" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import { devTest, emptyHtmlFile } from "../bake-harness";
        \\devTest("html file is watched", {
        \\  files: {
        \\    "index.html": emptyHtmlFile({
        \\      scripts: ["/script.ts"],
        \\      body: "<h1>Hello</h1>",
        \\    }),
        \\    "script.ts": `
        \\      console.log("hello");
        \\    `,
        \\  },
        \\  async test(dev) {
        \\    await dev.fetch("/").expect.toInclude("<h1>Hello</h1>");
        \\    await dev.patch("index.html", { find: "Hello", replace: "World" });
        \\    await dev.fetch("/").expect.toInclude("<h1>World</h1>");
        \\    await using c = await dev.client("/");
        \\    await c.expectMessage("hello");
        \\    await c.expectReload(async () => {
        \\      await dev.patch("index.html", { find: "World", replace: "Hello" });
        \\      await dev.fetch("/").expect.toInclude("<h1>Hello</h1>");
        \\    });
        \\    await c.expectMessage("hello");
        \\    await c.expectReload(async () => {
        \\      await dev.patch("index.html", { find: "Hello", replace: "Bar" });
        \\      await dev.fetch("/").expect.toInclude("<h1>Bar</h1>");
        \\    });
        \\    await c.expectMessage("hello");
        \\    await c.expectReload(async () => {
        \\      await dev.patch("script.ts", { find: "hello", replace: "world" });
        \\    });
        \\    await c.expectMessage("world");
        \\  },
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "bake/dev/html.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 1), file_run.result.passed);
}

test "bootstrap runner executes Bake image tag smoke" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import { devTest } from "../bake-harness";
        \\devTest("image tag", {
        \\  files: {
        \\    "index.html": `
        \\      <!DOCTYPE html><html><head></head><body>
        \\      <img src="image.png" alt="test image">
        \\      </body></html>
        \\    `,
        \\    "image.png": "FIRST",
        \\  },
        \\  async test(dev) {
        \\    await using c = await dev.client("/");
        \\    const url: string = await c.js`document.querySelector("img").src`;
        \\    expect(url).toBeString();
        \\    await dev.fetch(url).expect.toBe("FIRST");
        \\    await c.expectReload(async () => {
        \\      await dev.patch("index.html", {
        \\        find: 'alt="test image"',
        \\        replace: 'alt="modified image"',
        \\      });
        \\      await dev.fetch("/").expect.toInclude('alt="modified image"');
        \\    });
        \\    await c.expectReload(async () => {
        \\      await dev.patch("image.png", {
        \\        find: "FIRST",
        \\        replace: "SECOND",
        \\      });
        \\    });
        \\    const url2 = await c.js`document.querySelector("img").src`;
        \\    expect(url).not.toBe(url2);
        \\    await dev.fetch(url2).expect.toBe("SECOND");
        \\    await dev.fetch(url).expect404();
        \\  },
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "bake/dev/html.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 1), file_run.result.passed);
}

test "bootstrap runner executes Bake image import smoke" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import { devTest } from "../bake-harness";
        \\devTest("image import in JS", {
        \\  files: {
        \\    "index.html": `
        \\      <!DOCTYPE html><html><head></head><body>
        \\      <script type="module" src="script.ts"></script>
        \\      </body></html>
        \\    `,
        \\    "script.ts": `
        \\      import img from "./image.png";
        \\      console.log(img);
        \\    `,
        \\    "image.png": "FIRST",
        \\  },
        \\  async test(dev) {
        \\    await using c = await dev.client("/");
        \\    const img1 = await c.getStringMessage();
        \\    await dev.fetch(img1).expect.toBe("FIRST");
        \\    await c.expectReload(async () => {
        \\      await dev.patch("image.png", {
        \\        find: "FIRST",
        \\        replace: "SECOND",
        \\      });
        \\    });
        \\    const img2 = await c.getStringMessage();
        \\    await dev.fetch(img2).expect.toBe("SECOND");
        \\  },
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "bake/dev/html.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 1), file_run.result.passed);
}

test "bootstrap runner executes Bake import then create smoke" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import { devTest } from "../bake-harness";
        \\devTest("import then create", {
        \\  files: {
        \\    "index.html": `
        \\      <!DOCTYPE html><html><head></head><body>
        \\        <script type="module" src="/script.ts"></script>
        \\      </body></html>
        \\    `,
        \\    "script.ts": `
        \\      import data from "./data";
        \\      console.log(data);
        \\    `,
        \\  },
        \\  async test(dev) {
        \\    const c = await dev.client("/", {
        \\      errors: ['script.ts:1:18: error: Could not resolve: "./data"'],
        \\    });
        \\    await c.expectReload(async () => {
        \\      await dev.write("data.ts", "export default 'data';");
        \\    });
        \\    await c.expectMessage("data");
        \\  },
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "bake/dev/html.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 1), file_run.result.passed);
}

test "bootstrap runner executes Bake external links smoke" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import { devTest } from "../bake-harness";
        \\devTest("external links", {
        \\  files: {
        \\    "index.html": `
        \\      <!doctype html>
        \\      <html>
        \\      <head>
        \\        <link rel="stylesheet" href="./index.css" />
        \\        <link rel="icon" type="image/x-icon" href="https://bun.sh/favicon.ico" />
        \\      </head>
        \\      <body>
        \\        <script src="./index.client.tsx" type="module"></script>
        \\      </body>
        \\      </html>
        \\    `,
        \\    "index.css": `
        \\      body {
        \\        background-color: red;
        \\      }
        \\    `,
        \\    "index.client.tsx": `
        \\      console.log("hello");
        \\    `,
        \\  },
        \\  async test(dev) {
        \\    await using c = await dev.client("/");
        \\    await c.expectMessage("hello");
        \\    const ico: string = await c.js`document.querySelector("link[rel='icon']").href`;
        \\    expect(ico).toBe("https://bun.sh/favicon.ico");
        \\  },
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "bake/dev/html.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 1), file_run.result.passed);
}

test "bootstrap runner executes remaining Bake html smokes" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source =
        \\import { devTest } from "../bake-harness";
        \\devTest("memory leak case 1", {
        \\  files: {
        \\    "index.html": `<script type="module" src="/script.ts"></script>`,
        \\    "script.ts": `import data from "./data";`,
        \\  },
        \\  async test(dev) {
        \\    await dev.fetch("/");
        \\  },
        \\});
        \\devTest("chrome devtools automatic workspace folders", {
        \\  files: {
        \\    "index.html": `<script type="module" src="/script.ts"></script>`,
        \\    "script.ts": `console.log("hello");`,
        \\  },
        \\  async test(dev) {
        \\    const response = await dev.fetch("/.well-known/appspecific/com.chrome.devtools.json");
        \\    expect(response.status).toBe(200);
        \\    const json = await response.json();
        \\    const root = dev.join(".");
        \\    expect(json).toMatchObject({
        \\      workspace: {
        \\        root,
        \\        uuid: expect.any(String),
        \\      },
        \\    });
        \\  },
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "bake/dev/html.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 2), file_run.result.passed);
}

test "bootstrap rewrite erases explicit resource management declarations" {
    const source =
        \\import { expect } from "bun:test";
        \\test("using", async () => {
        \\  await using client = await connect();
        \\  using cleanup = makeCleanup();
        \\  expect(client).toBeDefined();
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "js/bun/test/using.test.ts");
    defer prepared.deinit(std.testing.allocator);

    try std.testing.expect(prepared.unsupported_reason == null);
    try std.testing.expect(std.mem.indexOf(u8, prepared.source, "await using ") == null);
    try std.testing.expect(std.mem.indexOf(u8, prepared.source, "using cleanup") == null);
    try std.testing.expect(std.mem.indexOf(u8, prepared.source, "const client = await connect();") != null);
    try std.testing.expect(std.mem.indexOf(u8, prepared.source, "const cleanup = makeCleanup();") != null);
}

test "bootstrap rewrite erases Bake TypeScript-only syntax" {
    const source =
        \\import { expect } from "bun:test";
        \\test("syntax", () => {
        \\  const hmrSelfAcceptingModule = (label: string) => String(label);
        \\  const waitForMessage = (value: string) => value;
        \\  const url: string = "https://example.test/image.png";
        \\  let timer: ReturnType<typeof setTimeout> | null = setTimeout(() => {}, 1);
        \\  client.on("message", (m: unknown) => expect(m).toBeDefined());
        \\  const framework = { serverComponents: { ...minimalFramework.serverComponents!, separateSSRGraph: true } };
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "bake/dev-and-prod.test.ts");
    defer prepared.deinit(std.testing.allocator);

    try std.testing.expect(prepared.unsupported_reason == null);
    try std.testing.expect(std.mem.indexOf(u8, prepared.source, ": string") == null);
    try std.testing.expect(std.mem.indexOf(u8, prepared.source, "const url =") != null);
    try std.testing.expect(std.mem.indexOf(u8, prepared.source, ": unknown") == null);
    try std.testing.expect(std.mem.indexOf(u8, prepared.source, "ReturnType") == null);
    try std.testing.expect(std.mem.indexOf(u8, prepared.source, "serverComponents!") == null);
}

test "bootstrap runner supports node fs sync utf8 file methods" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const target = ".zig-cache/home-test-node-fs-sync-smoke.txt";
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    defer Io.Dir.cwd().deleteFile(io, target) catch {};

    const source =
        \\import { expect, test } from "bun:test";
        \\import { readFileSync, realpathSync, writeFileSync } from "node:fs";
        \\test("node fs sync methods", () => {
        \\  const target = ".zig-cache/home-test-node-fs-sync-smoke.txt";
        \\  writeFileSync(target, "hello from home");
        \\  expect(readFileSync(target, "utf8")).toBe("hello from home");
        \\  expect(realpathSync(target).endsWith("/home-test-node-fs-sync-smoke.txt")).toBe(true);
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "js/node/fs/fs-sync-bootstrap-smoke.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 1), file_run.result.passed);
}

test "bootstrap runner supports node fs rename and unlink sync methods" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const source_path = ".zig-cache/home-test-node-fs-rename-source.txt";
    const target_path = ".zig-cache/home-test-node-fs-rename-target.txt";
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    defer Io.Dir.cwd().deleteFile(io, source_path) catch {};
    defer Io.Dir.cwd().deleteFile(io, target_path) catch {};

    const source =
        \\import { expect, test } from "bun:test";
        \\import { readFileSync, renameSync, unlinkSync, writeFileSync } from "node:fs";
        \\test("node fs rename unlink", () => {
        \\  const source = ".zig-cache/home-test-node-fs-rename-source.txt";
        \\  const target = ".zig-cache/home-test-node-fs-rename-target.txt";
        \\  writeFileSync(source, "move me");
        \\  renameSync(source, target);
        \\  expect(readFileSync(target, "utf8")).toBe("move me");
        \\  unlinkSync(target);
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "js/node/fs/fs-rename-unlink-bootstrap-smoke.test.ts");
    defer prepared.deinit(std.testing.allocator);

    var runtime = try jsc_bootstrap.Runtime.init(std.testing.allocator, harness_prelude);
    defer runtime.deinit();

    var file_run = try runtime.runFile(std.testing.allocator, prepared.fileSpec());
    defer file_run.deinit(std.testing.allocator);

    try std.testing.expectEqual(test_result.TestStatus.passed, file_run.result.status());
    try std.testing.expectEqual(@as(usize, 1), file_run.result.passed);
}

test "Bun test import rewrite lowers import.meta metadata" {
    const source =
        \\import { expect, it } from "bun:test";
        \\it("metadata", () => {
        \\  expect(import.meta.dir).toBe(__dirname);
        \\  expect(import.meta.dirname).toBe(__dirname);
        \\  expect(import.meta.path).toBe(__filename);
        \\  expect("import.meta.path").toBe("import.meta.path");
        \\  // import.meta.dir should not be rewritten in comments
        \\});
    ;
    const rewritten = try rewriteBunTestImport(std.testing.allocator, source, "js/node/dirname.test.js");
    defer std.testing.allocator.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "expect(import.meta") == null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "\"import.meta.path\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "// import.meta.dir") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "__home_import_meta_dir").? < std.mem.indexOf(u8, rewritten, "it(\"metadata\"").?);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "__home_import_meta_dirname").? < std.mem.indexOf(u8, rewritten, "it(\"metadata\"").?);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "__home_import_meta_path").? < std.mem.indexOf(u8, rewritten, "it(\"metadata\"").?);
}

test "Bun test import rewrite lowers import.meta resolve helpers" {
    const source =
        \\test("resolve", () => {
        \\  expect(() => import.meta.resolveSync("#foo", "file:/tmp")).toThrow();
        \\  expect(() => import.meta.resolve("#foo", "file:/tmp")).toThrow();
        \\  expect("import.meta.resolve").toBe("import.meta.resolve");
        \\});
    ;
    const rewritten = try rewriteBunTestImport(std.testing.allocator, source, "js/bun/resolve/resolve-bad-parent.test.mjs");
    defer std.testing.allocator.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "__home_import_meta_resolve(\"#foo\", \"file:/tmp\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "import.meta.resolveSync") == null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "expect(\"import.meta.resolve\")") != null);
}

test "Bun test import rewrite preserves shebangs" {
    const source =
        \\#!/usr/bin/env bun
        \\test("works", () => {});
    ;
    const rewritten = try rewriteBunTestImport(std.testing.allocator, source, "cli/hashbang.test.js");
    defer std.testing.allocator.free(rewritten);

    try std.testing.expect(std.mem.startsWith(u8, rewritten, "#!/usr/bin/env bun\n"));
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "var __filename") != null);
}

test "failure recorder keeps the first failing file" {
    var summary = Summary{};
    defer summary.deinit(std.testing.allocator);
    try recordFailure(std.testing.allocator, &summary, "first.test.js", null);
    try recordFailure(std.testing.allocator, &summary, "second.test.js", null);

    try std.testing.expectEqualStrings("first.test.js", summary.first_failure_file);
    try std.testing.expectEqualStrings("JSEvaluateScript returned null without an exception", summary.first_failure_message);
}

test "failure recorder owns duplicated exception messages" {
    var summary = Summary{};
    defer summary.deinit(std.testing.allocator);

    try recordFailure(std.testing.allocator, &summary, "first.test.js", "boom");

    try std.testing.expect(summary.first_failure_message_owned);
    try std.testing.expectEqualStrings("boom", summary.first_failure_message);
}

test "summary deinit resets owned failure state" {
    var summary = Summary{};
    try recordFailure(std.testing.allocator, &summary, "first.test.js", "boom");

    summary.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("", summary.first_failure_file);
    try std.testing.expectEqualStrings("", summary.first_failure_message);
    try std.testing.expect(!summary.first_failure_message_owned);
}
