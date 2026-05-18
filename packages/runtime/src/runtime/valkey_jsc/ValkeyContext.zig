// Copied verbatim bun/src/runtime/valkey_jsc/ValkeyContext.zig at upstream SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
//! Per-VM Valkey state. The four cached `us_socket_context_t`s that used to
//! live here are gone — connections link into `RareData.valkey_group` /
//! `valkey_tls_group` instead, and the default-TLS `SSL_CTX` is
//! `RareData.defaultClientSslCtx()`.

pub fn deinit(_: *@This()) void {}

const std = @import("std");

test "ValkeyContext.deinit is a no-op on an empty instance" {
    var ctx: @This() = .{};
    deinit(&ctx);
}
