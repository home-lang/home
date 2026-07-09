// Phase 3 — minimal Web Platform globals for the native JSC eval/run realm.
//
// The bare `JSGlobalContextCreate` realm has standard ECMAScript (JSON, Math,
// Promise, Uint8Array, …) but none of the Web/runtime globals Bun's realm
// exposes. This installs the synchronous, no-event-loop-needed subset that
// real scripts most commonly reach for:
//
//   - `TextEncoder` / `TextDecoder` (UTF-8) — backed by native callbacks that
//     bridge JS strings <-> `Uint8Array` through the JSC typed-array C API.
//   - `queueMicrotask` — the standard `Promise.resolve().then` scheduling.
//   - `btoa` / `atob` — Latin1 base64, implemented in JS so char-code access
//     is faithful (no UTF-8 reinterpretation of the input).
//
// Timers (`setTimeout`), `URL`, `crypto`, and `fetch` are intentionally left
// out: they need an event loop / larger subsystems (documented next steps).
// Same register-natives-then-JS-glue pattern as `console.zig`/`process.zig`.

const std = @import("std");
const bun = @import("bun");
const build_options = @import("build_options");
const evaluate = @import("evaluate.zig");
const callback = @import("callback.zig");
const extern_fns = @import("extern_fns.zig");
const opaques = @import("opaques.zig");

const JSValue = opaques.JSValue;
const JSContextRef = opaques.JSContextRef;
const JSObject = opaques.JSObject;
const JSGlobalObject = opaques.JSGlobalObject;

fn jsStringValue(ctx: *JSContextRef, text: []const u8) ?*JSValue {
    const allocator = std.heap.page_allocator;
    const text_z = bun.dupeZ(allocator, u8, text) catch return null;
    defer allocator.free(text_z);
    const string = extern_fns.JSStringCreateWithUTF8CString(text_z.ptr) orelse return null;
    defer extern_fns.JSStringRelease(string);
    return extern_fns.JSValueMakeString(ctx, string);
}

/// `TextEncoder.prototype.encode(string)` -> `Uint8Array` of the UTF-8 bytes.
fn textEncodeNative(
    ctx: ?*JSContextRef,
    function: ?*JSObject,
    this_object: ?*JSObject,
    argument_count: usize,
    arguments: [*c]const ?*JSValue,
    exception: extern_fns.ExceptionRef,
) callconv(.c) ?*JSValue {
    _ = function;
    _ = this_object;
    _ = exception;
    const c = ctx orelse return null;
    const allocator = std.heap.page_allocator;

    var utf8: []const u8 = "";
    var owned: ?[]u8 = null;
    defer if (owned) |o| allocator.free(o);
    if (argument_count >= 1) {
        if (arguments[0]) |value| {
            if (extern_fns.JSValueToStringCopy(c, value, null)) |string| {
                defer extern_fns.JSStringRelease(string);
                const capacity = extern_fns.JSStringGetLength(string) * 4 + 1;
                const buf = allocator.alloc(u8, capacity) catch return makeUint8Array(c, "");
                const written = extern_fns.JSStringGetUTF8CString(string, buf.ptr, buf.len);
                owned = buf;
                utf8 = buf[0 .. if (written > 0) written - 1 else 0];
            }
        }
    }
    return makeUint8Array(c, utf8);
}

fn makeUint8Array(ctx: *JSContextRef, bytes: []const u8) ?*JSValue {
    const array = extern_fns.JSObjectMakeTypedArray(ctx, .kJSTypedArrayTypeUint8Array, bytes.len, null) orelse
        return extern_fns.JSValueMakeUndefined(ctx);
    if (bytes.len > 0) {
        if (extern_fns.JSObjectGetTypedArrayBytesPtr(ctx, array, null)) |ptr| {
            const dest: [*]u8 = @ptrCast(ptr);
            @memcpy(dest[0..bytes.len], bytes);
        }
    }
    return @ptrCast(array);
}

/// `TextDecoder.prototype.decode(uint8array)` -> UTF-8 string.
fn textDecodeNative(
    ctx: ?*JSContextRef,
    function: ?*JSObject,
    this_object: ?*JSObject,
    argument_count: usize,
    arguments: [*c]const ?*JSValue,
    exception: extern_fns.ExceptionRef,
) callconv(.c) ?*JSValue {
    _ = function;
    _ = this_object;
    _ = exception;
    const c = ctx orelse return null;
    if (argument_count < 1) return jsStringValue(c, "");
    const value = arguments[0] orelse return jsStringValue(c, "");

    if (extern_fns.JSValueGetTypedArrayType(c, value, null) == .kJSTypedArrayTypeNone)
        return jsStringValue(c, "");
    const object = extern_fns.JSValueToObject(c, value, null) orelse return jsStringValue(c, "");
    const length = extern_fns.JSObjectGetTypedArrayLength(c, object, null);
    if (length == 0) return jsStringValue(c, "");
    const ptr = extern_fns.JSObjectGetTypedArrayBytesPtr(c, object, null) orelse return jsStringValue(c, "");
    const bytes: [*]const u8 = @ptrCast(ptr);

    const allocator = std.heap.page_allocator;
    const z = allocator.allocSentinel(u8, length, 0) catch return jsStringValue(c, "");
    defer allocator.free(z);
    @memcpy(z[0..length], bytes[0..length]);
    const string = extern_fns.JSStringCreateWithUTF8CString(z.ptr) orelse return jsStringValue(c, "");
    defer extern_fns.JSStringRelease(string);
    return extern_fns.JSValueMakeString(c, string);
}

