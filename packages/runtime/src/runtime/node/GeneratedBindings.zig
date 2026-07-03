// Hand-written stand-in for Bun's generated `bun.gen` bindgen namespace
// (upstream `src/jsc/bindings/GeneratedBindings.zig`, produced by the bindgen
// codegen). Bun's codegen reads each binding module's typed function signatures
// and emits arg/return marshalling thunks + `createXxxCallback` helpers that
// build the JSFunctions. Home has no bindgen codegen yet, so this provides the
// pieces actually referenced — currently only `node_os` (node_os.zig does
// `const gen = bun.gen.node_os`). Each callback wraps the native function as a
// JSHostFn, marshalling args/returns by hand (the bindgen-generated dispatchers
// `bindgen_Node_os_dispatch*` are not linked in Home, so we bypass them).
//
// As more node binding modules are brought up, add their `gen.<module>` here (or
// replace the whole file with real bindgen codegen output).

const bun = @import("home");
const jsc = bun.jsc;
const JSGlobalObject = jsc.JSGlobalObject;
const JSValue = jsc.JSValue;
const CallFrame = jsc.CallFrame;
const ZigString = jsc.ZigString;
const host_fn = @import("../../jsc/host_fn.zig");
const node_os_impl = @import("node_os.zig");

fn fn0(comptime name: [:0]const u8, comptime host: host_fn.JSHostFnZig) fn (*JSGlobalObject) callconv(jsc.conv) JSValue {
    return struct {
        fn create(global: *JSGlobalObject) callconv(jsc.conv) JSValue {
            return host_fn.NewRuntimeFunction(global, ZigString.static(name), 0, &host_fn.toJSHostFn(host), false, null);
        }
    }.create;
}

/// Hand-mirror of the bindgen-generated `bun.gen.BunObject` namespace. Only the
/// pieces Home references are provided. `BunObject.braces` takes
/// `gen.BracesOptions`; the pinned-obj C++ wrapper `bindgen_BunObject_jsBraces`
/// marshals JS args and passes this struct by pointer to the Zig dispatch
/// `bindgen_BunObject_dispatchBraces1` (real export in js2native_workarounds.zig).
/// Layout MUST match the C++ header `struct BracesOptions { bool parse; bool
/// tokenize; }` (GeneratedBunObject.h) — both fields are one byte, order matters.
pub const BunObject = struct {
    pub const BracesOptions = extern struct {
        parse: bool,
        tokenize: bool,
    };
};

pub const node_os = struct {
    // userInfo's options are currently ignored by the implementation.
    pub const UserInfoOptions = struct {
        encoding: ?bun.String = null,
    };

    pub const createCpusCallback = fn0("cpus", hCpus);
    pub const createFreememCallback = fn0("freemem", hFreemem);
    pub const createGetPriorityCallback = fn0("getPriority", hGetPriority);
    pub const createHomedirCallback = fn0("homedir", hHomedir);
    pub const createHostnameCallback = fn0("hostname", hHostname);
    pub const createLoadavgCallback = fn0("loadavg", hLoadavg);
    pub const createNetworkInterfacesCallback = fn0("networkInterfaces", hNetworkInterfaces);
    pub const createReleaseCallback = fn0("release", hRelease);
    pub const createTotalmemCallback = fn0("totalmem", hTotalmem);
    pub const createUptimeCallback = fn0("uptime", hUptime);
    pub const createUserInfoCallback = fn0("userInfo", hUserInfo);
    pub const createVersionCallback = fn0("version", hVersion);
    pub const createSetPriorityCallback = fn0("setPriority", hSetPriority);

    fn hCpus(g: *JSGlobalObject, _: *CallFrame) bun.JSError!JSValue {
        return node_os_impl.cpus(g);
    }
    fn hFreemem(_: *JSGlobalObject, _: *CallFrame) bun.JSError!JSValue {
        return JSValue.jsNumber(node_os_impl.freemem());
    }
    fn hGetPriority(g: *JSGlobalObject, cf: *CallFrame) bun.JSError!JSValue {
        const pid: i32 = if (cf.argumentsCount() > 0) cf.argument(0).toInt32() else 0;
        return JSValue.jsNumber(try node_os_impl.getPriority(g, pid));
    }
    fn hHomedir(g: *JSGlobalObject, _: *CallFrame) bun.JSError!JSValue {
        var s = try node_os_impl.homedir(g);
        defer s.deref();
        return s.toJS(g);
    }
    fn hHostname(g: *JSGlobalObject, _: *CallFrame) bun.JSError!JSValue {
        return node_os_impl.hostname(g);
    }
    fn hLoadavg(g: *JSGlobalObject, _: *CallFrame) bun.JSError!JSValue {
        return node_os_impl.loadavg(g);
    }
    fn hNetworkInterfaces(g: *JSGlobalObject, _: *CallFrame) bun.JSError!JSValue {
        return node_os_impl.networkInterfaces(g);
    }
    fn hRelease(g: *JSGlobalObject, _: *CallFrame) bun.JSError!JSValue {
        var s = node_os_impl.release();
        defer s.deref();
        return s.toJS(g);
    }
    fn hTotalmem(_: *JSGlobalObject, _: *CallFrame) bun.JSError!JSValue {
        return JSValue.jsNumber(node_os_impl.totalmem());
    }
    fn hUptime(g: *JSGlobalObject, _: *CallFrame) bun.JSError!JSValue {
        return JSValue.jsNumber(try node_os_impl.uptime(g));
    }
    fn hUserInfo(g: *JSGlobalObject, _: *CallFrame) bun.JSError!JSValue {
        return node_os_impl.userInfo(g, .{});
    }
    fn hVersion(g: *JSGlobalObject, _: *CallFrame) bun.JSError!JSValue {
        var s = try node_os_impl.version();
        defer s.deref();
        return s.toJS(g);
    }
    fn hSetPriority(g: *JSGlobalObject, cf: *CallFrame) bun.JSError!JSValue {
        if (cf.argumentsCount() >= 2) {
            try node_os_impl.setPriority1(g, cf.argument(0).toInt32(), cf.argument(1).toInt32());
        } else {
            try node_os_impl.setPriority2(g, cf.argument(0).toInt32());
        }
        return .js_undefined;
    }
};
