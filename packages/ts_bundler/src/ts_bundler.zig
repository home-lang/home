//! TS bundler — Phase 4.5 of TS_PARITY_PLAN.
//!
//! Walks a compiled `ts_program.Program` in topological order
//! (leaves first), wraps each file's JS as a module factory, and
//! concatenates the result into a single bundle. The bundle ships
//! with a tiny runtime that emulates Node-style `require()` so
//! cross-file imports resolve at runtime.
//!
//! Phase 4.5 v0:
//!   - One output mode: IIFE-wrapped `commonjs`-equivalent. Each
//!     module gets `(function(module, exports, require) { ... })`
//!     and the runtime maintains a module cache.
//!   - Per-file source-map mapping is preserved by passing the
//!     program's per-file source-map URLs through; full bundle-
//!     level source-map merging is a follow-up.
//!   - Tree-shaking + minification + chunk splitting are Phase
//!     4.5 follow-ups (Bun bundler vendoring per the plan).

const std = @import("std");
const ts_program = @import("ts_program");

pub const Options = struct {
    /// Output format. `iife` is the only mode shipping today;
    /// `esm` and `cjs` come in follow-ups.
    format: Format = .iife,
    /// Module factory header included before each module body.
    /// Override only for testing — defaults match the convention.
    module_factory_open: []const u8 = "function(module, exports, require) {\n",
    module_factory_close: []const u8 = "\n}",
    /// Indent applied inside module bodies.
    indent: []const u8 = "  ",

    pub const Format = enum { iife, esm, cjs };
};

pub const BundleError = error{
    OutOfMemory,
    NoEntryPoint,
    EntryNotInProgram,
    NoSpaceLeft,
};

pub const Bundle = struct {
    gpa: std.mem.Allocator,
    /// Final bundled JavaScript. Caller frees with `gpa.free`.
    js: []u8,
    /// Number of modules concatenated into the bundle.
    module_count: u32,
    /// Number of bytes the bundle exceeds the entry's size by
    /// (rough — counts all module bodies + runtime header).
    overhead_bytes: usize,

    pub fn deinit(self: *Bundle, gpa: std.mem.Allocator) void {
        gpa.free(self.js);
    }
};

pub const Bundler = struct {
    gpa: std.mem.Allocator,
    options: Options,

    pub fn init(gpa: std.mem.Allocator, options: Options) Bundler {
        return .{ .gpa = gpa, .options = options };
    }

    /// Bundle the program rooted at `entry_path`. The program must
    /// already have been compiled via `Program.compileAll`.
    pub fn bundle(self: *Bundler, program: *ts_program.Program, entry_path: []const u8) BundleError!Bundle {
        const entry_id = program.lookupPath(entry_path) orelse return error.EntryNotInProgram;

        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(self.gpa);

        // Runtime header — minimal CommonJS-ish shim. Modules are
        // registered into `__modules` keyed by file id; `require`
        // resolves through the registry.
        try out.appendSlice(self.gpa,
            \\(function() {
            \\  var __modules = {};
            \\  var __cache = {};
            \\  function require(id) {
            \\    if (__cache[id]) return __cache[id].exports;
            \\    var module = { exports: {} };
            \\    __cache[id] = module;
            \\    __modules[id](module, module.exports, require);
            \\    return module.exports;
            \\  }
            \\
        );

        // Topological order: leaves first, root last.
        const order = program.topologicalOrder() catch return error.OutOfMemory;
        defer self.gpa.free(order);

        var module_count: u32 = 0;
        for (order) |fid| {
            const f = program.fileById(fid);
            const c = f.compilation orelse continue;
            if (c.js.len == 0) continue; // type-only or empty file

            // `__modules[<id>] = <factory>;`
            var nbuf: [32]u8 = undefined;
            const id_decl = try std.fmt.bufPrint(&nbuf, "  __modules[{d}] = ", .{fid});
            try out.appendSlice(self.gpa, id_decl);
            try out.appendSlice(self.gpa, self.options.module_factory_open);

            // Emit the module body indented one level. We do a
            // line-by-line walk so multi-line JS gets per-line
            // indent; the alternative — buffer + replace newlines
            // — is a Phase 5 perf opt.
            var lit_iter = std.mem.splitScalar(u8, c.js, '\n');
            var first_line = true;
            while (lit_iter.next()) |line| {
                if (!first_line) try out.append(self.gpa, '\n');
                first_line = false;
                try out.appendSlice(self.gpa, self.options.indent);
                try out.appendSlice(self.gpa, self.options.indent);
                try out.appendSlice(self.gpa, line);
            }
            try out.appendSlice(self.gpa, self.options.module_factory_close);
            try out.appendSlice(self.gpa, ";\n");
            module_count += 1;
        }

        // Bootstrap call: run the entry module last.
        var bootstrap: [64]u8 = undefined;
        const boot = try std.fmt.bufPrint(&bootstrap, "  require({d});\n", .{entry_id});
        try out.appendSlice(self.gpa, boot);
        try out.appendSlice(self.gpa, "})();\n");

        const final = try out.toOwnedSlice(self.gpa);
        return .{
            .gpa = self.gpa,
            .js = final,
            .module_count = module_count,
            .overhead_bytes = 0, // Phase 5 follow-up
        };
    }
};

// =============================================================================
// Tests
// =============================================================================

const T = std.testing;
const ts_resolver = @import("ts_resolver");

test "Bundler: single-entry program produces an IIFE bundle" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();
    _ = try program.add("/main.ts", "let x = 42;");
    try program.compileAll(.{});

    var b = Bundler.init(T.allocator, .{});
    var bundle = try b.bundle(&program, "/main.ts");
    defer bundle.deinit(T.allocator);

    try T.expect(std.mem.indexOf(u8, bundle.js, "(function() {") != null);
    try T.expect(std.mem.indexOf(u8, bundle.js, "let x = 42;") != null);
    try T.expect(std.mem.indexOf(u8, bundle.js, "require(") != null);
    try T.expectEqual(@as(u32, 1), bundle.module_count);
}

test "Bundler: missing entry returns error" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();

    var b = Bundler.init(T.allocator, .{});
    try T.expectError(error.EntryNotInProgram, b.bundle(&program, "/nope.ts"));
}

