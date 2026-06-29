//! TS checker — Phase 3 of TS_PARITY_PLAN.
//!
//! Phase 3 ships the foundation: type representation, structural
//! interner, and the four core relations (identity / assignable /
//! subtype / comparable). The full conformance work (Phase 6) hangs
//! off this same shape.
//!
//! What's *not* here yet (tracked as Phase 3 / 6 follow-ups):
//!   - HIR → type lowering (taking a parsed file plus binder output
//!     and producing typed expressions)
//!   - Generic instantiation and inference
//!   - Mapped / conditional type evaluation under substitution
//!   - Control-flow narrowing
//!   - Variance computation per type parameter
//!   - Strict-mode flag handling
//!
//! Public re-exports give consumers (the eventual driver, the LSP,
//! Phase 4's emitter) a stable surface to compile against.

pub const types = @import("types.zig");
pub const interner = @import("interner.zig");
pub const relation = @import("relation.zig");
pub const lower = @import("lower.zig");
pub const check = @import("check.zig");
pub const render = @import("render.zig");

pub const TypeId = types.TypeId;
pub const Primitive = types.Primitive;
pub const TypeFlags = types.TypeFlags;
pub const Pool = types.Pool;
pub const Interner = interner.Interner;
pub const TypeKey = interner.TypeKey;
pub const Engine = relation.Engine;
pub const Relation = relation.Relation;
pub const RelationCache = relation.RelationCache;
pub const Lowerer = lower.Lowerer;
pub const Checker = check.Checker;
pub const Diagnostic = check.Diagnostic;
pub const DiagnosticChainEntry = check.DiagnosticChainEntry;
pub const RelatedInfo = check.RelatedInfo;
pub const StrictFlags = check.StrictFlags;
pub const ExternalResolver = check.ExternalResolver;
pub const ScriptObjectExpando = check.ScriptObjectExpando;
pub const ModuleInterfaceAugmentation = check.ModuleInterfaceAugmentation;
pub const ProgramExportedClass = check.ProgramExportedClass;
pub const ProgramExportedClassMember = check.ProgramExportedClassMember;
pub const ProgramAmbientModuleInterfaceExport = check.ProgramAmbientModuleInterfaceExport;
pub const ProgramAmbientInterfaceMember = check.ProgramAmbientInterfaceMember;
pub const renderType = render.renderType;

const std = @import("std");
const T = std.testing;

test {
    _ = types;
    _ = interner;
    _ = relation;
    _ = lower;
    _ = check;
    _ = render;
    _ = @import("lib.zig");
}

test "ts_checker: end-to-end smoke" {
    var ti = try Interner.init(T.allocator);
    defer ti.deinit();
    var e = try Engine.init(T.allocator, &ti);
    defer e.deinit();

    // Build `"hello" | "world"`.
    const hello = try ti.internStringLiteral(1);
    const world = try ti.internStringLiteral(2);
    const u = try ti.internUnion(&.{ hello, world });

    // The union assigns to `string`.
    try T.expect(try e.isAssignableTo(u, Primitive.string_t));
    // `string` does NOT assign to the union.
    try T.expect(!try e.isAssignableTo(Primitive.string_t, u));
    // `"hello"` assigns to the union.
    try T.expect(try e.isAssignableTo(hello, u));
    // The two literals are distinct.
    try T.expect(hello != world);
}
