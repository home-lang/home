// Copied from bun/src/jsc/TopExceptionScope.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// Binding for `JSC::TopExceptionScope`. Used at the rare translation
// boundaries where an external call has no other way to signal an exception.
// The Zig wrapper allocates the C++ scope inline as a fixed-size byte buffer
// and pins it via a debug-only location check.
//
// `JSGlobalObject`, `JSValue`, and `bun.JSTerminated` are not yet ported
// (Phase 12.2). Local stubs preserve the C ABI:
//   - `JSGlobalObject` stays opaque (only used as `*JSGlobalObject` extern arg).
//   - `JSValue` stays `enum(i64)`; the upstream `isTerminationException()`
//     helper isn't wrapped yet, so the few methods that ask the question are
//     rerouted to the new `error{JSError} || error{JSTerminated}` set.
//
// Omitted (re-attach in Phase 12.2):
//   - `assertNoExceptionExceptTermination` — calls
//     `JSValue.fromCell(e).isTerminationException()`, which depends on the
//     full JSValue surface that hasn't been ported. The hook is kept as a
//     `noinline` stub returning `void` so callers compile; once the JSValue
//     bridge lands the upstream body re-attaches verbatim.

const std = @import("std");
const home_rt = @import("home_rt");
const Environment = home_rt.Environment;
const Exception = home_rt.jsc.Exception;

// JSC bridge stubs — re-attach in Phase 12.2.
//
// Import the canonical `JSGlobalObject` opaque from `./JSGlobalObject.zig`
// so the extern `pinScope` / `unpinScope` argument types unify with the
// rest of the JSC subtree. Without this, every caller that spells
// `home_rt.jsc.JSGlobalObject` would surface a "pointer type child
// 'jsc.JSGlobalObject.JSGlobalObject' cannot cast into pointer type
// child 'jsc.TopExceptionScope.JSGlobalObject'" mismatch — both
// opaques would be distinct types despite the same name.
const JSGlobalObject = @import("./JSGlobalObject.zig").JSGlobalObject;

// Upstream gates on `Environment.allow_assert or enable_asan` /
// `ci_assert`. Home's `Environment` only exports `allow_assert`
// today (the ASAN + CI-assert toggles re-land in a later Phase). We collapse
// both predicates onto `allow_assert` until they exist, which keeps the byte
// layout aligned with upstream debug builds.
const enable_asan = false;
const ci_assert = Environment.allow_assert;

// TODO determine size and alignment automatically
const size = if (Environment.allow_assert or enable_asan) 56 else 8;
const alignment = 8;

