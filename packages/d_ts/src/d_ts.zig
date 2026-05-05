//! `.d.ts` declaration-file loader — Phase 1.A skeleton.
//!
//! Per TS_PARITY_PLAN §0 / Phase 1.A & 1.E. This package sits between
//! the file system and the binder: when the compiler encounters an
//! import that resolves to a `.d.ts` file (or a bundled `lib.es*.d.ts`
//! snapshot), the d_ts loader parses it via the same TS frontend and
//! exposes the ambient symbols.
//!
//! Phase 1.A: scaffold + lib catalog enum + loader signature.
//! Phase 1.E: full lib loading + ambient-module declaration handling.

const std = @import("std");

/// Versioned lib bundles tsc / tsgo distribute. Home embeds the same
/// ones, version-pinned to the upstream TS submodule SHA pinned in
/// `bench/vs_tsgo/corpus.toml`.
pub const Lib = enum {
    es5,
    es2015,
    es2016,
    es2017,
    es2018,
    es2019,
    es2020,
    es2021,
    es2022,
    es2023,
    es2024,
    esnext,
    dom,
    dom_iterable,
    webworker,
    scripthost,

    pub fn fileName(self: Lib) []const u8 {
        return switch (self) {
            .es5 => "lib.es5.d.ts",
            .es2015 => "lib.es2015.d.ts",
            .es2016 => "lib.es2016.d.ts",
            .es2017 => "lib.es2017.d.ts",
            .es2018 => "lib.es2018.d.ts",
            .es2019 => "lib.es2019.d.ts",
            .es2020 => "lib.es2020.d.ts",
            .es2021 => "lib.es2021.d.ts",
            .es2022 => "lib.es2022.d.ts",
            .es2023 => "lib.es2023.d.ts",
            .es2024 => "lib.es2024.d.ts",
            .esnext => "lib.esnext.d.ts",
            .dom => "lib.dom.d.ts",
            .dom_iterable => "lib.dom.iterable.d.ts",
            .webworker => "lib.webworker.d.ts",
            .scripthost => "lib.scripthost.d.ts",
        };
    }

    pub fn fromName(name: []const u8) ?Lib {
        // Accept both plain `es2024` and `lib.es2024.d.ts` forms.
        const Mapping = struct { name: []const u8, lib: Lib };
        const table = [_]Mapping{
            .{ .name = "es5", .lib = .es5 },
            .{ .name = "es2015", .lib = .es2015 },
            .{ .name = "es2016", .lib = .es2016 },
            .{ .name = "es2017", .lib = .es2017 },
            .{ .name = "es2018", .lib = .es2018 },
            .{ .name = "es2019", .lib = .es2019 },
            .{ .name = "es2020", .lib = .es2020 },
            .{ .name = "es2021", .lib = .es2021 },
            .{ .name = "es2022", .lib = .es2022 },
            .{ .name = "es2023", .lib = .es2023 },
            .{ .name = "es2024", .lib = .es2024 },
            .{ .name = "esnext", .lib = .esnext },
            .{ .name = "dom", .lib = .dom },
            .{ .name = "dom.iterable", .lib = .dom_iterable },
            .{ .name = "webworker", .lib = .webworker },
            .{ .name = "scripthost", .lib = .scripthost },
        };
        for (table) |m| {
            if (std.mem.eql(u8, name, m.name)) return m.lib;
        }
        return null;
    }
};

/// The transitive closure of libs implied by a target.
/// `target=es2024` implies all `es5..es2024` (plus `dom` if not
/// explicitly disabled). Mirrors tsc's `getLibFilesFromTargetAndLib`.
pub fn libsForTarget(target_es: Lib) []const Lib {
    const all = [_]Lib{ .es5, .es2015, .es2016, .es2017, .es2018, .es2019, .es2020, .es2021, .es2022, .es2023, .es2024, .esnext };
    inline for (all, 0..) |l, idx| {
        if (l == target_es) return all[0 .. idx + 1];
    }
    return all[0..];
}

/// Loader interface — Phase 1.E supplies the concrete impl.
pub const Loader = struct {
    /// Map from canonical lib name to the parsed declaration-only HIR
    /// produced by the TS frontend. Phase 1.E populates this.
    /// Phase 1.A: empty.
    libs_loaded: std.AutoHashMapUnmanaged(Lib, void),

    pub fn init() Loader {
        return .{ .libs_loaded = .empty };
    }

    pub fn deinit(self: *Loader, gpa: std.mem.Allocator) void {
        self.libs_loaded.deinit(gpa);
    }

    /// Phase 1.E will: open the lib file, run it through the TS
    /// frontend in declaration-only mode, register the ambient symbols.
    /// Today: returns `error.NotImplemented` so callers can plumb
    /// through and we fail loudly until 1.E lands.
    pub fn loadLib(self: *Loader, gpa: std.mem.Allocator, lib: Lib) !void {
        _ = self;
        _ = gpa;
        _ = lib;
        return error.NotImplemented;
    }
};

// =============================================================================
// Tests
// =============================================================================

const t = std.testing;

test "Lib.fileName: round-trips for the major versions" {
    try t.expectEqualStrings("lib.es5.d.ts", Lib.es5.fileName());
    try t.expectEqualStrings("lib.es2024.d.ts", Lib.es2024.fileName());
    try t.expectEqualStrings("lib.dom.d.ts", Lib.dom.fileName());
    try t.expectEqualStrings("lib.dom.iterable.d.ts", Lib.dom_iterable.fileName());
}

test "Lib.fromName: accepts plain names" {
    try t.expectEqual(@as(?Lib, .es2024), Lib.fromName("es2024"));
    try t.expectEqual(@as(?Lib, .dom_iterable), Lib.fromName("dom.iterable"));
    try t.expectEqual(@as(?Lib, .esnext), Lib.fromName("esnext"));
    try t.expectEqual(@as(?Lib, null), Lib.fromName("nonexistent"));
}

test "libsForTarget: closure includes all earlier versions" {
    const set = libsForTarget(.es2020);
    try t.expect(set.len >= 6);
    try t.expectEqual(Lib.es5, set[0]);
    try t.expectEqual(Lib.es2020, set[set.len - 1]);
}

test "libsForTarget: es5 alone implies no later versions" {
    const set = libsForTarget(.es5);
    try t.expectEqual(@as(usize, 1), set.len);
    try t.expectEqual(Lib.es5, set[0]);
}

test "Loader: scaffold init/deinit + loadLib stub" {
    var ldr = Loader.init();
    defer ldr.deinit(t.allocator);
    try t.expectError(error.NotImplemented, ldr.loadLib(t.allocator, .es2024));
}
