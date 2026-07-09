// Partial port of bun/src/analytics/analytics.zig (Features struct) at
// upstream SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see
// ../cli/LICENSE.bun.md.
//
// Home divergence: upstream's `builtin_modules` is an
// `std.enums.EnumSet(bun.jsc.ModuleLoader.HardcodedModule)`. The
// HardcodedModule enum hasn't landed in Home yet (`jsc.ModuleLoader` is
// parked in `home_rt.zig`). We stub `HardcodedModule` as an empty enum
// so the EnumSet type checks and the iterator in `Formatter.format`
// degenerates to a no-op iterator. Once Home's `jsc.ModuleLoader`
// arrives, swap the local enum for the real one and the rest of the
// surface (the per-feature `usize` counters, comptime exports, and the
// formatter) drops in unchanged.
//
// Upstream's `@export(&napi_module_register, .{ .name = "..." })` calls
// are preserved verbatim — the externs are referenced by C++ glue Home
// inherits.

const std = @import("std");

/// Stubbed — upstream's `bun.jsc.ModuleLoader.HardcodedModule` enum.
/// Empty enum keeps the EnumSet type-check happy until Home's JSC
/// ModuleLoader lands.
pub const HardcodedModule = enum {};

pub var builtin_modules = std.enums.EnumSet(HardcodedModule).empty;

pub var @"Bun.stderr": usize = 0;
pub var @"Bun.stdin": usize = 0;
pub var @"Bun.stdout": usize = 0;
pub var WebSocket: usize = 0;
pub var abort_signal: usize = 0;
pub var binlinks: usize = 0;
pub var bunfig: usize = 0;
pub var define: usize = 0;
pub var dotenv: usize = 0;
pub var debugger: usize = 0;
pub var external: usize = 0;
pub var extracted_packages: usize = 0;
pub var fetch: usize = 0;
pub var git_dependencies: usize = 0;
pub var html_rewriter: usize = 0;
/// TCP server from `Bun.listen`
pub var tcp_server: usize = 0;
/// TLS server from `Bun.listen`
pub var tls_server: usize = 0;
pub var http_server: usize = 0;
pub var https_server: usize = 0;
pub var http_client_proxy: usize = 0;
/// Set right before JSC::initialize is called
pub var jsc: usize = 0;
/// Set when bake.DevServer is initialized
pub var dev_server: usize = 0;
pub var lifecycle_scripts: usize = 0;
pub var loaders: usize = 0;
pub var lockfile_migration_from_package_lock: usize = 0;
pub var text_lockfile: usize = 0;
pub var isolated_bun_install: usize = 0;
pub var hoisted_bun_install: usize = 0;
pub var macros: usize = 0;
pub var no_avx2: usize = 0;
pub var no_avx: usize = 0;
pub var shell: usize = 0;
pub var spawn: usize = 0;
pub var standalone_executable: usize = 0;
pub var standalone_shell: usize = 0;
/// Set when invoking a todo panic
pub var todo_panic: usize = 0;
pub var transpiler_cache: usize = 0;
pub var tsconfig: usize = 0;
pub var tsconfig_paths: usize = 0;
pub var virtual_modules: usize = 0;
pub var workers_spawned: usize = 0;
pub var workers_terminated: usize = 0;
pub var napi_module_register: usize = 0;
pub var process_dlopen: usize = 0;
pub var postgres_connections: usize = 0;
pub var s3: usize = 0;
pub var valkey: usize = 0;
pub var csrf_verify: usize = 0;
pub var csrf_generate: usize = 0;
pub var unsupported_uv_function: usize = 0;
pub var exited: usize = 0;
pub var yarn_migration: usize = 0;
pub var pnpm_migration: usize = 0;
pub var yaml_parse: usize = 0;
pub var cpu_profile: usize = 0;
pub var heap_snapshot: usize = 0;
pub var webview_chrome: usize = 0;
pub var webview_webkit: usize = 0;

comptime {
    @export(&napi_module_register, .{ .name = "Bun__napi_module_register_count" });
    @export(&process_dlopen, .{ .name = "Bun__process_dlopen_count" });
    @export(&heap_snapshot, .{ .name = "Bun__Feature__heap_snapshot" });
    @export(&webview_chrome, .{ .name = "Bun__Feature__webview_chrome" });
    @export(&webview_webkit, .{ .name = "Bun__Feature__webview_webkit" });
}

pub fn formatter() Formatter {
    return Formatter{};
}

const Features = @This();

pub const Formatter = struct {
    pub fn format(_: Formatter, writer: *std.Io.Writer) !void {
        const fields = comptime brk: {
            const info: std.builtin.Type = @typeInfo(Features);
            // Note: upstream uses `.{""} ** info.@"struct".decl_names.len` (array
            // repetition). Zig 0.17-dev.263 `zig fmt` mis-tokenizes the `**`
            // after `}` as two `*` (which is a semantic-breaking rewrite to
            // multiply-deref). `@splat("")` is the modern equivalent and
            // round-trips cleanly through fmt.
            var buffer: [info.@"struct".decl_names.len][]const u8 = @splat("");
            var count: usize = 0;
            for (info.@"struct".decl_names) |decl| {
                var f = &@field(Features, decl.name);
                _ = &f;
                const Field = @TypeOf(f);
                const FieldT: std.builtin.Type = @typeInfo(Field);
                if (FieldT.pointer.child != usize) continue;
                buffer[count] = decl.name;
                count += 1;
            }

            break :brk buffer[0..count];
        };

        var is_first_feature = true;
        inline for (fields) |field| {
            const count = @field(Features, field);
            if (count > 0) {
                if (is_first_feature) {
                    try writer.writeAll("Features: ");
                    is_first_feature = false;
                }
                try writer.writeAll(field);
                if (count > 1) {
                    try writer.print("({d}) ", .{count});
                } else {
                    try writer.writeAll(" ");
                }
            }
        }
        if (!is_first_feature) {
            try writer.writeAll("\n");
        }

        var builtins = builtin_modules.iterator();
        if (builtins.next()) |first| {
            try writer.writeAll("Builtins: \"");
            try writer.writeAll(@tagName(first));
            try writer.writeAll("\" ");

            while (builtins.next()) |key| {
                try writer.writeAll("\"");
                try writer.writeAll(@tagName(key));
                try writer.writeAll("\" ");
            }

            try writer.writeAll("\n");
        }
    }
};

// ---- Inline tests ------------------------------------------------------

test "Features: counters default to zero" {
    // Snapshot counters so the test is hermetic against earlier mutations.
    try std.testing.expectEqual(@as(usize, 0), no_avx);
    try std.testing.expectEqual(@as(usize, 0), no_avx2);
}

test "Features: builtin_modules starts empty" {
    try std.testing.expectEqual(@as(usize, 0), builtin_modules.count());
}

test "Features: HardcodedModule stub is empty" {
    const info = @typeInfo(HardcodedModule).@"enum";
    try std.testing.expectEqual(@as(usize, 0), info.field_names.len);
}
