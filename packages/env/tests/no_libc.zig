const std = @import("std");
const env = @import("posix_env");
pub fn main() !void {
    const value = env.get(std.heap.page_allocator, "HOME_ENV_NO_LIBC_TEST") catch |err| {
        if (err == error.UnsupportedEnvironment) return;
        return err;
    };
    if (value) |v| std.heap.page_allocator.free(v);
    return error.ExpectedUnsupported;
}
