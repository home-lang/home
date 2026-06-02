const Response = @This();

// C++ helper functions for AsyncLocalStorage integration
extern fn Response__getAsyncLocalStorageStore(global: *JSGlobalObject, als: JSValue) JSValue;
extern fn Response__mergeAsyncLocalStorageOptions(global: *JSGlobalObject, alsStore: JSValue, initOptions: JSValue) void;

const ResponseMixin = BodyMixin(@This());
pub const js = jsc.Codegen.JSResponse;
// NOTE: toJS is overridden
pub const fromJS = js.fromJS;
pub const fromJSDirect = js.fromJSDirect;

_body: Body,
_init: Init,
_url: bun.String = bun.String.empty,
_redirected: bool = false,
/// We increment this count in fetch so if JS Response is discarted we can resolve the Body
/// In the server we use a flag response_protected to protect/unprotect the response
ref_count: u32 = 1,
/// Bun.serve's RequestContext holds a weak reference so `onAbort` /
/// `handleResolveStream` / `handleRejectStream` can safely observe that the
/// Response was GC'd (null) instead of dereferencing a freed pointer when
/// backpressure lets GC run between `render()` and the async callback.
weak_ptr_data: WeakRef.Data = .empty,
_js_ref: jsc.JSRef = .empty(),

// We must report a consistent value for this
_reported_estimated_size: usize = 0,

pub const WeakRef = bun.ptr.WeakPtr(Response, "weak_ptr_data");

pub const getText = ResponseMixin.getText;
pub const getBody = ResponseMixin.getBody;
pub const getBytes = ResponseMixin.getBytes;
pub const getBodyUsed = ResponseMixin.getBodyUsed;
pub const getJSON = ResponseMixin.getJSON;
pub const getArrayBuffer = ResponseMixin.getArrayBuffer;
pub const getBlob = ResponseMixin.getBlob;
pub const getBlobWithoutCallFrame = ResponseMixin.getBlobWithoutCallFrame;
pub const getFormData = ResponseMixin.getFormData;

pub fn init(response_init: Init, body: Body, url: bun.String, redirected: bool) Response {
    return Response{
        ._init = response_init,
        ._body = body,
        ._url = url,
        ._redirected = redirected,
    };
}

pub inline fn setInit(this: *Response, method: Method, status_code: u16, status_text: bun.String) void {
    this._init.method = method;
    this._init.status_code = status_code;
    this._init.status_text.deref();
    this._init.status_text = status_text;
}
pub inline fn setInitHeaders(this: *Response, headers: ?*FetchHeaders) void {
    if (this._init.headers) |_headers| {
        _headers.deref();
    }
    this._init.headers = headers;
}
pub inline fn getInitStatusCode(this: *Response) u16 {
    return this._init.status_code;
}
pub inline fn getInitStatusText(this: *Response) bun.String {
    return this._init.status_text;
}
pub inline fn setUrl(this: *Response, url: bun.String) void {
    this._url.deref();
    this._url = url;
}
pub inline fn getUTF8Url(this: *Response, allocator: std.mem.Allocator) ZigString.Slice {
    return this._url.toUTF8(allocator);
}
pub inline fn getUrl(this: *Response) bun.String {
    return this._url;
}
pub inline fn getInitHeaders(this: *Response) ?*FetchHeaders {
    return this._init.headers;
}
pub inline fn swapInitHeaders(this: *Response) ?*FetchHeaders {
    if (this._init.headers) |headers| {
        this._init.headers = null;
        return headers;
    }
    return null;
}
pub inline fn getBodyLen(this: *Response) usize {
    return this._body.len();
}
pub inline fn getMethod(this: *Response) Method {
    return this._init.method;
}
pub fn getFormDataEncoding(this: *Response) bun.JSError!?*bun.FormData.AsyncFormData {
    var content_type_slice: ZigString.Slice = (try this.getContentType()) orelse return null;
    defer content_type_slice.deinit();
    const encoding = bun.FormData.Encoding.get(content_type_slice.slice()) orelse return null;
    return bun.handleOom(bun.FormData.AsyncFormData.init(bun.default_allocator, encoding));
}

