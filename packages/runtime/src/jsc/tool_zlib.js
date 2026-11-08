// Real RFC 1952 bytes over the owned native compressor and managed streams.
globalThis.__home_tool_zlib_factory = function(nativeGzip, Buffer, Transform) {
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
  function bytes(input) {
    if (typeof input !== 'string' && !(input instanceof Uint8Array))
      fail('ERR_INVALID_ARG_TYPE', 'Gzip input must be a string, Buffer or Uint8Array', TypeError);
    return Buffer.from(input);
  }
  function operation(mode, input, options) {
    optionsFor(options, false);
    const limit = mode === 0 ? maxBytes : maxBytes + maxBytes / 8 + 1024;
    if ((typeof input === 'string' || input instanceof Uint8Array) && input.length > limit)
      fail('ERR_BUFFER_TOO_LARGE', 'Home gzip input exceeds its bounded profile', RangeError);
    const value = bytes(input);
    const result = nativeGzip(mode, value);
    if (typeof result === 'string')
      fail(result, 'Home gzip operation failed');
    if (!(result instanceof Uint8Array))
      fail('ERR_HOME_COMPRESSION', 'Native gzip did not return bytes');
    return Buffer.from(result);
  }
  function gzipSync(input, options) {
    return operation(0, input, options);
  }
  function gunzipSync(input, options) {
    return operation(1, input, options);
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
  return { gzipSync, gunzipSync, Gzip, createGzip };
};
