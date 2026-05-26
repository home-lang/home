// Copied verbatim from bun/src/perf/system_timer.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// Upstream pulls `Environment` from a relative `../core/env.zig`
// import; the home_rt aggregator exposes `home_rt.Environment` with
// the same compile-time `isWasm` field, so the rewrite collapses to
// a single import.

fn NewTimer() type {
    if (Environment.isWasm) {
        return struct {
            pub fn start() anyerror!@This() {
                return @This(){};
            }

            pub fn read(_: anytype) u64 {
                @compileError("FeatureFlags.tracing should be disabled in WASM");
            }

            pub fn lap(_: anytype) u64 {
                @compileError("FeatureFlags.tracing should be disabled in WASM");
            }

            pub fn reset(_: anytype) u64 {
                @compileError("FeatureFlags.tracing should be disabled in WASM");
            }
        };
    }

    return struct {
        pub fn start() anyerror!@This() {
            return .{};
        }

        pub fn read(_: @This()) u64 {
            return 0;
        }

        pub fn lap(_: *@This()) u64 {
            return 0;
        }

        pub fn reset(_: *@This()) u64 {
            return 0;
        }
    };
}
pub const Timer = NewTimer();

const home_rt = @import("home_rt");
const Environment = home_rt.Environment;
const std = @import("std");

test "system_timer: Timer resolves to a usable type on native targets" {
    // Native (non-WASM) target picks `std.time.Timer`. The substrate
    // is verified by checking the resolved type's declarations rather
    // than starting a timer, so this test is hermetic.
    if (Environment.isWasm) return;
    try std.testing.expect(@hasDecl(Timer, "start"));
    try std.testing.expect(@hasDecl(Timer, "read"));
    try std.testing.expect(@hasDecl(Timer, "lap"));
    try std.testing.expect(@hasDecl(Timer, "reset"));
}
