// Real implementations for the `$zig(...)`/`@lazy(id)` JS2Native bindings that
// the embedded node/bun JS modules call. Bun's codegen normally emits these
// C-ABI thunks (generated_js2native.rs); Home links Bun's compiled JS + the C++
// dispatch (GeneratedJS2Native / callJS2Native), which declares each thunk as an
// `extern "C"` the Zig side must provide. `native_stubs.zig` satisfies the rest
// with `noop` — so e.g. `fs = @lazy(53)` (→ callJS2Native(53) →
// node_fs_binding.createBinding) returned undefined and node:fs/node:fs.promises
// crashed at `fs.readFile.bind(fs)`. These export the real functions.
//
// SCOPE: only binding modules that currently compile in Home are wired here
// (fs/util/net/assert/zlib/types/Stat). os/crypto/cluster/http need the bindgen
// `bun.gen` subsystem and/or have unported gaps, so they stay noop in
// native_stubs.zig until those land. Gated behind enable_jsc (imported from
// home.zig's enable_jsc block) — the dispatch only exists in the JSC build.
//
// Two thunk shapes (see GeneratedJS2Native.h):
//   * Lazy bindings  — `..._workaround(*GlobalObject) -> EncodedJSValue`
//   * Host functions — `...(*GlobalObject, *CallFrame) -> EncodedJSValue`
//     (the standard JSHostFn shape; wrapped via toJSHostFn for JSError handling)

const bun = @import("home");
const jsc = bun.jsc;
const JSGlobalObject = jsc.JSGlobalObject;
const JSValue = jsc.JSValue;
const host_fn = @import("./host_fn.zig");

const node_os = @import("../runtime/node/node_os.zig");
const node_fs_binding = @import("../runtime/node/node_fs_binding.zig");
const node_assert_binding = @import("../runtime/node/node_assert_binding.zig");
const node_net_binding = @import("../runtime/node/node_net_binding.zig");
const node_zlib_binding = @import("../runtime/node/node_zlib_binding.zig");
const node_util_binding = @import("../runtime/node/node_util_binding.zig");
const node_crypto_binding = @import("../runtime/node/node_crypto_binding.zig");
const node_http_binding = @import("../runtime/node/node_http_binding.zig");
const node_parse_args = @import("../runtime/node/util/parse_args.zig");
const Timer = @import("../runtime/timer/Timer.zig");
const dns = @import("../runtime/dns_jsc/dns.zig");
const node_cluster_binding = @import("../runtime/node/node_cluster_binding.zig");
const socket = @import("../runtime/socket/socket.zig");
const udp_socket = @import("../runtime/socket/udp_socket.zig");
const h2_frame_parser = @import("../runtime/api/bun/h2_frame_parser.zig");
const Listener = @import("../runtime/socket/Listener.zig");
const ffi = @import("../runtime/ffi/ffi.zig");
const fetch = @import("../runtime/webcore/fetch.zig");
const sql_postgres = @import("../sql_jsc/postgres.zig");
const sql_mysql = @import("../sql_jsc/mysql.zig");
const node_types = @import("../runtime/node/types.zig");
const Stat = @import("../runtime/node/Stat.zig");
const error_jsc = @import("../sys_jsc/error_jsc.zig");
const secure_context = @import("../runtime/api/bun/SecureContext.zig");
const BunObject = @import("../runtime/api/BunObject.zig");
const shell = @import("../runtime/shell/shell.zig");
const NodeModuleModule = @import("NodeModuleModule.zig");
const escapeRegExp = @import("../string/escapeRegExp.zig");
const bun_string_jsc = @import("bun_string_jsc.zig");
const IniTestingAPIs = @import("../install_jsc/ini_jsc.zig").IniTestingAPIs;

