// Incremental byte-to-string decoding for the repository-tool host. Buffer's
// real UTF-8/base64 codecs do the conversion; only incomplete suffixes are held.
globalThis.__home_tool_string_decoder_factory = function(Buffer) {
  'use strict';
  const states = new WeakMap();
  const isView = ArrayBuffer.isView;
  const typed = Object.getPrototypeOf(Uint8Array.prototype);
  const typedBuffer = Object.getOwnPropertyDescriptor(typed, 'buffer').get;
  const typedOffset = Object.getOwnPropertyDescriptor(typed, 'byteOffset').get;
  const typedLength = Object.getOwnPropertyDescriptor(typed, 'byteLength').get;
  const dataBuffer = Object.getOwnPropertyDescriptor(DataView.prototype, 'buffer').get;
  const dataOffset = Object.getOwnPropertyDescriptor(DataView.prototype, 'byteOffset').get;
  const dataLength = Object.getOwnPropertyDescriptor(DataView.prototype, 'byteLength').get;
  function fail(code, message) {
    const error = new TypeError(message);
    error.code = code;
    throw error;
  }
  function normalize(value) {
    if (value === undefined || value === null || value === '') return 'utf8';
    if (typeof value !== 'string') fail('ERR_UNKNOWN_ENCODING', 'Unknown StringDecoder encoding');
    const name = value.toLowerCase();
    if (name === 'utf8' || name === 'utf-8') return 'utf8';
    if (name === 'ucs2' || name === 'ucs-2' || name === 'utf16le' || name === 'utf-16le') return 'utf16le';
    if (name === 'binary' || name === 'latin1') return 'latin1';
    if (['base64', 'base64url', 'ascii', 'hex'].includes(name)) return name;
    fail('ERR_UNKNOWN_ENCODING', 'Unknown StringDecoder encoding');
  }
  function stateOf(receiver) {
    const state = states.get(receiver);
    if (!state) fail('ERR_INVALID_THIS', 'StringDecoder receiver required');
    return state;
  }
  function bytes(value) {
    if (!isView(value)) fail('ERR_INVALID_ARG_TYPE', 'StringDecoder requires a string, Buffer, TypedArray or DataView');
    try {
      return new Uint8Array(typedBuffer.call(value), typedOffset.call(value), typedLength.call(value));
    }
    catch {
      return new Uint8Array(dataBuffer.call(value), dataOffset.call(value), dataLength.call(value));
    }
  }
  function StringDecoder(encoding) {
    this.encoding = normalize(encoding);
    states.set(this, { encoding: this.encoding, need: 0, total: 0, last: Buffer.alloc(4) });
  }
  function convert(state, input, start, end) {
    const encoding = state.encoding;
    if (encoding === 'utf8' || encoding === 'base64' || encoding === 'base64url' || encoding === 'hex') return Buffer.from(input.subarray(start, end)).toString(encoding);
    let output = '';
    if (encoding === 'utf16le') {
      // Node's decoder preserves UTF-16 code units, including lone surrogates,
      // and drops a final unmatched byte. No UTF-8 round trip is involved.
      for (let i = start; i + 1 < end; i += 2) output += String.fromCharCode(input[i] | (input[i + 1] << 8));
    }
    else {
      const mask = encoding === 'ascii' ? 127 : 255;
      for (let i = start; i < end; ++i) output += String.fromCharCode(input[i] & mask);
    }
    return output;
  }
  function width(byte) {
    if (byte < 128) return 1;
    if ((byte & 224) === 192) return 2;
    if ((byte & 240) === 224) return 3;
    if ((byte & 248) === 240) return 4;
    return 0;
  }
  function clear(state) {
    state.need = 0;
    state.total = 0;
  }
  StringDecoder.prototype.write = function(input) {
    // Node passes a string through without flushing pending bytes.
    if (typeof input === 'string') return input;
    const view = bytes(input);
    const state = stateOf(this);
    if (!view.length) return '';
    let offset = 0, output = '';
    if (state.need) {
      let count = Math.min(state.need, view.length);
      if (state.encoding === 'utf8') {
        for (let i = 0; i < count; ++i) {
          if ((view[i] & 192) !== 128) {
            count = i;
            break;
          }
        }
      }
      const buffered = state.total - state.need;
      for (let i = 0; i < count; ++i) state.last[buffered + i] = view[i];
      state.need -= count;
      offset = count;
      if (state.need && count === view.length) return '';
      output = convert(state, state.last, 0, buffered + count);
      clear(state);
    }
    let end = view.length, total = 0;
    if (state.encoding === 'utf8') {
      // Hold a trailing lead plus continuation bytes, even an invalid scalar
      // prefix: Node delays its replacement bytes until completion or end().
      for (let start = end - 1; start >= offset && start >= end - 4; --start) {
        const byte = view[start];
        if ((byte & 192) === 128) continue;
        const expected = width(byte);
        if (expected > end - start) {
          total = expected;
          end = start;
        }
        break;
      }
    }
    else if (state.encoding === 'utf16le') {
      if ((end - offset) % 2) {
        --end;
        total = 2;
      }
      else if (end > offset && (view[end - 1] & 252) === 216) {
        end -= 2;
        total = 4;
      }
    }
    else if (state.encoding === 'base64' || state.encoding === 'base64url') {
      const remainder = (end - offset) % 3;
      if (remainder) {
        end -= remainder;
        total = 3;
      }
    }
    if (total) {
      const buffered = view.length - end;
      state.total = total;
      state.need = total - buffered;
      for (let i = 0; i < buffered; ++i) state.last[i] = view[end + i];
    }
    return output + convert(state, view, offset, end);
  };
  StringDecoder.prototype.end = function(input) {
    let output = input === undefined ? '' : this.write(input);
    const state = stateOf(this);
    if (state.need) output += convert(state, state.last, 0, state.total - state.need);
    clear(state);
    return output;
  };
  StringDecoder.prototype.text = function(input, offset) {
    clear(stateOf(this));
    return this.write(input.slice(offset));
  };
  for (const name of ['lastNeed', 'lastTotal', 'lastChar']) {
    Object.defineProperty(StringDecoder.prototype, name, {
      enumerable: true, configurable: true,
      get: function() {
        const state = stateOf(this);
        return name === 'lastChar' ? state.last : name === 'lastNeed' ? state.need : state.total;
      },
    });
  }
  return { StringDecoder: StringDecoder };
};
