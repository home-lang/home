// Ported from bun/src/codegen/process_windows_translate_c.zig at upstream SHA
// 4982b91e3702094330f3be3883354c52b8c01323. MIT — see ../cli/LICENSE.bun.md.
// The transformation is unchanged; the executable entry point uses Zig 0.17's
// explicit process, file, and writer APIs.

// translate-c is unable to translate the unsuffixed windows functions
// like `SetCurrentDirectory` since they are defined with an odd macro
// that translate-c doesn't handle.
//
//     #define SetCurrentDirectory __MINGW_NAME_AW(SetCurrentDirectory)
//
// In these cases, it's better to just reference the underlying function
// directly: SetCurrentDirectoryW. To make the error better, a post
// processing step is applied to the translate-c file.

const symbol_replacements = std.StaticStringMap([]const u8).initComptime(&.{
    &.{ "NTSTATUS", "@import(\"std\").os.windows.NTSTATUS" },
    &.{ "HANDLE", "@import(\"std\").os.windows.HANDLE" },
    &.{ "PHANDLE", "*HANDLE" },
});

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) @panic("missing input argument");
    if (args.len < 3) @panic("missing output argument");

    const gpa = init.gpa;
    const in = try std.Io.Dir.cwd().readFileAllocOptions(
        init.io,
        args[1],
        gpa,
        .limited(std.math.maxInt(u32)),
        .of(u8),
        0,
    );
    defer gpa.free(in);

    var out = try std.Io.Writer.Allocating.initCapacity(gpa, in.len);
    defer out.deinit();
    try transform(in, &out.writer);

    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = args[2],
        .data = out.written(),
    });
}

fn transform(in: [:0]const u8, w: anytype) !void {
    var i: usize = 0;
    while (mem.indexOfPos(u8, in, i, "pub const ")) |pub_i| {
        var tokenizer = std.zig.Tokenizer.init(in);
        tokenizer.index = pub_i + "pub const ".len;
        const symbol_name_token = tokenizer.next();
        assert(symbol_name_token.tag == .identifier);
        const symbol_name = in[symbol_name_token.loc.start..symbol_name_token.loc.end];
        try w.writeAll(in[i..symbol_name_token.loc.end]);
        i = symbol_name_token.loc.end;
        var end_of_line = mem.indexOfScalarPos(u8, in, symbol_name_token.loc.end, '\n') orelse in.len;
        if (in[end_of_line - 1] != ';') {
            // skip multiline decl
            try w.writeAll(in[i..end_of_line]);
            i = end_of_line;
            continue;
        }
        end_of_line += 1; // include the \n
        if (symbol_replacements.get(symbol_name)) |replace| {
            try w.print(" = {s};\n", .{replace});
        } else if (mem.startsWith(u8, in[i..], " = __MINGW_NAME_AW(")) {
            try w.print(" = @compileError(\"Use '{s}W' instead.\");\n", .{symbol_name});
        } else {
            try w.writeAll(in[i..end_of_line]);
        }
        i = end_of_line;
    }
    try w.writeAll(in[i..]);
}

fn assert(cond: bool) void {
    if (!cond) @panic("unhandled");
}

test "translate-c declarations use explicit Windows symbols" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    try transform(@embedFile("process_windows_translate_c.input.zig"), &out.writer);
    try std.testing.expectEqualStrings(@embedFile("process_windows_translate_c.expected.zig"), out.written());
}

const std = @import("std");
const mem = std.mem;
