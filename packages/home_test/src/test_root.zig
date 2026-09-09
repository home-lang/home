const home_test = @import("home_test.zig");

comptime {
    if (@import("build_options").enable_jsc) {
        // The linked native C++ objects reference these Zig exports even when
        // a test filter excludes cases that instantiate a native VM.
        _ = @import("home_rt").jsc.VirtualMachine;
        _ = @import("home_rt").jsc.Codegen;
        _ = home_test.adapters.jsc_bootstrap.napi_module_register;
    }
}

test {
    // Discover nested tests independently of the facade's named smoke tests,
    // which a substring filter can exclude before their imports are analyzed.
    _ = home_test;
    _ = home_test.corpus;
    _ = home_test.corpus_selection;
    _ = home_test.corpus_platform;
    _ = home_test.corpus_vendor;
    _ = home_test.corpus_runner;
    _ = home_test.result;
    _ = home_test.runner;
    _ = home_test.adapters.jsc_bootstrap;
    _ = home_test.adapters.jsc_esm_smoke;
    if (@import("builtin").test_functions.len <= 1) return error.NoMatchingHarnessTests;
}
