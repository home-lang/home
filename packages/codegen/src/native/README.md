# packages/codegen/src/native/

Per-construct submodules extracted from `packages/codegen/src/native_codegen.zig`
(10 889 LOC at start of Phase 0.8).

Per [`docs/TS_PARITY_PLAN.md`](../../../../docs/TS_PARITY_PLAN.md) §0
Phase 0.8 ("split native_codegen.zig into instruction-selection,
scheduling, register-allocation modules; pure refactor; all existing
codegen tests must pass").

## Status

Phase 0.8 lands the **directory + extraction pattern + first
module** (`layouts.zig`). The remaining sections are scheduled as
Phase 0.8-followups, each landing as a separate PR with the codegen
test suite as the regression gate.

## Planned splits

Approximate line ranges from the monolith at the start of the
refactor (numbers will drift as extractions happen):

| Module | Source range (original) | Status |
|---|---|---|
| `layouts.zig` | 102–204 (StructLayout, FieldInfo, EnumLayout, LoopContext, LocalInfo, FunctionParamInfo, FunctionInfo, StringFixup) | ✅ Phase 0.8 — extracted |
| `register_allocator.zig` | 205–269 (RegisterAllocator) | ⬜ |
| `cpu_features.zig` | 270–315 (CpuFeatures) | ⬜ |
| `vectorizer.zig` | 316–645 (Vectorizer + VectorOp + VectorizationCost + VectorizablePattern) | ⬜ |
| `instruction_selection.zig` | 646–4000 (instruction selection emit paths — large) | ⬜ |
| `scheduling.zig` | (post-isel: instruction scheduling pass) | ⬜ |
| `monomorphization_emit.zig` | (TS-subset monomorphic specialization emit; existing `monomorphization.zig` covers Home generics) | ⬜ |
| `prologue_epilogue.zig` | (function prologue / epilogue / call ABI) | ⬜ |
| `data_section.zig` | (string fixups, .rodata layout) | ⬜ |
| `errors.zig` | 28–100 (CodegenError + diagnostic helpers) | ⬜ |

## Refactor protocol

1. Extract one module at a time.
2. Run the **codegen test suite** before and after each extraction;

   any regression blocks the merge.

3. Update the table above.

## Why we're doing this gradually

native_codegen.zig is the largest single file in the codebase and
its sections share a lot of state (locals, constants, fixup tables,
register state). Splitting requires understanding that state graph;
attempting it in one shot is high-risk and slows down concurrent
work in `packages/codegen/`. Phase 0 unblocks Phase 7 (native
codegen for TS) by establishing the _pattern_; the full split
proceeds as mechanical follow-up work that can run concurrently
with Phase 1–4.
