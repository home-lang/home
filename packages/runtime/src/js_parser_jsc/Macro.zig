const std = @import("std");
const bun = @import("bun");

const string = []const u8;
const logger = bun.logger;
const strings = bun.strings;
const Transpiler = bun.Transpiler;
const js_ast = bun.ast;
const Expr = js_ast.Expr;

const MacroRemap = @import("../resolver/package_json.zig").MacroMap;
const MacroRemapEntry = @import("../resolver/package_json.zig").MacroImportReplacementMap;

pub const namespace: string = "macro";
pub const namespaceWithColon: string = namespace ++ ":";

pub fn isMacroPath(str: string) bool {
    return strings.hasPrefixComptime(str, namespaceWithColon);
}

pub const MacroContext = struct {
    remap: MacroRemap,
    javascript_object: bun.jsc.JSValue = bun.jsc.JSValue.zero,

    pub fn init(transpiler: *Transpiler) MacroContext {
        return .{
            .remap = transpiler.options.macro_remap,
        };
    }

    pub fn getRemap(this: MacroContext, path: string) ?MacroRemapEntry {
        if (this.remap.count() == 0) return null;
        return this.remap.get(path);
    }

    pub fn call(
        _: *MacroContext,
        _: string,
        _: string,
        _: *logger.Log,
        _: *const logger.Source,
        _: logger.Range,
        caller: Expr,
        _: string,
    ) anyerror!Expr {
        return caller;
    }
};

pub const MacroResult = struct {
    import_statements: []js_ast.S.Import = &[_]js_ast.S.Import{},
    replacement: Expr,
};

comptime {
    _ = std;
}
