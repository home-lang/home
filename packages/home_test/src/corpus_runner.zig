//! Bootstrap runner for small, explicit Bun-corpus subsets.
//!
//! This is not the full Bun test runner. It is a native execution path for
//! allowlisted smoke files while the full `bun:test` port and JSC host
//! function surface are still coming online.

const std = @import("std");
const build_options = @import("build_options");
const corpus = @import("corpus.zig");
const jsc_bootstrap = @import("adapters/jsc_bootstrap.zig");
const runner = @import("runner.zig");
const test_result = @import("result.zig");

const Io = std.Io;

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
    "js/web/websocket/error-event.test.ts",
    "cli/test/test-randomize.fixture.ts",
};

const harness_prelude =
    \\var __home_bun_tests = globalThis.__home_bun_tests || { passed: 0, failed: 0, todo: 0, pending: 0, unsupported: 0, firstFailure: null };
    \\globalThis.__home_reset_tests = function() {
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
    \\var Bun = {
    \\  [Symbol.toStringTag]: "Bun",
    \\  version: "0.0.0-home",
    \\  revision: "home",
    \\  gc(force) {},
    \\  serve(options) {
    \\    if (typeof globalThis.__home_serveNative !== "function" || typeof globalThis.__home_stopServeNative !== "function") __home_unsupported("Bun.serve native bridge is not installed");
    \\    const handle = globalThis.__home_serveNative(options || {});
    \\    handle.stopped = false;
    \\    handle.abrupt = false;
    \\    globalThis.__home_serve_handles_by_origin[handle.origin] = handle;
    \\    const server = {
    \\      port: handle.port,
    \\      url: { origin: handle.origin, href: handle.origin + "/" },
    \\      stop(closeActiveConnections) {
    \\        if (handle.stopped) return;
    \\        handle.stopped = true;
    \\        handle.abrupt = !!closeActiveConnections;
    \\        delete globalThis.__home_serve_handles_by_origin[handle.origin];
    \\        return globalThis.__home_stopServeNative(handle.id, handle.abrupt);
    \\      },
    \\    };
    \\    return server;
    \\  },
    \\  spawnSync(options) {
    \\    if (typeof globalThis.__home_spawnSyncNative !== "function") __home_unsupported("Bun.spawnSync native bridge is not installed");
    \\    const result = globalThis.__home_spawnSyncNative(options || {});
    \\    if (typeof Buffer === "function") {
    \\      result.stdout = Buffer.from(result.stdout || "");
    \\      result.stderr = Buffer.from(result.stderr || "");
    \\    }
    \\    return result;
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
    \\if (typeof process !== "object") {
    \\  var process = {};
    \\}
    \\if (!process.versions) process.versions = {};
    \\if (!process.env) process.env = {};
    \\if (!process.execPath) process.execPath = "home";
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
    \\process.cwd = function() {
    \\  return globalThis.__home_current_dirname || "/";
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
    \\      const hasLifecycleHooks = chain.some(item => item.beforeEach.length > 0 || item.afterEach.length > 0);
    \\      if (hasLifecycleHooks || globalThis.__home_current_finished_callbacks.length > 0) __home_unsupported("Async tests with lifecycle hooks are not supported by the Home Bun corpus bootstrap runner yet");
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
    \\describe.todo = function(name, fn) {
    \\  __home_bun_tests.todo++;
    \\};
    \\describe.skip = describe.todo;
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
    \\    toBeDefined() {
    \\      __home_assert(value !== undefined, isNot, "Expected value" + (isNot ? " not" : "") + " to be defined");
    \\    },
    \\    toBeUndefined() {
    \\      __home_assert(value === undefined, isNot, "Expected value" + (isNot ? " not" : "") + " to be undefined");
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
    \\    toBeNumber() {
    \\      __home_assert(typeof value === "number", isNot, "Expected value" + (isNot ? " not" : "") + " to be a number");
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
    \\      try {
    \\        value();
    \\      } catch (error) {
    \\        thrown = error;
    \\      }
    \\      if (thrown === null) {
    \\        __home_assert(false, isNot, "Expected function" + (isNot ? " not" : "") + " to throw");
    \\        return;
    \\      }
    \\      if (isNot && expected === undefined) __home_fail("Expected function not to throw");
    \\      if (expected && expected.__home_expect_any) {
    \\        __home_assert(thrown instanceof expected.ctor, isNot, "Expected thrown value" + (isNot ? " not" : "") + " to be instance of " + expected.ctor.name);
    \\        return;
    \\      }
    \\      if (typeof expected === "function") {
    \\        __home_assert(thrown instanceof expected, isNot, "Expected thrown value" + (isNot ? " not" : "") + " to be instance of " + expected.name);
    \\        return;
    \\      }
    \\      if (expected instanceof RegExp) {
    \\        __home_assert(expected.test(String(thrown && thrown.message)), isNot, "Expected thrown message" + (isNot ? " not" : "") + " to match " + String(expected));
    \\        return;
    \\      }
    \\      if (expected && typeof expected === "object" && ("message" in expected || "name" in expected)) {
    \\        let pass = true;
    \\        if ("message" in expected) pass = pass && Object.is(thrown && thrown.message, expected.message);
    \\        if ("name" in expected) pass = pass && Object.is(thrown && thrown.name, expected.name);
    \\        __home_assert(pass, isNot, "Expected thrown error" + (isNot ? " not" : "") + " to match " + __home_format(expected));
    \\        return;
    \\      }
    \\      if (expected !== undefined) {
    \\        __home_assert(String(thrown && thrown.message).includes(String(expected)), isNot, "Expected thrown message" + (isNot ? " not" : "") + " to include " + String(expected));
    \\      }
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
    \\globalThis.__home_modules["bun"] = { semver: Bun.semver, concatArrayBuffers: __home_concat_array_buffers, escapeHTML: Bun.escapeHTML, indexOfLine: Bun.indexOfLine, spawnSync: Bun.spawnSync };
    \\globalThis.__home_modules["bun:test"] = globalThis.__home_bun_test;
    \\globalThis.__home_modules["node:test"] = { test };
    \\globalThis.__home_modules["harness"] = { isWindows: false, bunEnv: Object.assign({}, process.env), bunExe() { return process.execPath; } };
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
    \\async function __home_bake_run_define_config(options, nodeEnv) {
    \\  const files = options && options.files ? options.files : {};
    \\  const htmlSource = String(files["index.html"] || "");
    \\  const scriptSource = String(files["index.ts"] || "");
    \\  const bunfigSource = String(files["bunfig.toml"] || "");
    \\  if (typeof globalThis.__home_buildBakeStaticClientScriptNative !== "function") __home_unsupported("Bake static client script native bridge is not installed");
    \\  const clientScript = globalThis.__home_buildBakeStaticClientScriptNative(htmlSource, scriptSource, bunfigSource);
    \\  const html = { __home_bake_html_import: true, path: "index.html" };
    \\  const server = Bun.serve({ static: { "/*": html } });
    \\  const messages = [];
    \\  const previousLog = console.log;
    \\  console.log = function() {
    \\    messages.push(Array.prototype.map.call(arguments, String).join(" "));
    \\  };
    \\  try {
    \\    (0, eval)(String(clientScript));
    \\  } finally {
    \\    console.log = previousLog;
    \\    server.stop(true);
    \\  }
    \\  const dev = {
    \\    nodeEnv,
    \\    async client(path) {
    \\      return {
    \\        messages,
    \\        async expectMessage() {
    \\          for (const expected of arguments) {
    \\            if (!messages.includes(String(expected))) throw new Error("Timed out waiting for " + JSON.stringify(String(expected)) + "; buffered: " + JSON.stringify(messages));
    \\          }
    \\        },
    \\        [Symbol.dispose]() {},
    \\      };
    \\    },
    \\  };
    \\  return options.test(dev);
    \\}
    \\function __home_bake_register_or_run(description, options, nodeEnv) {
    \\  const name = __home_bake_test_name(description, nodeEnv);
    \\  if (String(description) === "define config via bunfig.toml" && options && options.files && options.files["index.html"] && options.files["index.ts"] && options.files["bunfig.toml"] && typeof options.test === "function") {
    \\    return test(name, async () => __home_bake_run_define_config(options, nodeEnv));
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
    \\  tempDirWithBakeDeps() {
    \\    __home_unsupported("Bake tempDirWithBakeDeps requires the real Bake runtime");
    \\  },
    \\  devTest(description, options) {
    \\    return __home_bake_register_or_run(description, options, "development");
    \\  },
    \\  prodTest(description, options) {
    \\    return __home_bake_register_or_run(description, options, "production");
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
    \\const __home_node_fs = {
    \\  writeFileSync(path, data) {
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
    \\};
    \\__home_node_fs.default = __home_node_fs;
    \\globalThis.__home_modules["fs"] = __home_node_fs;
    \\globalThis.__home_modules["node:fs"] = __home_node_fs;
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
    \\  getDevServerDeinitCount() {
    \\    if (typeof globalThis.__home_getDevServerDeinitCountNative !== "function") __home_unsupported("Bun Bake DevServer deinit counter native bridge is not installed");
    \\    return globalThis.__home_getDevServerDeinitCountNative();
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
    \\  var URL = function(input) {
    \\    const text = String(input);
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
    \\  };
    \\}
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
    try out.appendSlice(allocator, ";\nglobalThis.__home_current_filename = __filename;\nglobalThis.__home_current_dirname = __dirname;\nvar __home_import_meta_path = __filename;\nvar __home_import_meta_dir = __dirname;\nvar __home_import_meta_dirname = __dirname;\nfunction __home_import_meta_resolve(specifier, parent) { throw new Error(\"Cannot resolve \" + String(specifier) + \" from \" + String(parent)); }\n");
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
        .{ .needle = ": any[] =", .replacement = " =" },
        .{ .needle = ": WebSocket[] =", .replacement = " =" },
        .{ .needle = ": Promise<void>[] =", .replacement = " =" },
        .{ .needle = ": any =", .replacement = " =" },
        .{ .needle = ": number =", .replacement = " =" },
        .{ .needle = ": string {", .replacement = " {" },
        .{ .needle = ": number)", .replacement = ")" },
        .{ .needle = ": string)", .replacement = ")" },
        .{ .needle = ": string) =>", .replacement = ") =>" },
        .{ .needle = ": string)=>", .replacement = ")=>" },
        .{ .needle = ": unknown)", .replacement = ")" },
        .{ .needle = ": string, value: string)", .replacement = ", value)" },
        .{ .needle = ": ReturnType<typeof setTimeout> | null =", .replacement = " =" },
        .{ .needle = "await using ", .replacement = "const " },
        .{ .needle = "using ", .replacement = "const " },
        .{ .needle = "serverComponents!", .replacement = "serverComponents" },
        .{ .needle = "readonly foo: FooParent", .replacement = "foo" },
        .{ .needle = "override foo: FooChild", .replacement = "foo" },
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
        .{ .needle = "<[string]>", .replacement = "" },
        .{ .needle = "<string>", .replacement = "" },
        .{ .needle = " as unknown", .replacement = "" },
        .{ .needle = " as (err?: unknown) => void", .replacement = "" },
        .{ .needle = " as string[][]", .replacement = "" },
        .{ .needle = " as string", .replacement = "" },
        .{ .needle = " as any", .replacement = "" },
        .{ .needle = " as const", .replacement = "" },
        .{ .needle = " as CustomEventInit", .replacement = "" },
        .{ .needle = " as EventInit", .replacement = "" },
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
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    const Mode = enum { code, single_quote, double_quote, template, line_comment, block_comment };
    var mode: Mode = .code;
    var i: usize = 0;
    while (i < source.len) {
        const byte = source[i];
        switch (mode) {
            .code => {
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
            .needle = "import path from \"path\";",
            .replacement = "const path = globalThis.__home_import(\"path\");",
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
    return std.mem.indexOf(u8, source, "from \"bun:test\"") != null or
        std.mem.indexOf(u8, source, "from 'bun:test'") != null;
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
        .{ .line = "import { afterAll, afterEach, beforeAll, beforeEach, expect, test } from \"bun:test\";", .binding = "const { afterAll, afterEach, beforeAll, beforeEach, expect, test } = globalThis.__home_import(\"bun:test\");\n" },
        .{ .line = "import { afterAll, afterEach, beforeEach, describe, expect, onTestFinished, test } from \"bun:test\";", .binding = "const { afterAll, afterEach, beforeEach, describe, expect, onTestFinished, test } = globalThis.__home_import(\"bun:test\");\n" },
        .{ .line = "import { afterAll, afterEach, beforeAll, beforeEach, describe, test } from \"bun:test\";", .binding = "const { afterAll, afterEach, beforeAll, beforeEach, describe, test } = globalThis.__home_import(\"bun:test\");\n" },
        .{ .line = "import { expect, it } from \"bun:test\";", .binding = "const { expect, it } = globalThis.__home_import(\"bun:test\");\n" },
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
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "serve(options)") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "__home_serveNative(options || {})") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "__home_stopServeNative(handle.id") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "spawnSync(options)") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "__home_spawnSyncNative(options || {})") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "process.versions.bun = Bun.version") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "if (!process.env) process.env = {}") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "process.execPath = \"home\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "process.on = function(name, listener)") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "process.emit = function(name)") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "process.cwd = function()") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "return globalThis.__home_current_dirname || \"/\"") != null);
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
        \\  let timer: ReturnType<typeof setTimeout> | null = setTimeout(() => {}, 1);
        \\  client.on("message", (m: unknown) => expect(m).toBeDefined());
        \\  const framework = { serverComponents: { ...minimalFramework.serverComponents!, separateSSRGraph: true } };
        \\});
    ;
    var prepared = try prepareCorpusModule(std.testing.allocator, source, "bake/dev-and-prod.test.ts");
    defer prepared.deinit(std.testing.allocator);

    try std.testing.expect(prepared.unsupported_reason == null);
    try std.testing.expect(std.mem.indexOf(u8, prepared.source, ": string") == null);
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