pub fn estimatedSize(this: *Response) callconv(.c) usize {
    return this._reported_estimated_size;
}

pub fn calculateEstimatedByteSize(this: *Response) void {
    this._reported_estimated_size = this._body.value.estimatedSize() +
        this._url.byteSlice().len +
        this._init.status_text.byteSlice().len +
        @sizeOf(Response);
}

fn checkBodyStreamRef(this: *Response, globalObject: *JSGlobalObject) void {
    if (this._js_ref.tryGet()) |js_value| {
        if (this._body.value == .Locked) {
            if (this._body.value.Locked.readable.get(globalObject)) |stream| {
                // we dont hold a strong reference to the stream we will guard it in js.gc.stream
                // so we avoid cycled references
                // anyone using Response should not use Locked.readable directly because it dont always owns it
                // the owner will be always the Response object it self
                stream.value.ensureStillAlive();
                js.gc.stream.set(js_value, globalObject, stream.value);
                this._body.value.Locked.readable.deinit();
                this._body.value.Locked.readable = .{};
            }
        }
    }
}
pub fn toJS(this: *Response, globalObject: *JSGlobalObject) JSValue {
    this.calculateEstimatedByteSize();
    const js_value = js.toJSUnchecked(globalObject, this);
    this._js_ref = .initWeak(js_value);

    this.checkBodyStreamRef(globalObject);
    return js_value;
}

pub inline fn getBodyValue(
    this: *Response,
) *Body.Value {
    return &this._body.value;
}

pub inline fn getBodyReadableStream(
    this: *Response,
    globalObject: *JSGlobalObject,
) ?jsc.WebCore.ReadableStream {
    if (this._js_ref.tryGet()) |js_ref| {
        if (js.gc.stream.get(js_ref)) |stream| {
            // JS is always source of truth for the stream
            return jsc.WebCore.ReadableStream.fromJS(stream, globalObject) catch |err| {
                _ = globalObject.takeException(err);
                return null;
            };
        }
    }
    if (this._body.value == .Locked) {
        return this._body.value.Locked.readable.get(globalObject);
    }
    return null;
}
pub inline fn detachReadableStream(this: *Response, globalObject: *jsc.JSGlobalObject) void {
    if (this._js_ref.tryGet()) |js_ref| {
        js.gc.stream.clear(js_ref, globalObject);
    }
    if (this._body.value == .Locked) {
        var old = this._body.value.Locked.readable;
        old.deinit();
        this._body.value.Locked.readable = .{};
    }
}
pub inline fn setSizeHint(this: *Response, size_hint: Blob.SizeType) void {
    if (this._body.value == .Locked) {
        this._body.value.Locked.size_hint = size_hint;
        if (this._body.value.Locked.readable.get(this._body.value.Locked.global)) |readable| {
            if (readable.ptr == .Bytes) {
                readable.ptr.Bytes.size_hint = size_hint;
            }
        }
    }
}

pub export fn jsFunctionRequestOrResponseHasBodyValue(_: *jsc.JSGlobalObject, callframe: *jsc.CallFrame) callconv(jsc.conv) jsc.JSValue {
    const arguments = callframe.arguments_old(1);
    const this_value = arguments.ptr[0];
    if (this_value.isEmptyOrUndefinedOrNull()) {
        return .false;
    }

    if (this_value.as(Response)) |response| {
        return jsc.JSValue.jsBoolean(!response._body.value.isDefinitelyEmpty());
    } else if (this_value.as(Request)) |request| {
        return jsc.JSValue.jsBoolean(!request.getBodyValue().isDefinitelyEmpty());
    }

    return .false;
}