const install_glue =
    \\(function() {
    \\  var encodeFn = globalThis.__home_text_encode;
    \\  var decodeFn = globalThis.__home_text_decode;
    \\  globalThis.queueMicrotask = function(cb) {
    \\    if (typeof cb !== "function") throw new TypeError("queueMicrotask: argument is not a function");
    \\    Promise.resolve().then(cb);
    \\  };
    \\  globalThis.TextEncoder = class TextEncoder {
    \\    get encoding() { return "utf-8"; }
    \\    encode(input) { return encodeFn(input === undefined ? "" : String(input)); }
    \\  };
    \\  globalThis.TextDecoder = class TextDecoder {
    \\    constructor(label) { this._encoding = String(label || "utf-8").toLowerCase(); }
    \\    get encoding() { return "utf-8"; }
    \\    decode(input) { return input === undefined ? "" : decodeFn(input); }
    \\  };
    \\  var B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    \\  globalThis.btoa = function(input) {
    \\    var str = String(input);
    \\    for (var k = 0; k < str.length; k++) {
    \\      if (str.charCodeAt(k) > 0xFF) throw new Error("btoa: The string contains characters outside the Latin1 range.");
    \\    }
    \\    var out = "";
    \\    for (var i = 0; i < str.length; i += 3) {
    \\      var b0 = str.charCodeAt(i);
    \\      var b1 = i + 1 < str.length ? str.charCodeAt(i + 1) : NaN;
    \\      var b2 = i + 2 < str.length ? str.charCodeAt(i + 2) : NaN;
    \\      var e0 = b0 >> 2;
    \\      var e1 = ((b0 & 3) << 4) | (isNaN(b1) ? 0 : (b1 >> 4));
    \\      var e2 = isNaN(b1) ? 64 : (((b1 & 15) << 2) | (isNaN(b2) ? 0 : (b2 >> 6)));
    \\      var e3 = isNaN(b2) ? 64 : (b2 & 63);
    \\      out += B64.charAt(e0) + B64.charAt(e1) + (e2 === 64 ? "=" : B64.charAt(e2)) + (e3 === 64 ? "=" : B64.charAt(e3));
    \\    }
    \\    return out;
    \\  };
    \\  globalThis.atob = function(input) {
    \\    var str = String(input).replace(/[ \t\r\n\f]/g, "");
    \\    if (str.length % 4 === 1) throw new Error("atob: invalid base64 length");
    \\    str = str.replace(/=+$/, "");
    \\    var out = "", bits = 0, nbits = 0;
    \\    for (var i = 0; i < str.length; i++) {
    \\      var idx = B64.indexOf(str.charAt(i));
    \\      if (idx === -1) throw new Error("atob: invalid base64 character");
    \\      bits = (bits << 6) | idx;
    \\      nbits += 6;
    \\      if (nbits >= 8) { nbits -= 8; out += String.fromCharCode((bits >> nbits) & 0xFF); }
    \\    }
    \\    return out;
    \\  };
    \\  delete globalThis.__home_text_encode;
    \\  delete globalThis.__home_text_decode;
    \\})();
    \\(function() {
    \\  function makeReadableState() {
    \\    return {
    \\      queue: [],
    \\      closed: false,
    \\      errored: false,
    \\      storedError: undefined,
    \\      pendingReads: [],
    \\      reader: null,
    \\      started: false,
    \\      pulling: false,
    \\      source: null,
    \\      controller: null,
    \\      highWaterMark: 1,
    \\      sizeAlgorithm: function() { return 1; },
    \\      closeRequested: false,
    \\      disturbed: false
    \\    };
    \\  }
    \\  function readableQueueSize(state) {
    \\    var total = 0;
    \\    for (var i = 0; i < state.queue.length; i++) total += state.queue[i].size;
    \\    return total;
    \\  }
    \\  function readableDesiredSize(state) {
    \\    if (state.errored) return null;
    \\    if (state.closed || state.closeRequested) return 0;
    \\    return state.highWaterMark - readableQueueSize(state);
    \\  }
    \\  function settlePendingReadsClose(state) {
    \\    while (state.pendingReads.length > 0) {
    \\      var p = state.pendingReads.shift();
    \\      p.resolve({ value: undefined, done: true });
    \\    }
    \\  }
    \\  function settlePendingReadsError(state, e) {
    \\    while (state.pendingReads.length > 0) {
    \\      var p = state.pendingReads.shift();
    \\      p.reject(e);
    \\    }
    \\  }
    \\  function readablePull(state) {
    \\    if (state.errored || state.closed) return;
    \\    if (!state.started) return;
    \\    if (state.pulling) return;
    \\    var desired = readableDesiredSize(state);
    \\    var wantMore = state.pendingReads.length > 0 || (desired !== null && desired > 0);
    \\    if (!wantMore) return;
    \\    if (state.closeRequested) return;
    \\    if (typeof state.source.pull !== "function") return;
    \\    state.pulling = true;
    \\    Promise.resolve().then(function() {
    \\      return state.source.pull(state.controller);
    \\    }).then(function() {
    \\      state.pulling = false;
    \\      readablePull(state);
    \\    }, function(e) {
    \\      state.pulling = false;
    \\      readableError(state, e);
    \\    });
    \\  }
    \\  function readableEnqueue(state, chunk) {
    \\    if (state.errored) throw new TypeError("Cannot enqueue to an errored ReadableStream");
    \\    if (state.closeRequested || state.closed) throw new TypeError("Cannot enqueue to a closed ReadableStream");
    \\    if (state.pendingReads.length > 0) {
    \\      var p = state.pendingReads.shift();
    \\      p.resolve({ value: chunk, done: false });
    \\      return;
    \\    }
    \\    var size = 1;
    \\    try { size = state.sizeAlgorithm(chunk); } catch (e) { size = 1; }
    \\    state.queue.push({ chunk: chunk, size: size });
    \\  }
    \\  function readableClose(state) {
    \\    if (state.closeRequested || state.closed) return;
    \\    state.closeRequested = true;
    \\    if (state.queue.length === 0) {
    \\      state.closed = true;
    \\      settlePendingReadsClose(state);
    \\      if (state.closedResolve) state.closedResolve();
    \\    }
    \\  }
    \\  function readableError(state, e) {
    \\    if (state.errored || state.closed) return;
    \\    state.errored = true;
    \\    state.storedError = e;
    \\    state.queue = [];
    \\    settlePendingReadsError(state, e);
    \\    if (state.closedReject) state.closedReject(e);
    \\  }
    \\  function readableRead(state) {
    \\    state.disturbed = true;
    \\    if (state.queue.length > 0) {
    \\      var item = state.queue.shift();
    \\      if (state.closeRequested && state.queue.length === 0) {
    \\        state.closed = true;
    \\        if (state.closedResolve) state.closedResolve();
    \\      }
    \\      readablePull(state);
    \\      return Promise.resolve({ value: item.chunk, done: false });
    \\    }
    \\    if (state.errored) return Promise.reject(state.storedError);
    \\    if (state.closed) return Promise.resolve({ value: undefined, done: true });
    \\    var resolve, reject;
    \\    var promise = new Promise(function(res, rej) { resolve = res; reject = rej; });
    \\    state.pendingReads.push({ resolve: resolve, reject: reject });
    \\    readablePull(state);
    \\    return promise;
    \\  }
    \\  function readableCancel(state, reason) {
    \\    if (state.closed) return Promise.resolve();
    \\    if (state.errored) return Promise.reject(state.storedError);
    \\    state.queue = [];
    \\    state.closed = true;
    \\    state.closeRequested = true;
    \\    settlePendingReadsClose(state);
    \\    if (state.closedResolve) state.closedResolve();
    \\    var result;
    \\    try {
    \\      result = state.source && typeof state.source.cancel === "function" ? state.source.cancel(reason) : undefined;
    \\    } catch (e) {
    \\      return Promise.reject(e);
    \\    }
    \\    return Promise.resolve(result).then(function() { return undefined; });
    \\  }
    \\
    \\  function ReadableStreamDefaultController(state) {
    \\    this._state = state;
    \\  }
    \\  Object.defineProperty(ReadableStreamDefaultController.prototype, "desiredSize", {
    \\    get: function() { return readableDesiredSize(this._state); },
    \\    enumerable: true,
    \\    configurable: true
    \\  });
    \\  ReadableStreamDefaultController.prototype.enqueue = function(chunk) { readableEnqueue(this._state, chunk); };
    \\  ReadableStreamDefaultController.prototype.close = function() { readableClose(this._state); };
    \\  ReadableStreamDefaultController.prototype.error = function(e) { readableError(this._state, e); };
    \\
    \\  function ReadableStreamDefaultReader(stream) {
    \\    if (!(stream instanceof ReadableStream)) throw new TypeError("ReadableStreamDefaultReader: not a ReadableStream");
    \\    var state = stream._state;
    \\    if (state.reader) throw new TypeError("ReadableStream is locked to a reader");
    \\    this._stream = stream;
    \\    this._state = state;
    \\    state.reader = this;
    \\    var self = this;
    \\    this._closedPromise = new Promise(function(resolve, reject) {
    \\      if (state.closed) { resolve(); return; }
    \\      if (state.errored) { reject(state.storedError); return; }
    \\      state.closedResolve = resolve;
    \\      state.closedReject = reject;
    \\    });
    \\    this._closedPromise.catch(function() {});
    \\    void self;
    \\  }
    \\  ReadableStreamDefaultReader.prototype.read = function() {
    \\    if (!this._state) return Promise.reject(new TypeError("Reader has been released"));
    \\    return readableRead(this._state);
    \\  };
    \\  ReadableStreamDefaultReader.prototype.releaseLock = function() {
    \\    if (!this._state) return;
    \\    this._state.reader = null;
    \\    this._state = null;
    \\    this._stream = null;
    \\  };
    \\  ReadableStreamDefaultReader.prototype.cancel = function(reason) {
    \\    if (!this._state) return Promise.reject(new TypeError("Reader has been released"));
    \\    return readableCancel(this._state, reason);
    \\  };
    \\  Object.defineProperty(ReadableStreamDefaultReader.prototype, "closed", {
    \\    get: function() { return this._closedPromise || Promise.reject(new TypeError("Reader has been released")); },
    \\    enumerable: true,
    \\    configurable: true
    \\  });
    \\
    \\  function ReadableStream(underlyingSource, strategy) {
    \\    if (underlyingSource === undefined || underlyingSource === null) underlyingSource = {};
    \\    if (strategy === undefined || strategy === null) strategy = {};
    \\    var state = makeReadableState();
    \\    this._state = state;
    \\    state.source = underlyingSource;
    \\    state.controller = new ReadableStreamDefaultController(state);
    \\    if (typeof strategy.highWaterMark === "number") state.highWaterMark = strategy.highWaterMark;
    \\    if (typeof strategy.size === "function") state.sizeAlgorithm = strategy.size;
    \\    var startResult;
    \\    if (typeof underlyingSource.start === "function") {
    \\      try {
    \\        startResult = underlyingSource.start(state.controller);
    \\      } catch (e) {
    \\        readableError(state, e);
    \\        return;
    \\      }
    \\    }
    \\    Promise.resolve(startResult).then(function() {
    \\      state.started = true;
    \\      readablePull(state);
    \\    }, function(e) {
    \\      readableError(state, e);
    \\    });
    \\  }
    \\  Object.defineProperty(ReadableStream.prototype, "locked", {
    \\    get: function() { return this._state.reader !== null; },
    \\    enumerable: true,
    \\    configurable: true
    \\  });
    \\  ReadableStream.prototype.getReader = function(opts) {
    \\    if (opts && opts.mode === "byob") throw new TypeError("byob reader is not supported");
    \\    return new ReadableStreamDefaultReader(this);
    \\  };
    \\  ReadableStream.prototype.cancel = function(reason) {
    \\    if (this.locked) return Promise.reject(new TypeError("Cannot cancel a locked stream"));
    \\    return readableCancel(this._state, reason);
    \\  };
    \\  ReadableStream.prototype[Symbol.asyncIterator] = function(opts) {
    \\    var reader = this.getReader();
    \\    var preventCancel = !!(opts && opts.preventCancel);
    \\    return {
    \\      next: function() {
    \\        return reader.read().then(function(result) {
    \\          if (result.done) reader.releaseLock();
    \\          return result;
    \\        });
    \\      },
    \\      return: function(value) {
    \\        if (!preventCancel) {
    \\          var c = reader.cancel(value);
    \\          reader.releaseLock();
    \\          return c.then(function() { return { value: value, done: true }; });
    \\        }
    \\        reader.releaseLock();
    \\        return Promise.resolve({ value: value, done: true });
    \\      },
    \\      [Symbol.asyncIterator]: function() { return this; }
    \\    };
    \\  };
    \\  ReadableStream.prototype.values = function(opts) { return this[Symbol.asyncIterator](opts); };
    \\  ReadableStream.prototype.pipeTo = function(dest, opts) {
    \\    var src = this;
    \\    if (src.locked) return Promise.reject(new TypeError("Cannot pipe a locked stream"));
    \\    if (dest.locked) return Promise.reject(new TypeError("Cannot pipe to a locked stream"));
    \\    opts = opts || {};
    \\    var reader = src.getReader();
    \\    var writer = dest.getWriter();
    \\    return new Promise(function(resolve, reject) {
    \\      function step() {
    \\        reader.read().then(function(result) {
    \\          if (result.done) {
    \\            reader.releaseLock();
    \\            var closeP = opts.preventClose ? Promise.resolve() : writer.close();
    \\            closeP.then(function() { writer.releaseLock(); resolve(); }, function(e) { writer.releaseLock(); reject(e); });
    \\            return;
    \\          }
    \\          writer.write(result.value).then(function() { step(); }, function(e) {
    \\            reader.releaseLock();
    \\            if (!opts.preventAbort) { try { dest.abort(e); } catch (ig) { void ig; } }
    \\            reject(e);
    \\          });
    \\        }, function(e) {
    \\          if (!opts.preventAbort) { try { dest.abort(e); } catch (ig) { void ig; } }
    \\          reject(e);
    \\        });
    \\      }
    \\      step();
    \\    });
    \\  };
    \\  ReadableStream.prototype.pipeThrough = function(transform, opts) {
    \\    if (!transform || !transform.writable || !transform.readable) throw new TypeError("pipeThrough requires { writable, readable }");
    \\    if (this.locked) throw new TypeError("Cannot pipeThrough a locked stream");
    \\    this.pipeTo(transform.writable, opts).catch(function() {});
    \\    return transform.readable;
    \\  };
    \\  ReadableStream.prototype.tee = function() {
    \\    var src = this;
    \\    var reader = src.getReader();
    \\    var pull1Pending = false;
    \\    var branch1, branch2;
    \\    var state = { reading: false, canceled1: false, canceled2: false, reason1: undefined, reason2: undefined };
    \\    function pullAlgorithm(controller, which) {
    \\      if (state.reading) return;
    \\      state.reading = true;
    \\      reader.read().then(function(result) {
    \\        state.reading = false;
    \\        if (result.done) {
    \\          if (!state.canceled1) branch1._state.controller.close();
    \\          if (!state.canceled2) branch2._state.controller.close();
    \\          return;
    \\        }
    \\        if (!state.canceled1) branch1._state.controller.enqueue(result.value);
    \\        if (!state.canceled2) branch2._state.controller.enqueue(result.value);
    \\      }, function(e) {
    \\        state.reading = false;
    \\        if (!state.canceled1) branch1._state.controller.error(e);
    \\        if (!state.canceled2) branch2._state.controller.error(e);
    \\      });
    \\      void pull1Pending; void which;
    \\    }
    \\    branch1 = new ReadableStream({
    \\      pull: function(controller) { pullAlgorithm(controller, 1); },
    \\      cancel: function(reason) {
    \\        state.canceled1 = true; state.reason1 = reason;
    \\        if (state.canceled2) return reader.cancel([state.reason1, state.reason2]);
    \\        return Promise.resolve();
    \\      }
    \\    });
    \\    branch2 = new ReadableStream({
    \\      pull: function(controller) { pullAlgorithm(controller, 2); },
    \\      cancel: function(reason) {
    \\        state.canceled2 = true; state.reason2 = reason;
    \\        if (state.canceled1) return reader.cancel([state.reason1, state.reason2]);
    \\        return Promise.resolve();
    \\      }
    \\    });
    \\    return [branch1, branch2];
    \\  };
    \\  ReadableStream.from = function(iterable) {
    \\    if (iterable && typeof iterable[Symbol.asyncIterator] === "function") {
    \\      var aiter = iterable[Symbol.asyncIterator]();
    \\      return new ReadableStream({
    \\        pull: function(controller) {
    \\          return aiter.next().then(function(result) {
    \\            if (result.done) controller.close();
    \\            else controller.enqueue(result.value);
    \\          });
    \\        },
    \\        cancel: function(reason) {
    \\          if (typeof aiter.return === "function") return Promise.resolve(aiter.return(reason));
    \\          return Promise.resolve();
    \\        }
    \\      });
    \\    }
    \\    if (iterable && typeof iterable[Symbol.iterator] === "function") {
    \\      var siter = iterable[Symbol.iterator]();
    \\      return new ReadableStream({
    \\        pull: function(controller) {
    \\          var result = siter.next();
    \\          return Promise.resolve(result.value).then(function(value) {
    \\            if (result.done) controller.close();
    \\            else controller.enqueue(value);
    \\          });
    \\        },
    \\        cancel: function(reason) {
    \\          if (typeof siter.return === "function") siter.return(reason);
    \\        }
    \\      });
    \\    }
    \\    throw new TypeError("ReadableStream.from: argument is not iterable");
    \\  };
    \\
    \\  // ---- WritableStream ----
    \\  function makeWritableState() {
    \\    return {
    \\      sink: null,
    \\      controller: null,
    \\      started: false,
    \\      writing: false,
    \\      inFlight: false,
    \\      queue: [],
    \\      closed: false,
    \\      closeRequested: false,
    \\      errored: false,
    \\      storedError: undefined,
    \\      writer: null,
    \\      highWaterMark: 1,
    \\      sizeAlgorithm: function() { return 1; },
    \\      closedResolve: null,
    \\      closedReject: null,
    \\      startPromise: null
    \\    };
    \\  }
    \\  function writableQueueSize(state) {
    \\    var total = 0;
    \\    for (var i = 0; i < state.queue.length; i++) total += state.queue[i].size;
    \\    return total;
    \\  }
    \\  function writableDesiredSize(state) {
    \\    if (state.errored) return null;
    \\    if (state.closed || state.closeRequested) return 0;
    \\    return state.highWaterMark - writableQueueSize(state);
    \\  }
    \\  function writableError(state, e) {
    \\    if (state.errored || state.closed) return;
    \\    state.errored = true;
    \\    state.storedError = e;
    \\    var rejectAll = state.queue;
    \\    state.queue = [];
    \\    for (var i = 0; i < rejectAll.length; i++) rejectAll[i].reject(e);
    \\    if (state.closedReject) state.closedReject(e);
    \\  }
    \\  function writableAdvance(state) {
    \\    if (state.inFlight) return;
    \\    if (state.errored) return;
    \\    if (state.queue.length === 0) {
    \\      if (state.closeRequested && !state.closed) {
    \\        state.inFlight = true;
    \\        Promise.resolve().then(function() {
    \\          return state.sink && typeof state.sink.close === "function" ? state.sink.close() : undefined;
    \\        }).then(function() {
    \\          state.inFlight = false;
    \\          state.closed = true;
    \\          if (state.closeResolve) state.closeResolve();
    \\          if (state.closedResolve) state.closedResolve();
    \\        }, function(e) {
    \\          state.inFlight = false;
    \\          if (state.closeReject) state.closeReject(e);
    \\          writableError(state, e);
    \\        });
    \\      }
    \\      return;
    \\    }
    \\    var item = state.queue.shift();
    \\    state.inFlight = true;
    \\    Promise.resolve().then(function() {
    \\      return state.sink && typeof state.sink.write === "function" ? state.sink.write(item.chunk, state.controller) : undefined;
    \\    }).then(function() {
    \\      state.inFlight = false;
    \\      item.resolve();
    \\      writableAdvance(state);
    \\    }, function(e) {
    \\      state.inFlight = false;
    \\      item.reject(e);
    \\      writableError(state, e);
    \\    });
    \\  }
    \\  function writableWrite(state, chunk) {
    \\    if (state.errored) return Promise.reject(state.storedError);
    \\    if (state.closeRequested || state.closed) return Promise.reject(new TypeError("Cannot write to a closing/closed WritableStream"));
    \\    var size = 1;
    \\    try { size = state.sizeAlgorithm(chunk); } catch (e) { size = 1; }
    \\    var resolve, reject;
    \\    var promise = new Promise(function(res, rej) { resolve = res; reject = rej; });
    \\    state.queue.push({ chunk: chunk, size: size, resolve: resolve, reject: reject });
    \\    if (state.started) writableAdvance(state);
    \\    return promise;
    \\  }
    \\  function writableClose(state) {
    \\    if (state.errored) return Promise.reject(state.storedError);
    \\    if (state.closeRequested || state.closed) return Promise.reject(new TypeError("Cannot close an already-closing WritableStream"));
    \\    state.closeRequested = true;
    \\    var resolve, reject;
    \\    var promise = new Promise(function(res, rej) { resolve = res; reject = rej; });
    \\    state.closeResolve = resolve;
    \\    state.closeReject = reject;
    \\    if (state.started) writableAdvance(state);
    \\    return promise;
    \\  }
    \\  function writableAbort(state, reason) {
    \\    if (state.closed) return Promise.resolve();
    \\    if (state.errored) return Promise.resolve();
    \\    var result;
    \\    try {
    \\      result = state.sink && typeof state.sink.abort === "function" ? state.sink.abort(reason) : undefined;
    \\    } catch (e) {
    \\      writableError(state, e);
    \\      return Promise.reject(e);
    \\    }
    \\    writableError(state, reason instanceof Error ? reason : new Error("Aborted"));
    \\    return Promise.resolve(result).then(function() { return undefined; });
    \\  }
    \\
    \\  function WritableStreamDefaultController(state) { this._state = state; }
    \\  WritableStreamDefaultController.prototype.error = function(e) { writableError(this._state, e); };
    \\  Object.defineProperty(WritableStreamDefaultController.prototype, "signal", {
    \\    get: function() { return undefined; },
    \\    enumerable: true,
    \\    configurable: true
    \\  });
    \\
    \\  function WritableStreamDefaultWriter(stream) {
    \\    if (!(stream instanceof WritableStream)) throw new TypeError("WritableStreamDefaultWriter: not a WritableStream");
    \\    var state = stream._state;
    \\    if (state.writer) throw new TypeError("WritableStream is locked to a writer");
    \\    this._stream = stream;
    \\    this._state = state;
    \\    state.writer = this;
    \\    this._closedPromise = new Promise(function(resolve, reject) {
    \\      if (state.closed) { resolve(); return; }
    \\      if (state.errored) { reject(state.storedError); return; }
    \\      state.closedResolve = resolve;
    \\      state.closedReject = reject;
    \\    });
    \\    this._closedPromise.catch(function() {});
    \\  }
    \\  WritableStreamDefaultWriter.prototype.write = function(chunk) {
    \\    if (!this._state) return Promise.reject(new TypeError("Writer has been released"));
    \\    return writableWrite(this._state, chunk);
    \\  };
    \\  WritableStreamDefaultWriter.prototype.close = function() {
    \\    if (!this._state) return Promise.reject(new TypeError("Writer has been released"));
    \\    return writableClose(this._state);
    \\  };
    \\  WritableStreamDefaultWriter.prototype.abort = function(reason) {
    \\    if (!this._state) return Promise.reject(new TypeError("Writer has been released"));
    \\    return writableAbort(this._state, reason);
    \\  };
    \\  WritableStreamDefaultWriter.prototype.releaseLock = function() {
    \\    if (!this._state) return;
    \\    this._state.writer = null;
    \\    this._state = null;
    \\    this._stream = null;
    \\  };
    \\  Object.defineProperty(WritableStreamDefaultWriter.prototype, "desiredSize", {
    \\    get: function() { return this._state ? writableDesiredSize(this._state) : null; },
    \\    enumerable: true,
    \\    configurable: true
    \\  });
    \\  Object.defineProperty(WritableStreamDefaultWriter.prototype, "ready", {
    \\    get: function() {
    \\      if (!this._state) return Promise.reject(new TypeError("Writer has been released"));
    \\      return Promise.resolve();
    \\    },
    \\    enumerable: true,
    \\    configurable: true
    \\  });
    \\  Object.defineProperty(WritableStreamDefaultWriter.prototype, "closed", {
    \\    get: function() { return this._closedPromise || Promise.reject(new TypeError("Writer has been released")); },
    \\    enumerable: true,
    \\    configurable: true
    \\  });
    \\
    \\  function WritableStream(underlyingSink, strategy) {
    \\    if (underlyingSink === undefined || underlyingSink === null) underlyingSink = {};
    \\    if (strategy === undefined || strategy === null) strategy = {};
    \\    var state = makeWritableState();
    \\    this._state = state;
    \\    state.sink = underlyingSink;
    \\    state.controller = new WritableStreamDefaultController(state);
    \\    if (typeof strategy.highWaterMark === "number") state.highWaterMark = strategy.highWaterMark;
    \\    if (typeof strategy.size === "function") state.sizeAlgorithm = strategy.size;
    \\    var startResult;
    \\    if (typeof underlyingSink.start === "function") {
    \\      try {
    \\        startResult = underlyingSink.start(state.controller);
    \\      } catch (e) {
    \\        writableError(state, e);
    \\        return;
    \\      }
    \\    }
    \\    state.startPromise = Promise.resolve(startResult).then(function() {
    \\      state.started = true;
    \\      writableAdvance(state);
    \\    }, function(e) {
    \\      writableError(state, e);
    \\    });
    \\  }
    \\  Object.defineProperty(WritableStream.prototype, "locked", {
    \\    get: function() { return this._state.writer !== null; },
    \\    enumerable: true,
    \\    configurable: true
    \\  });
    \\  WritableStream.prototype.getWriter = function() { return new WritableStreamDefaultWriter(this); };
    \\  WritableStream.prototype.abort = function(reason) {
    \\    if (this.locked) return Promise.reject(new TypeError("Cannot abort a locked stream"));
    \\    return writableAbort(this._state, reason);
    \\  };
    \\  WritableStream.prototype.close = function() {
    \\    if (this.locked) return Promise.reject(new TypeError("Cannot close a locked stream"));
    \\    return writableClose(this._state);
    \\  };
    \\
    \\  // ---- TransformStream ----
    \\  function TransformStream(transformer, writableStrategy, readableStrategy) {
    \\    if (transformer === undefined || transformer === null) transformer = {};
    \\    writableStrategy = writableStrategy || {};
    \\    readableStrategy = readableStrategy || {};
    \\    var readableController = null;
    \\    var self = this;
    \\    var transformController = {
    \\      enqueue: function(chunk) {
    \\        if (readableController) readableController.enqueue(chunk);
    \\      },
    \\      terminate: function() {
    \\        if (readableController) readableController.close();
    \\      },
    \\      error: function(e) {
    \\        if (readableController) readableController.error(e);
    \\        if (self._writable && self._writable._state) writableError(self._writable._state, e);
    \\      }
    \\    };
    \\    var readable = new ReadableStream({
    \\      start: function(controller) { readableController = controller; },
    \\      pull: function() {},
    \\      cancel: function(reason) {
    \\        if (typeof transformer.cancel === "function") return transformer.cancel(reason);
    \\      }
    \\    }, readableStrategy);
    \\    var writable = new WritableStream({
    \\      start: function() {
    \\        if (typeof transformer.start === "function") return transformer.start(transformController);
    \\      },
    \\      write: function(chunk) {
    \\        if (typeof transformer.transform === "function") {
    \\          return Promise.resolve(transformer.transform(chunk, transformController));
    \\        }
    \\        transformController.enqueue(chunk);
    \\        return undefined;
    \\      },
    \\      close: function() {
    \\        var flushP = Promise.resolve();
    \\        if (typeof transformer.flush === "function") {
    \\          flushP = Promise.resolve(transformer.flush(transformController));
    \\        }
    \\        return flushP.then(function() {
    \\          if (readableController) readableController.close();
    \\        });
    \\      },
    \\      abort: function(reason) {
    \\        if (readableController) readableController.error(reason);
    \\      }
    \\    }, writableStrategy);
    \\    this._readable = readable;
    \\    this._writable = writable;
    \\  }
    \\  Object.defineProperty(TransformStream.prototype, "readable", {
    \\    get: function() { return this._readable; },
    \\    enumerable: true,
    \\    configurable: true
    \\  });
    \\  Object.defineProperty(TransformStream.prototype, "writable", {
    \\    get: function() { return this._writable; },
    \\    enumerable: true,
    \\    configurable: true
    \\  });
    \\
    \\  // ---- Queuing strategies ----
    \\  function CountQueuingStrategy(opts) {
    \\    this.highWaterMark = opts && opts.highWaterMark;
    \\  }
    \\  CountQueuingStrategy.prototype.size = function() { return 1; };
    \\  function ByteLengthQueuingStrategy(opts) {
    \\    this.highWaterMark = opts && opts.highWaterMark;
    \\  }
    \\  ByteLengthQueuingStrategy.prototype.size = function(chunk) { return chunk.byteLength; };
    \\
    \\  globalThis.ReadableStream = ReadableStream;
    \\  globalThis.ReadableStreamDefaultReader = ReadableStreamDefaultReader;
    \\  globalThis.ReadableStreamDefaultController = ReadableStreamDefaultController;
    \\  globalThis.WritableStream = WritableStream;
    \\  globalThis.WritableStreamDefaultWriter = WritableStreamDefaultWriter;
    \\  globalThis.WritableStreamDefaultController = WritableStreamDefaultController;
    \\  globalThis.TransformStream = TransformStream;
    \\  globalThis.CountQueuingStrategy = CountQueuingStrategy;
    \\  globalThis.ByteLengthQueuingStrategy = ByteLengthQueuingStrategy;
    \\
    \\  // ---- Encoding / Compression streams (built on TransformStream) ----
    \\  function TextEncoderStream() {
    \\    var enc = new TextEncoder();
    \\    var ts = new TransformStream({
    \\      transform: function(chunk, controller) {
    \\        if (chunk === undefined) return;
    \\        controller.enqueue(enc.encode(String(chunk)));
    \\      }
    \\    });
    \\    this._ts = ts;
    \\  }
    \\  Object.defineProperty(TextEncoderStream.prototype, "encoding", { get: function() { return "utf-8"; }, enumerable: true, configurable: true });
    \\  Object.defineProperty(TextEncoderStream.prototype, "readable", { get: function() { return this._ts.readable; }, enumerable: true, configurable: true });
    \\  Object.defineProperty(TextEncoderStream.prototype, "writable", { get: function() { return this._ts.writable; }, enumerable: true, configurable: true });
    \\
    \\  // Returns the count of leading bytes that form complete UTF-8 sequences; any
    \\  // trailing bytes of an incomplete sequence are excluded so the caller can buffer
    \\  // them across chunks (mirrors node:string_decoder boundary handling).
    \\  function utf8CompleteLen(bytes) {
    \\    var n = bytes.length;
    \\    if (n === 0) return 0;
    \\    var i = n - 1, cont = 0;
    \\    while (i >= 0 && (bytes[i] & 0xC0) === 0x80 && cont < 3) { i--; cont++; }
    \\    if (i < 0) return n;
    \\    var lead = bytes[i], need;
    \\    if (lead < 0x80) need = 1;
    \\    else if ((lead & 0xE0) === 0xC0) need = 2;
    \\    else if ((lead & 0xF0) === 0xE0) need = 3;
    \\    else if ((lead & 0xF8) === 0xF0) need = 4;
    \\    else return n;
    \\    var have = n - i;
    \\    if (have >= need) return n;
    \\    return i;
    \\  }
    \\  function toUint8(chunk) {
    \\    if (chunk instanceof Uint8Array) return chunk;
    \\    if (typeof chunk === "string") return new TextEncoder().encode(chunk);
    \\    return new Uint8Array(ArrayBuffer.isView(chunk) ? chunk.buffer : chunk);
    \\  }
    \\  function TextDecoderStream(label, options) {
    \\    var dec = new TextDecoder(label, options);
    \\    var carry = null;
    \\    var ts = new TransformStream({
    \\      transform: function(chunk, controller) {
    \\        if (chunk === undefined) return;
    \\        var bytes = toUint8(chunk);
    \\        if (carry && carry.length) {
    \\          var merged = new Uint8Array(carry.length + bytes.length);
    \\          merged.set(carry, 0);
    \\          merged.set(bytes, carry.length);
    \\          bytes = merged;
    \\          carry = null;
    \\        }
    \\        var split = utf8CompleteLen(bytes);
    \\        if (split < bytes.length) carry = bytes.slice(split);
    \\        if (split > 0) {
    \\          var s = dec.decode(bytes.slice(0, split));
    \\          if (s) controller.enqueue(s);
    \\        }
    \\      },
    \\      flush: function(controller) {
    \\        if (carry && carry.length) {
    \\          var s = dec.decode(carry);
    \\          if (s) controller.enqueue(s);
    \\          carry = null;
    \\        }
    \\      }
    \\    });
    \\    this._encoding = String(label || "utf-8").toLowerCase();
    \\    this._ts = ts;
    \\  }
    \\  Object.defineProperty(TextDecoderStream.prototype, "encoding", { get: function() { return this._encoding; }, enumerable: true, configurable: true });
    \\  Object.defineProperty(TextDecoderStream.prototype, "readable", { get: function() { return this._ts.readable; }, enumerable: true, configurable: true });
    \\  Object.defineProperty(TextDecoderStream.prototype, "writable", { get: function() { return this._ts.writable; }, enumerable: true, configurable: true });
    \\
    \\  function makeZlibStream(fnName) {
    \\    var parts = [];
    \\    return new TransformStream({
    \\      transform: function(chunk) {
    \\        if (chunk === undefined) return;
    \\        parts.push(toUint8(chunk));
    \\      },
    \\      flush: function(controller) {
    \\        var total = 0, i;
    \\        for (i = 0; i < parts.length; i++) total += parts[i].length;
    \\        var joined = new Uint8Array(total), off = 0;
    \\        for (i = 0; i < parts.length; i++) { joined.set(parts[i], off); off += parts[i].length; }
    \\        var zlib = globalThis.require("node:zlib");
    \\        var out = zlib[fnName](joined);
    \\        controller.enqueue(out instanceof Uint8Array ? out : new Uint8Array(out));
    \\      }
    \\    });
    \\  }
    \\  function CompressionStream(format) {
    \\    var fn = format === "gzip" ? "gzipSync" : (format === "deflate" ? "deflateSync" : (format === "deflate-raw" ? "deflateRawSync" : null));
    \\    if (!fn) throw new TypeError("Unsupported compression format: " + format);
    \\    this._format = String(format);
    \\    this._ts = makeZlibStream(fn);
    \\  }
    \\  Object.defineProperty(CompressionStream.prototype, "readable", { get: function() { return this._ts.readable; }, enumerable: true, configurable: true });
    \\  Object.defineProperty(CompressionStream.prototype, "writable", { get: function() { return this._ts.writable; }, enumerable: true, configurable: true });
    \\  function DecompressionStream(format) {
    \\    var fn = format === "gzip" ? "gunzipSync" : (format === "deflate" ? "inflateSync" : (format === "deflate-raw" ? "inflateRawSync" : null));
    \\    if (!fn) throw new TypeError("Unsupported compression format: " + format);
    \\    this._format = String(format);
    \\    this._ts = makeZlibStream(fn);
    \\  }
    \\  Object.defineProperty(DecompressionStream.prototype, "readable", { get: function() { return this._ts.readable; }, enumerable: true, configurable: true });
    \\  Object.defineProperty(DecompressionStream.prototype, "writable", { get: function() { return this._ts.writable; }, enumerable: true, configurable: true });
    \\
    \\  globalThis.TextEncoderStream = TextEncoderStream;
    \\  globalThis.TextDecoderStream = TextDecoderStream;
    \\  globalThis.CompressionStream = CompressionStream;
    \\  globalThis.DecompressionStream = DecompressionStream;
    \\
    \\  // ---- Events + Abort (DOM-ish, pure JS) ----
    \\  function Event(type, init) {
    \\    init = init || {};
    \\    this.type = String(type);
    \\    this.bubbles = !!init.bubbles;
    \\    this.cancelable = !!init.cancelable;
    \\    this.defaultPrevented = false;
    \\    this.timeStamp = 0;
    \\    this.target = null;
    \\    this.currentTarget = null;
    \\    this._stopPropagation = false;
    \\    this._stopImmediate = false;
    \\  }
    \\  Event.prototype.preventDefault = function() {
    \\    if (this.cancelable) this.defaultPrevented = true;
    \\  };
    \\  Event.prototype.stopPropagation = function() { this._stopPropagation = true; };
    \\  Event.prototype.stopImmediatePropagation = function() {
    \\    this._stopImmediate = true;
    \\    this._stopPropagation = true;
    \\  };
    \\
    \\  function CustomEvent(type, init) {
    \\    Event.call(this, type, init);
    \\    this.detail = init && init.detail !== undefined ? init.detail : null;
    \\  }
    \\  CustomEvent.prototype = Object.create(Event.prototype);
    \\  CustomEvent.prototype.constructor = CustomEvent;
    \\
    \\  // Event subclasses dispatched by MessagePort/BroadcastChannel/WebSocket.
    \\  function MessageEvent(type, init) {
    \\    Event.call(this, type, init); init = init || {};
    \\    this.data = init.data !== undefined ? init.data : null;
    \\    this.origin = init.origin !== undefined ? String(init.origin) : "";
    \\    this.lastEventId = init.lastEventId !== undefined ? String(init.lastEventId) : "";
    \\    this.source = init.source !== undefined ? init.source : null;
    \\    this.ports = init.ports !== undefined ? init.ports : [];
    \\  }
    \\  MessageEvent.prototype = Object.create(Event.prototype);
    \\  MessageEvent.prototype.constructor = MessageEvent;
    \\
    \\  function CloseEvent(type, init) {
    \\    Event.call(this, type, init); init = init || {};
    \\    this.wasClean = !!init.wasClean;
    \\    this.code = init.code !== undefined ? (init.code | 0) : 0;
    \\    this.reason = init.reason !== undefined ? String(init.reason) : "";
    \\  }
    \\  CloseEvent.prototype = Object.create(Event.prototype);
    \\  CloseEvent.prototype.constructor = CloseEvent;
    \\
    \\  function ErrorEvent(type, init) {
    \\    Event.call(this, type, init); init = init || {};
    \\    this.message = init.message !== undefined ? String(init.message) : "";
    \\    this.filename = init.filename !== undefined ? String(init.filename) : "";
    \\    this.lineno = init.lineno !== undefined ? (init.lineno | 0) : 0;
    \\    this.colno = init.colno !== undefined ? (init.colno | 0) : 0;
    \\    this.error = init.error !== undefined ? init.error : null;
    \\  }
    \\  ErrorEvent.prototype = Object.create(Event.prototype);
    \\  ErrorEvent.prototype.constructor = ErrorEvent;
    \\
    \\  function ProgressEvent(type, init) {
    \\    Event.call(this, type, init); init = init || {};
    \\    this.lengthComputable = !!init.lengthComputable;
    \\    this.loaded = init.loaded !== undefined ? Number(init.loaded) : 0;
    \\    this.total = init.total !== undefined ? Number(init.total) : 0;
    \\  }
    \\  ProgressEvent.prototype = Object.create(Event.prototype);
    \\  ProgressEvent.prototype.constructor = ProgressEvent;
    \\
    \\  function EventTarget() {
    \\    this._listeners = Object.create(null);
    \\  }
    \\  function ensureListeners(self) {
    \\    if (!self._listeners) self._listeners = Object.create(null);
    \\    return self._listeners;
    \\  }
    \\  EventTarget.prototype.addEventListener = function(type, listener, opts) {
    \\    if (listener === undefined || listener === null) return;
    \\    var t = String(type);
    \\    var map = ensureListeners(this);
    \\    var list = map[t] || (map[t] = []);
    \\    var once = !!(opts && typeof opts === "object" && opts.once);
    \\    for (var i = 0; i < list.length; i++) {
    \\      if (list[i].listener === listener) return;
    \\    }
    \\    list.push({ listener: listener, once: once });
    \\  };
    \\  EventTarget.prototype.removeEventListener = function(type, listener) {
    \\    var map = ensureListeners(this);
    \\    var list = map[String(type)];
    \\    if (!list) return;
    \\    for (var i = 0; i < list.length; i++) {
    \\      if (list[i].listener === listener) { list.splice(i, 1); return; }
    \\    }
    \\  };
    \\  EventTarget.prototype.dispatchEvent = function(event) {
    \\    var map = ensureListeners(this);
    \\    var list = map[event.type];
    \\    event.target = this;
    \\    event.currentTarget = this;
    \\    if (list && list.length) {
    \\      var snapshot = list.slice();
    \\      for (var i = 0; i < snapshot.length; i++) {
    \\        var entry = snapshot[i];
    \\        if (entry.once) {
    \\          for (var j = 0; j < list.length; j++) {
    \\            if (list[j] === entry) { list.splice(j, 1); break; }
    \\          }
    \\        }
    \\        var fn = entry.listener;
    \\        try {
    \\          if (typeof fn === "function") fn.call(this, event);
    \\          else if (fn && typeof fn.handleEvent === "function") fn.handleEvent(event);
    \\        } catch (e) { void e; }
    \\        if (event._stopImmediate) break;
    \\      }
    \\    }
    \\    event.currentTarget = null;
    \\    return !event.defaultPrevented;
    \\  };
    \\
    \\  function AbortSignal() {
    \\    EventTarget.call(this);
    \\    this.aborted = false;
    \\    this.reason = undefined;
    \\    this.onabort = null;
    \\  }
    \\  AbortSignal.prototype = Object.create(EventTarget.prototype);
    \\  AbortSignal.prototype.constructor = AbortSignal;
    \\  AbortSignal.prototype.throwIfAborted = function() {
    \\    if (this.aborted) throw this.reason;
    \\  };
    \\  function signalAbort(signal, reason) {
    \\    if (signal.aborted) return;
    \\    signal.aborted = true;
    \\    signal.reason = reason;
    \\    var ev = new Event("abort");
    \\    if (typeof signal.onabort === "function") {
    \\      try { signal.onabort.call(signal, ev); } catch (e) { void e; }
    \\    }
    \\    signal.dispatchEvent(ev);
    \\  }
    \\  AbortSignal.abort = function(reason) {
    \\    var s = new AbortSignal();
    \\    s.aborted = true;
    \\    s.reason = reason !== undefined ? reason : { name: "AbortError", message: "signal is aborted without reason" };
    \\    return s;
    \\  };
    \\  AbortSignal.timeout = function(ms) {
    \\    var s = new AbortSignal();
    \\    if (typeof globalThis.setTimeout === "function") {
    \\      globalThis.setTimeout(function() {
    \\        signalAbort(s, { name: "TimeoutError", message: "The operation timed out." });
    \\      }, ms);
    \\    }
    \\    return s;
    \\  };
    \\  AbortSignal.any = function(signals) {
    \\    var s = new AbortSignal();
    \\    var arr = [];
    \\    if (signals && typeof signals[Symbol.iterator] === "function") {
    \\      for (var it = signals[Symbol.iterator](), step = it.next(); !step.done; step = it.next()) arr.push(step.value);
    \\    }
    \\    for (var i = 0; i < arr.length; i++) {
    \\      var input = arr[i];
    \\      if (input && input.aborted) { signalAbort(s, input.reason); return s; }
    \\    }
    \\    arr.forEach(function(input) {
    \\      if (input && typeof input.addEventListener === "function") {
    \\        input.addEventListener("abort", function() { signalAbort(s, input.reason); }, { once: true });
    \\      }
    \\    });
    \\    return s;
    \\  };
    \\
    \\  function AbortController() {
    \\    this.signal = new AbortSignal();
    \\  }
    \\  AbortController.prototype.abort = function(reason) {
    \\    var r = reason !== undefined ? reason : { name: "AbortError", message: "The operation was aborted." };
    \\    signalAbort(this.signal, r);
    \\  };
    \\
    \\  globalThis.Event = Event;
    \\
    \\  // ---- DOMException (legacy-code mapped, Error-derived) ----
    \\  var DOM_CODES = {
    \\    IndexSizeError: 1,
    \\    HierarchyRequestError: 3,
    \\    WrongDocumentError: 4,
    \\    InvalidCharacterError: 5,
    \\    NoModificationAllowedError: 7,
    \\    NotFoundError: 8,
    \\    NotSupportedError: 9,
    \\    InUseAttributeError: 10,
    \\    InvalidStateError: 11,
    \\    SyntaxError: 12,
    \\    InvalidModificationError: 13,
    \\    NamespaceError: 14,
    \\    InvalidAccessError: 15,
    \\    SecurityError: 18,
    \\    NetworkError: 19,
    \\    AbortError: 20,
    \\    URLMismatchError: 21,
    \\    QuotaExceededError: 22,
    \\    TimeoutError: 23,
    \\    InvalidNodeTypeError: 24,
    \\    DataCloneError: 25
    \\  };
    \\  function DOMException(message, name) {
    \\    var msg = message === undefined ? "" : String(message);
    \\    var nm = name === undefined ? "Error" : String(name);
    \\    var err = new Error(msg);
    \\    Object.setPrototypeOf(err, DOMException.prototype);
    \\    Object.defineProperty(err, "name", { value: nm, writable: true, enumerable: false, configurable: true });
    \\    Object.defineProperty(err, "message", { value: msg, writable: true, enumerable: false, configurable: true });
    \\    Object.defineProperty(err, "code", { value: DOM_CODES[nm] || 0, writable: false, enumerable: false, configurable: true });
    \\    return err;
    \\  }
    \\  DOMException.prototype = Object.create(Error.prototype);
    \\  Object.defineProperty(DOMException.prototype, "constructor", { value: DOMException, writable: true, enumerable: false, configurable: true });
    \\  Object.defineProperty(DOMException.prototype, "name", { value: "Error", writable: true, enumerable: false, configurable: true });
    \\  Object.defineProperty(DOMException.prototype, "message", { value: "", writable: true, enumerable: false, configurable: true });
    \\  Object.defineProperty(DOMException.prototype, "code", { value: 0, writable: true, enumerable: false, configurable: true });
    \\  (function() {
    \\    var CONSTS = {
    \\      INDEX_SIZE_ERR: 1,
    \\      DOMSTRING_SIZE_ERR: 2,
    \\      HIERARCHY_REQUEST_ERR: 3,
    \\      WRONG_DOCUMENT_ERR: 4,
    \\      INVALID_CHARACTER_ERR: 5,
    \\      NO_DATA_ALLOWED_ERR: 6,
    \\      NO_MODIFICATION_ALLOWED_ERR: 7,
    \\      NOT_FOUND_ERR: 8,
    \\      NOT_SUPPORTED_ERR: 9,
    \\      INUSE_ATTRIBUTE_ERR: 10,
    \\      INVALID_STATE_ERR: 11,
    \\      SYNTAX_ERR: 12,
    \\      INVALID_MODIFICATION_ERR: 13,
    \\      NAMESPACE_ERR: 14,
    \\      INVALID_ACCESS_ERR: 15,
    \\      VALIDATION_ERR: 16,
    \\      TYPE_MISMATCH_ERR: 17,
    \\      SECURITY_ERR: 18,
    \\      NETWORK_ERR: 19,
    \\      ABORT_ERR: 20,
    \\      URL_MISMATCH_ERR: 21,
    \\      QUOTA_EXCEEDED_ERR: 22,
    \\      TIMEOUT_ERR: 23,
    \\      INVALID_NODE_TYPE_ERR: 24,
    \\      DATA_CLONE_ERR: 25
    \\    };
    \\    var keys = Object.keys(CONSTS);
    \\    for (var i = 0; i < keys.length; i++) {
    \\      var k = keys[i];
    \\      Object.defineProperty(DOMException, k, { value: CONSTS[k], writable: false, enumerable: true, configurable: false });
    \\      Object.defineProperty(DOMException.prototype, k, { value: CONSTS[k], writable: false, enumerable: false, configurable: false });
    \\    }
    \\  })();
    \\  globalThis.DOMException = DOMException;
    \\
    \\  // ---- Retrofit AbortSignal/AbortController to produce DOMException reasons ----
    \\  AbortSignal.abort = function(reason) {
    \\    var s = new AbortSignal();
    \\    s.aborted = true;
    \\    s.reason = reason !== undefined ? reason : new DOMException("signal is aborted without reason", "AbortError");
    \\    return s;
    \\  };
    \\  AbortSignal.timeout = function(ms) {
    \\    var s = new AbortSignal();
    \\    if (typeof globalThis.setTimeout === "function") {
    \\      globalThis.setTimeout(function() {
    \\        signalAbort(s, new DOMException("The operation timed out.", "TimeoutError"));
    \\      }, ms);
    \\    }
    \\    return s;
    \\  };
    \\  AbortController.prototype.abort = function(reason) {
    \\    var r = reason !== undefined ? reason : new DOMException("The operation was aborted.", "AbortError");
    \\    signalAbort(this.signal, r);
    \\  };
    \\
    \\  // ---- MessageChannel / MessagePort (pure JS, microtask delivery) ----
    \\  function MessagePort() {
    \\    EventTarget.call(this);
    \\    this._onmessage = null;
    \\    this._other = null;
    \\    this._started = false;
    \\    this._closed = false;
    \\    this._pending = [];
    \\  }
    \\  MessagePort.prototype = Object.create(EventTarget.prototype);
    \\  MessagePort.prototype.constructor = MessagePort;
    \\  Object.defineProperty(MessagePort.prototype, "onmessage", {
    \\    get: function() { return this._onmessage; },
    \\    set: function(v) { this._onmessage = (typeof v === "function") ? v : null; this.start(); },
    \\    enumerable: true,
    \\    configurable: true
    \\  });
    \\  function messagePortDeliver(port, data) {
    \\    if (port._closed) return;
    \\    var ev = new MessageEvent("message", { data: data });
    \\    if (typeof port._onmessage === "function") {
    \\      try { port._onmessage.call(port, ev); } catch (e) { void e; }
    \\    }
    \\    port.dispatchEvent(ev);
    \\  }
    \\  MessagePort.prototype.postMessage = function(data) {
    \\    var other = this._other;
    \\    if (!other || other._closed) return;
    \\    queueMicrotask(function() {
    \\      if (other._closed) return;
    \\      if (!other._started) { other._pending.push(data); return; }
    \\      messagePortDeliver(other, data);
    \\    });
    \\  };
    \\  MessagePort.prototype.start = function() {
    \\    if (this._started) return;
    \\    this._started = true;
    \\    var self = this;
    \\    var queued = this._pending;
    \\    this._pending = [];
    \\    queued.forEach(function(data) {
    \\      queueMicrotask(function() { messagePortDeliver(self, data); });
    \\    });
    \\  };
    \\  MessagePort.prototype.close = function() { this._closed = true; };
    \\  MessagePort.prototype.addEventListener = function(type, listener, opts) {
    \\    EventTarget.prototype.addEventListener.call(this, type, listener, opts);
    \\    if (String(type) === "message") this.start();
    \\  };
    \\  function MessageChannel() {
    \\    var p1 = new MessagePort();
    \\    var p2 = new MessagePort();
    \\    p1._other = p2;
    \\    p2._other = p1;
    \\    this.port1 = p1;
    \\    this.port2 = p2;
    \\  }
    \\  globalThis.MessagePort = MessagePort;
    \\  globalThis.MessageChannel = MessageChannel;
    \\  globalThis.CustomEvent = CustomEvent;
    \\  globalThis.MessageEvent = MessageEvent;
    \\  globalThis.CloseEvent = CloseEvent;
    \\  globalThis.ErrorEvent = ErrorEvent;
    \\  globalThis.ProgressEvent = ProgressEvent;
    \\  globalThis.EventTarget = EventTarget;
    \\  globalThis.AbortSignal = AbortSignal;
    \\  globalThis.AbortController = AbortController;
    \\  // globalThis is itself an EventTarget (Bun dispatches 'error',
    \\  // 'unhandledrejection', etc. here). Back it with a hidden EventTarget and
    \\  // delegate the three methods, binding `this` so the event target is global.
    \\  if (typeof globalThis.addEventListener !== "function") {
    \\    var __globalET = new EventTarget();
    \\    globalThis.addEventListener = function(type, listener, opts) { return EventTarget.prototype.addEventListener.call(__globalET, type, listener, opts); };
    \\    globalThis.removeEventListener = function(type, listener) { return EventTarget.prototype.removeEventListener.call(__globalET, type, listener); };
    \\    globalThis.dispatchEvent = function(event) { return EventTarget.prototype.dispatchEvent.call(__globalET, event); };
    \\  }
    \\})();
