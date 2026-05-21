// Temporary verification driver — pulls each newly-copied file into the
// home_rt module so `zig build-obj` exercises their tests. This file is
// not part of the home_rt public surface and will be removed once the
// aggregator is updated to import each new leaf.

test {
    _ = @import("options_types/GlobalCache.zig");
    _ = @import("options_types/BundleEnums.zig");
    _ = @import("options_types/CommandTag.zig");
    _ = @import("install/ExternalSlice.zig");
    _ = @import("install/padding_checker.zig");
    // Ninth-wave port batch (2026-05-18):
    _ = @import("core/string/StringBuilder.zig");
    _ = @import("http/HeaderBuilder.zig");
    // Thirteenth-wave port batch (2026-05-18) — orphan-wave smoke check.
    // Mirrors the home_rt aggregator additions so the smoke driver
    // exercises each file even before the test-step runs.
    _ = @import("analytics/Features.zig");
    _ = @import("node/path.zig");
    _ = @import("node/assert.zig");
    _ = @import("node/util.zig");
    // Phase 12.7 round-8 (2026-05-19) — `node:fs` sync substrate.
    _ = @import("node/fs.zig");
    // Phase 12.7 round-9 (2026-05-19) — `node:buffer` Zig substrate.
    _ = @import("node/buffer.zig");
    // Phase 12.7 (2026-05-19) — `node:os` Zig substrate (system info).
    _ = @import("node/os.zig");
    // Phase 12.7 (2026-05-19) — `node:url` Zig substrate (WHATWG URL +
    // legacy url.parse/format/resolve + pathToFileURL/fileURLToPath).
    _ = @import("node/url.zig");
    _ = @import("jsc/generated_classes_list.zig");
    _ = @import("runtime/api/bun/Terminal.zig");
    _ = @import("runtime/api/bun/spawn.zig");
    _ = @import("runtime/api/glob.zig");
    // Phase 12 Bake lifetime carrier: DevServer/HmrSocket teardown
    // substrate copied from Bun and made Zig 0.17-clean before the
    // JS-visible Bun.serve/Bake API is wired in.
    _ = @import("runtime/bake/bake.zig");
    _ = @import("runtime/bake/DevServer.zig");
    _ = @import("runtime/bake/DevServer/HmrSocket.zig");
    _ = @import("runtime/bake/DevServer/RouteBundle.zig");
    _ = @import("runtime/bake/DevServer/SourceMapStore.zig");
    _ = @import("runtime/server/server.zig");
    _ = @import("runtime/webcore/Body.zig");
    _ = @import("runtime/webcore/FormData.zig");
    _ = @import("runtime/webcore/ObjectURLRegistry.zig");
    _ = @import("runtime/webcore/Sink.zig");
    _ = @import("safety/safety.zig");
    // Wave-14 port batch (2026-05-18) — Tier-0 grinder.
    _ = @import("bun_alloc/BufferFallbackAllocator.zig");
    _ = @import("bun_alloc/MaxHeapAllocator.zig");
    _ = @import("bun_alloc/NullableAllocator.zig");
    _ = @import("string/HashedString.zig");
    _ = @import("string/PathString.zig");
    _ = @import("js_parser/lexer/identifier.zig");
    _ = @import("css/properties/svg.zig");
    _ = @import("ptr/weak_ptr.zig");
    // Phase 12.2 M1 (2026-05-19) — JSC bridge scaffold (opaques +
    // extern fn shapes + C-API enums). Bodies are link-resolved and
    // will fail under `home_rt_tests`; the smoke driver only compiles
    // so these are safe to pull in here.
    _ = @import("jsc/opaques.zig");
    _ = @import("jsc/extern_fns.zig");
    _ = @import("jsc/types.zig");
    // Phase 12.2 M4 (2026-05-19) — exception + coerce + array helper
    // surfaces. Bodies panic with TODO(phase-12.2-M3) until the C++
    // bridge lands; the smoke driver only compiles (and runs the
    // signature-shape tests), so these are safe here.
    _ = @import("jsc/exception_helpers.zig");
    _ = @import("jsc/coerce.zig");
    _ = @import("jsc/array.zig");
    // Phase 12.2 M5 (2026-05-19) — call + callback helper surfaces.
    // Same shape as M4: bodies panic with TODO(phase-12.2-M3); the
    // smoke driver compiles and runs the inline signature-shape tests.
    _ = @import("jsc/call.zig");
    _ = @import("jsc/callback.zig");
    // Phase 12.2 M3-real (2026-05-19) — first live JSC C++ smoke.
    // Tests gate on @import("build_options").enable_jsc and skip
    // when off. When -Denable_jsc=true is set, they call into
    // JavaScriptCore.framework directly and assert round-trips work.
    _ = @import("jsc/_m3_real_smoke.zig");
    // Wave-18 Tier-0 grinder (2026-05-18) — sql wire-protocol leaves.
    _ = @import("sql/shared/Data.zig");
    _ = @import("sql/mysql/protocol/NewReader.zig");
    _ = @import("sql/mysql/protocol/EOFPacket.zig");
    _ = @import("sql/mysql/protocol/StmtPrepareOKPacket.zig");
    _ = @import("sql/mysql/protocol/LocalInfileRequest.zig");
    _ = @import("sql/mysql/protocol/OKPacket.zig");
    _ = @import("sql/mysql/protocol/StackReader.zig");
    _ = @import("sql/mysql/protocol/Query.zig");
    _ = @import("sql/postgres/protocol/PasswordMessage.zig");
    _ = @import("sql/postgres/protocol/SASLResponse.zig");
    _ = @import("sql/postgres/protocol/SASLInitialResponse.zig");
    _ = @import("sql/postgres/protocol/CopyOutResponse.zig");
    _ = @import("sql/postgres/protocol/Parse.zig");
    _ = @import("sql/postgres/protocol/ReadyForQuery.zig");
    _ = @import("sql/postgres/protocol/ParameterStatus.zig");
    _ = @import("sql/postgres/protocol/DataRow.zig");
    _ = @import("sql/postgres/CommandTag.zig");
    // Wave-18 Tier-1 grinder (2026-05-18) — additional sql wire-protocol
    // leaves + css/properties/text.
    _ = @import("sql/postgres/protocol/Close.zig");
    _ = @import("sql/postgres/protocol/Describe.zig");
    _ = @import("sql/postgres/protocol/Execute.zig");
    _ = @import("sql/postgres/protocol/CopyInResponse.zig");
    _ = @import("sql/postgres/protocol/CommandComplete.zig");
    _ = @import("sql/postgres/protocol/CopyData.zig");
    _ = @import("sql/postgres/protocol/CopyFail.zig");
    _ = @import("css/properties/text.zig");
    // Wave-20 Tier-2 substrate (2026-05-19) — strerror tables + sql
    // wire-protocol leaves. Lifts the `sys.SystemErrno → message` maps
    // off the dispatched `errno/errno.zig` table so future copies of
    // `sys.zig` (strerror, formatPath, errorToZigString) can compile
    // without resurrecting JSC-bridge or libuv coupling.
    _ = @import("sys/libuv_error_map.zig");
    _ = @import("sys/coreutils_error_map.zig");
    _ = @import("sql/postgres/protocol/ArrayList.zig");
    _ = @import("sql/postgres/protocol/StackReader.zig");
    _ = @import("sql/mysql/protocol/AuthSwitchRequest.zig");
    // Wave-22 grinder (2026-05-19) — sql wire-protocol leaves
    // recovered from the round-8 attempt (uncommitted orphans) plus
    // additional ports from less-mined areas. Each carries the
    // standard `home_rt` rewrite + inline tests; bodies that reach
    // into wave-16/18 NewReader/NewWriter method stubs trip a normal
    // Zig "no method named X" compile error if exercised, which is
    // the trigger to port the real reader/writer.
    _ = @import("sql/shared/ColumnIdentifier.zig");
    _ = @import("sql/mysql/protocol/NewWriter.zig");
    _ = @import("sql/postgres/protocol/FieldDescription.zig");
    _ = @import("sql/postgres/protocol/ParameterDescription.zig");
    _ = @import("sql/postgres/protocol/RowDescription.zig");
    // Wave-22 grinder (2026-05-19) — additional wire-protocol leaves
    // mined from less-touched bun/src/sql corners. Each is purely
    // declarative over the wave-18 Data + NewReader/NewWriter stubs;
    // exercising decode/write trips a compile error pointing back at
    // the stub method surface.
    _ = @import("sql/mysql/protocol/ResultSetHeader.zig");
    _ = @import("sql/mysql/protocol/AuthSwitchResponse.zig");
    _ = @import("sql/mysql/protocol/ErrorPacket.zig");
    _ = @import("sql/postgres/protocol/StartupMessage.zig");
    // Wave-23 grinder (2026-05-19) — MySQL wire-protocol leaves from
    // less-mined corners (handshake/TLS-upgrade, column metadata,
    // request helpers). Each compiles over the wave-21 NewReader/
    // NewWriter stubs; method bodies trip a natural compile error
    // only if exercised at the call site.
    _ = @import("sql/mysql/protocol/SSLRequest.zig");
    _ = @import("sql/mysql/protocol/HandshakeV10.zig");
    _ = @import("sql/mysql/protocol/ColumnDefinition41.zig");
    _ = @import("sql/mysql/MySQLRequest.zig");
    _ = @import("sql/postgres/protocol/Authentication.zig");
    // Wave-26 grinder (2026-05-19) — fresh leaves from less-mined
    // corners. Each carries the standard home_rt rewrite + inline tests;
    // method-bodies that reach into wave-16/18 NewReader stubs trip a
    // normal Zig "no method named X" compile error only if exercised.
    //   - runtime/cli/which_npm_client: NPMClient pure descriptor.
    //   - sql/postgres/protocol/FieldMessage: tagged-union over the
    //     FieldType enum carrying each `T<value>` pair in an
    //     ErrorResponse / NoticeResponse body. `bun.String` substituted
    //     with a heap-owned `[]u8` slice + matching cloneUTF8/deref.
    //   - sql/postgres/protocol/ErrorResponse: `E` backend packet (stream
    //     of FieldMessage records) — fatal-or-info from the server.
    //   - sql/postgres/protocol/NoticeResponse: `N` backend packet,
    //     same shape as ErrorResponse but non-fatal.
    _ = @import("runtime/cli/which_npm_client.zig");
    _ = @import("sql/postgres/protocol/FieldMessage.zig");
    _ = @import("sql/postgres/protocol/ErrorResponse.zig");
    _ = @import("sql/postgres/protocol/NoticeResponse.zig");
    _ = @import("sql/postgres/protocol/NegotiateProtocolVersion.zig");
}
