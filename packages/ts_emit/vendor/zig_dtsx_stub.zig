//! Local stub for the zig-dtsx fast `.d.ts` emitter.
//!
//! The real implementation is the `@stacksjs/zig-dtsx` pantry package,
//! installed into `pantry/zig-dtsx/` (which is gitignored). When that
//! package is present, `build.zig` wires its `src/zig_dtsx.zig` in as
//! the `zig_dtsx` module and this stub is never compiled. On fresh
//! checkouts or machines without the pantry install, `build.zig` falls
//! back to this stub so the whole TS toolchain still builds.
//!
//! The stub satisfies exactly the API surface that
//! `packages/ts_emit/src/d_ts_fast.zig` consumes — `Scanner.init` /
//! `Scanner.scan` / `Scanner.declarations.items` and
//! `processDeclarations` — and returns an empty buffer. `d_ts_fast`'s
//! tests skip their content assertions when the output is empty (see
//! `fast .d.ts: declared function is preserved`), so the build stays
//! green until the real package is installed with
//! `pantry add @stacksjs/zig-dtsx`.

const std = @import("std");

/// Opaque declaration record. The real scanner populates these from the
/// source; the stub leaves the list empty.
pub const Declaration = struct {};

pub const Scanner = struct {
    pub const Declarations = struct {
        items: []Declaration = &.{},
    };

    allocator: std.mem.Allocator,
    declarations: Declarations = .{},

    /// Mirrors `dtsx.Scanner.init(allocator, source, isModule, keepComments)`.
    pub fn init(
        allocator: std.mem.Allocator,
        source: []const u8,
        is_module: bool,
        keep_comments: bool,
    ) Scanner {
        _ = source;
        _ = is_module;
        _ = keep_comments;
        return .{ .allocator = allocator };
    }

    /// The real scanner returns the number of declarations found; the
    /// stub finds none. d_ts_fast discards the value.
    pub fn scan(self: *Scanner) !usize {
        _ = self;
        return 0;
    }
};

/// Mirrors `dtsx.processDeclarations`. The real package allocates
/// `len + 1` bytes (a trailing NUL for FFI callers) and returns a slice
/// of `len`; d_ts_fast frees `ptr[0 .. len + 1]`. The stub returns an
/// empty (`len == 0`) slice backed by a single-byte NUL allocation.
pub fn processDeclarations(
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    declarations: []const Declaration,
    source: []const u8,
    keep_comments: bool,
    import_order: []const []const u8,
) ![]u8 {
    _ = arena;
    _ = declarations;
    _ = source;
    _ = keep_comments;
    _ = import_order;
    const buf = try gpa.alloc(u8, 1);
    buf[0] = 0;
    return buf[0..0];
}