;

/// Install the minimal Web Platform globals into `ctx`'s realm. No-op when
/// JSC is not linked.
pub fn install(allocator: std.mem.Allocator, ctx: *JSContextRef, global: *JSGlobalObject) void {
    if (comptime !build_options.enable_jsc) return;

    callback.registerCallback(ctx, global, "__home_text_encode", textEncodeNative);
    callback.registerCallback(ctx, global, "__home_text_decode", textDecodeNative);

    const result = evaluate.evaluateUtf8Detailed(allocator, ctx, install_glue, "home:web-globals-install", 1) catch return;
    result.deinit(allocator);
}

fn evalBool(allocator: std.mem.Allocator, ctx: *JSContextRef, source: []const u8) !bool {
    const value = (try evaluate.evaluateUtf8(allocator, ctx, source, "home:web-globals-probe", 1, null)) orelse
        return error.JSEvaluateReturnedNull;
    return extern_fns.JSValueToBoolean(ctx, value);
}

test "web globals install exposes the expected surface" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();

    const ctx = engine.currentContext();
    install(std.testing.allocator, ctx, engine.currentGlobalObject());

    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "typeof queueMicrotask === 'function' && typeof btoa === 'function' && typeof atob === 'function' && " ++
        "typeof TextEncoder === 'function' && typeof TextDecoder === 'function' && " ++
        "typeof globalThis.__home_text_encode === 'undefined'"));
}

