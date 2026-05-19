//! Bootstrap runner for small, explicit Bun-corpus subsets.
//!
//! This is not the full Bun test runner. It is a native execution path for
//! allowlisted smoke files while the full `bun:test` port and JSC host
//! function surface are still coming online.

const std = @import("std");
const build_options = @import("build_options");
const home_rt = @import("home_rt");

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
    blocked: bool = false,
    reason: []const u8 = "",
    first_failure_file: []const u8 = "",
    first_failure_message: []const u8 = "",
    first_failure_message_owned: bool = false,

    pub fn deinit(self: *Summary, allocator: std.mem.Allocator) void {
        if (self.first_failure_message_owned) {
            allocator.free(self.first_failure_message);
        }
        self.first_failure_file = "";
        self.first_failure_message = "";
        self.first_failure_message_owned = false;
    }
};

pub const PreparedModule = struct {
    source: []u8,
    unsupported_reason: ?[]const u8 = null,

    pub fn deinit(self: *PreparedModule, allocator: std.mem.Allocator) void {
        allocator.free(self.source);
        self.source = &.{};
        self.unsupported_reason = null;
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
};

const prelude =
    \\var __home_bun_tests = { passed: 0, failed: 0, todo: 0 };
    \\var Bun = {
    \\  [Symbol.toStringTag]: "Bun",
    \\  stripANSI(value) {
    \\    return String(value).replace(/\x1b\[[0-?]*[ -/]*[@-~]/g, "");
    \\  },
    \\};
    \\function __home_fail(message) {
    \\  throw new Error(message);
    \\}
    \\function __home_unsupported(message) {
    \\  const error = new Error(message);
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
    \\function __home_is_thenable(value) {
    \\  return value !== null && (typeof value === "object" || typeof value === "function") && typeof value.then === "function";
    \\}
    \\function __home_assert(pass, isNot, message) {
    \\  if (isNot ? pass : !pass) __home_fail(message);
    \\}
    \\function __home_deep_equal(a, b, strict, seen) {
    \\  if (Object.is(a, b)) return true;
    \\  if (a === null || b === null) return false;
    \\  if (typeof a !== "object" || typeof b !== "object") return false;
    \\  if (strict && Object.getPrototypeOf(a) !== Object.getPrototypeOf(b)) return false;
    \\  if (a instanceof Date || b instanceof Date) return a instanceof Date && b instanceof Date && Object.is(a.getTime(), b.getTime());
    \\  if (a instanceof RegExp || b instanceof RegExp) return a instanceof RegExp && b instanceof RegExp && a.source === b.source && a.flags === b.flags;
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
    \\function __home_run_test(name, fn) {
    \\  if (typeof fn !== "function") {
    \\    __home_bun_tests.todo++;
    \\    return;
    \\  }
    \\  try {
    \\    const result = fn();
    \\    if (__home_is_thenable(result)) __home_unsupported("Async tests are not supported by the Home Bun corpus bootstrap runner yet");
    \\    __home_bun_tests.passed++;
    \\  } catch (error) {
    \\    __home_bun_tests.failed++;
    \\    throw error;
    \\  }
    \\}
    \\function it(name, fn) { __home_run_test(name, fn); }
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
    \\function test(name, fn) { return it(name, fn); }
    \\test.todo = it.todo;
    \\test.failing = it.failing;
    \\function describe(name, fn) {
    \\  if (typeof fn === "function") fn();
    \\}
    \\function __home_make_expectation(value, isNot) {
    \\  const expectation = {
    \\    get not() {
    \\      return __home_make_expectation(value, !isNot);
    \\    },
    \\    toBe(expected) {
    \\      __home_assert(Object.is(value, expected), isNot, "Expected " + __home_format(value) + (isNot ? " not" : "") + " to be " + __home_format(expected));
    \\    },
    \\    toBeDefined() {
    \\      __home_assert(value !== undefined, isNot, "Expected value" + (isNot ? " not" : "") + " to be defined");
    \\    },
    \\    toBeUndefined() {
    \\      __home_assert(value === undefined, isNot, "Expected value" + (isNot ? " not" : "") + " to be undefined");
    \\    },
    \\    toBeInstanceOf(ctor) {
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
    \\      if (expected !== undefined) {
    \\        __home_assert(String(thrown && thrown.message).includes(String(expected)), isNot, "Expected thrown message" + (isNot ? " not" : "") + " to include " + String(expected));
    \\      }
    \\    },
    \\    toThrowError(expected) {
    \\      return this.toThrow(expected);
    \\    },
    \\    toIncludeRepeated(needle, expectedCount) {
    \\      const haystack = String(value);
    \\      const search = String(needle);
    \\      if (search.length === 0) __home_fail("toIncludeRepeated() requires a non-empty search string");
    \\      let count = 0;
    \\      let index = 0;
    \\      while (true) {
    \\        const found = haystack.indexOf(search, index);
    \\        if (found === -1) break;
    \\        count++;
    \\        index = found + search.length;
    \\      }
    \\      __home_assert(count === expectedCount, isNot, "Expected " + __home_format(value) + (isNot ? " not" : "") + " to include " + __home_format(needle) + " " + String(expectedCount) + " times");
    \\    }
    \\  };
    \\  return expectation;
    \\}
    \\function expect(value) {
    \\  return __home_make_expectation(value, false);
    \\}
    \\globalThis.__home_bun_test = { describe, expect, it, test };
    \\if (typeof Response !== "function") {
    \\  var Response = function(body, init) {
    \\    this.body = body;
    \\    this.init = init || {};
    \\  };
    \\}
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
    \\if (typeof Error.prepareStackTrace !== "function") {
    \\  Error.prepareStackTrace = function(error, stack) {
    \\    const name = error && error.name ? String(error.name) : "Error";
    \\    const message = error && error.message ? String(error.message) : "";
    \\    return message.length > 0 ? name + ": " + message : name;
    \\  };
    \\}
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
    \\expect.any = function(ctor) {
    \\  return { __home_expect_any: true, ctor };
    \\};
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
    try out.appendSlice(allocator, ";\nvar __home_import_meta_path = __filename;\nvar __home_import_meta_dir = __dirname;\nvar __home_import_meta_dirname = __dirname;\n");
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

fn hasBunTestImport(source: []const u8) bool {
    return std.mem.indexOf(u8, source, "from \"bun:test\"") != null or
        std.mem.indexOf(u8, source, "from 'bun:test'") != null;
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
    const imports = [_][]const u8{
        "import { expect, it, describe } from \"bun:test\";",
        "import { describe, expect, it } from \"bun:test\";",
        "import { describe, expect, test } from \"bun:test\";",
        "import { expect, it } from \"bun:test\";",
        "import { expect, test } from \"bun:test\";",
    };

    for (imports) |import_line| {
        if (std.mem.indexOf(u8, source, import_line)) |idx| {
            var out = std.ArrayList(u8).empty;
            defer out.deinit(allocator);

            try out.appendSlice(allocator, source[0..shebang_len]);
            try appendFileMetadataPrelude(&out, allocator, relative_path);
            try out.appendSlice(allocator, source[shebang_len..idx]);
            try out.appendSlice(allocator, prelude);
            try out.appendSlice(allocator, source[idx + import_line.len ..]);
            const with_prelude = try out.toOwnedSlice(allocator);
            defer allocator.free(with_prelude);
            return rewriteImportMeta(allocator, with_prelude);
        }
    }

    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    try out.appendSlice(allocator, source[0..shebang_len]);
    try appendFileMetadataPrelude(&out, allocator, relative_path);
    try out.appendSlice(allocator, prelude);
    try out.appendSlice(allocator, source[shebang_len..]);
    const with_prelude = try out.toOwnedSlice(allocator);
    defer allocator.free(with_prelude);
    return rewriteImportMeta(allocator, with_prelude);
}

pub fn prepareCorpusModule(allocator: std.mem.Allocator, source: []const u8, relative_path: []const u8) !PreparedModule {
    const rewritten = try rewriteBunTestImport(allocator, source, relative_path);
    if (hasBunTestImport(rewritten)) {
        return .{
            .source = rewritten,
            .unsupported_reason = "unsupported bun:test import shape",
        };
    }
    if (hasUnsupportedModuleSyntax(rewritten)) {
        return .{
            .source = rewritten,
            .unsupported_reason = "unsupported module syntax",
        };
    }
    return .{ .source = rewritten };
}

pub fn runSubset(io: Io, allocator: std.mem.Allocator, corpus_path: []const u8, subset: Subset) !Summary {
    if (!build_options.enable_jsc) {
        return .{
            .files = filesForSubset(subset).len,
            .blocked = true,
            .reason = "jsc-disabled",
        };
    }

    var engine = try home_rt.jsc.engine.Engine.init(allocator);
    defer engine.deinit();

    var summary = Summary{};
    for (filesForSubset(subset)) |relative| {
        const file_path = try std.fs.path.join(allocator, &.{ corpus_path, relative });
        defer allocator.free(file_path);

        const source = try Io.Dir.cwd().readFileAlloc(io, file_path, allocator, std.Io.Limit.limited(1024 * 1024));
        defer allocator.free(source);

        var prepared = try prepareCorpusModule(allocator, source, relative);
        defer prepared.deinit(allocator);

        summary.files += 1;
        if (prepared.unsupported_reason) |reason| {
            summary.failed += 1;
            try recordFailure(allocator, &summary, relative, reason);
            continue;
        }

        const evaluation = try home_rt.jsc.evaluate.evaluateUtf8Detailed(
            allocator,
            engine.currentContext(),
            prepared.source,
            relative,
            1,
        );
        defer evaluation.deinit(allocator);

        if (evaluation.exception != null or evaluation.value == null) {
            summary.failed += 1;
            try recordFailure(allocator, &summary, relative, evaluation.exception_message);
            continue;
        }

        const counters = readCounters(allocator, &engine) catch |err| {
            summary.failed += 1;
            try recordFailure(allocator, &summary, relative, @errorName(err));
            continue;
        };
        summary.passed += counters.passed;
        summary.failed += counters.failed;
        summary.todo += counters.todo;
    }

    return summary;
}

const Counters = struct {
    passed: usize,
    failed: usize,
    todo: usize,
};

fn readCounters(allocator: std.mem.Allocator, engine: *home_rt.jsc.engine.Engine) !Counters {
    return .{
        .passed = try readCounter(allocator, engine, "__home_bun_tests.passed"),
        .failed = try readCounter(allocator, engine, "__home_bun_tests.failed"),
        .todo = try readCounter(allocator, engine, "__home_bun_tests.todo"),
    };
}

fn readCounter(allocator: std.mem.Allocator, engine: *home_rt.jsc.engine.Engine, expr: []const u8) !usize {
    const value = (try home_rt.jsc.evaluate.evaluateUtf8(
        allocator,
        engine.currentContext(),
        expr,
        "home:corpus-counter",
        1,
        null,
    )) orelse return error.CounterEvaluateFailed;

    const number = home_rt.jsc.extern_fns.JSValueToNumber(engine.currentContext(), value, null);
    if (!std.math.isFinite(number) or number < 0 or @floor(number) != number) {
        return error.InvalidCorpusCounter;
    }
    return @intFromFloat(number);
}

fn recordFailure(
    allocator: std.mem.Allocator,
    summary: *Summary,
    relative: []const u8,
    message: ?[]const u8,
) !void {
    if (summary.first_failure_file.len != 0) return;

    summary.first_failure_file = relative;
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
}

test "Bun test import rewrite installs the bootstrap prelude" {
    const source =
        \\import { expect, it, describe } from "bun:test";
        \\it("works", () => {});
    ;
    const rewritten = try rewriteBunTestImport(std.testing.allocator, source, "js/node/example.test.js");
    defer std.testing.allocator.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "function it(name, fn)") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "function __home_is_thenable(value)") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "stripANSI(value)") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "toBeInstanceOf(ctor)") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "toBeUndefined()") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "toIncludeRepeated(needle, expectedCount)") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "globalThis.__home_bun_test") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "Response.json") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "Error.prepareStackTrace") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "from \"bun:test\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "var __dirname = \"js/node\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "it(\"works\"") != null);
}

test "Bun test import rewrite installs globals for no-import tests" {
    const source =
        \\test("works", () => {
        \\  expect(1).toBe(1);
        \\});
    ;
    const rewritten = try rewriteBunTestImport(std.testing.allocator, source, "regression/issue/example.test.js");
    defer std.testing.allocator.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "function test(name, fn)") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "var __filename = \"regression/issue/example.test.js\"") != null);
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
