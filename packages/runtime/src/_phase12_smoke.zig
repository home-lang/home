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
    _ = @import("jsc/generated_classes_list.zig");
    _ = @import("runtime/api/bun/Terminal.zig");
    _ = @import("runtime/api/bun/spawn.zig");
    _ = @import("runtime/api/glob.zig");
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
    // Wave-18 Tier-0 grinder (2026-05-18) — sql wire-protocol leaves.
    _ = @import("sql/shared/Data.zig");
    _ = @import("sql/mysql/protocol/NewReader.zig");
    _ = @import("sql/mysql/protocol/EOFPacket.zig");
    _ = @import("sql/mysql/protocol/StmtPrepareOKPacket.zig");
    _ = @import("sql/mysql/protocol/LocalInfileRequest.zig");
    _ = @import("sql/mysql/protocol/OKPacket.zig");
    _ = @import("sql/postgres/protocol/PasswordMessage.zig");
    _ = @import("sql/postgres/protocol/SASLResponse.zig");
    _ = @import("sql/postgres/protocol/SASLInitialResponse.zig");
    _ = @import("sql/postgres/protocol/CopyOutResponse.zig");
    _ = @import("sql/postgres/protocol/Parse.zig");
    _ = @import("sql/postgres/protocol/ReadyForQuery.zig");
    _ = @import("sql/postgres/protocol/ParameterStatus.zig");
    _ = @import("sql/postgres/protocol/DataRow.zig");
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
}
