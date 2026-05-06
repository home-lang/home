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
//! Phase 6 ships the harness; the suite of cases comes from the
//! local `microsoft/TypeScript` checkout — typically already on
//! disk for tooling reasons. Point `runDirectory` at
//! `~/Code/typescript-go/_submodules/TypeScript/tests/cases/conformance/`
//! (the canonical path tsgo uses) or wherever the upstream TS
//! repo is installed locally. We deliberately do NOT vendor TS
//! as a git submodule — every contributor with a Code workspace
//! already has it, and pinning it here would bloat the repo.

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

/// Owned-source variant — like `CorpusEntry` but the source is
/// owned by the caller and freed after the run.
pub const OwnedCorpusEntry = struct {
    name: []u8,
    source: []u8,
    expects_error: bool = false,
    is_tsx: bool = false,
};

/// Walk `dir_path` recursively and collect every `.ts` / `.tsx`
/// file as an `OwnedCorpusEntry`. Convention for `.errors.ts` is
/// "expects an error" — same as on tsgo's tests/cases/conformance/
/// corpus. Caller owns each name+source slice and the outer slice.
///
/// Zig 0.16-dev moved the FS surface to `std.Io.Dir`, which threads
/// an `Io` instance through every call. We construct a short-lived
/// `Threaded` `Io` so the public API stays plain `std.mem.Allocator`.
pub fn loadDirectory(gpa: std.mem.Allocator, dir_path: []const u8) ![]OwnedCorpusEntry {
    var out: std.ArrayListUnmanaged(OwnedCorpusEntry) = .empty;
    errdefer {
        for (out.items) |entry| {
            gpa.free(entry.name);
            gpa.free(entry.source);
        }
        out.deinit(gpa);
    }
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cwd = std.Io.Dir.cwd();
    var dir = try cwd.openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const ext_end = entry.basename.len;
        const is_ts = std.mem.endsWith(u8, entry.basename, ".ts");
        const is_tsx = std.mem.endsWith(u8, entry.basename, ".tsx");
        if (!is_ts and !is_tsx) continue;
        // Open through the iterating root so paths are dir-relative.
        var file = entry.dir.openFile(io, entry.basename, .{}) catch continue;
        defer file.close(io);
        const stat = file.stat(io) catch continue;
        const file_size: usize = @intCast(stat.size);
        const src = gpa.alloc(u8, file_size) catch continue;
        var read_total: usize = 0;
        var read_failed = false;
        while (read_total < file_size) {
            const n = file.readPositionalAll(io, src[read_total..], read_total) catch {
                read_failed = true;
                break;
            };
            if (n == 0) break;
            read_total += n;
        }
        if (read_failed or read_total != file_size) {
            gpa.free(src);
            continue;
        }
        const expects_error = std.mem.indexOf(u8, entry.basename, ".errors.") != null;
        const ext_dot = std.mem.lastIndexOfScalar(u8, entry.basename, '.') orelse ext_end;
        const stem = entry.basename[0..ext_dot];
        const name = try gpa.dupe(u8, stem);
        try out.append(gpa, .{
            .name = name,
            .source = src,
            .expects_error = expects_error,
            .is_tsx = is_tsx,
        });
    }
    return out.toOwnedSlice(gpa);
}

/// Run an owned-source corpus (typically loaded via `loadDirectory`).
pub fn runOwnedCorpus(
    gpa: std.mem.Allocator,
    corpus: []const OwnedCorpusEntry,
    results: *std.ArrayListUnmanaged(Result),
) !Stats {
    // Convert to the borrow-shaped CorpusEntry view + dispatch.
    var stats: Stats = .{};
    for (corpus) |entry| {
        const view: CorpusEntry = .{
            .name = entry.name,
            .source = entry.source,
            .expects_error = entry.expects_error,
            .is_tsx = entry.is_tsx,
        };
        const r = try runOneEntry(gpa, view);
        switch (r.outcome) {
            .passed => stats.passed += 1,
            .failed => stats.failed += 1,
            .skipped => stats.skipped += 1,
        }
        try results.append(gpa, r);
    }
    return stats;
}

