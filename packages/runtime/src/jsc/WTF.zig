// Copied from bun/src/jsc/WTF.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// Free-form WebKit "WTF" helper namespace. All of these wrap real C++
// implementations linked from libWTF — the Zig side is just a tiny shim.
// `jsc.markBinding` is the binding-trace hook; we stub it as a no-op until
// the full JSC bridge re-attaches in Phase 12.2. `StringBuilder` is in a
// sibling file but we don't re-export it here — it's not yet ported.

const std = @import("std");

// JSC binding-trace hook stubbed — re-attaches in Phase 12.2. Upstream
// `bun.jsc.markBinding` records the call site for debugging; our build has
// nothing to record into yet, so it elides at compile-time.
const jsc = struct {
    inline fn markBinding(_: std.builtin.SourceLocation) void {}
};

pub const WTF = struct {
    extern fn WTF__parseDouble(bytes: [*]const u8, length: usize, counted: *usize) f64;

    extern fn WTF__numberOfProcessorCores() c_int;

    /// On Linux, this is min(sysconf(_SC_NPROCESSORS_ONLN), sched_getaffinity count, cgroup cpu.max quota).
    /// Result is cached after the first call.
    pub fn numberOfProcessorCores() u32 {
        jsc.markBinding(@src());
        return @intCast(@max(1, WTF__numberOfProcessorCores()));
    }

    extern fn WTF__releaseFastMallocFreeMemoryForThisThread() void;

    pub fn releaseFastMallocFreeMemoryForThisThread() void {
        jsc.markBinding(@src());
        WTF__releaseFastMallocFreeMemoryForThisThread();
    }

    pub fn parseDouble(buf: []const u8) !f64 {
        jsc.markBinding(@src());

        if (buf.len == 0)
            return error.InvalidCharacter;

        var count: usize = 0;
        const res = WTF__parseDouble(buf.ptr, buf.len, &count);

        if (count == 0)
            return error.InvalidCharacter;
        return res;
    }

    extern fn WTF__parseES5Date(bytes: [*]const u8, length: usize) f64;

    // 2000-01-01T00:00:00.000Z -> 946684800000 (ms)
    pub fn parseES5Date(buf: []const u8) !f64 {
        jsc.markBinding(@src());

        if (buf.len == 0)
            return error.InvalidDate;

        const ms = WTF__parseES5Date(buf.ptr, buf.len);
        if (std.math.isFinite(ms))
            return ms;

        return error.InvalidDate;
    }

    extern fn Bun__writeHTTPDate(buffer: *[32]u8, length: usize, timestampMs: u64) c_int;

    pub fn writeHTTPDate(buffer: *[32]u8, timestampMs: u64) []u8 {
        if (timestampMs == 0) {
            return buffer[0..0];
        }

        const res = Bun__writeHTTPDate(buffer, 32, timestampMs);
        if (res < 1) {
            return buffer[0..0];
        }

        return buffer[0..@intCast(res)];
    }

    // StringBuilder lives next to this file but is not yet ported; the C++
    // ABI it wraps (TopExceptionScope, JSValue, JSGlobalObject) doesn't have
    // home_rt equivalents yet. Once those land in Phase 12.2 this comment
    // becomes `pub const StringBuilder = @import("./StringBuilder.zig");`.
};

test "WTF exposes the expected entrypoints" {
    // We can't *call* any of these in a unit test — they would force the
    // linker to resolve the WTF__/Bun__ C symbols, which only the JSC
    // bridge provides. Use `@hasDecl` to verify the surface only.
    try std.testing.expect(@hasDecl(WTF, "numberOfProcessorCores"));
    try std.testing.expect(@hasDecl(WTF, "releaseFastMallocFreeMemoryForThisThread"));
    try std.testing.expect(@hasDecl(WTF, "parseDouble"));
    try std.testing.expect(@hasDecl(WTF, "parseES5Date"));
    try std.testing.expect(@hasDecl(WTF, "writeHTTPDate"));
}