pub export fn jsFunctionGetCompleteRequestOrResponseBodyValueAsArrayBuffer(globalObject: *jsc.JSGlobalObject, callframe: *jsc.CallFrame) callconv(jsc.conv) jsc.JSValue {
    const arguments = callframe.arguments_old(1);
    const this_value = arguments.ptr[0];
    if (this_value.isEmptyOrUndefinedOrNull()) {
        return .js_undefined;
    }

    const body: *Body.Value = brk: {
        if (this_value.as(Response)) |response| {
            break :brk &response._body.value;
        } else if (this_value.as(Request)) |request| {
            break :brk request.getBodyValue();
        }

        return .js_undefined;
    };

    // Get the body if it's available synchronously.
    switch (body.*) {
        .Used, .Empty, .Null => return .js_undefined,
        .Blob => |*blob| {
            if (blob.isBunFile()) {
                return .js_undefined;
            }
            defer body.* = .{ .Used = {} };
            return blob.toArrayBuffer(globalObject, .transfer) catch return .zero;
        },
        .WTFStringImpl, .InternalBlob => {
            var any_blob = body.useAsAnyBlob();
            return any_blob.toArrayBufferTransfer(globalObject) catch return .zero;
        },
        .Error, .Locked => return .js_undefined,
    }
}

pub fn getFetchHeaders(
    this: *Response,
) ?*FetchHeaders {
    return this._init.headers;
}

pub inline fn statusCode(this: *const Response) u16 {
    return this._init.status_code;
}

pub fn redirectLocation(this: *const Response) ?[]const u8 {
    return this.header(.Location);
}

pub fn header(this: *const Response, name: bun.webcore.FetchHeaders.HTTPHeaderName) ?[]const u8 {
    return if (try (this._init.headers orelse return null).fastGet(name)) |str|
        str.slice()
    else
        null;
}

pub const Props = struct {};

pub fn writeFormat(this: *Response, comptime Formatter: type, formatter: *Formatter, writer: anytype, comptime enable_ansi_colors: bool) !void {
    const Writer = @TypeOf(writer);
    try writer.print("Response ({f}) {{\n", .{bun.fmt.size(this._body.len(), .{})});

    {
        formatter.indent += 1;
        defer formatter.indent -|= 1;

        try formatter.writeIndent(Writer, writer);
        try writer.writeAll(comptime Output.prettyFmt("<r>ok<d>:<r> ", enable_ansi_colors));
        try formatter.printAs(.Boolean, Writer, writer, jsc.JSValue.jsBoolean(this.isOK()), .BooleanObject, enable_ansi_colors);
        try formatter.printComma(Writer, writer, enable_ansi_colors);
        try writer.writeAll("\n");

        try formatter.writeIndent(Writer, writer);
        try writer.writeAll(comptime Output.prettyFmt("<r>url<d>:<r> \"", enable_ansi_colors));
        try writer.print(comptime Output.prettyFmt("<r><b>{f}<r>", enable_ansi_colors), .{this._url});
        try writer.writeAll("\"");
        try formatter.printComma(Writer, writer, enable_ansi_colors);
        try writer.writeAll("\n");

        try formatter.writeIndent(Writer, writer);
        try writer.writeAll(comptime Output.prettyFmt("<r>status<d>:<r> ", enable_ansi_colors));
        try formatter.printAs(.Double, Writer, writer, jsc.JSValue.jsNumber(this._init.status_code), .NumberObject, enable_ansi_colors);
        try formatter.printComma(Writer, writer, enable_ansi_colors);
        try writer.writeAll("\n");

        try formatter.writeIndent(Writer, writer);
        try writer.writeAll(comptime Output.prettyFmt("<r>statusText<d>:<r> ", enable_ansi_colors));
        try writer.print(comptime Output.prettyFmt("<r>\"<b>{f}<r>\"", enable_ansi_colors), .{this._init.status_text});
        try formatter.printComma(Writer, writer, enable_ansi_colors);
        try writer.writeAll("\n");

        try formatter.writeIndent(Writer, writer);
        try writer.writeAll(comptime Output.prettyFmt("<r>headers<d>:<r> ", enable_ansi_colors));
        try formatter.printAs(.Private, Writer, writer, try this.getHeaders(formatter.globalThis), .DOMWrapper, enable_ansi_colors);
        try formatter.printComma(Writer, writer, enable_ansi_colors);
        try writer.writeAll("\n");

        try formatter.writeIndent(Writer, writer);
        try writer.writeAll(comptime Output.prettyFmt("<r>redirected<d>:<r> ", enable_ansi_colors));
        try formatter.printAs(.Boolean, Writer, writer, jsc.JSValue.jsBoolean(this._redirected), .BooleanObject, enable_ansi_colors);
        try formatter.printComma(Writer, writer, enable_ansi_colors);
        try writer.writeAll("\n");

        formatter.resetLine();
        try this._body.writeFormat(Formatter, formatter, writer, enable_ansi_colors);
    }
    try writer.writeAll("\n");
    try formatter.writeIndent(Writer, writer);
    try writer.writeAll("}");
    formatter.resetLine();
}

