//! Bootstrap runner for small, explicit Bun-corpus subsets.
//!
//! This is not the full Bun test runner. It is a native execution path for
//! allowlisted smoke files while the full `bun:test` port and JSC host
//! function surface are still coming online.

const std = @import("std");
const build_options = @import("build_options");
const home_rt = @import("home_rt");
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

    pub fn addFileResult(self: *Summary, file: test_result.FileResult) void {
        self.files += 1;
        self.passed += file.passed;
        self.failed += file.failed + file.unsupported;
        self.todo += file.todo;
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

const CorpusRuntime = struct {
    engine: home_rt.jsc.engine.Engine,

    pub fn init(allocator: std.mem.Allocator) !CorpusRuntime {
        var self = CorpusRuntime{
            .engine = try home_rt.jsc.engine.Engine.init(allocator),
        };
        errdefer self.deinit();

        try self.installHarness(allocator);
        return self;
    }

    pub fn deinit(self: *CorpusRuntime) void {
        self.engine.deinit();
    }

    fn installHarness(self: *CorpusRuntime, allocator: std.mem.Allocator) !void {
        const evaluation = try home_rt.jsc.evaluate.evaluateUtf8Detailed(
            allocator,
            self.engine.currentContext(),
            harness_prelude,
            "home:corpus-harness",
            1,
        );
        defer evaluation.deinit(allocator);

        if (evaluation.exception != null or evaluation.value == null) {
            return error.CorpusHarnessInstallFailed;
        }
    }

    fn resetFileState(self: *CorpusRuntime, allocator: std.mem.Allocator) !void {
        const evaluation = try home_rt.jsc.evaluate.evaluateUtf8Detailed(
            allocator,
            self.engine.currentContext(),
            "globalThis.__home_reset_tests();",
            "home:corpus-reset",
            1,
        );
        defer evaluation.deinit(allocator);

        if (evaluation.exception != null or evaluation.value == null) {
            return error.CorpusHarnessResetFailed;
        }
    }

    fn readCounters(self: *CorpusRuntime, allocator: std.mem.Allocator) !Counters {
        return .{
            .passed = try readCounter(allocator, &self.engine, "__home_bun_tests.passed"),
            .failed = try readCounter(allocator, &self.engine, "__home_bun_tests.failed"),
            .todo = try readCounter(allocator, &self.engine, "__home_bun_tests.todo"),
        };
    }

    fn runFile(self: *CorpusRuntime, allocator: std.mem.Allocator, spec: runner.FileSpec) !runner.FileRun {
        self.resetFileState(allocator) catch |err| {
            return runner.FileRun.failBorrowed(spec.path, @errorName(err));
        };

        const evaluation = try home_rt.jsc.evaluate.evaluateUtf8Detailed(
            allocator,
            self.engine.currentContext(),
            spec.source,
            spec.path,
            1,
        );
        defer evaluation.deinit(allocator);

        if (evaluation.exception != null or evaluation.value == null) {
            return runner.FileRun.failOwned(allocator, spec.path, evaluation.exception_message);
        }

        const finish_evaluation = try home_rt.jsc.evaluate.evaluateUtf8Detailed(
            allocator,
            self.engine.currentContext(),
            "globalThis.__home_finish_tests();",
            "home:corpus-finish",
            1,
        );
        defer finish_evaluation.deinit(allocator);

        if (finish_evaluation.exception != null or finish_evaluation.value == null) {
            return runner.FileRun.failOwned(allocator, spec.path, finish_evaluation.exception_message);
        }

        const counters = self.readCounters(allocator) catch |err| {
            return runner.FileRun.failBorrowed(spec.path, @errorName(err));
        };

        return .{
            .result = .{
                .path = spec.path,
                .passed = counters.passed,
                .failed = counters.failed,
                .todo = counters.todo,
            },
        };
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
};

const harness_prelude =
    \\var __home_bun_tests = globalThis.__home_bun_tests || { passed: 0, failed: 0, todo: 0 };
    \\globalThis.__home_reset_tests = function() {
    \\  __home_bun_tests = globalThis.__home_bun_tests = { passed: 0, failed: 0, todo: 0 };
    \\  globalThis.__home_hooks = {
    \\    beforeAll: [],
    \\    beforeEach: [],
    \\    afterEach: [],
    \\    afterAll: [],
    \\    beforeAllDone: false,
    \\    afterAllDone: false,
    \\  };
    \\};
    \\globalThis.__home_reset_tests();
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
    \\function __home_has_own_property(value, key) {
    \\  return Object.prototype.hasOwnProperty.call(value, key);
    \\}
    \\function __home_is_unsupported_deep_value(value) {
    \\  return value !== null && typeof value === "object" && (value instanceof ArrayBuffer || ArrayBuffer.isView(value) || value instanceof Error);
    \\}
    \\function __home_deep_equal(a, b, strict, seen) {
    \\  if (Object.is(a, b)) return true;
    \\  if (a === null || b === null) return false;
    \\  if (typeof a !== "object" || typeof b !== "object") return false;
    \\  if (__home_is_unsupported_deep_value(a) || __home_is_unsupported_deep_value(b)) __home_unsupported("Deep equality for this value type is not supported by the Home Bun corpus bootstrap runner yet");
    \\  if (strict && Object.getPrototypeOf(a) !== Object.getPrototypeOf(b)) return false;
    \\  if (a instanceof Date || b instanceof Date) return a instanceof Date && b instanceof Date && Object.is(a.getTime(), b.getTime());
    \\  if (a instanceof RegExp || b instanceof RegExp) return a instanceof RegExp && b instanceof RegExp && a.source === b.source && a.flags === b.flags;
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
    \\function __home_run_before_all_hooks() {
    \\  if (__home_hooks.beforeAllDone) return;
    \\  __home_hooks.beforeAllDone = true;
    \\  for (const hook of __home_hooks.beforeAll) __home_run_hook(hook);
    \\}
    \\function __home_register_hook(list, fn) {
    \\  if (typeof fn === "function") list.push(fn);
    \\}
    \\function __home_run_test(name, fn) {
    \\  if (typeof fn !== "function") {
    \\    __home_bun_tests.todo++;
    \\    return;
    \\  }
    \\  try {
    \\    __home_run_before_all_hooks();
    \\    for (const hook of __home_hooks.beforeEach) __home_run_hook(hook);
    \\    const result = fn();
    \\    if (__home_is_thenable(result)) __home_unsupported("Async tests are not supported by the Home Bun corpus bootstrap runner yet");
    \\    for (const hook of __home_hooks.afterEach) __home_run_hook(hook);
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
    \\function beforeAll(fn, options) { __home_register_hook(__home_hooks.beforeAll, fn); }
    \\function beforeEach(fn, options) { __home_register_hook(__home_hooks.beforeEach, fn); }
    \\function afterEach(fn, options) { __home_register_hook(__home_hooks.afterEach, fn); }
    \\function afterAll(fn, options) { __home_register_hook(__home_hooks.afterAll, fn); }
    \\globalThis.__home_finish_tests = function() {
    \\  if (__home_hooks.afterAllDone) return;
    \\  __home_hooks.afterAllDone = true;
    \\  for (const hook of __home_hooks.afterAll) __home_run_hook(hook);
    \\};
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
    \\      if (expected && typeof expected === "object" && "message" in expected) {
    \\        __home_assert(Object.is(thrown && thrown.message, expected.message), isNot, "Expected thrown message" + (isNot ? " not" : "") + " to match " + String(expected.message));
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
    \\  return expectation;
    \\}
    \\function expect(value) {
    \\  return __home_make_expectation(value, false);
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
    \\  if (matchers === null || typeof matchers !== "object") __home_fail("expect.extend() expected an object containing matchers");
    \\  for (const name of Object.keys(matchers)) {
    \\    const matcher = matchers[name];
    \\    if (typeof matcher !== "function") __home_fail("expect.extend: `" + name + "` is not a valid matcher");
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
    \\globalThis.__home_bun_test = { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, test };
    \\globalThis.__home_modules = globalThis.__home_modules || Object.create(null);
    \\globalThis.__home_modules["bun:test"] = globalThis.__home_bun_test;
    \\globalThis.__home_import = function(specifier) {
    \\  const module = globalThis.__home_modules[String(specifier)];
    \\  if (!module) throw new Error("Cannot find module: " + String(specifier));
    \\  return module;
    \\};
    \\if (typeof Headers !== "function") {
    \\  var Headers = function(init) {
    \\    this.__home_headers = {};
    \\    if (init) {
    \\      for (const key of Object.keys(init)) this.set(key, init[key]);
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
    \\  var URL = function(input) {
    \\    const match = String(input).match(/^([A-Za-z][A-Za-z0-9+.-]*:\/\/)([^\/?#]*)(.*)$/);
    \\    if (!match) throw new TypeError("Invalid URL");
    \\    this.protocolPrefix = match[1];
    \\    this.hostname = match[2];
    \\    this.suffix = match[3] || "/";
    \\  };
    \\  Object.defineProperty(URL.prototype, "href", {
    \\    get() {
    \\      return this.protocolPrefix + this.hostname + this.suffix;
    \\    },
    \\  });
    \\}
    \\if (typeof Response !== "function") {
    \\  var Response = function(body, init) {
    \\    this.body = body;
    \\    this.init = init || {};
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
    \\if (typeof Request !== "function") {
    \\  var Request = function(input, init) {
    \\    const options = init || {};
    \\    if (input instanceof Request) {
    \\      this.url = input.url;
    \\      this.cache = input.cache;
    \\      this.mode = input.mode;
    \\    } else {
    \\      this.url = input && typeof input.href === "string" ? input.href : String(input);
    \\      this.cache = "default";
    \\      this.mode = "cors";
    \\    }
    \\    if (Object.prototype.hasOwnProperty.call(options, "cache")) this.cache = String(options.cache);
    \\    if (Object.prototype.hasOwnProperty.call(options, "mode")) this.mode = String(options.mode);
    \\  };
    \\  Request.prototype.clone = function() {
    \\    return new Request(this);
    \\  };
    \\}
    \\globalThis.__home_modules["node-fetch"] = { Request };
    \\if (typeof Buffer !== "function") {
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
    \\      const byte = typeof fill === "number" ? fill & 0xff : String(fill).charCodeAt(0) & 0xff;
    \\      for (let i = 0; i < buffer.length; i++) buffer[i] = byte;
    \\    }
    \\    return buffer;
    \\  };
    \\  Buffer.from = function(value, encoding) {
    \\    if (Array.isArray(value)) {
    \\      const buffer = new Buffer(value.length);
    \\      for (let i = 0; i < value.length; i++) buffer[i] = Number(value[i]) & 0xff;
    \\      return buffer;
    \\    }
    \\    const normalized = encoding === undefined ? "utf8" : String(encoding).toLowerCase();
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
    \\    __home_unsupported("Only Buffer.toString('hex') is supported by the Home Bun corpus bootstrap runner");
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
        .{ .needle = ": number =", .replacement = " =" },
        .{ .needle = ": any)", .replacement = ")" },
        .{ .needle = ": any;", .replacement = ";" },
        .{ .needle = "<any, any>", .replacement = "" },
        .{ .needle = " as const", .replacement = "" },
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
        .{ .line = "import { describe, expect, test } from \"bun:test\";", .binding = "const { describe, expect, test } = globalThis.__home_import(\"bun:test\");\n" },
        .{ .line = "import { afterAll, afterEach, beforeAll, beforeEach, expect, test } from \"bun:test\";", .binding = "const { afterAll, afterEach, beforeAll, beforeEach, expect, test } = globalThis.__home_import(\"bun:test\");\n" },
        .{ .line = "import { expect, it } from \"bun:test\";", .binding = "const { expect, it } = globalThis.__home_import(\"bun:test\");\n" },
        .{ .line = "import { expect, test } from \"bun:test\";", .binding = "const { expect, test } = globalThis.__home_import(\"bun:test\");\n" },
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
    const with_metadata = try out.toOwnedSlice(allocator);
    defer allocator.free(with_metadata);
    return finishModuleRewrite(allocator, with_metadata);
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

    var runtime = try CorpusRuntime.init(allocator);
    defer runtime.deinit();

    var summary = Summary{};
    for (filesForSubset(subset)) |relative| {
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
            try recordFailure(allocator, &summary, relative, reason);
            continue;
        }

        var file_run = try runtime.runFile(allocator, .{
            .path = relative,
            .source = prepared.source,
        });
        defer file_run.deinit(allocator);

        summary.addFileResult(file_run.result);
        if (file_run.result.status() == .failed) {
            try recordFailure(allocator, &summary, relative, file_run.result.first_failure_message);
        }
    }

    return summary;
}

const Counters = struct {
    passed: usize,
    failed: usize,
    todo: usize,
};

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
}

test "harness prelude installs Bun test globals once" {
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "function it(name, fn)") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "function __home_is_thenable(value)") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "stripANSI(value)") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "toBeInstanceOf(ctor)") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "toBeInstanceOf() requires 1 argument") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "Expected value must be a function:") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "toBeTypeOf(expected)") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "toBeTypeOf() requires a valid type string argument") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "toBeUndefined()") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "a instanceof Map || b instanceof Map") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "a instanceof Set || b instanceof Set") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "toIncludeRepeated(needle, expectedCount)") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "function beforeAll(fn, options)") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "globalThis.__home_finish_tests") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "toContain(expected)") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "toIncludeRepeated() requires the expect(value) to be a string") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "toContainKey(expected)") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "toContainAnyKeys(expected)") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "expect.unreachable") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "expect.extend") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "asymmetricMatch(received)") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "Expected value must be string or Error") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "Deep equality for this value type is not supported") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "UnreachableError") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "globalThis.__home_bun_test") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "globalThis.__home_import") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "Response.redirect") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "Response.json") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "var Request = function(input, init)") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "typeof input.href === \"string\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "Request.prototype.clone") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "__home_modules[\"node-fetch\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "Buffer.alloc = function(size, fill)") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "Buffer.from") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "Buffer.prototype.compare") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "toString(16).padStart") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness_prelude, "Error.prepareStackTrace") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "it(\"works\"") != null);
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

test "bootstrap rewrite erases admitted type-only syntax" {
    const source =
        \\import { describe, expect, test } from "bun:test";
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
    try std.testing.expect(std.mem.indexOf(u8, rewritten, ": any") == null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "<any, any>") == null);
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