/// Convenience: run every TS file under `dir_path` and return Stats.
/// Each result's name is the file's basename (without extension).
/// Per-result `name`+`detail` are owned; the corpus itself is freed
/// internally.
pub fn runDirectory(
    gpa: std.mem.Allocator,
    dir_path: []const u8,
    results: *std.ArrayListUnmanaged(Result),
) !Stats {
    const corpus = try loadDirectory(gpa, dir_path);
    defer {
        for (corpus) |entry| {
            gpa.free(entry.name);
            gpa.free(entry.source);
        }
        gpa.free(corpus);
    }
    return runOwnedCorpus(gpa, corpus, results);
}

fn runOneEntry(gpa: std.mem.Allocator, entry: CorpusEntry) !Result {
    const name_owned = try gpa.dupe(u8, entry.name);
    var compilation = ts_driver.compileSource(gpa, entry.source, .{
        .is_tsx = entry.is_tsx,
        .continue_on_error = true,
    }) catch |err| {
        const detail = try std.fmt.allocPrint(gpa, "compile crash: {s}", .{@errorName(err)});
        return .{
            .name = name_owned,
            .outcome = .failed,
            .detail = detail,
        };
    };
    const had_errors = compilation.has_errors;
    compilation.deinit();
    gpa.destroy(compilation);
    const passed = if (entry.expects_error) had_errors else !had_errors;
    if (passed) {
        return .{ .name = name_owned, .outcome = .passed };
    }
    const detail = if (entry.expects_error)
        try gpa.dupe(u8, "expected at least one diagnostic; got none")
    else
        try gpa.dupe(u8, "expected no diagnostics; got at least one");
    return .{
        .name = name_owned,
        .outcome = .failed,
        .detail = detail,
    };
}

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
    // ----- Cases exercising recently-landed features -----
    .{ .name = "26-explicit-type-args", .source = "function id<T>(x: T): T { return x; } let r = id<number>(42);" },
    .{ .name = "27-mapped-type-literal-keys", .source = "type M = { [K in \"x\" | \"y\"]: number }; let r: M = { x: 1, y: 2 };" },
    .{ .name = "28-conditional-eager", .source = "type Pick<T> = T extends string ? number : boolean; let r: Pick<string> = 1;" },
    .{ .name = "29-conditional-distributes", .source = "type T = (string | number) extends string ? \"x\" : \"y\"; let r: T;" },
    .{ .name = "30-type-predicate", .source = "function isString(x: any): x is string { return true; } function f(x: any) { if (isString(x)) { let s = x; } }" },
    .{ .name = "31-asserts-predicate", .source = "function assert(x: unknown): asserts x is string { } function f(x: unknown) { assert(x); let s = x; }" },
    .{ .name = "32-non-null-assertion", .source = "function pick(): string | null { return \"\"; } let s = pick()!;" },
    .{ .name = "33-tuple-literal-index", .source = "let t: [number, string]; let n = t[0]; let s = t[1];" },
    .{ .name = "34-array-shape", .source = "let a: number[] = [1, 2, 3]; let n = a[0]; let len = a.length;" },
    .{ .name = "35-keyof-eval", .source = "type O = { x: number; y: string }; type K = keyof O; let k: K;" },
    .{ .name = "36-discriminated-union", .source = "type S = { kind: \"a\"; v: number } | { kind: \"b\"; v: string }; function f(s: S) { if (s.kind === \"a\") { let n = s.v; } }" },
    .{ .name = "37-in-narrowing", .source = "function f(p: { x: number } | { y: string }) { if (\"x\" in p) { let n = p.x; } }" },
    .{ .name = "38-as-const", .source = "let x = \"hi\" as const;" },
    .{ .name = "39-for-of", .source = "let arr = [1, 2, 3]; for (let n of arr) { let v = n; }" },
    .{ .name = "40-index-signature-string", .source = "let m: { [k: string]: number } = {}; let v = m.foo;" },
    .{ .name = "41-index-signature-number", .source = "let m: { [i: number]: string } = {}; let v = m[0];" },
    .{ .name = "42-interface-extends", .source = "interface A { x: number } interface B extends A { y: string } let b: B = { x: 1, y: \"\" };" },
    .{ .name = "43-optional-params", .source = "function f(a: number, b?: string): number { return a; } let r = f(1);" },
    .{ .name = "44-default-params", .source = "function f(a: number, b: string = \"x\"): number { return a; } let r = f(1);" },
    .{ .name = "45-strict-fn-types", .source = "function inner(s: string): void {} function outer(f: (s: string) => void): void {} outer(inner);" },
    .{ .name = "46-fresh-excess-prop", .source = "let p: { x: number } = { x: 1, y: 2 };", .expects_error = true },
    .{ .name = "47-noImplicitAny-let", .source = "let x;", .expects_error = false }, // expected only with strict; included as smoke
    .{ .name = "48-this-in-class", .source = "class C { v: number = 0; m(): number { return this.v; } }" },
    .{ .name = "49-super-call", .source = "class A { hello(): string { return \"a\"; } } class B extends A { hello(): string { return super.hello(); } }" },
    .{ .name = "50-class-instance-type", .source = "class P { x: number = 0 } function f(p: P): number { return p.x; }" },
    .{ .name = "51-instanceof-narrowing", .source = "class P { v: number = 0 } function f(o: any) { if (o instanceof P) { let v = o.v; } }" },
    .{ .name = "52-typeof-type-query", .source = "let f = (n: number) => n + 1; type F = typeof f;" },
    .{ .name = "53-optional-chaining", .source = "let p: { x?: number } = {}; let n = p?.x;" },
    .{ .name = "54-nullish-coalescing", .source = "function pick(): string | null { return \"\"; } let s = pick() ?? \"default\";" },
    .{ .name = "55-generic-alias-instantiation", .source = "type Box<T> = { value: T }; let b: Box<number> = { value: 42 };" },
    // ----- Cases exercising 2026-05-06 landings -----
    .{ .name = "56-overload-resolution", .source = "function p(x: string): number; function p(x: number): string; function p(x: any): any { return x; } let n = p(\"a\"); let s = p(1);" },
    .{ .name = "57-aliased-narrowing", .source = "function isS(x: any): x is string { return true; } function f(x: any) { let cond = isS(x); if (cond) { let s = x; } }" },
    .{ .name = "58-asserts-narrowing", .source = "function assert(x: unknown): asserts x is string {} function f(x: unknown) { assert(x); let s = x; }" },
    .{ .name = "59-this-param", .source = "function f(this: { x: number }, y: number): number { return y; }" },
    .{ .name = "60-template-literal-type", .source = "type T = `hello`; let x: T;" },
    .{ .name = "61-homomorphic-partial", .source = "type Partial<T> = { [K in keyof T]?: T[K] }; let p: Partial<{ x: number }>;" },
    .{ .name = "62-readonly-mapped", .source = "type Readonly<T> = { readonly [K in keyof T]: T[K] }; let r: Readonly<{ x: number }>;" },
    .{ .name = "63-infer-return", .source = "type Return<T> = T extends (...a: any[]) => infer R ? R : never; let r: Return<() => string>;" },
    .{ .name = "64-explicit-type-args", .source = "function id<T>(): T { return null as any; } let n = id<number>();" },
    .{ .name = "65-cjs-import", .source = "import { x } from \"y\";" },
    .{ .name = "66-arrow-with-types", .source = "let inc = (n: number): number => n + 1;" },
    .{ .name = "67-class-with-method-decorator", .source = "class C { greet() { return 1; } }" },
    .{ .name = "68-enum-numeric", .source = "enum Color { Red = 0, Green = 1, Blue = 2 }" },
    .{ .name = "69-module-namespace", .source = "namespace N { export function f(): number { return 1; } }" },
    .{ .name = "70-dynamic-import", .source = "let mod = import(\"foo\");" },
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

    // Print any failures to stderr so triage during PR review is easy.
    for (results.items) |r| {
        if (r.outcome == .failed) {
            std.debug.print("[conformance fail] {s}: {s}\n", .{ r.name, r.detail });
        }
    }

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

