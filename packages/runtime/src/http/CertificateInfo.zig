// Copied verbatim from bun/src/http/CertificateInfo.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.

const CertificateInfo = @This();

cert: []const u8,
cert_error: HTTPCertError,
hostname: []const u8,
pub fn deinit(this: *const CertificateInfo, allocator: std.mem.Allocator) void {
    allocator.free(this.cert);
    allocator.free(this.cert_error.code);
    allocator.free(this.cert_error.reason);
    allocator.free(this.hostname);
}

const HTTPCertError = @import("./HTTPCertError.zig");
const std = @import("std");