pub fn isOK(this: *const Response) bool {
    return this._init.status_code >= 200 and this._init.status_code <= 299;
}

pub fn getURL(
    this: *Response,
    globalThis: *jsc.JSGlobalObject,
) bun.JSError!jsc.JSValue {
    // https://developer.mozilla.org/en-US/docs/Web/API/Response/url
    return this._url.toJS(globalThis);
}

pub fn getResponseType(
    this: *Response,
    globalThis: *jsc.JSGlobalObject,
) bun.JSError!jsc.JSValue {
    if (this._init.status_code < 200) {
        return globalThis.commonStrings().@"error"();
    }

    return globalThis.commonStrings().default();
}

pub fn getStatusText(
    this: *Response,
    globalThis: *jsc.JSGlobalObject,
) bun.JSError!jsc.JSValue {
    // https://developer.mozilla.org/en-US/docs/Web/API/Response/statusText
    return this._init.status_text.toJS(globalThis);
}

pub fn getRedirected(
    this: *Response,
    _: *jsc.JSGlobalObject,
) jsc.JSValue {
    // https://developer.mozilla.org/en-US/docs/Web/API/Response/redirected
    return JSValue.jsBoolean(this._redirected);
}

pub fn getOK(
    this: *Response,
    _: *jsc.JSGlobalObject,
) jsc.JSValue {
    // https://developer.mozilla.org/en-US/docs/Web/API/Response/ok
    return JSValue.jsBoolean(this.isOK());
}

fn getOrCreateHeaders(this: *Response, globalThis: *jsc.JSGlobalObject) bun.JSError!*FetchHeaders {
    if (this._init.headers == null) {
        this._init.headers = FetchHeaders.createEmpty();

        if (this._body.value == .Blob) {
            const content_type = this._body.value.Blob.content_type;
            if (content_type.len > 0) {
                try this._init.headers.?.put(.ContentType, content_type, globalThis);
            }
        }
    }

    return this._init.headers.?;
}

pub fn getHeaders(
    this: *Response,
    globalThis: *jsc.JSGlobalObject,
) bun.JSError!jsc.JSValue {
    return (try this.getOrCreateHeaders(globalThis)).toJS(globalThis);
}

pub fn doClone(
    this: *Response,
    globalThis: *jsc.JSGlobalObject,
    callframe: *jsc.CallFrame,
) bun.JSError!JSValue {
    const this_value = callframe.this();
    const cloned = try this.clone(globalThis);

    const js_wrapper = Response.makeMaybePooled(globalThis, cloned);

    if (js_wrapper != .zero) {
        // After toJS/makeMaybePooled, checkBodyStreamRef has already moved
        // the streams from Locked.readable to js.gc.stream. So we need to
        // use js.gc.stream to get the streams and update the body cache.
        if (js.gc.stream.get(js_wrapper)) |cloned_stream| {
            js.bodySetCached(js_wrapper, globalThis, cloned_stream);
        }
    }

    // Update the original response's body cache with the new teed stream.
    // At this point, this._body.value.Locked.readable still holds the teed stream
    // because checkBodyStreamRef hasn't been called on the original response yet.
    if (this._body.value == .Locked) {
        if (this._body.value.Locked.readable.get(globalThis)) |readable| {
            js.bodySetCached(this_value, globalThis, readable.value);
        }
    }

    this.checkBodyStreamRef(globalThis);

    return js_wrapper;
}

pub fn makeMaybePooled(globalObject: *jsc.JSGlobalObject, ptr: *Response) JSValue {
    return ptr.toJS(globalObject);
}

