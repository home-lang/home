//! Link the actual decoder and row permutation without libc, heap or an OS.
const cnn = @import("cnn");
export fn home_cnn_row_major(info: [*]const u8, info_length: usize, values: [*]const u8, values_length: usize, output: [*]f32, capacity: usize) u32 {
    if (info_length > 712 or values_length > 64 * 1024 * 1024 or capacity > 16 * 1024 * 1024) return 1;
    const model = cnn.Outputs.fromRaw(info[0..info_length], values[0..values_length], .little, 16 * 1024 * 1024) catch return 1;
    model.copy(output[0..capacity], .row_major) catch return 1;
    return 0;
}