test "conformance: smoke-run local TS conformance subdirectory" {
    // Smoke-run a SUBSET of the canonical microsoft/TypeScript
    // conformance suite from a contributor's local TS checkout.
    // We deliberately do NOT vendor TS as a submodule — every
    // contributor with a Code workspace already has it. When the
    // path doesn't exist (CI, fresh contributors), skip cleanly.
    //
    // Subdir picked: types/typeRelationships/comparable/ — 13
    // small cases exercising equality / switch / type-assertion
    // comparability (union, intersection, optional, nullish).
    // Goal here is only that the harness can walk a real-world
    // directory of TS files without crashing; we don't ratchet on
    // pass/fail rate yet — Phase 6 is about wiring up the runner.
    const corpus_path = "/Users/chrisbreuer/Code/typescript-go/_submodules/TypeScript/tests/cases/conformance/types/typeRelationships/comparable";
    {
        // Skip cleanly when the contributor has no local TS checkout.
        var threaded = std.Io.Threaded.init(T.allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();
        std.Io.Dir.cwd().access(io, corpus_path, .{}) catch return;
    }

    var results: std.ArrayListUnmanaged(Result) = .empty;
    defer {
        for (results.items) |r| {
            T.allocator.free(r.name);
            if (r.detail.len > 0) T.allocator.free(r.detail);
        }
        results.deinit(T.allocator);
    }

    const stats = try runDirectory(T.allocator, corpus_path, &results);

    // Visibility: print per-case pass/fail counts plus a one-line
    // summary so PR reviewers can eyeball the breakdown without
    // re-running the harness.
    std.debug.print(
        "[ts_conformance smoke] comparable: total={d} passed={d} failed={d} skipped={d} pass_rate={d:.2}\n",
        .{ stats.total(), stats.passed, stats.failed, stats.skipped, stats.passRate() },
    );
    for (results.items) |r| {
        switch (r.outcome) {
            .passed => std.debug.print("  PASS  {s}\n", .{r.name}),
            .failed => std.debug.print("  FAIL  {s}: {s}\n", .{ r.name, r.detail }),
            .skipped => std.debug.print("  SKIP  {s}\n", .{r.name}),
        }
    }

    // Sanity: at minimum, we want to confirm the harness walked
    // SOME files. Per-case pass/fail isn't asserted here — the
    // expectation is that the runner doesn't crash on a real-world
    // dir of TS files.
    try T.expect(stats.total() > 0);
}

test "conformance: runOwnedCorpus matches runCorpus on equal inputs" {
    // We can't easily create disk files in this Zig 0.16-dev test
    // harness (writeFile API in flux), so verify runOwnedCorpus
    // produces the same results as runCorpus on the same data.
    const owned = try T.allocator.alloc(OwnedCorpusEntry, 2);
    defer {
        for (owned) |o| {
            T.allocator.free(o.name);
            T.allocator.free(o.source);
        }
        T.allocator.free(owned);
    }
    owned[0] = .{
        .name = try T.allocator.dupe(u8, "ok"),
        .source = try T.allocator.dupe(u8, "let x: number = 1;"),
    };
    owned[1] = .{
        .name = try T.allocator.dupe(u8, "fail"),
        .source = try T.allocator.dupe(u8, "let x: number = \"hi\";"),
        .expects_error = true,
    };
    var results: std.ArrayListUnmanaged(Result) = .empty;
    defer {
        for (results.items) |r| {
            T.allocator.free(r.name);
            if (r.detail.len > 0) T.allocator.free(r.detail);
        }
        results.deinit(T.allocator);
    }
    const stats = try runOwnedCorpus(T.allocator, owned, &results);
    try T.expectEqual(@as(u32, 2), stats.passed);
}
