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
fn abortingPanic(_: [*]u8, _: usize) callconv(.c) noreturn {
    @panic("Bun crash handler called");
}

comptime {
    @export(&abortingPanic, .{ .name = "Bun__crashHandler" });
    @export(&noopInt, .{ .name = "Bun__doesMacOSVersionSupportSendRecvMsgX" });
    @export(&noopSize, .{ .name = "NetworkSink__memoryCost" });

    for ([_][]const u8{
        "Bake__bundleNewRouteJSFunctionImpl",
        "Bake__getNewRouteParamsJSFunctionImpl",
        "Bun__dns_internal_registerQuic",
        "Bun__HTTPRequestContextDebugH3__onReject",
        "Bun__HTTPRequestContextDebugH3__onRejectStream",
        "Bun__HTTPRequestContextDebugH3__onResolve",
        "Bun__HTTPRequestContextDebugH3__onResolveStream",
        "Bun__HTTPRequestContextDebugTLS__onReject",
        "Bun__HTTPRequestContextDebugTLS__onRejectStream",
        "Bun__HTTPRequestContextDebugTLS__onResolve",
        "Bun__HTTPRequestContextDebugTLS__onResolveStream",
        "Bun__HTTPRequestContextDebug__onReject",
        "Bun__HTTPRequestContextDebug__onRejectStream",
        "Bun__HTTPRequestContextDebug__onResolve",
        "Bun__HTTPRequestContextDebug__onResolveStream",
        "Bun__HTTPRequestContextH3__onReject",
        "Bun__HTTPRequestContextH3__onRejectStream",
        "Bun__HTTPRequestContextH3__onResolve",
        "Bun__HTTPRequestContextH3__onResolveStream",
        "Bun__HTTPRequestContextTLS__onReject",
        "Bun__HTTPRequestContextTLS__onRejectStream",
        "Bun__HTTPRequestContextTLS__onResolve",
        "Bun__HTTPRequestContextTLS__onResolveStream",
        "Bun__HTTPRequestContext__onReject",
        "Bun__HTTPRequestContext__onRejectStream",
        "Bun__HTTPRequestContext__onResolve",
        "Bun__HTTPRequestContext__onResolveStream",
        "Bun__InspectorBunFrontendDevServerAgent__setEnabled",
        "Bun__Secrets__scheduleJob",
        "Bun__eventLoop__incrementRefConcurrently",
        "Bun__onRejectEntryPointResult",
        "Bun__onResolveEntryPointResult",
        "Bun__queueJSCDeferredWorkTaskConcurrently",
        "CrashHandler__setDlOpenAction",
        "CrashHandler__setInsideNativePlugin",
        "CrashHandler__unsupportedUVFunction",
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
        "JS2Zig___src_bun_core_string_immutable_unicode_zig__TestingAPIs_toUTF__AllocSentinel",
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
        "JS2Zig___src_ini_ini_zig__IniTestingAPIs_loadNpmrcFromJS",
        "JS2Zig___src_ini_ini_zig__IniTestingAPIs_parse",
        "JS2Zig___src_install_dependency_zig__Version_Tag_inferFromJS",
        "JS2Zig___src_install_dependency_zig__fromJS",
        "JS2Zig___src_install_hosted_git_info_zig__TestingAPIs_jsFromUrl",
        "JS2Zig___src_install_hosted_git_info_zig__TestingAPIs_jsParseUrl",
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
        "JS2Zig___src_runtime_api_bun_SecureContext_zig__jsLiveCount",
        "JS2Zig___src_runtime_api_bun_SecureContext_zig__js_getConstructor_workaround",
        "JS2Zig___src_runtime_api_bun_subprocess_zig__TestingAPIs_injectStdioReadError",
        "JS2Zig___src_runtime_bake_FrameworkRouter_zig__JSFrameworkRouter_getBindings_workaround",
        "JS2Zig___src_runtime_cli_pack_command_zig__bindings_jsReadTarball",
        "JS2Zig___src_runtime_cli_upgrade_command_zig__upgrade_js_bindings_generate_workaround",
        // getBunServerAllClosedPromise now has a real export in js2native_workarounds.zig.
        "JS2Zig___src_runtime_shell_shell_zig__TestingAPIs_disabledOnThisPlatform",
        "JS2Zig___src_runtime_shell_shell_zig__TestingAPIs_shellLex",
        "JS2Zig___src_runtime_shell_shell_zig__TestingAPIs_shellParse",
        "JS2Zig___src_runtime_webcore_FileSink_zig__TestingAPIs_fileSinkLiveCount",
        "JS2Zig___src_sourcemap_InternalSourceMap_zig__TestingAPIs_find",
        "JS2Zig___src_sourcemap_InternalSourceMap_zig__TestingAPIs_fromVLQ",
        "JS2Zig___src_sourcemap_InternalSourceMap_zig__TestingAPIs_toVLQ",
        "JS2Zig___src_string_escapeRegExp_zig__jsEscapeRegExp",
        "JS2Zig___src_string_escapeRegExp_zig__jsEscapeRegExpForPackageNameMatching",
        "JS2Zig___src_sys_Error_zig__TestingAPIs_sysErrorNameFromLibuv",
        "JS2Zig___src_sys_sys_zig__TestingAPIs_sigactionLayout",
        "JS2Zig___src_sys_sys_zig__TestingAPIs_translateUVErrorToE",
        "bindgen_Bindgen_test_dispatchAdd1",
        "bindgen_Bindgen_test_dispatchRequiredAndOptionalArg1",
        "bindgen_BunObject_dispatchBraces1",
        "bindgen_BunObject_dispatchGc1",
        "bindgen_DevServer_dispatchGetDeinitCountForTesting1",
        "bindgen_Fmt_jsc_dispatchFmtString1",
        "bindgen_NodeModuleModule_dispatch_stat1",
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
        "js2native_bindgen_fmt_jsc_fmtString",
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