pub fn cloneValue(
    this: *Response,
    globalThis: *JSGlobalObject,
) bun.JSError!Response {
    var body = brk: {
        if (this._js_ref.tryGet()) |js_ref| {
            if (js.gc.stream.get(js_ref)) |stream| {
                var readable = try jsc.WebCore.ReadableStream.fromJS(stream, globalThis);
                if (readable != null) {
                    break :brk try this._body.cloneWithReadableStream(globalThis, &readable.?);
                }
            }
        }

        break :brk try this._body.clone(globalThis);
    };
    errdefer body.deinit(bun.default_allocator);
    var _init = try this._init.clone(globalThis);
    errdefer _init.deinit(bun.default_allocator);
    return Response{
        ._body = body,
        ._init = _init,
        ._url = this._url.clone(),
        ._redirected = this._redirected,
    };
}

pub fn clone(this: *Response, globalThis: *JSGlobalObject) bun.JSError!*Response {
    return bun.new(Response, try this.cloneValue(globalThis));
}

pub fn getStatus(
    this: *Response,
    _: *jsc.JSGlobalObject,
) jsc.JSValue {
    // https://developer.mozilla.org/en-US/docs/Web/API/Response/status
    return JSValue.jsNumber(this._init.status_code);
}

fn destroy(this: *Response) void {
    this._init.deinit(bun.default_allocator);
    this._body.deinit(bun.default_allocator);
    this._url.deref();
    this._js_ref.deinit();

    // Contents are gone; the allocation itself stays until any outstanding
    // WeakRef derefs (RequestContext.response_weakref). WeakRef.get() returns
    // null from here on.
    if (this.weak_ptr_data.onFinalize()) {
        bun.destroy(this);
    }
}

pub fn ref(this: *Response) *Response {
    this.ref_count += 1;
    return this;
}

pub fn unref(this: *Response) void {
    bun.assert(this.ref_count > 0);
    this.ref_count -= 1;
    if (this.ref_count == 0) {
        this.destroy();
    }
}

pub fn finalize(
    this: *Response,
) callconv(.c) void {
    this._js_ref.finalize();
    this.unref();
}

pub fn getContentType(
    this: *Response,
) bun.JSError!?ZigString.Slice {
    if (this._init.headers) |headers| {
        if (headers.fastGet(.ContentType)) |value| {
            return value.toSlice(bun.default_allocator);
        }
    }

    if (this._body.value == .Blob) {
        if (this._body.value.Blob.content_type.len > 0)
            return ZigString.Slice.fromUTF8NeverFree(this._body.value.Blob.content_type);
    }

    return null;
}

pub fn constructJSON(
    globalThis: *jsc.JSGlobalObject,
    callframe: *jsc.CallFrame,
) bun.JSError!JSValue {
    const args_list = callframe.arguments_old(2);
    // https://github.com/remix-run/remix/blob/db2c31f64affb2095e4286b91306b96435967969/packages/remix-server-runtime/responses.ts#L4
    var args = jsc.CallFrame.ArgumentsSlice.init(globalThis.bunVM(), args_list.ptr[0..args_list.len]);

    var response = Response{
        ._body = Body{
            .value = .{ .Empty = {} },
        },
        ._init = Response.Init{
            .status_code = 200,
        },
        ._url = bun.String.empty,
    };
    var did_succeed = false;
    defer {
        if (!did_succeed) {
            response._body.deinit(bun.default_allocator);
            response._init.deinit(bun.default_allocator);
        }
    }
    const json_value = args.nextEat() orelse jsc.JSValue.zero;

    if (@intFromEnum(json_value) != 0) {
        // Validate top-level values that are not JSON serializable (Node.js compatibility)
        if (json_value.isUndefined() or json_value.isSymbol() or json_value.jsType() == .JSFunction) {
            const err = globalThis.createTypeErrorInstance("Value is not JSON serializable", .{});
            return globalThis.throwValue(err);
        }

        // BigInt has a different error message to match Node.js exactly
        if (json_value.isBigInt()) {
            const err = globalThis.createTypeErrorInstance("Do not know how to serialize a BigInt", .{});
            return globalThis.throwValue(err);
        }

        var str = bun.String.empty;
        // Use jsonStringifyFast which passes undefined for the space parameter,
        // triggering JSC's FastStringifier optimization. This is significantly faster
        // than jsonStringify which passes 0 for space and uses the slower Stringifier.
        try json_value.jsonStringifyFast(globalThis, &str);

        if (globalThis.hasException()) {
            return .zero;
        }

        if (!str.isEmpty()) {
            if (str.value.WTFStringImpl.toUTF8IfNeeded(bun.default_allocator)) |bytes| {
                defer str.deref();
                response._body.value = .{
                    .InternalBlob = InternalBlob{
                        .bytes = std.array_list.Managed(u8).fromOwnedSlice(bun.default_allocator, @constCast(bytes.slice())),
                        .was_string = true,
                    },
                };
            } else {
                response._body.value = Body.Value{
                    .WTFStringImpl = str.value.WTFStringImpl,
                };
            }
        }
    }

    if (args.nextEat()) |arg_init| {
        if (arg_init.isUndefinedOrNull()) {} else if (arg_init.isNumber()) {
            response._init.status_code = @as(u16, @intCast(@min(@max(0, arg_init.toInt32()), std.math.maxInt(u16))));
        } else {
            if (Response.Init.init(globalThis, arg_init) catch |err| if (err == error.JSError) return .zero else null) |_init| {
                response._init = _init;
            }
        }
    }

    var headers_ref = try response.getOrCreateHeaders(globalThis);
    try headers_ref.putDefault(.ContentType, MimeType.json.value, globalThis);
    did_succeed = true;
    return bun.new(Response, response).toJS(globalThis);
}

