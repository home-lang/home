// Real RFC 1950/1951/1952 bytes over the owned native codecs and managed streams.
globalThis.__home_tool_zlib_factory = function(nativeGzip, Buffer, Transform, scheduleImmediate) {
  'use strict';
  const maxBytes = 2 * 1024 * 1024;
  function fail(code, message, Type) {
    const error = new (Type || Error)(message);
    error.code = code;
    throw error;
  }
  function optionsFor(options, stream) {
    if (options === undefined || options === null) return {};
    if (typeof options !== 'object')
      fail('ERR_INVALID_ARG_TYPE', 'Gzip options must be an object', TypeError);
    const prototype = Object.getPrototypeOf(options);
    if (prototype !== null && prototype !== Object.prototype)
      fail('ERR_HOME_UNSUPPORTED', 'Home gzip requires plain options');
    for (const key of Reflect.ownKeys(options)) {
      if (stream && key === 'highWaterMark') continue;
      fail('ERR_HOME_UNSUPPORTED', 'Home gzip supports default compression options and stream highWaterMark only');
    }
    const highWaterMark = stream ? options.highWaterMark : undefined;
    return highWaterMark !== undefined ? { highWaterMark } : {};
  }
  function bytes(input, label) {
    if (typeof input !== 'string' && !(input instanceof Uint8Array))
      fail('ERR_INVALID_ARG_TYPE', `${label} input must be a string, Buffer or Uint8Array`, TypeError);
    return Buffer.from(input);
  }
  function operation(mode, input, options, outputLimit) {
    optionsFor(options, false);
    const limit = mode === 0 || mode === 3 ? maxBytes : maxBytes + maxBytes / 8 + 1024;
    if ((typeof input === 'string' || input instanceof Uint8Array) && input.length > limit)
      fail('ERR_BUFFER_TOO_LARGE', `Home ${mode === 2 ? 'inflate' : mode === 3 ? 'deflateRaw' : 'gzip'} input exceeds its bounded profile`, RangeError);
    const value = bytes(input, mode === 2 ? 'Inflate' : 'Gzip');
    const result = mode === 2 ? nativeGzip(mode, value, outputLimit) : nativeGzip(mode, value);
    if (typeof result === 'string')
      fail(result, `Home ${mode === 2 ? 'inflate' : mode === 3 ? 'deflateRaw' : 'gzip'} operation failed`, result === 'ERR_BUFFER_TOO_LARGE' ? RangeError : undefined);
    if (!(result instanceof Uint8Array))
      fail('ERR_HOME_COMPRESSION', `Native ${mode === 2 ? 'inflate' : mode === 3 ? 'deflateRaw' : 'gzip'} did not return bytes`);
    return Buffer.from(result);
  }
  function gzipSync(input, options) {
    return operation(0, input, options);
  }
  function gunzipSync(input, options) {
    return operation(1, input, options);
  }
  function inflateSync(input, options) {
    let outputLimit = maxBytes;
    if (options !== undefined && options !== null) {
      if (typeof options !== 'object') fail('ERR_INVALID_ARG_TYPE', 'Inflate options must be an object', TypeError);
      const prototype = Object.getPrototypeOf(options);
      if (prototype !== null && prototype !== Object.prototype)
        fail('ERR_HOME_UNSUPPORTED', 'Home inflate requires plain options');
      for (const key of Reflect.ownKeys(options)) {
        if (key !== 'maxOutputLength') fail('ERR_HOME_UNSUPPORTED', 'Home inflate supports maxOutputLength only');
      }
      const requested = options.maxOutputLength;
      if (requested !== undefined && !Number.isNaN(requested)) {
        if (typeof requested !== 'number') fail('ERR_INVALID_ARG_TYPE', 'Inflate maxOutputLength must be a number', TypeError);
        if (!Number.isFinite(requested) || requested < 1 || requested > Number.MAX_SAFE_INTEGER)
          fail('ERR_OUT_OF_RANGE', 'Inflate maxOutputLength is out of range', RangeError);
        // The requested bound narrows native decoding. A larger ceiling never
        // lifts the host's independent 2 MiB codec profile or allocates it.
        outputLimit = Math.min(maxBytes, Math.floor(requested));
      }
    }
    if (input instanceof ArrayBuffer) input = new Uint8Array(input);
    else if (ArrayBuffer.isView(input) && !(input instanceof Uint8Array))
      input = new Uint8Array(input.buffer, input.byteOffset, input.byteLength);
    return operation(2, input, undefined, outputLimit);
  }
  function rawInput(input, options) {
    optionsFor(options, false);
    if (input instanceof ArrayBuffer) input = new Uint8Array(input);
    else if (ArrayBuffer.isView(input) && !(input instanceof Uint8Array))
      input = new Uint8Array(input.buffer, input.byteOffset, input.byteLength);
    if ((typeof input === 'string' || input instanceof Uint8Array) && input.length > maxBytes)
      fail('ERR_BUFFER_TOO_LARGE', 'Home deflateRaw input exceeds 2 MiB', RangeError);
    return bytes(input, 'DeflateRaw');
  }
  function deflateRawSync(input, options) {
    return operation(3, rawInput(input, options));
  }
  function deflateRaw(input, options, callback) {
    if (typeof options === 'function') { callback = options; options = undefined; }
    if (typeof callback !== 'function')
      fail('ERR_INVALID_ARG_TYPE', 'DeflateRaw callback must be a function', TypeError);
    const snapshot = rawInput(input, options);
    // A bounded native codec runs on the owner thread in a real immediate task.
    // Input is snapshotted now; no worker-pool or libuv completion-order claim.
    scheduleImmediate(() => {
      let output;
      try { output = operation(3, snapshot); }
      catch (error) { callback(error); return; }
      callback(null, output);
    });
  }
  function Gzip(options) {
    if (!this || !(this instanceof Gzip)) return new Gzip(options);
    const settings = optionsFor(options, true);
    let chunks = [];
    let length = 0;
    // This bounded transform accepts real input copies and compresses at final
    // acknowledgment. It promises no incremental output or flush boundary.
    // eslint-disable-next-line pickier/no-unused-vars
    settings.transform = function(chunk, encoding, callback) {
      if (length + chunk.length > maxBytes) {
        const error = new RangeError('Home gzip input exceeds 2 MiB');
        error.code = 'ERR_BUFFER_TOO_LARGE';
        callback(error);
        return;
      }
      chunks.push(Buffer.from(chunk));
      length += chunk.length;
      callback();
    };
    settings.flush = function(callback) {
      let output;
      try {
        const input = Buffer.concat(chunks, length);
        chunks = [];
        length = 0;
        output = gzipSync(input);
      }
      catch (error) {
        callback(error);
        return;
      }
      callback(null, output);
    };
    settings.destroy = function(error, callback) {
      chunks = [];
      length = 0;
      callback(error);
    };
    Transform.call(this, settings);
  }
  Object.setPrototypeOf(Gzip.prototype, Transform.prototype);
  Object.setPrototypeOf(Gzip, Transform);
  Gzip.prototype.flush = function() {
    fail('ERR_HOME_UNSUPPORTED', 'Home gzip emits compressed bytes on finalization; incremental flush is not implemented');
  };
  function createGzip(options) {
    return new Gzip(options);
  }
  return { gzipSync, gunzipSync, inflateSync, deflateRawSync, deflateRaw, Gzip, createGzip };
};
