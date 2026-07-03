pub export var Bun__reported_memory_size: usize = 0;
pub export const Bun__githubURL: [*:0]const u8 = "https://github.com/oven-sh/bun";

const Environment = @import("environment.zig");

fn noop() callconv(.c) void {}
fn noopInt() callconv(.c) i32 {
    return 0;
}
fn noopSize() callconv(.c) usize {
    return 0;
}
fn noopPtr() callconv(.c) ?*anyopaque {
    return null;
}
fn noopBool() callconv(.c) bool {
    return false;
}
fn noopEncoded() callconv(.c) usize {
    return 0;
}
fn noopDetached(_: ?*anyopaque, _: usize) callconv(.c) void {}
fn noopDispatch(_: ?*anyopaque, _: ?*const u8, _: c_int) callconv(.c) void {}
extern fn u_hasBinaryProperty(c: c_int, which: c_int) callconv(.c) u8;
fn icuHasBinaryProperty(c: u32, which: c_uint) callconv(.c) bool {
    return u_hasBinaryProperty(@intCast(c), @intCast(which)) != 0;
}
fn abortingPanic(_: [*]u8, _: usize) callconv(.c) noreturn {
    @panic("Bun crash handler called");
}

comptime {
    @export(&abortingPanic, .{ .name = "Bun__crashHandler" });
    @export(&noopInt, .{ .name = "Bun__doesMacOSVersionSupportSendRecvMsgX" });
    @export(&noopSize, .{ .name = "NetworkSink__memoryCost" });
    @export(&noopBool, .{ .name = "Bun__CryptoHasherExtern__isXof" });
    @export(&noopBool, .{ .name = "Bun__streamIterEnabled" });
    // `icu_hasBinaryProperty` is provided by Bun's linked
    // `workaround-missing-symbols.cpp.o` (real ICU `u_hasBinaryProperty` via
    // WebKit); exporting Home's stub here duplicate-clashes with it.

    for ([_][]const u8{
        "ArrayBufferSink__controllerDetached",
        "FileSink__controllerDetached",
        "H3ResponseSink__controllerDetached",
        "HTTPResponseSink__controllerDetached",
        "HTTPSResponseSink__controllerDetached",
        "NetworkSink__controllerDetached",
    }) |name| {
        @export(&noopDetached, .{ .name = name });
    }

    for ([_][]const u8{
        "us_dispatch_keylog",
        "us_dispatch_session",
    }) |name| {
        @export(&noopDispatch, .{ .name = name });
    }

    for ([_][]const u8{
        "BunObject_lazyPropCb_isStandaloneExecutable",
        "H2FrameParserPrototype__pushPromise",
        "JS2Zig___src_collections_linear_fifo_zig__TestingAPIs_orderedRemoveProbe",
        "JS2Zig___src_sys_sys_zig__TestingAPIs_translateNtStatusToE",
        "SecureContextClass__create_private",
        "SecureContextClass__parse_pkcs12",
        "SecureContextPrototype__add_ca_cert",
        "TCPSocketPrototype__getTypeOfService",
        "TCPSocketPrototype__resumeSNI",
        "TCPSocketPrototype__setKeyCert",
        "TCPSocketPrototype__setTypeOfService",
        "TLSSocketPrototype__getTypeOfService",
        "TLSSocketPrototype__resumeSNI",
        "TLSSocketPrototype__setKeyCert",
        "TLSSocketPrototype__setTypeOfService",
    }) |name| {
        @export(&noopEncoded, .{ .name = name });
    }

    for ([_][]const u8{
        "Bake__bundleNewRouteJSFunctionImpl",
        "Bake__getNewRouteParamsJSFunctionImpl",
        "Bun__dns_internal_registerQuic",
        "Bun__InspectorBunFrontendDevServerAgent__setEnabled",
        "Bun__Secrets__scheduleJob",
        "Bun__eventLoop__incrementRefConcurrently",
        "Bun__onRejectEntryPointResult",
        "Bun__onResolveEntryPointResult",
        "Bun__queueJSCDeferredWorkTaskConcurrently",
        "BlockList__onStructuredCloneDestroy",
        "CrashHandler__setDlOpenAction",
        "CrashHandler__setInsideNativePlugin",
        "CrashHandler__unsupportedUVFunction",
        "CryptoClass__finalize",
        "FileSink__assertLive",
        "NetworkSink__close",
        "NetworkSink__construct",
        "NetworkSink__end",
        "NetworkSink__endWithSink",
        "NetworkSink__finalize",
        "NetworkSink__flush",
        "NetworkSink__getInternalFd",
        "NetworkSink__start",
        "NetworkSink__updateRef",
        "NetworkSink__write",
        // ResolvePath__joinAbsStringBufCurrentPlatformBunString +
        // Resolver__nodeModulePaths{ForJS,JSValue} now have their real exports in
        // jsc/resolve_path_jsc.zig + jsc/resolver_jsc.zig (force-linked from
        // home.zig). The no-ops made relative Bun.pathToFileURL collapse to
        // file:/// and require.resolve.paths()/_nodeModulePaths return garbage.
        // HTTPRequestContext onResolve/onReject exports now have their real
        // request lifecycle callbacks in runtime/server/RequestContext.zig.
    }) |name| {
        @export(&noop, .{ .name = name });
    }

    if (!Environment.export_cpp_apis) {
        // NOTE: the JSSink method symbols (ArrayBufferSink/FileSink/H3ResponseSink/
        // HTTPResponseSink/HTTPSResponseSink __write/__end/__flush/__close/… and
        // Bun__FileSink__on{Resolve,Reject}Stream) are NO LONGER noop-stubbed here.
        // `Sink.JSSink` (and FileSink) now export their real Zig implementations
        // unconditionally; the noops silently broke every sink JS `.write()/.end()`
        // in the `.Exe` runtime build (e.g. subprocess `stdin:"pipe"` writes never
        // reached the child). Re-adding any of them here would be a duplicate symbol.
        // WebCore__alert/confirm/prompt are NO LONGER noop-stubbed: prompt.zig
        // now exports its real Zig implementations (force-linked from home.zig)
        // so `alert()/confirm()/prompt()` actually work in the `.Exe` build.
    }

    for ([_][]const u8{
        "ConcurrentCppTask__createAndRun",
        // toUTF16AllocSentinel now has its real export in
        // jsc/js2native_workarounds.zig — the noop returned garbage.
        "JS2Zig___src_bun_zig__getUseSystemCA",
        "JS2Zig___src_crash_handler_crash_handler_zig__js_bindings_generate_workaround",
        "JS2Zig___src_css_jsc_css_internals_zig___test",
        "JS2Zig___src_css_jsc_css_internals_zig__attrTest",
        "JS2Zig___src_css_jsc_css_internals_zig__minifyErrorTestWithOptions",
        "JS2Zig___src_css_jsc_css_internals_zig__minifyTest",
        "JS2Zig___src_css_jsc_css_internals_zig__minifyTestWithOptions",
        "JS2Zig___src_css_jsc_css_internals_zig__prefixTest",
        "JS2Zig___src_css_jsc_css_internals_zig__prefixTestWithOptions",
        "JS2Zig___src_css_jsc_css_internals_zig__testWithOptions",
        "JS2Zig___src_http_H_Client_zig__TestingAPIs_liveCounts",
        "JS2Zig___src_http_H_Client_zig__TestingAPIs_quicLiveCounts",
        // ini IniTestingAPIs now have real exports in js2native_workarounds.zig.
        "JS2Zig___src_install_dependency_zig__Version_Tag_inferFromJS",
        "JS2Zig___src_install_dependency_zig__fromJS",
        // hostedGitInfo fromUrl/parseUrl now have real exports in
        // jsc/js2native_workarounds.zig (the noops returned globalThis).
        "JS2Zig___src_install_jsc_install_binding_zig__bun_install_js_bindings_generate_workaround",
        "JS2Zig___src_install_npm_zig__Architecture_jsFunctionArchitectureIsMatch",
        "JS2Zig___src_install_npm_zig__OperatingSystem_jsFunctionOperatingSystemIsMatch",
        "JS2Zig___src_install_npm_zig__PackageManifest_bindings_generate_workaround",
        "JS2Zig___src_jsc_Counters_zig__createCountersObject",
        "JS2Zig___src_jsc_bindgen_test_zig__getBindgenTestFunctions_workaround",
        "JS2Zig___src_jsc_event_loop_zig__getActiveTasks",
        "JS2Zig___src_jsc_ipc_zig__emitHandleIPCMessage",
        "JS2Zig___src_jsc_virtual_machine_exports_zig__Bun__setSyntheticAllocationLimitForTesting",
        "JS2Zig___src_patch_patch_zig__TestingAPIs_apply",
        "JS2Zig___src_patch_patch_zig__TestingAPIs_makeDiff",
        "JS2Zig___src_patch_patch_zig__TestingAPIs_parse",
        "JS2Zig___src_runtime_api_bun_subprocess_zig__TestingAPIs_injectStdioReadError",
        "JS2Zig___src_runtime_bake_FrameworkRouter_zig__JSFrameworkRouter_getBindings_workaround",
        "JS2Zig___src_runtime_cli_pack_command_zig__bindings_jsReadTarball",
        "JS2Zig___src_runtime_cli_upgrade_command_zig__upgrade_js_bindings_generate_workaround",
        // getBunServerAllClosedPromise now has a real export in js2native_workarounds.zig.
        // shell TestingAPIs (shellLex/shellParse/disabledOnThisPlatform) now
        // have real exports in jsc/js2native_workarounds.zig — the noops made
        // lex.test.ts / parse.test.ts skip (garbage return from the hooks).
        "JS2Zig___src_runtime_webcore_FileSink_zig__TestingAPIs_fileSinkLiveCount",
        // InternalSourceMap fromVLQ/toVLQ/find now have real exports in
        // jsc/js2native_workarounds.zig (the noops returned garbage — byteLength
        // / generatedLine came back undefined in the roundtrip test).
        // jsEscapeRegExp{,ForPackageNameMatching} now have real exports in
        // jsc/js2native_workarounds.zig — the noops returned garbage (globalThis)
        // from Bun.escapeRegExp / the internal-for-testing bindings.
        "JS2Zig___src_sys_sys_zig__TestingAPIs_sigactionLayout",
        "bindgen_Bindgen_test_dispatchAdd1",
        "bindgen_Bindgen_test_dispatchRequiredAndOptionalArg1",
        // bindgen_BunObject_dispatch{Braces1,Gc1} now have real exports in
        // jsc/js2native_workarounds.zig. The noops returned garbage —
        // `$.braces(...)` yielded globalThis; `Bun.gc()` yielded an
        // uninitialized heap-size (the out-param was never written).
        "bindgen_DevServer_dispatchGetDeinitCountForTesting1",
        // bindgen_Fmt_jsc_dispatchFmtString1 + js2native_bindgen_fmt_jsc_fmtString
        // now have real exports in jsc/js2native_workarounds.zig (the noops made
        // highlightJavaScript throw "fmtBinding is not a function").
        // bindgen_NodeModuleModule_dispatch_stat1 now has its real export in
        // jsc/js2native_workarounds.zig — the noop left Module._stat's i32
        // out-param uninitialized (garbage file/dir kind for the CJS resolver).
        "bindgen_Node_os_dispatchCpus1",
        "bindgen_Node_os_dispatchFreemem1",
        "bindgen_Node_os_dispatchGetPriority1",
        "bindgen_Node_os_dispatchHomedir1",
        "bindgen_Node_os_dispatchHostname1",
        "bindgen_Node_os_dispatchLoadavg1",
        "bindgen_Node_os_dispatchNetworkInterfaces1",
        "bindgen_Node_os_dispatchRelease1",
        "bindgen_Node_os_dispatchSetPriority1",
        "bindgen_Node_os_dispatchSetPriority2",
        "bindgen_Node_os_dispatchTotalmem1",
        "bindgen_Node_os_dispatchUptime1",
        "bindgen_Node_os_dispatchUserInfo1",
        "bindgen_Node_os_dispatchVersion1",
        "js2native_bindgen_DevServer_getDeinitCountForTesting",
        "lol_html_attribute_name_get",
        "lol_html_attribute_value_get",
        "lol_html_attributes_iterator_free",
        "lol_html_attributes_iterator_get",
        "lol_html_attributes_iterator_next",
        "lol_html_comment_after",
        "lol_html_comment_before",
        "lol_html_comment_is_removed",
        "lol_html_comment_remove",
        "lol_html_comment_text_get",
        "lol_html_comment_text_set",
        "lol_html_doc_end_append",
        "lol_html_doctype_is_removed",
        "lol_html_doctype_name_get",
        "lol_html_doctype_public_id_get",
        "lol_html_doctype_remove",
        "lol_html_doctype_system_id_get",
        "lol_html_element_add_end_tag_handler",
        "lol_html_element_after",
        "lol_html_element_append",
        "lol_html_element_before",
        "lol_html_element_can_have_content",
        "lol_html_element_clear_end_tag_handlers",
        "lol_html_element_get_attribute",
        "lol_html_element_has_attribute",
        "lol_html_element_is_removed",
        "lol_html_element_is_self_closing",
        "lol_html_element_namespace_uri_get",
        "lol_html_element_prepend",
        "lol_html_element_remove",
        "lol_html_element_remove_and_keep_content",
        "lol_html_element_remove_attribute",
        "lol_html_element_replace",
        "lol_html_element_set_attribute",
        "lol_html_element_set_inner_content",
        "lol_html_element_tag_name_get",
        "lol_html_element_tag_name_set",
        "lol_html_end_tag_after",
        "lol_html_end_tag_before",
        "lol_html_end_tag_name_get",
        "lol_html_end_tag_name_set",
        "lol_html_end_tag_remove",
        "lol_html_rewriter_build",
        "lol_html_rewriter_builder_add_document_content_handlers",
        "lol_html_rewriter_builder_add_element_content_handlers",
        "lol_html_rewriter_builder_free",
        "lol_html_rewriter_builder_new",
        "lol_html_rewriter_end",
        "lol_html_rewriter_free",
        "lol_html_rewriter_write",
        "lol_html_selector_free",
        "lol_html_selector_parse",
        "lol_html_str_free",
        "lol_html_take_last_error",
        "lol_html_text_chunk_after",
        "lol_html_text_chunk_before",
        "lol_html_text_chunk_content_get",
        "lol_html_text_chunk_is_last_in_text_node",
        "lol_html_text_chunk_is_removed",
        "lol_html_text_chunk_remove",
        "lol_html_text_chunk_replace",
    }) |name| {
        @export(&noop, .{ .name = name });
    }
}
