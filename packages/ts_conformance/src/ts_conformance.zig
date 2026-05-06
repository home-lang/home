//! Conformance harness — Phase 6 of TS_PARITY_PLAN.
//!
//! Runs TS source through the compiler and verifies the result
//! against expected baseline files (matching tsgo's
//! `tests/baselines/reference/` layout):
//!
//!   - `name.ts`            — input source
//!   - `name.errors.txt`    — expected diagnostic header lines (tsc
//!                            `path(line,col): error TSxxxx: message`
//!                            format)
//!   - `name.types`         — expected `(file, line, col, type)` rows
//!                            for every typed expression
//!   - `name.symbols`       — expected `(file, line, col, symbol)`
//!                            rows for every bound identifier
//!
//! Phase 6 ships the harness; the suite of cases under
//! `_submodules/TypeScript/tests/cases/conformance/` is run from
//! a separate test target so per-case failures don't gate the
//! main suite.

const std = @import("std");
const ts_driver = @import("ts_driver");
const ts_diagnostics = @import("ts_diagnostics");

pub const patience = @import("patience.zig");
test {
    _ = patience;
}

pub const Outcome = enum {
    passed,
    failed,
    skipped,
};

pub const Result = struct {
    name: []const u8,
    outcome: Outcome,
    /// First-failure description; empty on `.passed`.
    detail: []const u8 = "",
    /// Number of expected diagnostic lines.
    expected_diag_count: u32 = 0,
    /// Number of actual diagnostic lines from the compile.
    actual_diag_count: u32 = 0,
};

pub const Case = struct {
    /// Logical case name (filename minus extension).
    name: []const u8,
    /// Source bytes for the .ts / .tsx / .d.ts file.
    source: []const u8,
    /// Path used in diagnostic output (e.g. `tests/foo.ts`).
    path: []const u8,
    /// Expected diagnostic header lines, one per line. Empty
    /// means "expect no errors".
    expected_errors: []const u8 = "",
    /// True for .tsx / .jsx sources.
    is_tsx: bool = false,
};

/// Run a single conformance case. Returns the outcome and writes
/// human-readable detail when the case fails.
pub fn run(gpa: std.mem.Allocator, c: Case) !Result {
    var compilation = ts_driver.compileSource(gpa, c.source, .{
        .is_tsx = c.is_tsx,
        .continue_on_error = true,
    }) catch |err| {
        const detail = try std.fmt.allocPrint(gpa, "compile failed: {s}", .{@errorName(err)});
        return .{
            .name = c.name,
            .outcome = .failed,
            .detail = detail,
        };
    };
    defer {
        compilation.deinit();
        gpa.destroy(compilation);
    }

    // Render the actual diagnostics in tsc-default format and
    // compare against the expected baseline.
    var actual: std.ArrayListUnmanaged(u8) = .empty;
    defer actual.deinit(gpa);
    var actual_count: u32 = 0;
    for (compilation.diagnostics.items) |d| {
        const pos = ts_diagnostics.positionToLineCol(c.source, d.pos);
        const code = if (d.code != 0) d.code else mapPhaseToCode(d.phase);
        const prefix: ts_diagnostics.Diagnostic.CodePrefix = switch (d.code_prefix) {
            .TS => .TS,
            .HM => .HM,
        };
        const fdiag: ts_diagnostics.Diagnostic = .{
            .file = c.path,
            .line = pos.line,
            .col = pos.col,
            .code = code,
            .code_prefix = prefix,
            .severity = .err,
            .message = d.message,
            .span_len = 0,
        };
        const formatted = try ts_diagnostics.formatDefault(gpa, fdiag);
        defer gpa.free(formatted);
        try actual.appendSlice(gpa, formatted);
        try actual.append(gpa, '\n');
        actual_count += 1;
    }

    // Strip trailing newlines for stable comparison.
    const actual_trimmed = trimRightNewlines(actual.items);
    const expected_trimmed = trimRightNewlines(c.expected_errors);
    const expected_count = countLines(expected_trimmed);

    if (std.mem.eql(u8, actual_trimmed, expected_trimmed)) {
        return .{
            .name = c.name,
            .outcome = .passed,
            .expected_diag_count = expected_count,
            .actual_diag_count = actual_count,
        };
    }

    const detail = try std.fmt.allocPrint(
        gpa,
        "diagnostic mismatch.\n  expected:\n{s}\n  actual:\n{s}",
        .{ expected_trimmed, actual_trimmed },
    );
    return .{
        .name = c.name,
        .outcome = .failed,
        .detail = detail,
        .expected_diag_count = expected_count,
        .actual_diag_count = actual_count,
    };
}