/// Real Zig dispatch for `$.braces(...)`. The pinned-obj C++ wrapper
/// `bindgen_BunObject_jsBraces` marshals JS args, then calls this. native_stubs
/// had noop-stubbed it, so `$.braces(...)` returned garbage (the noop leaves the
/// return register holding globalThis). Mirrors the pin's generated dispatch
/// (GeneratedBindings.zig): forward to `BunObject.braces` via `toJSHostCall`,
/// which turns a thrown JSError into `.zero`. `BracesOptions` layout is the
/// hand-mirror in runtime/node/GeneratedBindings.zig (`bun.gen.BunObject`).
fn bindgen_BunObject_dispatchBraces1_impl(
    global: *JSGlobalObject,
    input: *const bun.String,
    options: *const bun.gen.BunObject.BracesOptions,
) callconv(.c) JSValue {
    return jsc.toJSHostCall(global, @src(), BunObject.braces, .{ global, input.*, options.* });
}

/// Real Zig dispatch for `Bun.gc(force)`. The pinned-obj C++ wrapper
/// `bindgen_BunObject_jsGc` passes `&force` in and `&out` for the heap size,
/// then encodes `out` as the JS return. native_stubs noop-stubbed this, so the
/// out-param was never written — `Bun.gc()` returned uninitialized stack garbage
/// (a pointer-sized number) instead of the reported heap size. Mirrors the pin.
fn bindgen_BunObject_dispatchGc1_impl(
    global: *JSGlobalObject,
    arg_force: *const bool,
    out: *usize,
) callconv(.c) bool {
    out.* = BunObject.gc(global.bunVM(), arg_force.*);
    return true;
}

/// Real Zig dispatch for `Module._stat(path)` (node:module). The pinned-obj C++
/// wrapper `bindgen_NodeModuleModule_js_stat` passes `&path` in and `&out` (i32)
/// for the result (0=file, 1=dir, -1=missing). native_stubs noop-stubbed this,
/// so the out-param was never written — `Module._stat(...)` returned garbage,
/// which the CJS resolver reads as a bogus file/dir kind. Mirrors the pin.
fn bindgen_NodeModuleModule_dispatch_stat1_impl(
    _: *JSGlobalObject,
    arg_str: *const bun.String,
    out: *i32,
) callconv(.c) bool {
    const utf8 = arg_str.toUTF8(bun.default_allocator);
    defer utf8.deinit();
    out.* = NodeModuleModule._stat(utf8.slice());
    return true;
}

// The bindgen `Formatter` string-enum ("highlight-javascript",
// "escape-powershell"). VALUES must match the pin's generated
// GeneratedBindings.zig `Formatter` (escape_powershell=0, highlight_javascript=1),
// because the linked pin C++ (`bindgen_Fmt_jsc_jsFmtString`) marshals the JS
// string arg to those numeric values before calling the dispatch below. (Home's
// jsc/fmt_jsc.zig declares its own Formatter in the opposite order for its
// name-locking tests — do NOT reuse it here; only the C-ABI value matters.)
const FmtFormatter = enum(u8) { escape_powershell = 0, highlight_javascript = 1 };

fn fmtStringImpl(global: *JSGlobalObject, code: []const u8, formatter: FmtFormatter) bun.JSError!bun.String {
    var buffer = bun.MutableString.initEmpty(bun.default_allocator);
    defer buffer.deinit();
    var w = buffer.bufferedWriter();
    switch (formatter) {
        // `bun.fmt.fmtJavaScript` is Home's pared-down highlighter (the full
        // `bun_core/fmt.zig` one needs unported `strings.startsWith{Secret,UUID}`).
        .highlight_javascript => {
            const f = bun.fmt.fmtJavaScript(code, .{ .enable_colors = true });
            w.writer().print("{f}", .{f}) catch |err| return global.throwError(err, "while formatting");
        },
        // Inlined `bun_core/fmt.zig`'s escapePowershellImpl (prefix `"` and `` ` ``
        // with a backtick) — self-contained, avoids importing the whole file.
        .escape_powershell => {
            var remain = code;
            while (bun.strings.indexOfAny(remain, "\"`")) |i| {
                w.writer().print("{s}`{s}", .{ remain[0..i], remain[i .. i + 1] }) catch |err| return global.throwError(err, "while formatting");
                remain = remain[i + 1 ..];
            }
            w.writer().print("{s}", .{remain}) catch |err| return global.throwError(err, "while formatting");
        },
    }
    w.flush() catch |err| return global.throwError(err, "while formatting");
    return bun.String.cloneUTF8(buffer.list.items);
}

