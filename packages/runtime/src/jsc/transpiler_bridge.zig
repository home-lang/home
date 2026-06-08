// Standalone TS/JS -> CommonJS transpile, the basis for loading `.ts`/`.tsx`/
// `.mts`/`.cts` (and ESM-syntax) files through the realm's CommonJS require().
//
// This drives Home's own parser + js_printer.printCommonJS directly (no bundler
// Transpiler / resolver / Fs), mirroring the recipe in
// `src/bundler/transpiler.zig` (parse via `Parser`, print via `printCommonJS`
// with a `Symbol.Map` built from `ast.symbols`). Type annotations are stripped
// and `import`/`export` are lowered to CommonJS by the CJS printer.
//
// LIMITATION: `opts.macro_context` defaults to `undefined`, so sources that use
// Bun macro imports are out of scope here (no_macros path); normal TS/JS/ESM is
// fine. A JSC-callable wrapper + loader wiring lands on top of this.

const std = @import("std");
const bun = @import("bun");
const js_parser = bun.js_parser;
const js_printer = bun.js_printer;
const js_ast = bun.ast;
const logger = bun.logger;
const options = @import("../bundler/options.zig");
const Define = @import("../bundler/defines.zig").Define;

pub const TranspileError = error{ ParseFailed, PrintFailed, UnsupportedEsm, UnsupportedImports };

/// Pick the parser loader from a file path's extension.
pub fn loaderForPath(path: []const u8) options.Loader {
    if (std.mem.endsWith(u8, path, ".tsx")) return .tsx;
    if (std.mem.endsWith(u8, path, ".jsx")) return .jsx;
    if (std.mem.endsWith(u8, path, ".ts") or std.mem.endsWith(u8, path, ".mts") or std.mem.endsWith(u8, path, ".cts")) return .ts;
    return .js;
}

/// Transpile `source_code` (named `path`, used for diagnostics + loader choice)
/// to CommonJS JavaScript. Caller owns the returned slice.
pub fn transpileToCjs(allocator: std.mem.Allocator, source_code: []const u8, path: []const u8) ![]u8 {
    // The parser allocates AST nodes out of thread-local stores; create() is
    // idempotent and reset() recycles them when we're done.
    js_ast.Expr.Data.Store.create();
    js_ast.Stmt.Data.Store.create();
    defer {
        js_ast.Expr.Data.Store.reset();
        js_ast.Stmt.Data.Store.reset();
    }

    // All parse/print scratch lives in an arena freed on return; only the final
    // CJS text is duped into the caller's allocator.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var log = logger.Log.init(a);

    const source = logger.Source.initPathString(path, source_code);
    const loader = loaderForPath(path);

    var opts = js_parser.Parser.Options.init(.{}, loader);
    opts.transform_only = true;
    opts.features.top_level_await = true;
    opts.features.no_macros = true;

    const defines = try Define.init(a, null, null, false, false);

    var parser = js_parser.Parser.init(opts, &log, &source, defines, a) catch
        return TranspileError.ParseFailed;
    const result = parser.parse() catch return TranspileError.ParseFailed;
    const ast = switch (result) {
        .ast => |parsed| parsed,
        else => return TranspileError.ParseFailed,
    };

    // This standalone parse+print path faithfully strips TS types from a
    // self-contained module, but it is NOT a full transpiler: the CJS printer
    // needs the bundler's runtime-import + import-record resolution to lower
    // ESM `export`/`import` (it would crash) and even to emit plain `require()`
    // calls (it silently drops them). So bail cleanly on both rather than
    // produce wrong output. Lowering those needs the bundler Transpiler — the
    // next step. (Tracked in memory: project_jsc_test_target_build.)
    switch (ast.exports_kind) {
        .esm, .esm_with_dynamic_fallback => return TranspileError.UnsupportedEsm,
        else => {},
    }
    if (ast.import_records.len > 0) return TranspileError.UnsupportedImports;

    const symbols = js_ast.Symbol.NestedList.fromBorrowedSliceDangerous(&.{ast.symbols});

    const buffer_writer = js_printer.BufferWriter.init(a);
    var printer = js_printer.BufferPrinter.init(buffer_writer);

    _ = js_printer.printCommonJS(
        *js_printer.BufferPrinter,
        &printer,
        ast,
        js_ast.Symbol.Map.initList(symbols),
        &source,
        false,
        .{
            .allocator = a,
            .bundling = false,
            .runtime_imports = ast.runtime_imports,
            .require_ref = ast.require_ref,
            .transform_only = true,
            .hmr_ref = ast.wrapper_ref,
            .mangled_props = null,
        },
        false,
    ) catch return TranspileError.PrintFailed;

    return allocator.dupe(u8, printer.ctx.getWritten());
}

test "transpileToCjs strips TS types from a CommonJS module" {
    const src =
        "const x: number = 41;\n" ++
        "function add(a: number, b: number): number { return a + b; }\n" ++
        "interface Ignored { z: string }\n" ++
        "module.exports = { y: add(x, 1) };\n";
    const out = try transpileToCjs(std.testing.allocator, src, "/virtual/mod.ts");
    defer std.testing.allocator.free(out);

    // Types gone, runtime code preserved.
    try std.testing.expect(std.mem.indexOf(u8, out, ": number") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "interface") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "41") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "module.exports") != null);
}

test "transpileToCjs strips types preserving plain CommonJS exports" {
    const src =
        "const greeting: string = 'hi';\n" ++
        "type Unused = { a: number };\n" ++
        "exports.greet = (name: string): string => greeting + ' ' + name;\n";
    const out = try transpileToCjs(std.testing.allocator, src, "/virtual/greet.ts");
    defer std.testing.allocator.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, ": string") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "type Unused") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "exports.greet") != null);
}

test "transpileToCjs bails cleanly on ESM and on import/require (need bundler)" {
    const esm =
        "export const z = 5;\n" ++
        "export default function () { return z; }\n";
    try std.testing.expectError(TranspileError.UnsupportedEsm, transpileToCjs(std.testing.allocator, esm, "/virtual/esm.ts"));

    // require() creates an import record the standalone printer can't emit yet.
    const cjs_req = "const p = require('node:path'); module.exports = p;\n";
    try std.testing.expectError(TranspileError.UnsupportedImports, transpileToCjs(std.testing.allocator, cjs_req, "/virtual/req.ts"));
}
