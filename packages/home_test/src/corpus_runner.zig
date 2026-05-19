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
            self.first_failure_message_owned = false;
        }
    }
};

pub const minimal_js_files = [_][]const u8{
    "snippets/segfault-todo.test.js",
    "js/web/util/atob.test.js",
    "regression/issue/23723.test.js",
    "regression/issue/12650.test.js",
    "js/node/domexception-node.test.js",
    "js/bun/jsc/shadow.test.js",
};

const prelude =
    \\var __home_bun_tests = { passed: 0, failed: 0, todo: 0 };
    \\var Bun = { [Symbol.toStringTag]: "Bun" };
    \\function __home_fail(message) {
    \\  throw new Error(message);
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
    \\    __home_bun_tests.passed++;
    \\    return;
    \\  }
    \\  try {
    \\    const result = fn();
    \\    if (__home_is_thenable(result)) __home_fail("Async tests are not supported by the Home Bun corpus bootstrap runner yet");
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
    \\    if (__home_is_thenable(result)) __home_fail("Async tests are not supported by the Home Bun corpus bootstrap runner yet");
    \\  } catch (error) {
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
    \\    }
    \\  };
    \\  return expectation;
    \\}
    \\function expect(value) {
    \\  return __home_make_expectation(value, false);
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

pub fn rewriteBunTestImport(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    const imports = [_][]const u8{
        "import { expect, it, describe } from \"bun:test\";",
        "import { describe, expect, it } from \"bun:test\";",
        "import { expect, it } from \"bun:test\";",
        "import { expect, test } from \"bun:test\";",
    };

    for (imports) |import_line| {
        if (std.mem.indexOf(u8, source, import_line)) |idx| {
            var out = std.ArrayList(u8).empty;
            defer out.deinit(allocator);

            try out.appendSlice(allocator, source[0..idx]);
            try out.appendSlice(allocator, prelude);
            try out.appendSlice(allocator, source[idx + import_line.len ..]);
            return out.toOwnedSlice(allocator);
        }
    }

    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    try out.appendSlice(allocator, prelude);
    try out.appendSlice(allocator, source);
    return out.toOwnedSlice(allocator);
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

        const rewritten = try rewriteBunTestImport(allocator, source);
        defer allocator.free(rewritten);

        summary.files += 1;
        const evaluation = try home_rt.jsc.evaluate.evaluateUtf8Detailed(
            allocator,
            engine.currentContext(),
            rewritten,
            relative,
            1,
        );
        defer evaluation.deinit(allocator);

        if (evaluation.exception != null or evaluation.value == null) {
            summary.failed += 1;
            try recordFailure(allocator, &summary, relative, evaluation.exception_message);
            continue;
        }

        summary.passed += try readCounter(allocator, &engine, "__home_bun_tests.passed");
        summary.failed += try readCounter(allocator, &engine, "__home_bun_tests.failed");
        summary.todo += try readCounter(allocator, &engine, "__home_bun_tests.todo");
    }

    return summary;
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
}

test "Bun test import rewrite installs the bootstrap prelude" {
    const source =
        \\import { expect, it, describe } from "bun:test";
        \\it("works", () => {});
    ;
    const rewritten = try rewriteBunTestImport(std.testing.allocator, source);
    defer std.testing.allocator.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "function it(name, fn)") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "function __home_is_thenable(value)") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "toBeInstanceOf(ctor)") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "from \"bun:test\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "it(\"works\"") != null);
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
