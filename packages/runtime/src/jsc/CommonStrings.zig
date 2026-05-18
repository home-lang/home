// Copied from bun/src/jsc/CommonStrings.zig at upstream SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// `JSGlobalObject` and `JSValue` are not yet ported. Local opaque/struct stubs
// keep the public surface intact — the JSC bridge re-attaches in Phase 12.2.

const std = @import("std");

// JSC bridge JSGlobalObject stubbed — re-attaches in Phase 12.2.
const JSGlobalObject = opaque {};
// JSC bridge JSValue stubbed — re-attaches in Phase 12.2.
const JSValue = opaque {};

// Local mini-namespace `jsc` so the upstream `jsc.JSGlobalObject` /
// `jsc.JSValue` spellings stay verbatim.
const jsc = struct {
    pub const JSGlobalObject = @import("CommonStrings.zig").JSGlobalObject;
    pub const JSValue = @import("CommonStrings.zig").JSValue;
};

/// Common strings from `BunCommonStrings.h`.
///
/// All getters return a `JSC::JSString`;
pub const CommonStrings = struct {
    globalObject: *jsc.JSGlobalObject,

    const CommonStringsForZig = enum(u8) {
        IPv4 = 0,
        IPv6 = 1,
        IN4Loopback = 2,
        IN6Any = 3,
        ipv4Lower = 4,
        ipv6Lower = 5,
        fetchDefault = 6,
        fetchError = 7,
        fetchInclude = 8,
        buffer = 9,
        binaryTypeArrayBuffer = 10,
        binaryTypeNodeBuffer = 11,
        binaryTypeUint8Array = 12,

        extern "c" fn Bun__CommonStringsForZig__toJS(commonString: CommonStringsForZig, globalObject: *jsc.JSGlobalObject) *jsc.JSValue;
        pub const toJS = Bun__CommonStringsForZig__toJS;
    };

    pub inline fn IPv4(this: CommonStrings) *JSValue {
        return CommonStringsForZig.IPv4.toJS(this.globalObject);
    }
    pub inline fn IPv6(this: CommonStrings) *JSValue {
        return CommonStringsForZig.IPv6.toJS(this.globalObject);
    }
    pub inline fn @"127.0.0.1"(this: CommonStrings) *JSValue {
        return CommonStringsForZig.IN4Loopback.toJS(this.globalObject);
    }
    pub inline fn @"::"(this: CommonStrings) *JSValue {
        return CommonStringsForZig.IN6Any.toJS(this.globalObject);
    }
    pub inline fn ipv4(this: CommonStrings) *JSValue {
        return CommonStringsForZig.ipv4Lower.toJS(this.globalObject);
    }
    pub inline fn ipv6(this: CommonStrings) *JSValue {
        return CommonStringsForZig.ipv6Lower.toJS(this.globalObject);
    }
    pub inline fn default(this: CommonStrings) *JSValue {
        return CommonStringsForZig.fetchDefault.toJS(this.globalObject);
    }
    pub inline fn @"error"(this: CommonStrings) *JSValue {
        return CommonStringsForZig.fetchError.toJS(this.globalObject);
    }
    pub inline fn include(this: CommonStrings) *JSValue {
        return CommonStringsForZig.fetchInclude.toJS(this.globalObject);
    }
    pub inline fn buffer(this: CommonStrings) *JSValue {
        return CommonStringsForZig.buffer.toJS(this.globalObject);
    }
    pub inline fn arraybuffer(this: CommonStrings) *JSValue {
        return CommonStringsForZig.binaryTypeArrayBuffer.toJS(this.globalObject);
    }
    pub inline fn nodebuffer(this: CommonStrings) *JSValue {
        return CommonStringsForZig.binaryTypeNodeBuffer.toJS(this.globalObject);
    }
    pub inline fn uint8array(this: CommonStrings) *JSValue {
        return CommonStringsForZig.binaryTypeUint8Array.toJS(this.globalObject);
    }
};

test "CommonStrings has the expected getter surface" {
    try std.testing.expect(@hasDecl(CommonStrings, "IPv4"));
    try std.testing.expect(@hasDecl(CommonStrings, "IPv6"));
    try std.testing.expect(@hasDecl(CommonStrings, "ipv4"));
    try std.testing.expect(@hasDecl(CommonStrings, "ipv6"));
    try std.testing.expect(@hasDecl(CommonStrings, "buffer"));
    try std.testing.expect(@hasDecl(CommonStrings, "arraybuffer"));
    try std.testing.expect(@hasDecl(CommonStrings, "nodebuffer"));
    try std.testing.expect(@hasDecl(CommonStrings, "uint8array"));
}

test "CommonStrings holds exactly a globalObject pointer" {
    try std.testing.expect(@sizeOf(CommonStrings) == @sizeOf(*JSGlobalObject));
}
