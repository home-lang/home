const std = @import("std");
const codegen = @import("codegen");

pub const Options = struct {
    entrypoint: []const u8,
    output_path: ?[]const u8 = null,
    outdir: ?[]const u8 = null,
    target: ?[]const u8 = null,
    format: []const u8 = "esm",
    sourcemap: ?[]const u8 = null,
    kernel_mode: bool = false,
    compile: bool = false,
    bytecode: bool = false,
    allow_type_errors: bool = false,
};

pub const ErrorKind = enum {
    missing_entrypoint,
    missing_value,
    empty_value,
    unknown_option,
    duplicate_entrypoint,
    unsupported_format,
    unsupported_target,
    unsupported_kernel_target,
    unsupported_sourcemap,
    output_path_conflicts_with_outdir,
    bytecode_requires_compile,
};

pub const ParseError = struct {
    kind: ErrorKind,
    argument: ?[]const u8 = null,
};

pub const ParseResult = union(enum) {
    ok: Options,
    err: ParseError,
};

pub const TypeCheckOutcome = enum {
    passed,
    fail,
    continue_by_request,
};

pub fn checkPassed(had_parse_errors: bool, type_check_passed: bool) bool {
    return !had_parse_errors and type_check_passed;
}

pub fn typeCheckOutcome(options: Options, type_check_passed: bool) TypeCheckOutcome {
    if (type_check_passed) return .passed;
    return if (options.allow_type_errors) .continue_by_request else .fail;
}

pub fn parse(args: []const [:0]const u8) ParseResult {
    var entrypoint: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;
    var outdir: ?[]const u8 = null;
    var target: ?[]const u8 = null;
    var format: []const u8 = "esm";
    var sourcemap: ?[]const u8 = null;
    var kernel_mode = false;
    var compile = false;
    var bytecode = false;
    var allow_type_errors = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--kernel")) {
            kernel_mode = true;
        } else if (std.mem.eql(u8, arg, "--compile")) {
            compile = true;
        } else if (std.mem.eql(u8, arg, "--bytecode")) {
            bytecode = true;
        } else if (std.mem.eql(u8, arg, "--allow-type-errors")) {
            allow_type_errors = true;
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--outfile")) {
            if (i + 1 >= args.len) return .{ .err = .{ .kind = .missing_value, .argument = arg } };
            i += 1;
            if (args[i].len == 0) return .{ .err = .{ .kind = .empty_value, .argument = arg } };
            output_path = args[i];
        } else if (std.mem.startsWith(u8, arg, "--outfile=")) {
            const value = arg["--outfile=".len..];
            if (value.len == 0) return .{ .err = .{ .kind = .empty_value, .argument = "--outfile" } };
            output_path = value;
        } else if (std.mem.startsWith(u8, arg, "-o") and arg.len > 2) {
            output_path = arg[2..];
        } else if (std.mem.eql(u8, arg, "--outdir")) {
            if (i + 1 >= args.len) return .{ .err = .{ .kind = .missing_value, .argument = arg } };
            i += 1;
            if (args[i].len == 0) return .{ .err = .{ .kind = .empty_value, .argument = arg } };
            outdir = args[i];
        } else if (std.mem.startsWith(u8, arg, "--outdir=")) {
            const value = arg["--outdir=".len..];
            if (value.len == 0) return .{ .err = .{ .kind = .empty_value, .argument = "--outdir" } };
            outdir = value;
        } else if (std.mem.eql(u8, arg, "--target")) {
            if (i + 1 >= args.len) return .{ .err = .{ .kind = .missing_value, .argument = arg } };
            i += 1;
            if (args[i].len == 0) return .{ .err = .{ .kind = .empty_value, .argument = arg } };
            target = args[i];
        } else if (std.mem.startsWith(u8, arg, "--target=")) {
            const value = arg["--target=".len..];
            if (value.len == 0) return .{ .err = .{ .kind = .empty_value, .argument = "--target" } };
            target = value;
        } else if (std.mem.eql(u8, arg, "--format")) {
            if (i + 1 >= args.len) return .{ .err = .{ .kind = .missing_value, .argument = arg } };
            i += 1;
            if (args[i].len == 0) return .{ .err = .{ .kind = .empty_value, .argument = arg } };
            format = args[i];
        } else if (std.mem.startsWith(u8, arg, "--format=")) {
            format = arg["--format=".len..];
            if (format.len == 0) return .{ .err = .{ .kind = .empty_value, .argument = "--format" } };
        } else if (std.mem.eql(u8, arg, "--sourcemap")) {
            sourcemap = "external";
        } else if (std.mem.startsWith(u8, arg, "--sourcemap=")) {
            const value = arg["--sourcemap=".len..];
            if (value.len == 0) return .{ .err = .{ .kind = .empty_value, .argument = "--sourcemap" } };
            sourcemap = value;
        } else if (arg.len > 0 and arg[0] == '-') {
            return .{ .err = .{ .kind = .unknown_option, .argument = arg } };
        } else if (entrypoint != null) {
            return .{ .err = .{ .kind = .duplicate_entrypoint, .argument = arg } };
        } else {
            entrypoint = arg;
        }
    }

    if (entrypoint == null) return .{ .err = .{ .kind = .missing_entrypoint } };
    if (!std.mem.eql(u8, format, "esm") and !std.mem.eql(u8, format, "cjs") and !std.mem.eql(u8, format, "iife")) {
        return .{ .err = .{ .kind = .unsupported_format, .argument = format } };
    }
    if (target) |value| {
        if (kernel_mode) {
            if (codegen.KernelArch.parseTriple(value) == null) {
                return .{ .err = .{ .kind = .unsupported_kernel_target, .argument = value } };
            }
        } else if (!std.mem.eql(u8, value, "browser") and
            !std.mem.eql(u8, value, "bun") and
            !std.mem.eql(u8, value, "node"))
        {
            return .{ .err = .{ .kind = .unsupported_target, .argument = value } };
        }
    }
    if (sourcemap) |value| {
        if (!std.mem.eql(u8, value, "external") and
            !std.mem.eql(u8, value, "inline") and
            !std.mem.eql(u8, value, "linked") and
            !std.mem.eql(u8, value, "none"))
        {
            return .{ .err = .{ .kind = .unsupported_sourcemap, .argument = value } };
        }
    }
    if (output_path != null and outdir != null) return .{ .err = .{ .kind = .output_path_conflicts_with_outdir } };
    if (bytecode and !compile) return .{ .err = .{ .kind = .bytecode_requires_compile, .argument = "--bytecode" } };

    return .{ .ok = .{
        .entrypoint = entrypoint.?,
        .output_path = output_path,
        .outdir = outdir,
        .target = target,
        .format = format,
        .sourcemap = sourcemap,
        .kernel_mode = kernel_mode,
        .compile = compile,
        .bytecode = bytecode,
        .allow_type_errors = allow_type_errors,
    } };
}

