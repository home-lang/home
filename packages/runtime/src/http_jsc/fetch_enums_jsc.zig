// Copied from bun/src/http_jsc/fetch_enums_jsc.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
// Imports rewritten: @import("bun") → @import("home_rt"). Upstream spells
// the Fetch* enums as `bun.http.FetchRedirect` (a re-export of
// `http_types/Fetch*`); Home keeps them only under `http_types/` so the
// references resolve to `home_rt.http_types.Fetch*`.
// JSC-bridge `Bun__Fetch*__toJS` externs stay declared — the C++ host fns
// re-land in Phase 12.2.

//! `toJS` bridges for the small `http_types/Fetch*` enums. The enum types
//! themselves stay in `http_types/`; only the JSC extern + wrapper live here
//! so `http_types/` has no `JSValue`/`JSGlobalObject` references.

// JSC-bridge omitted — Phase 12.2.
extern "c" fn Bun__FetchRedirect__toJS(v: u8, global: *anyopaque) usize;
pub fn fetchRedirectToJS(this: home_rt.http_types.FetchRedirect, global: *anyopaque) usize {
    return Bun__FetchRedirect__toJS(@intFromEnum(this), global);
}

// JSC-bridge omitted — Phase 12.2.
extern "c" fn Bun__FetchRequestMode__toJS(v: u8, global: *anyopaque) usize;
pub fn fetchRequestModeToJS(this: home_rt.http_types.FetchRequestMode, global: *anyopaque) usize {
    return Bun__FetchRequestMode__toJS(@intFromEnum(this), global);
}

// JSC-bridge omitted — Phase 12.2.
extern "c" fn Bun__FetchCacheMode__toJS(v: u8, global: *anyopaque) usize;
pub fn fetchCacheModeToJS(this: home_rt.http_types.FetchCacheMode, global: *anyopaque) usize {
    return Bun__FetchCacheMode__toJS(@intFromEnum(this), global);
}

const home_rt = @import("home_rt");

test "fetch_enums_jsc: bridges name all three Fetch* enums" {
    _ = fetchRedirectToJS;
    _ = fetchRequestModeToJS;
    _ = fetchCacheModeToJS;
}