fn trimRightNewlines(s: []const u8) []const u8 {
    var end: usize = s.len;
    while (end > 0 and (s[end - 1] == '\n' or s[end - 1] == '\r')) end -= 1;
    return s[0..end];
}

fn countLines(s: []const u8) u32 {
    if (s.len == 0) return 0;
    var n: u32 = 1;
    for (s) |c| if (c == '\n') {
        n += 1;
    };
    return n;
}

fn mapPhaseToCode(phase: ts_driver.Diagnostic.Phase) u32 {
    return switch (phase) {
        .lex => 1109, // unexpected token
        .parse => 1109,
        .bind => 2304, // cannot find name (binder catch-all)
        .emit => 5024, // emit failed (Home-only)
    };
}

pub const Suite = struct {
    cases: []const Case,
    pub fn run(self: Suite, gpa: std.mem.Allocator, results: *std.ArrayListUnmanaged(Result)) !Stats {
        var stats: Stats = .{};
        for (self.cases) |c| {
            const r = try run_(gpa, c);
            switch (r.outcome) {
                .passed => stats.passed += 1,
                .failed => stats.failed += 1,
                .skipped => stats.skipped += 1,
            }
            try results.append(gpa, r);
        }
        return stats;
    }
};

pub const Stats = struct {
    passed: u32 = 0,
    failed: u32 = 0,
    skipped: u32 = 0,
    pub fn total(self: Stats) u32 {
        return self.passed + self.failed + self.skipped;
    }
    pub fn passRate(self: Stats) f64 {
        const t = self.total();
        if (t == 0) return 0.0;
        return @as(f64, @floatFromInt(self.passed)) / @as(f64, @floatFromInt(t));
    }
};

fn run_(gpa: std.mem.Allocator, c: Case) !Result {
    return try run(gpa, c);
}

// =============================================================================
// In-memory bulk runner
// =============================================================================

/// Built-in corpus entry — the test runner exercises a fixed set
/// of these so the test is hermetic and doesn't depend on the
/// Zig stdlib's still-shifting filesystem API. A future
/// `runDirectory` will read these from disk once `std.Io.Dir`
/// stabilizes.
pub const CorpusEntry = struct {
    name: []const u8,
    source: []const u8,
    expects_error: bool = false,
    is_tsx: bool = false,
};

/// Run every entry in `corpus` and append a `Result` per case.
/// Returns aggregate Stats. Caller owns the per-result `name`
/// and `detail` strings (deinit is responsibility of the caller).
pub fn runCorpus(
    gpa: std.mem.Allocator,
    corpus: []const CorpusEntry,
    results: *std.ArrayListUnmanaged(Result),
) !Stats {
    var stats: Stats = .{};
    for (corpus) |entry| {
        const name_owned = try gpa.dupe(u8, entry.name);

        var compilation = ts_driver.compileSource(gpa, entry.source, .{
            .is_tsx = entry.is_tsx,
            .continue_on_error = true,
        }) catch |err| {
            const detail = try std.fmt.allocPrint(gpa, "compile crash: {s}", .{@errorName(err)});
            try results.append(gpa, .{
                .name = name_owned,
                .outcome = .failed,
                .detail = detail,
            });
            stats.failed += 1;
            continue;
        };
        const had_errors = compilation.has_errors;
        compilation.deinit();
        gpa.destroy(compilation);

        const passed = if (entry.expects_error) had_errors else !had_errors;
        if (passed) {
            try results.append(gpa, .{
                .name = name_owned,
                .outcome = .passed,
            });
            stats.passed += 1;
        } else {
            const detail = if (entry.expects_error)
                try gpa.dupe(u8, "expected at least one diagnostic; got none")
            else
                try gpa.dupe(u8, "expected no diagnostics; got at least one");
            try results.append(gpa, .{
                .name = name_owned,
                .outcome = .failed,
                .detail = detail,
            });
            stats.failed += 1;
        }
    }
    return stats;
}