fn validateRedirectStatusCode(globalThis: *jsc.JSGlobalObject, status_code: i32) bun.JSError!u16 {
    switch (status_code) {
        301, 302, 303, 307, 308 => return @intCast(status_code),
        else => {
            const err = globalThis.createRangeErrorInstance("Failed to execute 'redirect' on 'Response': Invalid status code", .{});
            return globalThis.throwValue(err);
        },
    }
}

pub fn constructRedirect(
    globalThis: *jsc.JSGlobalObject,
    callframe: *jsc.CallFrame,
) bun.JSError!JSValue {
    const response = try constructRedirectImpl(globalThis, callframe);
    const ptr = bun.new(Response, response);
    const response_js = ptr.toJS(globalThis);
    return response_js;
}

pub fn constructRedirectImpl(
    globalThis: *jsc.JSGlobalObject,
    callframe: *jsc.CallFrame,
) bun.JSError!Response {
    var args_list = callframe.arguments_old(4);
    // https://github.com/remix-run/remix/blob/db2c31f64affb2095e4286b91306b96435967969/packages/remix-server-runtime/responses.ts#L4
    var args = jsc.CallFrame.ArgumentsSlice.init(globalThis.bunVM(), args_list.ptr[0..args_list.len]);

    var url_string_slice = ZigString.Slice.empty;
    defer url_string_slice.deinit();
    var response: Response = brk: {
        var response = Response{
            ._init = Response.Init{
                .status_code = 302,
            },
            ._body = Body{
                .value = .{ .Empty = {} },
            },
            ._url = bun.String.empty,
        };

        const url_string_value = args.nextEat() orelse jsc.JSValue.zero;
        var url_string = ZigString.init("");

        if (@intFromEnum(url_string_value) != 0) {
            url_string = try url_string_value.getZigString(globalThis);
        }
        url_string_slice = url_string.toSlice(bun.default_allocator);
        var did_succeed = false;
        defer {
            if (!did_succeed) {
                response._body.deinit(bun.default_allocator);
                response._init.deinit(bun.default_allocator);
            }
        }

        if (args.nextEat()) |arg_init| {
            if (arg_init.isUndefinedOrNull()) {} else if (arg_init.isNumber()) {
                response._init.status_code = try validateRedirectStatusCode(globalThis, arg_init.toInt32());
            } else if (try Response.Init.init(globalThis, arg_init)) |_init| {
                errdefer response._init.deinit(bun.default_allocator);
                response._init = _init;

                if (_init.status_code != 200) {
                    response._init.status_code = try validateRedirectStatusCode(globalThis, _init.status_code);
                }
            }
        }

        if (globalThis.hasException()) {
            return error.JSError;
        }
        did_succeed = true;
        break :brk response;
    };

    response._init.headers = try response.getOrCreateHeaders(globalThis);
    var headers_ref = response._init.headers.?;
    try headers_ref.put(.Location, url_string_slice.slice(), globalThis);
    return response;
}