test "globalThis is an EventTarget (add/remove/dispatchEvent)" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();

    const ctx = engine.currentContext();
    install(std.testing.allocator, ctx, engine.currentGlobalObject());

    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "(function() {" ++
        "  if (typeof addEventListener !== 'function' || typeof dispatchEvent !== 'function') return false;" ++
        "  var hits = 0; var saw = null;" ++
        "  function on(e) { hits++; saw = e; }" ++
        "  addEventListener('ping', on);" ++
        "  var ev = new Event('ping');" ++
        "  if (dispatchEvent(ev) !== true) return false;" ++
        "  if (hits !== 1 || saw !== ev) return false;" ++
        "  removeEventListener('ping', on);" ++
        "  dispatchEvent(new Event('ping'));" ++
        "  if (hits !== 1) return false;" ++ // listener removed
        "  var n = 0; addEventListener('once', function() { n++; }, { once: true });" ++
        "  dispatchEvent(new Event('once')); dispatchEvent(new Event('once'));" ++
        "  return n === 1;" ++
        "})()"));
}

test "Event subclasses (Message/Close/Error/Progress) carry their init fields" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();

    const ctx = engine.currentContext();
    install(std.testing.allocator, ctx, engine.currentGlobalObject());

    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "(function() {" ++
        "  var me = new MessageEvent('message', { data: { x: 1 }, origin: 'o', lastEventId: '7' });" ++
        "  if (!(me instanceof Event) || me.type !== 'message' || me.data.x !== 1 || me.origin !== 'o' || me.lastEventId !== '7') return false;" ++
        "  var ce = new CloseEvent('close', { wasClean: true, code: 1000, reason: 'bye' });" ++
        "  if (!(ce instanceof Event) || ce.wasClean !== true || ce.code !== 1000 || ce.reason !== 'bye') return false;" ++
        "  var ee = new ErrorEvent('error', { message: 'boom', filename: 'a.js', lineno: 3, colno: 4 });" ++
        "  if (!(ee instanceof Event) || ee.message !== 'boom' || ee.filename !== 'a.js' || ee.lineno !== 3 || ee.colno !== 4) return false;" ++
        "  var pe = new ProgressEvent('progress', { lengthComputable: true, loaded: 5, total: 10 });" ++
        "  if (!(pe instanceof Event) || pe.lengthComputable !== true || pe.loaded !== 5 || pe.total !== 10) return false;" ++
        "  return new MessageEvent('m').data === null && new CloseEvent('c').code === 0;" ++
        "})()"));
}