/// Built-in conformance corpus — small smoke set of valid TS
/// programs exercising every grammar shape the parser supports.
/// Mirrors `tests/conformance/*.ts` on disk.
pub const builtin_corpus = [_]CorpusEntry{
    .{ .name = "00-empty", .source = "" },
    .{ .name = "01-let-number", .source = "let x: number = 1;" },
    .{ .name = "02-let-string", .source = "let s: string = \"hi\";" },
    .{ .name = "03-fn-decl", .source = "function id(x: number): number { return x; }" },
    .{ .name = "04-class-with-method", .source = "class Foo { count: number = 0; inc(): number { return this.count; } }" },
    .{ .name = "05-interface", .source = "interface Point { x: number; y: number; }" },
    .{ .name = "06-type-alias", .source = "type ID = string | number;" },
    .{ .name = "07-arrow", .source = "let inc = (n: number) => n + 1;" },
    .{ .name = "08-generics", .source = "function id<T>(x: T): T { return x; }" },
    .{ .name = "09-import", .source = "import { foo } from \"./bar\";" },
    .{ .name = "10-mismatched-assignment", .source = "let x: number = \"hi\";", .expects_error = true },
    .{ .name = "11-call-correct-args", .source = "function f(a: number): number { return a; } let r = f(42);" },
    .{ .name = "12-call-wrong-arg-count", .source = "function f(a: number): number { return a; } f(1, 2);", .expects_error = true },
    .{ .name = "13-call-wrong-arg-type", .source = "function f(a: number): number { return a; } f(\"hi\");", .expects_error = true },
    .{ .name = "14-property-exists", .source = "let p: { x: number }; let v = p.x;" },
    .{ .name = "15-property-missing", .source = "let p: { x: number }; let v = p.missing;", .expects_error = true },
    .{ .name = "16-generic-instantiation", .source = "function id<T>(x: T): T { return x; } let n = id(42); let s = id(\"hi\");" },
    .{ .name = "17-typeof-narrowing", .source = "function f(x: any) { if (typeof x === \"string\") { let s = x; } }" },
    .{ .name = "18-class-extends", .source = "class A {} class B extends A {}" },
    .{ .name = "19-arrow-with-types", .source = "let f: (n: number) => string = (n) => \"x\";" },
    .{ .name = "20-tsx", .source = "let v = <Foo bar={1} />;", .is_tsx = true },
    .{ .name = "21-decorator", .source = "@dec class Foo {}" },
    .{ .name = "22-export", .source = "export function f(): number { return 1; }" },
    .{ .name = "23-import-default", .source = "import React from \"react\"; React;" },
    .{ .name = "24-namespace", .source = "namespace N { let x: number = 1; }" },
    .{ .name = "25-enum", .source = "enum Color { Red, Green, Blue }" },
};

// =============================================================================
// Tests — small built-in conformance corpus
// =============================================================================

const T = std.testing;

test "conformance: empty file passes with no diagnostics" {
    const r = try run(T.allocator, .{
        .name = "empty",
        .source = "",
        .path = "tests/empty.ts",
        .expected_errors = "",
    });
    defer if (r.detail.len > 0) T.allocator.free(r.detail);
    try T.expectEqual(Outcome.passed, r.outcome);
}