pub fn constructError(
    globalThis: *jsc.JSGlobalObject,
    _: *jsc.CallFrame,
) bun.JSError!JSValue {
    const response = bun.new(
        Response,
        Response{
            ._init = Response.Init{
                .status_code = 0,
            },
            ._body = Body{
                .value = .{ .Empty = {} },
            },
        },
    );

    const js_value = response.toJS(globalThis);
    response._js_ref = .initWeak(js_value);
    return js_value;
}

pub fn constructor(globalThis: *jsc.JSGlobalObject, callframe: *jsc.CallFrame, js_this: jsc.JSValue) bun.JSError!*Response {
    var arguments = callframe.argumentsAsArray(2);

    if (!arguments[0].isUndefinedOrNull() and arguments[0].isObject()) {
        if (arguments[0].as(Blob)) |blob| {
            if (blob.isS3()) {
                if (!arguments[1].isEmptyOrUndefinedOrNull()) {
                    return globalThis.throwInvalidArguments("new Response(s3File) do not support ResponseInit options", .{});
                }
                var response: Response = .{
                    ._init = Response.Init{
                        .status_code = 302,
                    },
                    ._body = Body{
                        .value = .{ .Empty = {} },
                    },
                    ._url = bun.String.empty,
                    ._js_ref = .initWeak(js_this),
                };

                const credentials = blob.store.?.data.s3.getCredentials();

                const result = credentials.signRequest(.{
                    .path = blob.store.?.data.s3.path(),
                    .method = .GET,
                }, false, .{ .expires = 15 * 60 }) catch |sign_err| {
                    return s3.throwSignError(sign_err, globalThis);
                };
                defer result.deinit();
                response._init.headers = try response.getOrCreateHeaders(globalThis);
                response._redirected = true;
                var headers_ref = response._init.headers.?;
                try headers_ref.put(.Location, result.url, globalThis);
                return bun.new(Response, response);
            }
        }
    }
    var _init: Init = (brk: {
        if (arguments[1].isUndefinedOrNull()) {
            break :brk Init{
                .status_code = 200,
                .headers = null,
            };
        }
        if (arguments[1].isObject()) {
            break :brk try Init.init(globalThis, arguments[1]) orelse unreachable;
        }
        if (!globalThis.hasException()) {
            return globalThis.throwInvalidArguments("Failed to construct 'Response': The provided body value is not of type 'ResponseInit'", .{});
        }
        return error.JSError;
    });
    errdefer _init.deinit(bun.default_allocator);

    if (globalThis.hasException()) {
        return error.JSError;
    }

    var body: Body = brk: {
        if (arguments[0].isUndefinedOrNull()) {
            break :brk Body{
                .value = Body.Value{ .Null = {} },
            };
        }
        break :brk try Body.extract(globalThis, arguments[0]);
    };
    errdefer body.deinit(bun.default_allocator);

    if (globalThis.hasException()) {
        return error.JSError;
    }

    var response = bun.new(Response, Response{
        ._body = body,
        ._init = _init,
        ._js_ref = .initWeak(js_this),
    });

    if (response._body.value == .Blob and
        response._init.headers != null and
        response._body.value.Blob.content_type.len > 0 and
        !response._init.headers.?.fastHas(.ContentType))
    {
        try response._init.headers.?.put(.ContentType, response._body.value.Blob.content_type, globalThis);
    }

    response.calculateEstimatedByteSize();
    response.checkBodyStreamRef(globalThis);
    return response;
}