test "TextEncoder/TextDecoder round-trip UTF-8 including multibyte" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();

    const ctx = engine.currentContext();
    install(std.testing.allocator, ctx, engine.currentGlobalObject());

    // ASCII byte length, a known UTF-8 multibyte length, and a full round-trip.
    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "(function() {" ++
        "  var enc = new TextEncoder();" ++
        "  var a = enc.encode('abc');" ++
        "  if (!(a instanceof Uint8Array) || a.length !== 3 || a[0] !== 97) return false;" ++
        "  var e = enc.encode('héllo');" ++ // é = 2 UTF-8 bytes -> length 6
        "  if (e.length !== 6) return false;" ++
        "  var dec = new TextDecoder();" ++
        "  return dec.decode(enc.encode('round → trip ✓')) === 'round → trip ✓';" ++
        "})()"));
}

test "btoa/atob round-trip and match known vectors" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();

    const ctx = engine.currentContext();
    install(std.testing.allocator, ctx, engine.currentGlobalObject());

    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "btoa('hello') === 'aGVsbG8=' && btoa('Man') === 'TWFu' && btoa('Ma') === 'TWE=' && " ++
        "atob('aGVsbG8=') === 'hello' && atob(btoa('any carnal pleasure.')) === 'any carnal pleasure.'"));
}