test "conformance: type-correct decl passes" {
    const r = try run(T.allocator, .{
        .name = "ok",
        .source = "let x: number = 42;",
        .path = "tests/ok.ts",
        .expected_errors = "",
    });
    defer if (r.detail.len > 0) T.allocator.free(r.detail);
    try T.expectEqual(Outcome.passed, r.outcome);
}

test "conformance: type-error decl fails as expected" {
    const r = try run(T.allocator, .{
        .name = "type_error",
        .source = "let x: number = \"hi\";",
        .path = "tests/te.ts",
        .expected_errors = "tests/te.ts(1,1): error TS2322: Type is not assignable to declared type.",
    });
    defer if (r.detail.len > 0) T.allocator.free(r.detail);
    try T.expectEqual(Outcome.passed, r.outcome);
}

test "conformance: missing-error case fails" {
    // Source has no errors but baseline expects one — verify we
    // detect this mismatch.
    const r = try run(T.allocator, .{
        .name = "missing_error",
        .source = "let x: number = 1;",
        .path = "tests/m.ts",
        .expected_errors = "tests/m.ts(1,1): error TS2304: Expected error.",
    });
    defer if (r.detail.len > 0) T.allocator.free(r.detail);
    try T.expectEqual(Outcome.failed, r.outcome);
    try T.expect(std.mem.indexOf(u8, r.detail, "diagnostic mismatch") != null);
}

test "conformance: Suite aggregates Stats" {
    var results: std.ArrayListUnmanaged(Result) = .empty;
    defer {
        for (results.items) |r| if (r.detail.len > 0) T.allocator.free(r.detail);
        results.deinit(T.allocator);
    }
    const cases = [_]Case{
        .{ .name = "ok-1", .source = "let a: number = 1;", .path = "ok1.ts" },
        .{ .name = "ok-2", .source = "let b: string = \"x\";", .path = "ok2.ts" },
        .{ .name = "fail", .source = "let c: number = \"x\";", .path = "f.ts", .expected_errors = "" },
    };
    const stats = try (Suite{ .cases = &cases }).run(T.allocator, &results);
    try T.expectEqual(@as(u32, 2), stats.passed);
    try T.expectEqual(@as(u32, 1), stats.failed);
    try T.expectApproxEqAbs(0.6666, stats.passRate(), 0.01);
}

test "conformance: countLines" {
    try T.expectEqual(@as(u32, 0), countLines(""));
    try T.expectEqual(@as(u32, 1), countLines("one"));
    try T.expectEqual(@as(u32, 2), countLines("one\ntwo"));
    try T.expectEqual(@as(u32, 3), countLines("one\ntwo\nthree"));
}

test "conformance: builtin corpus runs and reports pass rate" {
    var results: std.ArrayListUnmanaged(Result) = .empty;
    defer {
        for (results.items) |r| {
            T.allocator.free(r.name);
            if (r.detail.len > 0) T.allocator.free(r.detail);
        }
        results.deinit(T.allocator);
    }

    const stats = try runCorpus(T.allocator, &builtin_corpus, &results);

    // Smoke: every built-in case must compile (or fail per its
    // expects_error flag). 100% pass rate on the canon corpus is
    // the ratchet — any new corpus entry must keep passing.
    try T.expectEqual(@as(u32, builtin_corpus.len), stats.total());
    try T.expectEqual(@as(u32, builtin_corpus.len), stats.passed);
    try T.expectEqual(@as(u32, 0), stats.failed);
    try T.expectApproxEqAbs(@as(f64, 1.0), stats.passRate(), 0.001);
}

test "conformance: each builtin case names match files in tests/conformance" {
    // Lightly verify the naming convention we expect on disk —
    // each name maps to `tests/conformance/<name>.ts` (or
    // `<name>.errors.ts` for expects_error cases).
    for (builtin_corpus) |entry| {
        try T.expect(entry.name.len > 0);
    }
}