pub const Init = struct {
    headers: ?*FetchHeaders = null,
    status_code: u16,
    status_text: bun.String = bun.String.empty,
    method: Method = Method.GET,

    pub fn clone(this: Init, ctx: *JSGlobalObject) bun.JSError!Init {
        var that = this;
        const headers = this.headers;
        if (headers) |head| {
            that.headers = try head.cloneThis(ctx);
        }
        that.status_text = this.status_text.clone();

        return that;
    }

    pub fn init(globalThis: *JSGlobalObject, response_init: jsc.JSValue) bun.JSError!?Init {
        var result = Init{ .status_code = 200 };
        errdefer {
            result.deinit(bun.default_allocator);
        }

        if (!response_init.isCell())
            return null;

        const js_type = response_init.jsType();

        if (!js_type.isObject()) {
            return null;
        }

        if (js_type == .DOMWrapper) {
            // fast path: it's a Request object or a Response object
            // we can skip calling JS getters
            if (response_init.asDirect(Request)) |req| {
                if (req.getFetchHeadersUnlessEmpty()) |headers| {
                    result.headers = try headers.cloneThis(globalThis);
                }

                result.method = req.method;
                return result;
            }

            if (response_init.asDirect(Response)) |resp| {
                return try resp._init.clone(globalThis);
            }
        }

        if (globalThis.hasException()) {
            return error.JSError;
        }

        if (try response_init.fastGet(globalThis, .headers)) |headers| {
            if (headers.as(FetchHeaders)) |orig| {
                if (!orig.isEmpty()) {
                    result.headers = try orig.cloneThis(globalThis);
                }
            } else {
                result.headers = try FetchHeaders.createFromJS(globalThis, headers);
            }
        }

        if (globalThis.hasException()) {
            return error.JSError;
        }

        if (try response_init.fastGet(globalThis, .status)) |status_value| {
            const number = try status_value.coerceToInt64(globalThis);
            if ((200 <= number and number < 600) or number == 101) {
                result.status_code = @as(u16, @truncate(@as(u32, @intCast(number))));
            } else {
                if (!globalThis.hasException()) {
                    const err = globalThis.createRangeErrorInstance("The status provided ({d}) must be 101 or in the range of [200, 599]", .{number});
                    return globalThis.throwValue(err);
                }
                return error.JSError;
            }
        }

        if (globalThis.hasException()) {
            return error.JSError;
        }

        if (try response_init.getTruthy(globalThis, "statusText")) |status_text| {
            result.status_text = try bun.String.fromJS(status_text, globalThis);
        }

        if (try response_init.getTruthy(globalThis, "method")) |method_value| {
            if (try Method.fromJS(globalThis, method_value)) |method| {
                result.method = method;
            }
        }

        return result;
    }

    pub fn deinit(this: *Init, _: std.mem.Allocator) void {
        if (this.headers) |headers| {
            this.headers = null;

            headers.deref();
        }

        this.status_text.deref();
        this.status_text = bun.String.empty;
    }
};

pub fn @"404"(globalThis: *jsc.JSGlobalObject) Response {
    return emptyWithStatus(globalThis, 404);
}

pub fn @"200"(globalThis: *jsc.JSGlobalObject) Response {
    return emptyWithStatus(globalThis, 200);
}

inline fn emptyWithStatus(_: *jsc.JSGlobalObject, status: u16) Response {
    return bun.new(Response, .{
        ._body = Body{
            .value = Body.Value{ .Null = {} },
        },
        .init = Init{
            .status_code = status,
        },
    });
}

/// https://developer.mozilla.org/en-US/docs/Web/API/Headers
// TODO: move to http.zig. this has nothing to do with jsc or WebCore

const std = @import("std");
const Method = @import("../../http_types/Method.zig").Method;

const bun = @import("bun");
const Output = bun.Output;
const default_allocator = bun.default_allocator;
const s3 = bun.S3;
const FetchHeaders = bun.webcore.FetchHeaders;

const http = bun.http;
const MimeType = bun.http.MimeType;

const jsc = bun.jsc;
const JSGlobalObject = jsc.JSGlobalObject;
const JSValue = jsc.JSValue;
const ZigString = jsc.ZigString;
const Request = jsc.WebCore.Request;

const Blob = jsc.WebCore.Blob;
const InternalBlob = jsc.WebCore.Blob.Internal;

const Body = jsc.WebCore.Body;
const BodyMixin = jsc.WebCore.Body.Mixin;