test "queueMicrotask runs the callback after the current job" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();

    const ctx = engine.currentContext();
    install(std.testing.allocator, ctx, engine.currentGlobalObject());

    _ = try evaluate.evaluateUtf8(std.testing.allocator, ctx, "globalThis.__q = 0; queueMicrotask(function() { globalThis.__q = 1; });", "home:qmt-setup", 1, null);
    try std.testing.expect(try evalBool(std.testing.allocator, ctx, "globalThis.__q === 1"));
}

test "web streams surface is installed" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();

    const ctx = engine.currentContext();
    install(std.testing.allocator, ctx, engine.currentGlobalObject());

    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "typeof ReadableStream === 'function' && typeof WritableStream === 'function' && " ++
        "typeof TransformStream === 'function' && typeof CountQueuingStrategy === 'function' && " ++
        "typeof ByteLengthQueuingStrategy === 'function' && typeof ReadableStream.from === 'function'"));
}

test "ReadableStream getReader().read() collects enqueued chunks then done" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();

    const ctx = engine.currentContext();
    install(std.testing.allocator, ctx, engine.currentGlobalObject());

    _ = try evaluate.evaluateUtf8(std.testing.allocator, ctx,
        "globalThis.__rs_a = '';(function(){var rs = new ReadableStream({start: function(c){c.enqueue('x');c.enqueue('y');c.enqueue('z');c.close();}});var reader = rs.getReader();var out = [];function loop(){return reader.read().then(function(r){if (r.done){globalThis.__rs_a = out.join(',');return;}out.push(r.value);return loop();});}loop();})();",
        "home:rs-read-setup", 1, null);
    try std.testing.expect(try evalBool(std.testing.allocator, ctx, "globalThis.__rs_a === 'x,y,z'"));
}