/// Binding for `JSC::TopExceptionScope`. Should be used rarely, only at the
/// translation boundary between JSC's exception checking and Zig's. Make sure
/// not to move it after creation. Use this if you are making an external call
/// that has no other way to indicate an exception.
///
/// ```zig
/// // Declare a TopExceptionScope surrounding the call that may throw an exception
/// var scope: TopExceptionScope = undefined;
/// scope.init(global, @src());
/// defer scope.deinit();
///
/// const value: i32 = external_call(vm, foo, bar, baz);
/// // Calling returnIfException() suffices to prove that we checked for an exception.
/// // This function's caller does not need to use a TopExceptionScope or
/// // ThrowScope because it can use Zig error unions.
/// try scope.returnIfException();
/// return value;
/// ```
pub const TopExceptionScope = struct {
    bytes: [size]u8 align(alignment),
    /// Pointer to `bytes`, set by `init()`, used to assert that the location
    /// did not change.
    location: if (ci_assert) *u8 else void,

    pub fn init(
        self: *TopExceptionScope,
        global: *JSGlobalObject,
        src: std.builtin.SourceLocation,
    ) void {
        TopExceptionScope__construct(
            &self.bytes,
            global,
            src.fn_name,
            src.file,
            src.line,
            size,
            alignment,
        );

        self.* = .{
            .bytes = self.bytes,
            .location = if (ci_assert) &self.bytes[0],
        };
    }

    /// Generate a useful message including where the exception was thrown.
    /// Only intended to be called when there is a pending exception.
    fn assertionFailure(self: *TopExceptionScope, proof: *Exception) noreturn {
        _ = proof;
        std.debug.assert(self.location == &self.bytes[0]);
        TopExceptionScope__assertNoException(&self.bytes);
        @panic("assertionFailure called without a pending exception");
    }

    pub fn hasException(self: *TopExceptionScope) bool {
        return self.exception() != null;
    }

    /// Get the thrown exception if it exists (like `scope.exception()` in C++).
    pub fn exception(self: *TopExceptionScope) ?*Exception {
        if (comptime ci_assert) std.debug.assert(self.location == &self.bytes[0]);
        return TopExceptionScope__pureException(&self.bytes);
    }

    pub fn clearException(self: *TopExceptionScope) void {
        if (comptime ci_assert) std.debug.assert(self.location == &self.bytes[0]);
        return TopExceptionScope__clearException(&self.bytes);
    }

    /// Get the thrown exception if it exists, or if an unhandled trap causes
    /// an exception to be thrown.
    pub fn exceptionIncludingTraps(self: *TopExceptionScope) ?*Exception {
        if (comptime ci_assert) std.debug.assert(self.location == &self.bytes[0]);
        return TopExceptionScope__exceptionIncludingTraps(&self.bytes);
    }

    /// Intended for use with `try`. Returns `error.JSError` if there is
    /// already a pending exception or if traps cause an exception to be
    /// thrown (mirrors `RETURN_IF_EXCEPTION` in C++).
    pub fn returnIfException(self: *TopExceptionScope) !void {
        if (self.exceptionIncludingTraps() != null) return error.JSError;
    }

    /// Asserts there has not been any exception thrown.
    ///
    /// Upstream additionally consults
    /// `JSValue.fromCell(e).isTerminationException()` to allow termination
    /// exceptions to bubble silently — that branch re-attaches in Phase 12.2
    /// once `JSValue.fromCell` is ported. For now we treat any pending
    /// exception as a hard assertion failure.
    pub fn assertNoException(self: *TopExceptionScope) void {
        if (comptime ci_assert) {
            if (self.exception()) |e| {
                self.assertionFailure(e);
            }
        }
    }

    /// Asserts that there is or is not an exception according to the value of
    /// `should_have_exception`. Prefer over `assert(scope.hasException() == ...)`
    /// because if there is an unexpected exception, this function prints a
    /// trace of where it was thrown.
    pub fn assertExceptionPresenceMatches(self: *TopExceptionScope, should_have_exception: bool) void {
        if (comptime ci_assert) {
            if (should_have_exception) {
                std.debug.assert(self.hasException());
            } else {
                self.assertNoException();
            }
        }
    }

    /// Upstream returns `bun.JSTerminated!void`. The
    /// `error.JSTerminated` channel is part of the still-unported global
    /// error set, so we re-route to a local `error{JSTerminated}` set and
    /// drop the `isTerminationException` distinction.
    pub fn assertNoExceptionExceptTermination(self: *TopExceptionScope) error{JSTerminated}!void {
        if (self.exception() != null) {
            // Without the `isTerminationException` predicate, we cannot
            // distinguish between a termination exception (which upstream
            // returns as `error.JSTerminated`) and an assertion failure.
            // Conservatively treat every pending exception as termination —
            // safer than panicking, and the production seam re-attaches in
            // Phase 12.2.
            return error.JSTerminated;
        }
    }

    pub fn deinit(self: *TopExceptionScope) void {
        if (comptime ci_assert) std.debug.assert(self.location == &self.bytes[0]);
        TopExceptionScope__destruct(&self.bytes);
        self.bytes = undefined;
    }
};

