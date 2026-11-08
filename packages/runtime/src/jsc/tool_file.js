// A readonly filesystem-backed profile; this does not impersonate a Web Blob.
globalThis.__home_tool_file_factory = function(fsOperation, Buffer, decodeUtf8Hex) {
  'use strict';
  const files = new WeakMap();
  const maxBytes = 8 * 1024 * 1024;
  const Bytes = Uint8Array;
  const fromHex = Buffer.from.bind(Buffer);
  function fail(code, message, Type) {
    const error = new (Type || Error)(message);
    error.code = code;
    throw error;
  }
  function unsupported() {
    fail('ERR_HOME_UNSUPPORTED', 'Home file supports stable regular-file reads; Blob/MIME, slices, streams, writers and mutable-file caching require separate implementations');
  }
  function stateFor(file) {
    const state = files.get(file);
    if (!state) throw new TypeError('Invalid Home file receiver');
    return state;
  }
  function same(a, b) {
    if (a === null || b === null) return a === b;
    return a.kind === b.kind && a.ino === b.ino && a.size === b.size && a.mtimeMs === b.mtimeMs && a.ctimeMs === b.ctimeMs;
  }
  function inspect(state) {
    let metadata;
    try {
      metadata = fsOperation('stat', state.path, false, false);
    }
    catch (error) {
      if (error.code !== 'ENOENT') throw error;
      metadata = null;
    }
    // Native Bun caches size/existence and sometimes clips subsequent reads.
    // Refuse observed mutations instead of guessing at those cache semantics.
    if (state.observed && !same(state.metadata, metadata)) unsupported();
    state.observed = true;
    state.metadata = metadata;
    return metadata;
  }
  function read(file) {
    const state = stateFor(file);
    const metadata = inspect(state);
    if (metadata && metadata.kind !== 'file' && metadata.kind !== 'directory') unsupported();
    if (metadata && metadata.size > maxBytes)
      fail('ERR_BUFFER_TOO_LARGE', 'Home file reads are limited to 8 MiB', RangeError);
    let hex;
    try {
      // Missing paths/directories still perform the real OS read and preserve
      // its failure. No empty Buffer or successful missing-file read is made.
      hex = fsOperation('readToolFile', state.path, false, false).hex;
    }
    catch (error) {
      error.syscall = error.code === 'EISDIR' ? 'read' : 'open';
      throw error;
    }
    inspect(state);
    if (hex.length / 2 > maxBytes)
      fail('ERR_BUFFER_TOO_LARGE', 'Home file reads are limited to 8 MiB', RangeError);
    return hex;
  }
  function FileSource(path) {
    files.set(this, { path, observed: false, metadata: null });
  }
  FileSource.prototype.exists = async function() {
    const metadata = inspect(stateFor(this));
    return metadata !== null && metadata.kind === 'file';
  };
  function text(file) {
    // Decode the actual native bytes once. Text reads must not round-trip
    // through publicly mutable Buffer methods or rebuild their hex string.
    const value = decodeUtf8Hex(read(file));
    // Blob text decoding consumes one initial UTF-8 BOM. Node readFile keeps
    // it, so the shared Buffer decoder deliberately leaves this to the file.
    return value.charCodeAt(0) === 0xfeff ? value.slice(1) : value;
  }
  FileSource.prototype.text = async function() {
    return text(this);
  };
  FileSource.prototype.json = async function() {
    return JSON.parse(text(this));
  };
  FileSource.prototype.bytes = async function() {
    return new Bytes(fromHex(read(this), 'hex'));
  };
  FileSource.prototype.arrayBuffer = async function() {
    return new Bytes(fromHex(read(this), 'hex')).buffer;
  };
  Object.defineProperty(FileSource.prototype, 'size', { get: function() {
    const metadata = inspect(stateFor(this));
    return metadata === null ? 0 : metadata.size;
  } });
  Object.defineProperty(FileSource.prototype, 'lastModified', { get: function() {
    const metadata = inspect(stateFor(this));
    if (metadata === null) unsupported();
    return Math.trunc(metadata.mtimeMs);
  } });
  Object.defineProperty(FileSource.prototype, 'type', { get: unsupported });
  for (const name of ['slice', 'stream', 'writer', 'write', 'delete'])
    FileSource.prototype[name] = unsupported;
  return function file(path, options) {
    if (typeof path !== 'string') unsupported();
    if (path.indexOf('\0') !== -1) throw new TypeError('File paths cannot contain NUL bytes');
    if (options !== undefined) {
      if (options === null || typeof options !== 'object'
        || (Object.getPrototypeOf(options) !== Object.prototype && Object.getPrototypeOf(options) !== null)
        || Reflect.ownKeys(options).length) unsupported();
    }
    return new FileSource(path);
  };
};