test "ReadableStream supports for-await async iteration" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();

    const ctx = engine.currentContext();
    install(std.testing.allocator, ctx, engine.currentGlobalObject());

    _ = try evaluate.evaluateUtf8(std.testing.allocator, ctx,
        "globalThis.__rs_b = '';(function(){var rs = new ReadableStream({start: function(c){c.enqueue(1);c.enqueue(2);c.enqueue(3);c.close();}});(async function(){var out = [];for await (var ch of rs) out.push(ch);globalThis.__rs_b = out.join('-');})();})();",
        "home:rs-foreach-setup", 1, null);
    try std.testing.expect(try evalBool(std.testing.allocator, ctx, "globalThis.__rs_b === '1-2-3'"));
}

test "ReadableStream.from collects a sync iterable" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();

    const ctx = engine.currentContext();
    install(std.testing.allocator, ctx, engine.currentGlobalObject());

    _ = try evaluate.evaluateUtf8(std.testing.allocator, ctx,
        "globalThis.__rs_c = '';(function(){var rs = ReadableStream.from(['a','b']);var reader = rs.getReader();var out = [];function loop(){return reader.read().then(function(r){if (r.done){globalThis.__rs_c = out.join('');return;}out.push(r.value);return loop();});}loop();})();",
        "home:rs-from-setup", 1, null);
    try std.testing.expect(try evalBool(std.testing.allocator, ctx, "globalThis.__rs_c === 'ab'"));
}

test "WritableStream collects writes then close fires" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();

    const ctx = engine.currentContext();
    install(std.testing.allocator, ctx, engine.currentGlobalObject());

    _ = try evaluate.evaluateUtf8(std.testing.allocator, ctx,
        "globalThis.__rs_d = '';(function(){var written = [];var closed = false;var ws = new WritableStream({write: function(ch){written.push(ch);},close: function(){closed = true;}});var w = ws.getWriter();w.write('a');w.write('b');w.write('c');w.close().then(function(){globalThis.__rs_d = written.join('') + ':' + (closed ? 'closed' : 'open');});})();",
        "home:ws-write-setup", 1, null);
    try std.testing.expect(try evalBool(std.testing.allocator, ctx, "globalThis.__rs_d === 'abc:closed'"));
}

test "TransformStream uppercases via pipeThrough" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();

    const ctx = engine.currentContext();
    install(std.testing.allocator, ctx, engine.currentGlobalObject());

    _ = try evaluate.evaluateUtf8(std.testing.allocator, ctx,
        "globalThis.__rs_e = '';(function(){var ts = new TransformStream({transform: function(ch, c){c.enqueue(ch.toUpperCase());}});var source = new ReadableStream({start: function(c){c.enqueue('foo');c.enqueue('bar');c.close();}});var out = source.pipeThrough(ts);(async function(){var collected = [];for await (var ch of out) collected.push(ch);globalThis.__rs_e = collected.join(',');})();})();",
        "home:ts-pipethrough-setup", 1, null);
    try std.testing.expect(try evalBool(std.testing.allocator, ctx, "globalThis.__rs_e === 'FOO,BAR'"));
}

test "ReadableStream.tee yields two independent readers of the same data" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();

    const ctx = engine.currentContext();
    install(std.testing.allocator, ctx, engine.currentGlobalObject());

    _ = try evaluate.evaluateUtf8(std.testing.allocator, ctx,
        "globalThis.__rs_f = '';(function(){var rs = new ReadableStream({start: function(c){c.enqueue('m');c.enqueue('n');c.close();}});var b = rs.tee();var r1 = b[0].getReader(), r2 = b[1].getReader();var o1 = [], o2 = [];var d1 = false, d2 = false;function fin(){if (d1 && d2) globalThis.__rs_f = o1.join('') + '|' + o2.join('');}function loop(reader, out, done){return reader.read().then(function(r){if (r.done){done();return;}out.push(r.value);return loop(reader, out, done);});}loop(r1, o1, function(){d1 = true; fin();});loop(r2, o2, function(){d2 = true; fin();});})();",
        "home:rs-tee-setup", 1, null);
    try std.testing.expect(try evalBool(std.testing.allocator, ctx, "globalThis.__rs_f === 'mn|mn'"));
}

test "CountQueuingStrategy and ByteLengthQueuingStrategy report size and highWaterMark" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();

    const ctx = engine.currentContext();
    install(std.testing.allocator, ctx, engine.currentGlobalObject());

    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "(function(){" ++
        "  var cqs = new CountQueuingStrategy({ highWaterMark: 5 });" ++
        "  if (cqs.highWaterMark !== 5 || cqs.size('anything') !== 1) return false;" ++
        "  var bqs = new ByteLengthQueuingStrategy({ highWaterMark: 16 });" ++
        "  return bqs.highWaterMark === 16 && bqs.size(new Uint8Array(4)) === 4;" ++
        "})()"));
}

test "TextEncoderStream pipes string chunks to UTF-8 bytes" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();

    const ctx = engine.currentContext();
    install(std.testing.allocator, ctx, engine.currentGlobalObject());

    _ = try evaluate.evaluateUtf8(std.testing.allocator, ctx,
        "globalThis.__es_a = '';(function(){var tes = new TextEncoderStream();var w = tes.writable.getWriter();var reader = tes.readable.getReader();var chunks = [];function loop(){return reader.read().then(function(r){if (r.done){var total=0;for(var i=0;i<chunks.length;i++)total+=chunks[i].length;var all=new Uint8Array(total);var off=0;for(var j=0;j<chunks.length;j++){all.set(chunks[j],off);off+=chunks[j].length;}globalThis.__es_a = new TextDecoder().decode(all);return;}chunks.push(r.value);return loop();});}loop();w.write('hé');w.write('llo ✓');w.close();})();",
        "home:es-encstream-setup", 1, null);
    try std.testing.expect(try evalBool(std.testing.allocator, ctx, "globalThis.__es_a === 'héllo ✓'"));
}

test "TextDecoderStream buffers a multibyte sequence split across chunks" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();

    const ctx = engine.currentContext();
    install(std.testing.allocator, ctx, engine.currentGlobalObject());

    // "✓" = U+2713 = bytes E2 9C 93, written as [E2,9C] then [93].
    _ = try evaluate.evaluateUtf8(std.testing.allocator, ctx,
        "globalThis.__es_b = '';(function(){var tds = new TextDecoderStream();var w = tds.writable.getWriter();var reader = tds.readable.getReader();var out = [];function loop(){return reader.read().then(function(r){if (r.done){globalThis.__es_b = out.join('');return;}out.push(r.value);return loop();});}loop();w.write(new Uint8Array([0xE2,0x9C]));w.write(new Uint8Array([0x93]));w.close();})();",
        "home:es-decstream-setup", 1, null);
    try std.testing.expect(try evalBool(std.testing.allocator, ctx, "globalThis.__es_b === '✓'"));
}

