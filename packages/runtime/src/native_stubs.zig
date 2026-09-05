const std = @import("std");

pub export var Bun__reported_memory_size: usize = 0;

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
/// JSC reserves zero as the empty JSValue sentinel. Returning it across a host
/// callback boundary corrupts ordinary JavaScript operations such as `typeof`
/// and property enumeration. Unsupported callbacks must return a valid value.
fn unsupportedEncoded() callconv(.c) usize {
    return 0xa; // JSValue.js_undefined
}

test "unsupported encoded callbacks return JavaScript undefined, never the empty sentinel" {
    try @import("std").testing.expectEqual(@as(usize, 0xa), unsupportedEncoded());
}
fn noopDetached(_: ?*anyopaque, _: usize) callconv(.c) void {}
extern fn u_hasBinaryProperty(c: c_int, which: c_int) callconv(.c) u8;
fn icuHasBinaryProperty(c: u32, which: c_uint) callconv(.c) bool {
    return u_hasBinaryProperty(@intCast(c), @intCast(which)) != 0;
}
fn abortingPanic(message: [*]u8, message_len: usize) callconv(.c) noreturn {
    // Keep Bun's stable crash prefix even when Zig changes its default panic
    // formatting. Bun's Node-API tests use this line to stop a deliberately
    // crashing child before symbolization or core-dump handling can stall it.
    std.debug.print("panic(main thread): {s}\n", .{message[0..message_len]});
    std.process.abort();
}

comptime {
    @export(&abortingPanic, .{ .name = "Bun__crashHandler" });
    @export(&noopInt, .{ .name = "Bun__doesMacOSVersionSupportSendRecvMsgX" });
    // NetworkSink__memoryCost now has its real export (streams.zig NetworkSink,
    // force-referenced once the S3 write path un-stub links the real uploader).
    @export(&noopBool, .{ .name = "Bun__CryptoHasherExtern__isXof" });
    // Bun object sets differ on whether workaround-missing-symbols.cpp.o
    // exports this wrapper, so Home keeps a weak bridge to ICU.
    @export(&icuHasBinaryProperty, .{ .name = "icu_hasBinaryProperty", .linkage = .weak });

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
        "JS2Zig___src_collections_linear_fifo_zig__TestingAPIs_orderedRemoveProbe",
        "JS2Zig___src_sys_sys_zig__TestingAPIs_translateNtStatusToE",
        "TCPSocketPrototype__getTypeOfService",
        "TCPSocketPrototype__setKeyCert",
        "TCPSocketPrototype__setTypeOfService",
        "TLSSocketPrototype__getTypeOfService",
        "TLSSocketPrototype__setKeyCert",
        "TLSSocketPrototype__setTypeOfService",
    }) |name| {
        @export(&unsupportedEncoded, .{ .name = name });
    }

    for ([_][]const u8{
        // Bun__dns_internal_registerQuic now has its real export in
        // dns.zig (the noop left hostname HTTP/3 connects hanging).
        "Bun__InspectorBunFrontendDevServerAgent__setEnabled",
        // Bun__Secrets__scheduleJob now has its real export in JSSecrets.zig;
        // the noop left every Bun.secrets promise permanently pending.
        // Entry-point result handlers are real VirtualMachine exports. Native
        // promiseHandlerID compares their addresses against its fixed table.
        "BlockList__onStructuredCloneDestroy",
        "CrashHandler__setDlOpenAction",
        "CrashHandler__setInsideNativePlugin",
        "CrashHandler__unsupportedUVFunction",
        "CryptoClass__finalize",
        "FileSink__assertLive",
        // NetworkSink__* now have their real exports (streams.zig NetworkSink),
        // pulled in once the S3 write path un-stub (home.zig S3.uploadStream/
        // writableStream → real client) links the real uploader/sink. Keeping
        // the noops here would collide with the real strong exports.
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
        // ConcurrentCppTask__createAndRun now has its real export in
        // jsc/CppTask.zig. The old no-op silently discarded WebCrypto work
        // queue jobs, leaving promises such as subtle.sign(HMAC, ...) pending.
        // toUTF16AllocSentinel now has its real export in
        // jsc/js2native_workarounds.zig — the noop returned garbage.
        "JS2Zig___src_bun_zig__getUseSystemCA",
        "JS2Zig___src_crash_handler_crash_handler_zig__js_bindings_generate_workaround",
        // H2/H3 liveCounts/quicLiveCounts now have real exports in
        // js2native_workarounds.zig (the noops returned undefined counts → NaN).
        // ini IniTestingAPIs now have real exports in js2native_workarounds.zig.
        "JS2Zig___src_install_dependency_zig__Version_Tag_inferFromJS",
        "JS2Zig___src_install_dependency_zig__fromJS",
        // hostedGitInfo fromUrl/parseUrl now have real exports in
        // jsc/js2native_workarounds.zig (the noops returned globalThis).
        "JS2Zig___src_install_jsc_install_binding_zig__bun_install_js_bindings_generate_workaround",
        // PackageManifest.bindings.generate now has its real export in
        // js2native_workarounds.zig (the noop left parseManifest undefined).
        "JS2Zig___src_jsc_bindgen_test_zig__getBindgenTestFunctions_workaround",
        // event_loop getActiveTasks now has its real export in js2native_workarounds.zig.
        "JS2Zig___src_jsc_ipc_zig__emitHandleIPCMessage",
        // setSyntheticAllocationLimitForTesting now has its real export in
        // js2native_workarounds.zig (the noop left the OOM tests unable to
        // lower the limit, so they never threw the OOM they assert on).
        "JS2Zig___src_runtime_api_bun_subprocess_zig__TestingAPIs_injectStdioReadError",
        // patch TestingAPIs stay noop'd: patch.zig's makeDiff uses Zig-0.16
        // std.process.Child.init (removed in 0.17) so the impl doesn't compile.
        "JS2Zig___src_patch_patch_zig__TestingAPIs_makeDiff",
        "JS2Zig___src_runtime_cli_pack_command_zig__bindings_jsReadTarball",
        "JS2Zig___src_runtime_cli_upgrade_command_zig__upgrade_js_bindings_generate_workaround",
        // getBunServerAllClosedPromise now has a real export in js2native_workarounds.zig.
        // shell TestingAPIs (shellLex/shellParse/disabledOnThisPlatform) now
        // have real exports in jsc/js2native_workarounds.zig — the noops made
        // lex.test.ts / parse.test.ts skip (garbage return from the hooks).
        // FileSink fileSinkLiveCount now has its real export in js2native_workarounds.zig.
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
    }) |name| {
        @export(&noop, .{ .name = name });
    }
}

// lol-html C-API fallback: when the real staticlib (.native/liblolhtml.a,
// built by scripts/build-lolhtml.sh) is NOT linked, keep the lol_html_*
// symbols satisfied with noops so the exe still links (HTMLRewriter then
// no-ops instead of failing the whole build). With the lib present these
// are provided for real, so gating avoids duplicate-symbol errors.
comptime {
    if (!@import("build_options").have_lolhtml) {
        for (.{
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
}