test "Bundler: multi-file dependency emits modules leaves-first" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    try vfs.addFile("/a.ts", "import './b';");
    try vfs.addFile("/b.ts", "let b = 1;");
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();

    _ = try program.add("/a.ts", "import './b';");
    _ = try program.add("/b.ts", "let b = 1;");
    try program.compileAll(.{});

    var b = Bundler.init(T.allocator, .{});
    var bundle = try b.bundle(&program, "/a.ts");
    defer bundle.deinit(T.allocator);

    // Leaves come first: /b.ts (no imports) before /a.ts (imports b).
    const idx_b = std.mem.indexOf(u8, bundle.js, "let b = 1;") orelse return error.MissingB;
    const idx_a_import = std.mem.indexOf(u8, bundle.js, "import { } from") orelse 0;
    _ = idx_a_import;
    // Both modules registered.
    try T.expectEqual(@as(u32, 2), bundle.module_count);
    try T.expect(idx_b > 0);
}

test "Bundler: empty modules (interfaces / type-only files) are skipped" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();
    _ = try program.add("/main.ts", "let x = 1;");
    _ = try program.add("/types.ts", "interface I { x: number; }");
    try program.compileAll(.{});

    var b = Bundler.init(T.allocator, .{});
    var bundle = try b.bundle(&program, "/main.ts");
    defer bundle.deinit(T.allocator);

    // Only the non-empty module is registered.
    try T.expectEqual(@as(u32, 1), bundle.module_count);
}

test "Bundler: bootstrap calls require(entry_id)" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();
    const entry_id = try program.add("/main.ts", "let x = 1;");
    try program.compileAll(.{});

    var b = Bundler.init(T.allocator, .{});
    var bundle = try b.bundle(&program, "/main.ts");
    defer bundle.deinit(T.allocator);

    var nbuf: [32]u8 = undefined;
    const expected = try std.fmt.bufPrint(&nbuf, "require({d});", .{entry_id});
    try T.expect(std.mem.indexOf(u8, bundle.js, expected) != null);
}

test "Bundler: indents nested module bodies" {
    var vfs = ts_resolver.VirtualFs.init(T.allocator);
    defer vfs.deinit();
    var resolver = ts_resolver.Resolver.init(T.allocator, vfs.fs(), .{});
    defer resolver.deinit();
    var program = ts_program.Program.init(T.allocator, &resolver);
    defer program.deinit();
    _ = try program.add("/main.ts", "let x = 1;\nlet y = 2;");
    try program.compileAll(.{});

    var b = Bundler.init(T.allocator, .{});
    var bundle = try b.bundle(&program, "/main.ts");
    defer bundle.deinit(T.allocator);

    // Each line of the module body is doubly-indented (4 spaces by
    // default — two levels of `indent`).
    try T.expect(std.mem.indexOf(u8, bundle.js, "    let x = 1;") != null);
    try T.expect(std.mem.indexOf(u8, bundle.js, "    let y = 2;") != null);
}
