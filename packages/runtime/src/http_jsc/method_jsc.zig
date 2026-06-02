// Copied from bun/src/http_jsc/method_jsc.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
// Imports rewritten: @import("bun") → @import("home"); bun.jsc → home_rt.jsc.
// JSC-bridge `Bun__HTTPMethod__toJS` stays as an extern decl — the C++
// definition re-lands in Phase 12.2 alongside the rest of the JSC engine.

//! JSC bridge for `home_rt.http_types.Method`. Keeps `src/http_types/` free of JSC types.

// JSC-bridge omitted — Phase 12.2 (`Bun__HTTPMethod__toJS` extern stays
// declared so callers can name the symbol; resolves at link time once the
// C++ host fns land).
extern "c" fn Bun__HTTPMethod__toJS(method: Method, globalObject: *anyopaque) usize;

pub const toJS = Bun__HTTPMethod__toJS;

const Method = @import("../http_types/Method.zig").Method;

test "method_jsc: toJS symbol is declared" {
    // Compile-time presence check — the extern resolves at link time.
    const t = @TypeOf(toJS);
    _ = t;
}