/// Real Zig dispatch for `fmtString` (bun:internal-for-testing `highlightJavaScript`
/// / `escapePowershell`). The pinned-obj C++ wrapper `bindgen_Fmt_jsc_jsFmtString`
/// marshals (code, formatter) and calls this. native_stubs noop-stubbed it, so the
/// out-param was never written. Mirrors the pin's generated dispatch.
fn bindgen_Fmt_jsc_dispatchFmtString1_impl(
    arg_global: *JSGlobalObject,
    arg_code: *const bun.String,
    arg_formatter: *const FmtFormatter,
    out: *bun.String,
) callconv(.c) bool {
    const code_utf8 = arg_code.toUTF8(bun.default_allocator);
    defer code_utf8.deinit();
    // On error the pending JS exception is already set (fmtStringImpl routes every
    // failure through global.throwError / throwOutOfMemory); signal failure via the
    // bool return, matching the pin's dispatch contract.
    out.* = fmtStringImpl(arg_global, code_utf8.slice(), arg_formatter.*) catch {
        return false;
    };
    return true;
}

const jsFmtString = @extern(*const host_fn.JSHostFn, .{ .name = "bindgen_Fmt_jsc_jsFmtString" });

/// Lazy binding for `$bindgenFn("fmt_jsc.bind.ts", "fmtString")` — returns the
/// `fmtString` host function. native_stubs noop-stubbed this so the JS side got
/// globalThis back ("fmtBinding is not a function"). Mirrors the pin's
/// `createFmtStringCallback`.
fn js2native_bindgen_fmt_jsc_fmtString_impl(global: *JSGlobalObject) callconv(jsc.conv) JSValue {
    return host_fn.NewRuntimeFunction(global, jsc.ZigString.static("fmtString"), 3, jsFmtString, false, null);
}

/// Wrap a `fn(*GlobalObject) JSValue` lazy binding as a C-ABI thunk.
fn lazy(comptime f: fn (*JSGlobalObject) callconv(.auto) JSValue) fn (*JSGlobalObject) callconv(jsc.conv) JSValue {
    return struct {
        fn call(global: *JSGlobalObject) callconv(jsc.conv) JSValue {
            return f(global);
        }
    }.call;
}

/// Wrap a `fn(*GlobalObject) JSError!JSValue` lazy binding, surfacing a thrown
/// exception as `.zero` (faithful to toJSHostFnResult).
fn lazyErr(comptime f: fn (*JSGlobalObject) callconv(.auto) bun.JSError!JSValue) fn (*JSGlobalObject) callconv(jsc.conv) JSValue {
    return struct {
        fn call(global: *JSGlobalObject) callconv(jsc.conv) JSValue {
            return host_fn.toJSHostFnResult(global, f(global));
        }
    }.call;
}

