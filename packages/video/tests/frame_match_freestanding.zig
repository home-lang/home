//! Link probe keeps the actual policy reachable without libc, a heap or an OS.
const match = @import("match");
export fn home_frame_match(stamps: [*]const u64, count: usize, tolerance: u64, times: *[3]u64) u32 {
    if (count < 2 or count > match.max_streams) return 0xffffffff;
    const decision = match.choose(stamps[0..count], tolerance) catch return 0xffffffff;
    times.* = .{ decision.earliest_ns, decision.latest_ns, decision.skewNs() };
    return decision.replace_mask;
}
