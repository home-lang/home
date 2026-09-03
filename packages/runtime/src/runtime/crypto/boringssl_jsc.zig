//! JSC bridge for BoringSSL error formatting. Keeps `src/boringssl/` free of JSC types.

/// Node's `ERR_LIB_*` to macro-prefix map from `crypto_util.cc`
/// (`OSSL_ERROR_CODES_MAP`). Libraries Node does not map get an empty prefix
/// and compose to `ERR_OSSL_<REASON>`.
fn libShortName(lib: c_int) []const u8 {
    return switch (lib) {
        2 => "SYS_",
        3 => "BN_",
        4 => "RSA_",
        5 => "DH_",
        6 => "EVP_",
        7 => "BUF_",
        8 => "OBJ_",
        9 => "PEM_",
        10 => "DSA_",
        11 => "X509_",
        12 => "ASN1_",
        13 => "CONF_",
        14 => "CRYPTO_",
        15 => "EC_",
        16 => "SSL_",
        17 => "BIO_",
        18 => "PKCS7_",
        20 => "X509V3_",
        21 => "RAND_",
        22 => "ENGINE_",
        23 => "OCSP_",
        24 => "UI_",
        25 => "COMP_",
        26 => "ECDSA_",
        27 => "ECDH_",
        28 => "HMAC_",
        33 => "USER_",
        else => "",
    };
}

fn staticCString(ptr: [*c]const u8) ?[]const u8 {
    if (ptr == null) return null;
    const bytes = ptr[0..bun.len(ptr)];
    return if (bytes.len == 0) null else bytes;
}

pub fn ERR_toJS(globalThis: *jsc.JSGlobalObject, err_code: u32) jsc.JSValue {
    // Match Node's BoringSSL-backed ThrowCryptoError shape. The message is
    // the raw ERR_error_string output; the structured fields below expose the
    // library/function/reason decomposition and Node-compatible error code.
    var outbuf: [128 + 1]u8 = undefined;
    @memset(&outbuf, 0);
    _ = boring.ERR_error_string_n(err_code, &outbuf, outbuf.len);

    const error_message: []const u8 = bun.sliceTo(outbuf[0..], 0);
    if (error_message.len == 0) {
        return globalThis.ERR(.BORINGSSL, "An unknown BoringSSL error occurred: {d}", .{err_code}).toJS();
    }

    const err = bun.String.cloneUTF8(error_message).toErrorInstance(globalThis);

    if (staticCString(boring.ERR_lib_error_string(err_code))) |library| {
        err.put(globalThis, "library", jsc.ZigString.init(library).toJS(globalThis));
    }
    if (staticCString(boring.ERR_func_error_string(err_code))) |function| {
        err.put(globalThis, "function", jsc.ZigString.init(function).toJS(globalThis));
    }
    if (staticCString(boring.ERR_reason_error_string(err_code))) |reason| {
        err.put(globalThis, "reason", jsc.ZigString.init(reason).toJS(globalThis));

        const lib = libShortName(@intCast((err_code >> 24) & 0xff));
        const prefix = if (std.mem.eql(u8, lib, "SSL_")) "" else "OSSL_";
        var code_buf: [128]u8 = undefined;
        const code = std.fmt.bufPrint(&code_buf, "ERR_{s}{s}{s}", .{ prefix, lib, reason }) catch "ERR_BORINGSSL";
        err.put(globalThis, "code", jsc.ZigString.init(code).toJS(globalThis));
    }

    return err;
}

const std = @import("std");
const bun = @import("bun");
const jsc = bun.jsc;
const boring = bun.BoringSSL.c;
