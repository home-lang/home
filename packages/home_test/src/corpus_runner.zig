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
};

pub const minimal_js_files = [_][]const u8{
    "snippets/segfault-todo.test.js",
};

const prelude =
    \\var __home_bun_tests = { passed: 0, failed: 0, todo: 0 };
    \\function __home_run_test(name, fn) {
    \\  if (typeof fn !== "function") {
    \\    __home_bun_tests.passed++;
    \\    return;
    \\  }
    \\  try {
    \\    fn();
    \\    __home_bun_tests.passed++;
    \\  } catch (error) {
    \\    __home_bun_tests.failed++;
    \\    throw error;
    \\  }
    \\}
    \\function it(name, fn) { __home_run_test(name, fn); }
    \\it.todo = function(name, fn) {
    \\  __home_bun_tests.todo++;
    \\};
    \\function test(name, fn) { return it(name, fn); }
    \\test.todo = it.todo;
    \\function describe(name, fn) {
    \\  if (typeof fn === "function") fn();
    \\}
    \\function expect(value) {
    \\  return {
    \\    toBe(expected) {
    \\      if (!Object.is(value, expected)) {
    \\        throw new Error("Expected " + String(value) + " to be " + String(expected));
    \\      }
    \\    }
    \\  };
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

pub fn rewriteBunTestImport(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    const imports = [_][]const u8{
        "import { expect, it, describe } from \"bun:test\";",
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
        const value = (try home_rt.jsc.evaluate.evaluateUtf8(
            allocator,
            engine.currentContext(),
            rewritten,
            relative,
            1,
            null,
        )) orelse {
            summary.failed += 1;
            continue;
        };
        _ = value;

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

test "subset flag parser recognizes the bootstrap subset" {
    try std.testing.expectEqual(Subset.minimal_js, parseSubsetFlagValue("minimal-js").?);
    try std.testing.expect(parseSubsetFlagValue("all") == null);
}

test "minimal JS subset starts with the todo smoke" {
    try std.testing.expectEqualStrings("snippets/segfault-todo.test.js", filesForSubset(.minimal_js)[0]);
}

test "Bun test import rewrite installs the bootstrap prelude" {
    const source =
        \\import { expect, it, describe } from "bun:test";
        \\it("works", () => {});
    ;
    const rewritten = try rewriteBunTestImport(std.testing.allocator, source);
    defer std.testing.allocator.free(rewritten);

    try std.testing.expect(std.mem.indexOf(u8, rewritten, "function it(name, fn)") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "from \"bun:test\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "it(\"works\"") != null);
}