comptime {
    // ---- bindgen dispatches (real, replacing native_stubs no-ops) -------
    @export(&bindgen_BunObject_dispatchBraces1_impl, .{ .name = "bindgen_BunObject_dispatchBraces1" });
    @export(&bindgen_BunObject_dispatchGc1_impl, .{ .name = "bindgen_BunObject_dispatchGc1" });
    @export(&bindgen_NodeModuleModule_dispatch_stat1_impl, .{ .name = "bindgen_NodeModuleModule_dispatch_stat1" });

    // ---- fmt_jsc fmtString (bun:internal-for-testing highlightJavaScript) ----
    @export(&bindgen_Fmt_jsc_dispatchFmtString1_impl, .{ .name = "bindgen_Fmt_jsc_dispatchFmtString1" });
    @export(&js2native_bindgen_fmt_jsc_fmtString_impl, .{ .name = "js2native_bindgen_fmt_jsc_fmtString" });

    // ---- shell TestingAPIs (bun:internal-for-testing shellInternals) ----
    // Real exports for the shell lexer/parser test hooks. native_stubs had
    // these noop-stubbed, so `shellInternals.lex/parse/disabledOnPosix` in
    // lex.test.ts / parse.test.ts returned garbage and the files were skipped.
    @export(&host_fn.toJSHostFn(shell.TestingAPIs.shellLex), .{ .name = "JS2Zig___src_runtime_shell_shell_zig__TestingAPIs_shellLex" });
    @export(&host_fn.toJSHostFn(shell.TestingAPIs.shellParse), .{ .name = "JS2Zig___src_runtime_shell_shell_zig__TestingAPIs_shellParse" });
    @export(&host_fn.toJSHostFn(shell.TestingAPIs.disabledOnThisPlatform), .{ .name = "JS2Zig___src_runtime_shell_shell_zig__TestingAPIs_disabledOnThisPlatform" });

    // ---- string escapeRegExp TestingAPIs (bun:internal-for-testing) -----
    @export(&host_fn.toJSHostFn(escapeRegExp.jsEscapeRegExp), .{ .name = "JS2Zig___src_string_escapeRegExp_zig__jsEscapeRegExp" });
    @export(&host_fn.toJSHostFn(escapeRegExp.jsEscapeRegExpForPackageNameMatching), .{ .name = "JS2Zig___src_string_escapeRegExp_zig__jsEscapeRegExpForPackageNameMatching" });

    // ---- strings.toUTF16AllocSentinel TestingAPI (stringsInternals) -----
    @export(&host_fn.toJSHostFn(bun_string_jsc.UnicodeTestingAPIs.toUTF16AllocSentinel), .{ .name = "JS2Zig___src_bun_core_string_immutable_unicode_zig__TestingAPIs_toUTF__AllocSentinel" });

    // ---- ini IniTestingAPIs (iniInternals.parse / loadNpmrc) ------------
    @export(&host_fn.toJSHostFn(IniTestingAPIs.parse), .{ .name = "JS2Zig___src_ini_ini_zig__IniTestingAPIs_parse" });
    @export(&host_fn.toJSHostFn(IniTestingAPIs.loadNpmrcFromJS), .{ .name = "JS2Zig___src_ini_ini_zig__IniTestingAPIs_loadNpmrcFromJS" });

    // ---- Lazy bindings (`..._workaround`) -------------------------------
    @export(&lazyErr(node_os.createNodeOsBinding), .{ .name = "JS2Zig___src_runtime_node_node_os_zig__createNodeOsBinding_workaround" });
    @export(&lazy(node_fs_binding.createBinding), .{ .name = "JS2Zig___src_runtime_node_node_fs_binding_zig__createBinding_workaround" });
    @export(&lazy(node_assert_binding.generate), .{ .name = "JS2Zig___src_runtime_node_node_assert_binding_zig__generate_workaround" });
    @export(&lazy(node_net_binding.getDefaultAutoSelectFamily), .{ .name = "JS2Zig___src_runtime_node_node_net_binding_zig__getDefaultAutoSelectFamily_workaround" });
    @export(&lazy(node_net_binding.setDefaultAutoSelectFamily), .{ .name = "JS2Zig___src_runtime_node_node_net_binding_zig__setDefaultAutoSelectFamily_workaround" });
    @export(&lazy(node_net_binding.getDefaultAutoSelectFamilyAttemptTimeout), .{ .name = "JS2Zig___src_runtime_node_node_net_binding_zig__getDefaultAutoSelectFamilyAttemptTimeout_workaround" });
    @export(&lazy(node_net_binding.setDefaultAutoSelectFamilyAttemptTimeout), .{ .name = "JS2Zig___src_runtime_node_node_net_binding_zig__setDefaultAutoSelectFamilyAttemptTimeout_workaround" });
    @export(&lazy(node_net_binding.SocketAddress), .{ .name = "JS2Zig___src_runtime_node_node_net_binding_zig__SocketAddress_workaround" });
    @export(&lazy(node_net_binding.BlockList), .{ .name = "JS2Zig___src_runtime_node_node_net_binding_zig__BlockList_workaround" });
    @export(&lazy(node_zlib_binding.NativeZlib), .{ .name = "JS2Zig___src_runtime_node_node_zlib_binding_zig__NativeZlib_workaround" });
    @export(&lazy(node_zlib_binding.NativeBrotli), .{ .name = "JS2Zig___src_runtime_node_node_zlib_binding_zig__NativeBrotli_workaround" });
    @export(&lazy(node_zlib_binding.NativeZstd), .{ .name = "JS2Zig___src_runtime_node_node_zlib_binding_zig__NativeZstd_workaround" });
    // node:crypto binding — the embedded crypto.ts reads pbkdf2/pbkdf2Sync/
    // randomBytes/randomInt/randomFill/scrypt/timingSafeEqual/getHashes/etc.
    // from here. Was noop in native_stubs.zig, leaving them all `undefined`.
    @export(&lazy(node_crypto_binding.createNodeCryptoBindingZig), .{ .name = "JS2Zig___src_runtime_node_node_crypto_binding_zig__createNodeCryptoBindingZig_workaround" });
    // Bun.sql drivers (Postgres/MySQL) + http2 frame-parser class constructor.
    @export(&lazy(sql_postgres.createBinding), .{ .name = "JS2Zig___src_sql_jsc_postgres_zig__createBinding_workaround" });
    @export(&lazy(sql_mysql.createBinding), .{ .name = "JS2Zig___src_sql_jsc_mysql_zig__createBinding_workaround" });
    @export(&lazy(h2_frame_parser.H2FrameParserConstructor), .{ .name = "JS2Zig___src_runtime_api_bun_h__frame_parser_zig__H_FrameParserConstructor_workaround" });

    // ---- Host functions (no suffix) -------------------------------------
    @export(&host_fn.toJSHostFn(node_util_binding.normalizeEncoding), .{ .name = "JS2Zig___src_runtime_node_node_util_binding_zig__normalizeEncoding" });
    @export(&host_fn.toJSHostFn(node_util_binding.parseEnv), .{ .name = "JS2Zig___src_runtime_node_node_util_binding_zig__parseEnv" });
    @export(&host_fn.toJSHostFn(node_util_binding.internalErrorName), .{ .name = "JS2Zig___src_runtime_node_node_util_binding_zig__internalErrorName" });
    @export(&host_fn.toJSHostFn(node_util_binding.enobufsErrorCode), .{ .name = "JS2Zig___src_runtime_node_node_util_binding_zig__enobufsErrorCode" });
    @export(&host_fn.toJSHostFn(node_util_binding.etimedoutErrorCode), .{ .name = "JS2Zig___src_runtime_node_node_util_binding_zig__etimedoutErrorCode" });
    @export(&host_fn.toJSHostFn(node_util_binding.extractedSplitNewLinesFastPathStringsOnly), .{ .name = "JS2Zig___src_runtime_node_node_util_binding_zig__extractedSplitNewLinesFastPathStringsOnly" });
    @export(&host_fn.toJSHostFn(node_net_binding.newDetachedSocket), .{ .name = "JS2Zig___src_runtime_node_node_net_binding_zig__newDetachedSocket" });
    @export(&host_fn.toJSHostFn(node_net_binding.doConnect), .{ .name = "JS2Zig___src_runtime_node_node_net_binding_zig__doConnect" });
    @export(&host_fn.toJSHostFn(node_types.jsAssertEncodingValid), .{ .name = "JS2Zig___src_runtime_node_types_zig__jsAssertEncodingValid" });
    @export(&host_fn.toJSHostFn(Stat.createStatsForIno), .{ .name = "JS2Zig___src_runtime_node_Stat_zig__createStatsForIno" });
    // node:util.parseArgs + node:http maxHeaderSize get/set (were noop, so
    // util.parseArgs threw "not a function" and http.maxHeaderSize was undefined).
    @export(&host_fn.toJSHostFn(node_parse_args.parseArgs), .{ .name = "JS2Zig___src_runtime_node_util_parse_args_zig__parseArgs" });
    @export(&host_fn.toJSHostFn(node_http_binding.getMaxHTTPHeaderSize), .{ .name = "JS2Zig___src_runtime_node_node_http_binding_zig__getMaxHTTPHeaderSize" });
    @export(&host_fn.toJSHostFn(node_http_binding.setMaxHTTPHeaderSize), .{ .name = "JS2Zig___src_runtime_node_node_http_binding_zig__setMaxHTTPHeaderSize" });
    // node:http's server close path awaits this promise; without the real export
    // it was a native_stubs noop (returned undefined) and `.@then` threw, failing
    // ~60 node-http.test.ts cases at once.
    @export(&host_fn.toJSHostFn(node_http_binding.getBunServerAllClosedPromise), .{ .name = "JS2Zig___src_runtime_node_node_http_binding_zig__getBunServerAllClosedPromise" });
    // Self-contained pure-function bindings (were noop).
    @export(&host_fn.toJSHostFn(bun.String.jsGetStringWidth), .{ .name = "JS2Zig___src_string_string_zig__String_jsGetStringWidth" });
    @export(&host_fn.toJSHostFn(Timer.internal_bindings.timerClockMs), .{ .name = "JS2Zig___src_runtime_timer_Timer_zig__internal_bindings_timerClockMs" });
    // node:dns Resolver constructor + default result-order (were noop).
    @export(&host_fn.toJSHostFn(dns.Resolver.newResolver), .{ .name = "JS2Zig___src_runtime_dns_jsc_dns_zig__Resolver_newResolver" });
    @export(&host_fn.toJSHostFn(dns.Resolver.getRuntimeDefaultResultOrderOption), .{ .name = "JS2Zig___src_runtime_dns_jsc_dns_zig__Resolver_getRuntimeDefaultResultOrderOption" });
    // node:cluster IPC helpers (were noop).
    @export(&host_fn.toJSHostFn(node_cluster_binding.sendHelperChild), .{ .name = "JS2Zig___src_runtime_node_node_cluster_binding_zig__sendHelperChild" });
    @export(&host_fn.toJSHostFn(node_cluster_binding.onInternalMessageChild), .{ .name = "JS2Zig___src_runtime_node_node_cluster_binding_zig__onInternalMessageChild" });
    @export(&host_fn.toJSHostFn(node_cluster_binding.sendHelperPrimary), .{ .name = "JS2Zig___src_runtime_node_node_cluster_binding_zig__sendHelperPrimary" });
    @export(&host_fn.toJSHostFn(node_cluster_binding.onInternalMessagePrimary), .{ .name = "JS2Zig___src_runtime_node_node_cluster_binding_zig__onInternalMessagePrimary" });
    @export(&host_fn.toJSHostFn(node_cluster_binding.setRef), .{ .name = "JS2Zig___src_runtime_node_node_cluster_binding_zig__setRef" });
    @export(&host_fn.toJSHostFn(node_cluster_binding.channelIgnoreOneDisconnectEventListener), .{ .name = "JS2Zig___src_runtime_node_node_cluster_binding_zig__channelIgnoreOneDisconnectEventListener" });
    // Bun socket helpers (were noop).
    @export(&host_fn.toJSHostFn(socket.jsCreateSocketPair), .{ .name = "JS2Zig___src_runtime_socket_socket_zig__jsCreateSocketPair" });
    @export(&host_fn.toJSHostFn(socket.jsGetBufferedAmount), .{ .name = "JS2Zig___src_runtime_socket_socket_zig__jsGetBufferedAmount" });
    @export(&host_fn.toJSHostFn(socket.jsIsNamedPipeSocket), .{ .name = "JS2Zig___src_runtime_socket_socket_zig__jsIsNamedPipeSocket" });
    @export(&host_fn.toJSHostFn(socket.jsUpgradeDuplexToTLS), .{ .name = "JS2Zig___src_runtime_socket_socket_zig__jsUpgradeDuplexToTLS" });
    @export(&host_fn.toJSHostFn(socket.jsSetSocketOptions), .{ .name = "JS2Zig___src_runtime_socket_socket_zig__jsSetSocketOptions" });
    @export(&host_fn.toJSHostFn(udp_socket.UDPSocket.jsConnect), .{ .name = "JS2Zig___src_runtime_socket_udp_socket_zig__UDPSocket_jsConnect" });
    @export(&host_fn.toJSHostFn(udp_socket.UDPSocket.jsDisconnect), .{ .name = "JS2Zig___src_runtime_socket_udp_socket_zig__UDPSocket_jsDisconnect" });
    @export(&host_fn.toJSHostFn(h2_frame_parser.jsAssertSettings), .{ .name = "JS2Zig___src_runtime_api_bun_h__frame_parser_zig__jsAssertSettings" });
    @export(&host_fn.toJSHostFn(Listener.jsAddServerName), .{ .name = "JS2Zig___src_runtime_socket_Listener_zig__jsAddServerName" });
    @export(&host_fn.toJSHostFn(ffi.Bun__FFI__cc), .{ .name = "JS2Zig___src_runtime_ffi_ffi_zig__Bun__FFI__cc" });
    @export(&host_fn.toJSHostFn(fetch.nodeHttpClient), .{ .name = "JS2Zig___src_runtime_webcore_fetch_zig__nodeHttpClient" });
    @export(&host_fn.toJSHostFn(node_zlib_binding.crc32), .{ .name = "JS2Zig___src_runtime_node_node_zlib_binding_zig__crc__" });
    @export(&host_fn.toJSHostFn(node_fs_binding.createMemfdForTesting), .{ .name = "JS2Zig___src_runtime_node_node_fs_binding_zig__createMemfdForTesting" });
    // bun:internal-for-testing sys helpers. Were noop in native_stubs.zig, so
    // calling them returned `.zero` WITHOUT a pending exception — which trips
    // `toJSHostCall`'s `assertExceptionPresenceMatches` and PANICS the process
    // (translate-uv-error-windows.test.ts crashed on the first call). The real
    // impls live in error_jsc.TestingAPIs (off-Windows no-ops return undefined).
    @export(&host_fn.toJSHostFn(error_jsc.TestingAPIs.translateUVErrorToE), .{ .name = "JS2Zig___src_sys_sys_zig__TestingAPIs_translateUVErrorToE" });
    @export(&host_fn.toJSHostFn(error_jsc.TestingAPIs.sysErrorNameFromLibuv), .{ .name = "JS2Zig___src_sys_Error_zig__TestingAPIs_sysErrorNameFromLibuv" });
    // node:tls SecureContext: `NativeSecureContext = $zig("SecureContext.zig",
    // "js.getConstructor")` + the jsLiveCount churn-test helper. Were noop in
    // native_stubs → NativeSecureContext undefined → `.intern` undefined → ~80
    // node-tls tests failed.
    @export(&lazy(secure_context.js.getConstructor), .{ .name = "JS2Zig___src_runtime_api_bun_SecureContext_zig__js_getConstructor_workaround" });
    @export(&host_fn.toJSHostFn(secure_context.jsLiveCount), .{ .name = "JS2Zig___src_runtime_api_bun_SecureContext_zig__jsLiveCount" });
    // NOTE: sigactionLayout stays a native_stubs noop — its POSIX body uses
    // `home.sys.sigemptyset`, which isn't ported yet, so @export-ing it would
    // force that path to compile and fail. It has no crashing test depending on
    // it (its own test would just see undefined), unlike translateUVErrorToE.
}
