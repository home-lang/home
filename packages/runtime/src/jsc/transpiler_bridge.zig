// TS/JS/ESM -> CommonJS transpile for the realm's CommonJS require(): the basis
// for loading `.ts`/`.tsx`/`.mts`/`.cts`/`.mjs` (and ESM-syntax) files.
//
// Unlike a bare parse+printCommonJS (which drops require() calls and crashes on
// ESM exports because it lacks runtime-import + import-record resolution), this
// drives Home's full bundler `Transpiler` in transform-only mode — the same
// engine behind `Bun.Transpiler`. The transpiler is created once and reused
// (its AST node stores are reset between files); it is single-threaded, matching
// the realm. Mirrors the recipe in `src/runtime/api/JSTranspiler.zig`.

const std = @import("std");
const bun = @import("bun");
const Transpiler = bun.transpiler.Transpiler;
const JSPrinter = bun.js_printer;
const logger = bun.logger;
const api = bun.schema.api;
const options = @import("../bundler/options.zig");
const Loader = options.Loader;
const MacroMap = @import("../resolver/package_json.zig").MacroMap;

pub const TranspileError = error{ InitFailed, ParseFailed, PrintFailed, UnsupportedEsm };

/// Pick the parser loader from a file path's extension.
pub fn loaderForPath(path: []const u8) Loader {
    if (std.mem.endsWith(u8, path, ".tsx")) return .tsx;
    if (std.mem.endsWith(u8, path, ".jsx")) return .jsx;
    if (std.mem.endsWith(u8, path, ".ts") or std.mem.endsWith(u8, path, ".mts") or std.mem.endsWith(u8, path, ".cts")) return .ts;
    return .js;
}

// Cached transform-only transpiler + its log, created lazily on first use.
var g_log: logger.Log = undefined;
var g_transpiler: ?Transpiler = null;

fn getTranspiler() !*Transpiler {
    if (g_transpiler == null) {
        g_log = logger.Log.init(bun.default_allocator);
        var opts = std.mem.zeroes(api.TransformOptions);
        opts.disable_hmr = true;
        opts.target = api.Target.browser;
        var t = Transpiler.init(bun.default_allocator, &g_log, opts, null) catch
            return TranspileError.InitFailed;
        t.options.no_macros = true;
        t.configureLinkerWithAutoJSX(false);
        t.options.env.behavior = .disable;
        t.configureDefines() catch return TranspileError.InitFailed;
        g_transpiler = t;
    }
    return &g_transpiler.?;
}

/// Transpile `source_code` (named `path`, used for diagnostics + loader choice)
/// to CommonJS JavaScript. Caller owns the returned slice.
pub fn transpileToCjs(allocator: std.mem.Allocator, source_code: []const u8, path: []const u8) ![]u8 {
    const transpiler = try getTranspiler();
    transpiler.resetStore();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const source = logger.Source.initPathString(path, source_code);
    const loader = loaderForPath(path);

    const parse_options = Transpiler.ParseOptions{
        .allocator = a,
        .macro_remappings = MacroMap{},
        .dirname_fd = .invalid,
        .file_descriptor = null,
        .loader = loader,
        .jsx = transpiler.options.jsx,
        .path = source.path,
        .virtual_source = &source,
    };

    const parse_result = transpiler.parse(parse_options, null) orelse
        return TranspileError.ParseFailed;
    if (parse_result.empty) return allocator.dupe(u8, "");

    // Bail only on ACTUAL ESM syntax — a real `export` keyword (TS-only syntax
    // excluded) or an `import` statement (kind .stmt; require() is .require).
    // `exports_kind` defaults to .esm for ambiguous no-marker files, so it would
    // wrongly reject plain scripts like `const x = 1; console.log(x)`. Lowering
    // real ESM->CJS needs the bundler link stage; until then it's delegated.
    if (parse_result.ast.export_keyword.len > 0) return TranspileError.UnsupportedEsm;
    for (parse_result.ast.import_records.slice()) |rec| {
        if (rec.kind == .stmt) return TranspileError.UnsupportedEsm;
    }

    var buffer_writer = JSPrinter.BufferWriter.init(a);
    buffer_writer.buffer.list.ensureTotalCapacity(a, 512) catch {};
    buffer_writer.reset();
    var printer = JSPrinter.BufferPrinter.init(buffer_writer);

    // .esm_ascii (not .cjs): for a CommonJS AST this prints the JS verbatim
    // (type-stripped), preserving require()/module.exports. The .cjs format
    // assumes a bundler require_ref and would drop bare require() calls.
    _ = transpiler.print(parse_result, @TypeOf(&printer), &printer, .esm_ascii) catch
        return TranspileError.PrintFailed;

    return allocator.dupe(u8, printer.ctx.getWritten());
}

test "transpileToCjs strips TS types from a self-contained module" {
    const src =
        "const x: number = 41;\n" ++
        "function add(a: number, b: number): number { return a + b; }\n" ++
        "interface Ignored { z: string }\n" ++
        "module.exports = { y: add(x, 1) };\n";
    const out = try transpileToCjs(std.testing.allocator, src, "/virtual/mod.ts");
    defer std.testing.allocator.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, ": number") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "interface") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "41") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "module.exports") != null);
}

test "transpileToCjs preserves require() calls (full transpiler)" {
    const src =
        "const path = require('node:path');\n" ++
        "const base: string = path.basename('/a/b.ts');\n" ++
        "module.exports = base;\n";
    const out = try transpileToCjs(std.testing.allocator, src, "/virtual/usespath.ts");
    defer std.testing.allocator.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, ": string") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "require") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "node:path") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "module.exports") != null);
}

test "transpileToCjs bails on ESM (needs bundler link stage)" {
    const src =
        "export const joined = 1;\n" ++
        "export default 7;\n";
    try std.testing.expectError(TranspileError.UnsupportedEsm, transpileToCjs(std.testing.allocator, src, "/virtual/esm.ts"));
}