test "CompressionStream then DecompressionStream round-trips gzip" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();

    const ctx = engine.currentContext();
    const global = engine.currentGlobalObject();
    install(std.testing.allocator, ctx, global);
    @import("node_modules.zig").installZlibOnly(std.testing.allocator, ctx, global);

    _ = try evaluate.evaluateUtf8(std.testing.allocator, ctx,
        "globalThis.__es_c = '';(function(){var input='hello hello hello';var src=new ReadableStream({start:function(c){c.enqueue(new TextEncoder().encode(input));c.close();}});var out=src.pipeThrough(new CompressionStream('gzip')).pipeThrough(new DecompressionStream('gzip'));var reader=out.getReader();var chunks=[];function loop(){return reader.read().then(function(r){if (r.done){var total=0;for(var i=0;i<chunks.length;i++)total+=chunks[i].length;var all=new Uint8Array(total);var off=0;for(var j=0;j<chunks.length;j++){all.set(chunks[j],off);off+=chunks[j].length;}globalThis.__es_c=new TextDecoder().decode(all);return;}chunks.push(r.value);return loop();});}loop();})();",
        "home:es-gzip-setup", 1, null);
    try std.testing.expect(try evalBool(std.testing.allocator, ctx, "globalThis.__es_c === 'hello hello hello'"));
}

test "EventTarget addEventListener/dispatchEvent fires with event.type, once removes, removeEventListener works" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();

    const ctx = engine.currentContext();
    install(std.testing.allocator, ctx, engine.currentGlobalObject());

    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "(function(){" ++
        "  var et = new EventTarget();" ++
        "  var seen = [];" ++
        "  var onceCount = 0;" ++
        "  var typed = null;" ++
        "  function regular(e){ seen.push(e.type); typed = e.type; }" ++
        "  function onceCb(){ onceCount++; }" ++
        "  et.addEventListener('ping', regular);" ++
        "  et.addEventListener('ping', onceCb, { once: true });" ++
        "  et.dispatchEvent(new Event('ping'));" ++
        "  et.dispatchEvent(new Event('ping'));" ++
        "  if (onceCount !== 1) return false;" ++
        "  if (typed !== 'ping' || seen.length !== 2) return false;" ++
        "  et.removeEventListener('ping', regular);" ++
        "  et.dispatchEvent(new Event('ping'));" ++
        "  if (seen.length !== 2) return false;" ++
        "  var handlerObj = { calls: 0, handleEvent: function(){ this.calls++; } };" ++
        "  et.addEventListener('obj', handlerObj);" ++
        "  et.dispatchEvent(new Event('obj'));" ++
        "  return handlerObj.calls === 1;" ++
        "})()"));
}

test "CustomEvent carries detail and extends Event" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();

    const ctx = engine.currentContext();
    install(std.testing.allocator, ctx, engine.currentGlobalObject());

    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "(function(){" ++
        "  var ce = new CustomEvent('thing', { detail: { n: 42 } });" ++
        "  if (!(ce instanceof Event)) return false;" ++
        "  if (ce.type !== 'thing') return false;" ++
        "  if (!ce.detail || ce.detail.n !== 42) return false;" ++
        "  var plain = new CustomEvent('empty');" ++
        "  return plain.detail === null;" ++
        "})()"));
}

test "AbortController.abort sets aborted+reason, fires 'abort' listener, throwIfAborted throws" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();

    const ctx = engine.currentContext();
    install(std.testing.allocator, ctx, engine.currentGlobalObject());

    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "(function(){" ++
        "  var ac = new AbortController();" ++
        "  var sig = ac.signal;" ++
        "  if (sig.aborted !== false) return false;" ++
        "  var fired = 0;" ++
        "  sig.addEventListener('abort', function(e){ if (e.type === 'abort') fired++; });" ++
        "  ac.abort('boom');" ++
        "  if (!sig.aborted || sig.reason !== 'boom' || fired !== 1) return false;" ++
        "  ac.abort('again');" ++
        "  if (fired !== 1) return false;" ++
        "  var threw = false;" ++
        "  try { sig.throwIfAborted(); } catch (e) { threw = (e === 'boom'); }" ++
        "  return threw;" ++
        "})()"));
}

test "AbortSignal.abort returns an already-aborted signal" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();

    const ctx = engine.currentContext();
    install(std.testing.allocator, ctx, engine.currentGlobalObject());

    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "(function(){" ++
        "  var s = AbortSignal.abort('x');" ++
        "  if (s.aborted !== true || s.reason !== 'x') return false;" ++
        "  var d = AbortSignal.abort();" ++
        "  return d.aborted === true && !!d.reason && d.reason.name === 'AbortError';" ++
        "})()"));
}

test "AbortSignal.any aborts when an input is already aborted" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();

    const ctx = engine.currentContext();
    install(std.testing.allocator, ctx, engine.currentGlobalObject());

    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "(function(){" ++
        "  var combined = AbortSignal.any([AbortSignal.abort('pre')]);" ++
        "  if (combined.aborted !== true || combined.reason !== 'pre') return false;" ++
        "  var ac = new AbortController();" ++
        "  var any2 = AbortSignal.any([ac.signal]);" ++
        "  if (any2.aborted !== false) return false;" ++
        "  ac.abort('later');" ++
        "  return any2.aborted === true && any2.reason === 'later';" ++
        "})()"));
}

test "AbortSignal.timeout aborts after the timer fires (drained via timers_global)" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();

    const ctx = engine.currentContext();
    const global = engine.currentGlobalObject();
    install(std.testing.allocator, ctx, global);
    @import("timers_global.zig").install(std.testing.allocator, ctx, global);

    _ = try evaluate.evaluateUtf8(std.testing.allocator, ctx,
        "globalThis.__abrt = '';" ++
        "(function(){" ++
        "  var s = AbortSignal.timeout(1);" ++
        "  s.addEventListener('abort', function(){ globalThis.__abrt = s.aborted && s.reason && s.reason.name === 'TimeoutError' ? 'timeout' : 'wrong'; });" ++
        "})();",
        "home:abort-timeout-setup", 1, null);

    // Not aborted yet: the timer is pending until the loop is pumped.
    try std.testing.expect(try evalBool(std.testing.allocator, ctx, "globalThis.__abrt === ''"));

    @import("timers_global.zig").drain(ctx);

    try std.testing.expect(try evalBool(std.testing.allocator, ctx, "globalThis.__abrt === 'timeout'"));
}

test "DOMException is Error-derived with legacy name->code mapping and static constants" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();

    const ctx = engine.currentContext();
    install(std.testing.allocator, ctx, engine.currentGlobalObject());

    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "(function(){" ++
        "  var e = new DOMException('x', 'AbortError');" ++
        "  if (!(e instanceof Error)) return false;" ++
        "  if (!(e instanceof DOMException)) return false;" ++
        "  if (e.name !== 'AbortError' || e.message !== 'x' || e.code !== 20) return false;" ++
        "  if (typeof e.stack !== 'string') return false;" ++
        "  var d = new DOMException();" ++
        "  if (d.name !== 'Error' || d.message !== '' || d.code !== 0) return false;" ++
        "  var nf = new DOMException('m', 'NotFoundError');" ++
        "  if (nf.code !== 8) return false;" ++
        "  var ns = new DOMException('m', 'NotSupportedError');" ++
        "  if (ns.code !== 9) return false;" ++
        "  var dc = new DOMException('m', 'DataCloneError');" ++
        "  if (dc.code !== 25) return false;" ++
        "  var sx = new DOMException('m', 'SyntaxError');" ++
        "  if (sx.code !== 12) return false;" ++
        "  var to = new DOMException('m', 'TimeoutError');" ++
        "  if (to.code !== 23) return false;" ++
        "  var unk = new DOMException('m', 'TotallyMadeUpError');" ++
        "  if (unk.code !== 0) return false;" ++
        "  return DOMException.ABORT_ERR === 20 && DOMException.TIMEOUT_ERR === 23 && " ++
        "    DOMException.NOT_FOUND_ERR === 8 && DOMException.DATA_CLONE_ERR === 25;" ++
        "})()"));
}

test "AbortController.abort default reason is a DOMException named AbortError" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();

    const ctx = engine.currentContext();
    install(std.testing.allocator, ctx, engine.currentGlobalObject());

    try std.testing.expect(try evalBool(std.testing.allocator, ctx,
        "(function(){" ++
        "  var ac = new AbortController();" ++
        "  ac.abort();" ++
        "  var r = ac.signal.reason;" ++
        "  if (!(r instanceof DOMException) || !(r instanceof Error)) return false;" ++
        "  if (r.name !== 'AbortError' || r.code !== 20) return false;" ++
        "  var d = AbortSignal.abort();" ++
        "  return d.reason instanceof DOMException && d.reason.name === 'AbortError' && d.reason.code === 20;" ++
        "})()"));
}

test "MessageChannel port1.postMessage delivers to port2.onmessage on a microtask" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();

    const ctx = engine.currentContext();
    install(std.testing.allocator, ctx, engine.currentGlobalObject());

    _ = try evaluate.evaluateUtf8(std.testing.allocator, ctx,
        "globalThis.__mc = '';globalThis.__mcEv = false;(function(){var mc = new MessageChannel();var got = [];mc.port2.onmessage = function(e){ globalThis.__mcEv = (e instanceof MessageEvent); got.push('2:' + e.data); };mc.port1.onmessage = function(e){ got.push('1:' + e.data); };mc.port1.postMessage('ping');mc.port2.postMessage('pong');queueMicrotask(function(){ queueMicrotask(function(){ globalThis.__mc = got.join(','); }); });})();",
        "home:mc-setup", 1, null);
    try std.testing.expect(try evalBool(std.testing.allocator, ctx, "globalThis.__mc === '2:ping,1:pong' && globalThis.__mcEv === true"));
}

test "MessagePort addEventListener('message') receives postMessage from the paired port" {
    if (!build_options.enable_jsc) return error.SkipZigTest;

    const Engine = @import("engine.zig").Engine;
    var engine = try Engine.init(std.testing.allocator);
    defer engine.deinit();

    const ctx = engine.currentContext();
    install(std.testing.allocator, ctx, engine.currentGlobalObject());

    _ = try evaluate.evaluateUtf8(std.testing.allocator, ctx,
        "globalThis.__mc2 = '';(function(){var mc = new MessageChannel();mc.port2.addEventListener('message', function(e){ globalThis.__mc2 = String(e.data); });mc.port1.postMessage('hello');})();",
        "home:mc2-setup", 1, null);
    try std.testing.expect(try evalBool(std.testing.allocator, ctx, "globalThis.__mc2 === 'hello'"));
}