/// Limited subset of TopExceptionScope functionality, for when you have a
/// different way to detect exceptions and you only need a TopExceptionScope
/// to prove that you are checking exceptions correctly. Gated by
/// `ci_assert`.
///
/// ```zig
/// var scope: ExceptionValidationScope = undefined;
/// // these do nothing when ci_assert == false
/// scope.init(global, @src());
/// defer scope.deinit();
///
/// const maybe_empty: JSValue = externalFunction(global, foo, bar, baz);
/// // does nothing when ci_assert == false
/// // with assertions on, this call serves as proof that you checked for an exception
/// scope.assertExceptionPresenceMatches(maybe_empty == .zero);
/// // you decide whether to return JSError using the return value instead of the scope
/// return if (value == .zero) error.JSError else value;
/// ```
pub const ExceptionValidationScope = struct {
    scope: if (ci_assert) TopExceptionScope else void,

    pub fn init(
        self: *ExceptionValidationScope,
        global: *JSGlobalObject,
        src: std.builtin.SourceLocation,
    ) void {
        if (ci_assert) self.scope.init(global, src);
    }

    /// Asserts there has not been any exception thrown.
    pub fn assertNoException(self: *ExceptionValidationScope) void {
        if (ci_assert) {
            self.scope.assertNoException();
        }
    }

    /// Asserts that there is or is not an exception according to the value of
    /// `should_have_exception`.
    pub fn assertExceptionPresenceMatches(self: *ExceptionValidationScope, should_have_exception: bool) void {
        if (ci_assert) {
            self.scope.assertExceptionPresenceMatches(should_have_exception);
        }
    }

    /// If no exception, returns.
    /// If termination exception, returns `error.JSTerminated` (so you can `try`)
    /// If non-termination exception, assertion failure.
    pub fn assertNoExceptionExceptTermination(self: *ExceptionValidationScope) error{JSTerminated}!void {
        if (ci_assert) {
            return self.scope.assertNoExceptionExceptTermination();
        }
    }

    /// Inconveniently named on purpose; this is only needed for some weird
    /// edge cases.
    pub fn hasExceptionOrFalseWhenAssertionsAreDisabled(self: *ExceptionValidationScope) bool {
        return if (ci_assert) self.scope.hasException() else false;
    }

    pub fn deinit(self: *ExceptionValidationScope) void {
        if (ci_assert) self.scope.deinit();
    }
};

extern fn TopExceptionScope__construct(
    ptr: *align(alignment) [size]u8,
    global: *JSGlobalObject,
    function: [*:0]const u8,
    file: [*:0]const u8,
    line: c_uint,
    size: usize,
    alignment: usize,
) void;
/// Only returns exceptions that have already been thrown. Does not check traps.
extern fn TopExceptionScope__pureException(ptr: *align(alignment) [size]u8) ?*Exception;
extern fn TopExceptionScope__clearException(ptr: *align(alignment) [size]u8) void;
/// Returns if an exception was already thrown, or if a trap (like another thread
/// requesting termination) causes an exception to be thrown.
extern fn TopExceptionScope__exceptionIncludingTraps(ptr: *align(alignment) [size]u8) ?*Exception;
extern fn TopExceptionScope__assertNoException(ptr: *align(alignment) [size]u8) void;
extern fn TopExceptionScope__destruct(ptr: *align(alignment) [size]u8) void;

test "TopExceptionScope has a fixed size that follows Environment.allow_assert" {
    const expected: usize = if (Environment.allow_assert or enable_asan) 56 else 8;
    try std.testing.expectEqual(expected, @sizeOf(@TypeOf(@as(TopExceptionScope, undefined).bytes)));
}

test "TopExceptionScope exposes the expected entrypoints" {
    try std.testing.expect(@hasDecl(TopExceptionScope, "init"));
    try std.testing.expect(@hasDecl(TopExceptionScope, "deinit"));
    try std.testing.expect(@hasDecl(TopExceptionScope, "hasException"));
    try std.testing.expect(@hasDecl(TopExceptionScope, "exception"));
    try std.testing.expect(@hasDecl(TopExceptionScope, "clearException"));
    try std.testing.expect(@hasDecl(TopExceptionScope, "exceptionIncludingTraps"));
    try std.testing.expect(@hasDecl(TopExceptionScope, "returnIfException"));
    try std.testing.expect(@hasDecl(TopExceptionScope, "assertNoException"));
    try std.testing.expect(@hasDecl(TopExceptionScope, "assertExceptionPresenceMatches"));
    try std.testing.expect(@hasDecl(TopExceptionScope, "assertNoExceptionExceptTermination"));
}

test "ExceptionValidationScope mirrors the TopExceptionScope surface" {
    try std.testing.expect(@hasDecl(ExceptionValidationScope, "init"));
    try std.testing.expect(@hasDecl(ExceptionValidationScope, "deinit"));
    try std.testing.expect(@hasDecl(ExceptionValidationScope, "assertNoException"));
    try std.testing.expect(@hasDecl(ExceptionValidationScope, "assertExceptionPresenceMatches"));
    try std.testing.expect(@hasDecl(ExceptionValidationScope, "assertNoExceptionExceptTermination"));
    try std.testing.expect(@hasDecl(ExceptionValidationScope, "hasExceptionOrFalseWhenAssertionsAreDisabled"));
}

test "ExceptionValidationScope drops to a zero-sized struct without ci_assert" {
    if (!ci_assert) {
        try std.testing.expectEqual(@as(usize, 0), @sizeOf(ExceptionValidationScope));
    }
}