test "build options accept Bun compile flags and explicit type-error opt-out" {
    const args = [_][:0]const u8{
        "--compile",
        "--bytecode",
        "--allow-type-errors",
        "--format=esm",
        "/tmp/project/c.ts",
        "--outfile",
        "/tmp/project/compiled",
    };
    const options = switch (parse(&args)) {
        .ok => |value| value,
        .err => return error.ExpectedBuildOptions,
    };
    try std.testing.expect(options.compile);
    try std.testing.expect(options.bytecode);
    try std.testing.expect(options.allow_type_errors);
    try std.testing.expectEqualStrings("/tmp/project/c.ts", options.entrypoint);
    try std.testing.expectEqualStrings("/tmp/project/compiled", options.output_path.?);
}

test "build options keep type errors fatal by default" {
    const args = [_][:0]const u8{"entry.home"};
    const options = switch (parse(&args)) {
        .ok => |value| value,
        .err => return error.ExpectedBuildOptions,
    };
    try std.testing.expect(!options.allow_type_errors);
}

test "build options retain output target and sourcemap validation" {
    const valid = [_][:0]const u8{ "./index.ts", "--target=browser", "--sourcemap=external", "--outdir=./out" };
    const options = switch (parse(&valid)) {
        .ok => |value| value,
        .err => return error.ExpectedBuildOptions,
    };
    try std.testing.expectEqualStrings("./out", options.outdir.?);
    try std.testing.expectEqualStrings("browser", options.target.?);

    const invalid = [_][:0]const u8{ "entry.ts", "--outfile=app", "--outdir=dist" };
    switch (parse(&invalid)) {
        .err => |parse_error| try std.testing.expectEqual(.output_path_conflicts_with_outdir, parse_error.kind),
        .ok => return error.ExpectedBuildParseError,
    }
}

test "build options support compact output and separate format options" {
    const args = [_][:0]const u8{ "entry.ts", "-odist/app", "--format", "cjs", "--compile" };
    const options = switch (parse(&args)) {
        .ok => |value| value,
        .err => return error.ExpectedBuildOptions,
    };

    try std.testing.expectEqualStrings("entry.ts", options.entrypoint);
    try std.testing.expectEqualStrings("dist/app", options.output_path.?);
    try std.testing.expectEqualStrings("cjs", options.format);
}

test "build options reject malformed arguments" {
    const cases = [_]struct {
        args: []const [:0]const u8,
        kind: ErrorKind,
    }{
        .{ .args = &.{ "entry.ts", "--outfile" }, .kind = .missing_value },
        .{ .args = &.{ "--wat", "entry.ts" }, .kind = .unknown_option },
        .{ .args = &.{ "one.ts", "two.ts" }, .kind = .duplicate_entrypoint },
        .{ .args = &.{ "--bytecode", "entry.ts" }, .kind = .bytecode_requires_compile },
        .{ .args = &.{ "entry.ts", "--sourcemap=wat" }, .kind = .unsupported_sourcemap },
    };

    for (cases) |case| {
        switch (parse(case.args)) {
            .err => |parse_error| try std.testing.expectEqual(case.kind, parse_error.kind),
            .ok => return error.ExpectedBuildParseError,
        }
    }
}

test "check rejects parse errors without an environment toggle" {
    try std.testing.expect(checkPassed(false, true));
    try std.testing.expect(!checkPassed(true, true));
    try std.testing.expect(!checkPassed(false, false));
}

test "build type errors are fatal unless explicitly allowed" {
    const strict = Options{ .entrypoint = "entry.home" };
    try std.testing.expectEqual(TypeCheckOutcome.passed, typeCheckOutcome(strict, true));
    try std.testing.expectEqual(TypeCheckOutcome.fail, typeCheckOutcome(strict, false));

    var permissive = strict;
    permissive.allow_type_errors = true;
    try std.testing.expectEqual(TypeCheckOutcome.continue_by_request, typeCheckOutcome(permissive, false));
}
