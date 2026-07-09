//! Provenance manifest for the CLI run / spawn / process / fs / file Bun
//! source slice.
//!
//! This module intentionally contains no replacement behavior and does not
//! re-export parked upstream files that still depend on Bun's full JSC/process
//! substrate. It makes the copied-source boundary build-visible while keeping
//! promotion tied to the real imported implementations.

const std = @import("std");

pub const upstream_sha = "fd0b6f1a271fca0b8124b69f230b100f4d636af6";

pub const Slice = enum {
    cli_run,
    spawn,
    process,
    node_fs,
    bun_file,
};

pub const PortStatus = enum {
    verbatim,
    adapted,
};

pub const SourceFile = struct {
    slice: Slice,
    upstream: []const u8,
    local: []const u8,
    status: PortStatus,
    note: []const u8,
};

pub const sources = [_]SourceFile{
    .{ .slice = .cli_run, .upstream = "bun/src/runtime/cli/Arguments.zig", .local = "packages/runtime/src/runtime/cli/Arguments.zig", .status = .verbatim, .note = "Bun CLI argument parser source copied byte-for-byte; parked on the wider Bun runtime namespace." },
    .{ .slice = .cli_run, .upstream = "bun/src/runtime/cli/run_command.zig", .local = "packages/runtime/src/runtime/cli/run_command.zig", .status = .verbatim, .note = "Bun run command implementation copied byte-for-byte; parked on CLI environment, package manager state, and subprocess wiring." },
    .{ .slice = .spawn, .upstream = "bun/src/runtime/api/bun/js_bun_spawn_bindings.zig", .local = "packages/runtime/src/runtime/api/bun/js_bun_spawn_bindings.zig", .status = .verbatim, .note = "JS binding glue for Bun.spawn/Bun.spawnSync copied byte-for-byte; parked on JSC codegen/runtime bindings." },
    .{ .slice = .spawn, .upstream = "bun/src/runtime/api/bun/spawn.zig", .local = "packages/runtime/src/runtime/api/bun/spawn.zig", .status = .adapted, .note = "POSIX spawn substrate adapted for Zig 0.17-dev and Home allocator/sys aliases; high-level spawn request wiring remains parked." },
    .{ .slice = .spawn, .upstream = "bun/src/runtime/api/bun/spawn/stdio.zig", .local = "packages/runtime/src/runtime/api/bun/spawn/stdio.zig", .status = .verbatim, .note = "Bun stdio option lowering copied byte-for-byte; parked on subprocess/JSC/webcore dependencies." },
    .{ .slice = .spawn, .upstream = "bun/src/runtime/api/bun/subprocess.zig", .local = "packages/runtime/src/runtime/api/bun/subprocess.zig", .status = .verbatim, .note = "Subprocess object implementation copied byte-for-byte; parked on Process, IPC, JSC, and event-loop surfaces." },
    .{ .slice = .spawn, .upstream = "bun/src/runtime/api/bun/subprocess/Readable.zig", .local = "packages/runtime/src/runtime/api/bun/subprocess/Readable.zig", .status = .verbatim, .note = "Subprocess stdout/stderr readable pipe source copied byte-for-byte." },
    .{ .slice = .spawn, .upstream = "bun/src/runtime/api/bun/subprocess/Writable.zig", .local = "packages/runtime/src/runtime/api/bun/subprocess/Writable.zig", .status = .verbatim, .note = "Subprocess stdin writable pipe source copied byte-for-byte." },
    .{ .slice = .spawn, .upstream = "bun/src/runtime/api/bun/subprocess/StaticPipeWriter.zig", .local = "packages/runtime/src/runtime/api/bun/subprocess/StaticPipeWriter.zig", .status = .verbatim, .note = "Static pipe writer source copied byte-for-byte." },
    .{ .slice = .spawn, .upstream = "bun/src/runtime/api/bun/subprocess/SubprocessPipeReader.zig", .local = "packages/runtime/src/runtime/api/bun/subprocess/SubprocessPipeReader.zig", .status = .verbatim, .note = "Subprocess pipe reader source copied byte-for-byte." },
    .{ .slice = .spawn, .upstream = "bun/src/runtime/api/bun/subprocess/ResourceUsage.zig", .local = "packages/runtime/src/runtime/api/bun/subprocess/ResourceUsage.zig", .status = .verbatim, .note = "ResourceUsage conversion source copied byte-for-byte." },
    .{ .slice = .process, .upstream = "bun/src/runtime/api/bun/process.zig", .local = "packages/runtime/src/runtime/api/bun/process.zig", .status = .verbatim, .note = "Bun process substrate copied byte-for-byte; parked on libuv/windows/JSC process bindings." },
    .{ .slice = .process, .upstream = "bun/src/runtime/node/node_process.zig", .local = "packages/runtime/src/runtime/node/node_process.zig", .status = .verbatim, .note = "Node process binding source copied byte-for-byte; JS-visible node:process currently uses Home's smaller substrate." },
    .{ .slice = .node_fs, .upstream = "bun/src/runtime/node/node_fs.zig", .local = "packages/runtime/src/runtime/node/node_fs.zig", .status = .verbatim, .note = "Full Bun node:fs implementation copied byte-for-byte; parked on Bun's JSC/fs task substrate." },
    .{ .slice = .node_fs, .upstream = "bun/src/runtime/node/node_fs_binding.zig", .local = "packages/runtime/src/runtime/node/node_fs_binding.zig", .status = .verbatim, .note = "Node fs binding glue copied byte-for-byte." },
    .{ .slice = .node_fs, .upstream = "bun/src/runtime/node/node_fs_constant.zig", .local = "packages/runtime/src/runtime/node/node_fs_constant.zig", .status = .verbatim, .note = "Node fs constants copied byte-for-byte." },
    .{ .slice = .node_fs, .upstream = "bun/src/runtime/node/node_fs_watcher.zig", .local = "packages/runtime/src/runtime/node/node_fs_watcher.zig", .status = .verbatim, .note = "FS watcher source copied byte-for-byte." },
    .{ .slice = .node_fs, .upstream = "bun/src/runtime/node/node_fs_stat_watcher.zig", .local = "packages/runtime/src/runtime/node/node_fs_stat_watcher.zig", .status = .verbatim, .note = "Stat watcher source copied byte-for-byte." },
    .{ .slice = .node_fs, .upstream = "bun/src/runtime/node/fs_events.zig", .local = "packages/runtime/src/runtime/node/fs_events.zig", .status = .verbatim, .note = "fs_events source copied byte-for-byte." },
    .{ .slice = .bun_file, .upstream = "bun/src/runtime/webcore/blob/read_file.zig", .local = "packages/runtime/src/runtime/webcore/blob/read_file.zig", .status = .verbatim, .note = "Bun.file read path copied byte-for-byte." },
    .{ .slice = .bun_file, .upstream = "bun/src/runtime/webcore/blob/write_file.zig", .local = "packages/runtime/src/runtime/webcore/blob/write_file.zig", .status = .verbatim, .note = "Bun.write file path copied byte-for-byte." },
    .{ .slice = .bun_file, .upstream = "bun/src/runtime/webcore/blob/copy_file.zig", .local = "packages/runtime/src/runtime/webcore/blob/copy_file.zig", .status = .verbatim, .note = "Blob/file copy path copied byte-for-byte." },
    .{ .slice = .bun_file, .upstream = "bun/src/sys/copy_file.zig", .local = "packages/runtime/src/sys/copy_file.zig", .status = .verbatim, .note = "Platform copy_file syscall helper copied byte-for-byte." },
};

test "manifest records CLI/spawn/process/fs/file Bun source provenance" {
    try std.testing.expectEqualStrings("fd0b6f1a271fca0b8124b69f230b100f4d636af6", upstream_sha);
    try std.testing.expect(sources.len >= 20);

    var saw = std.EnumSet(Slice).empty;
    var saw_adapted = false;

    for (sources) |entry| {
        try std.testing.expect(std.mem.startsWith(u8, entry.upstream, "bun/src/"));
        try std.testing.expect(std.mem.startsWith(u8, entry.local, "packages/runtime/src/"));
        try std.testing.expect(entry.note.len > 0);
        saw.insert(entry.slice);
        if (entry.status == .adapted) saw_adapted = true;
    }

    try std.testing.expect(saw.contains(.cli_run));
    try std.testing.expect(saw.contains(.spawn));
    try std.testing.expect(saw.contains(.process));
    try std.testing.expect(saw.contains(.node_fs));
    try std.testing.expect(saw.contains(.bun_file));
    try std.testing.expect(saw_adapted);
}
