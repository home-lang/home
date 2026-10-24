const std = @import("std");
const jpeg = @import("jpeg");
const a = std.heap.c_allocator;
export fn home_jpeg_decode(data: [*]const u8, length: usize, nearest: u32, out: *?*anyopaque, info: [*]u64, pixels: *?[*]const u8, icc: *?[*]const u8, exif: *?[*]const u8) c_int {
    out.* = null;
    var result = jpeg.decode(a, data[0..length], .{ .upsampling = if (nearest == 0) .linear else .nearest }) catch |err| {
        std.debug.print("Home JPEG rejected reference: {s}\n", .{@errorName(err)});
        return -1;
    };
    const owner = a.create(jpeg.Result) catch {
        result.deinit();
        return -2;
    };
    owner.* = result;
    out.* = owner;
    info[0] = result.width;
    info[1] = result.height;
    info[2] = result.components;
    info[3] = @intFromBool(result.progressive);
    info[4] = result.scans;
    info[5] = @intFromEnum(result.color_model);
    info[6] = result.pixels.len;
    info[7] = if (result.icc) |b| b.len else 0;
    info[8] = if (result.exif) |b| b.len else 0;
    info[9] = result.working_peak;
    info[10] = result.work_units;
    pixels.* = result.pixels.ptr;
    icc.* = if (result.icc) |b| b.ptr else null;
    exif.* = if (result.exif) |b| b.ptr else null;
    return 0;
}
export fn home_jpeg_free(p: *anyopaque) void {
    const result: *jpeg.Result = @ptrCast(@alignCast(p));
    result.deinit();
    a.destroy(result);
}
export fn home_jpeg_reject(data: [*]const u8, length: usize) c_int {
    var result = jpeg.decode(a, data[0..length], .{}) catch return 1;
    result.deinit();
    return 0;
}
