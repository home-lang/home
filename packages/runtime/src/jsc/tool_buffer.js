// Managed Uint8Array storage and deliberately bounded Buffer operations.
globalThis.__home_tool_buffer_factory = function(decodeUtf8Hex) {
  'use strict';
  const Bytes = Uint8Array;
  // Match the engine's existing numeric TypedArray allocation ceiling and enforce the
  // same repository-tool Buffer profile on both providers. This is a length
  // bound, not a promise that the host can satisfy an allocation of that size.
  const maxLength = 1 << 30;
  const viewLength = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(Bytes.prototype), 'byteLength').get;
  const viewTag = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(Bytes.prototype), Symbol.toStringTag).get;
  const viewBuffer = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(Bytes.prototype), 'buffer').get;
  const viewOffset = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(Bytes.prototype), 'byteOffset').get;
  const dataBuffer = Object.getOwnPropertyDescriptor(DataView.prototype, 'buffer').get;
  const dataLength = Object.getOwnPropertyDescriptor(DataView.prototype, 'byteLength').get;
  const dataOffset = Object.getOwnPropertyDescriptor(DataView.prototype, 'byteOffset').get;
  const bufferApply = Reflect.apply;
  const constants = {};
  Object.defineProperty(constants, 'MAX_LENGTH', { value: maxLength, enumerable: true });
  const subarray = Bytes.prototype.subarray;
  const setBytes = Bytes.prototype.set;
  const fillBytes = Bytes.prototype.fill;
  const rawLength = Object.getOwnPropertyDescriptor(ArrayBuffer.prototype, 'byteLength').get;
  const sharedLength = typeof SharedArrayBuffer === 'function'
    ? Object.getOwnPropertyDescriptor(SharedArrayBuffer.prototype, 'byteLength').get : null;
  const digits = '0123456789abcdef';
  function fail(code, message, Type) {
    const error = new (Type || Error)(message);
    error.code = code;
    throw error;
  }
  function unsupported(message) {
    fail('ERR_HOME_UNSUPPORTED', message);
  }
  function Buffer() {
    unsupported('Home Buffer uses from/alloc; the deprecated constructor is not implemented');
  }
  Object.setPrototypeOf(Buffer.prototype, Bytes.prototype);
  Object.setPrototypeOf(Buffer, Bytes);
  function wrap(bytes) {
    if (viewLength.call(bytes) > maxLength) fail('ERR_BUFFER_TOO_LARGE', 'Home Buffer exceeds MAX_LENGTH', RangeError);
    Object.setPrototypeOf(bytes, Buffer.prototype);
    return bytes;
  }
  // TypedArray map/filter/subarray allocate real managed storage through this
  // species constructor, rather than calling the unsupported legacy API.
  function BufferStorage(value, offset, length) {
    return wrap(new Bytes(value, offset, length));
  }
  Object.defineProperty(Buffer, Symbol.species, { get: function() {
    return BufferStorage;
  } });
  function isRawBuffer(value) {
    try {
      rawLength.call(value);
      return true;
    }
    catch { /* Try shared storage without trusting an instanceof/prototype tag. */ }
    if (sharedLength) {
      try {
        sharedLength.call(value);
        return true;
      }
      catch { /* Not a managed ArrayBuffer. */ }
    }
    return false;
  }
  function encoding(value, forgiving) {
    if (value === undefined || (forgiving && (typeof value !== 'string' || value === ''))) return 'utf8';
    if (typeof value !== 'string') fail('ERR_UNKNOWN_ENCODING', 'Unknown Buffer encoding', TypeError);
    const name = value.toLowerCase();
    if (name === 'utf8' || name === 'utf-8') return 'utf8';
    if (name === 'hex') return 'hex';
    if (name === 'base64' || name === 'base64url') return name;
    if (['ascii', 'latin1', 'binary', 'ucs2', 'ucs-2', 'utf16le', 'utf-16le'].includes(name)) unsupported(`Home Buffer encoding ${name} is not implemented`);
    fail('ERR_UNKNOWN_ENCODING', `Unknown Buffer encoding: ${value}`, TypeError);
  }
  function hexDigit(code) {
    code &= 255;
    if (code >= 48 && code <= 57) return code - 48;
    if (code >= 65 && code <= 70) return code - 55;
    if (code >= 97 && code <= 102) return code - 87;
    return -1;
  }
  function encode(text, name) {
    const bytes = [];
    if (name === 'base64' || name === 'base64url') {
      let pending = 0, bits = 0;
      for (let index = 0; index < text.length; ++index) {
        // Node's Buffer decoder consumes the low byte of UTF-16 code units,
        // accepts either alphabet, ignores non-digits, and stops at padding.
        const c = text.charCodeAt(index) & 255;
        if (c === 61) break;
        const digit = c >= 65 && c <= 90 ? c - 65 : c >= 97 && c <= 122 ? c - 71
          : c >= 48 && c <= 57 ? c + 4 : c === 43 || c === 45 ? 62 : c === 47 || c === 95 ? 63 : -1;
        if (digit < 0) continue;
        pending = (pending << 6) | digit;
        bits += 6;
        if (bits >= 8) { bits -= 8; bytes.push((pending >>> bits) & 255); }
      }
    }
    else if (name === 'hex') {
      for (let index = 0; index + 1 < text.length; index += 2) {
        const high = hexDigit(text.charCodeAt(index));
        const low = hexDigit(text.charCodeAt(index + 1));
        if (high < 0 || low < 0) break;
        bytes.push((high << 4) | low);
      }
    }
    else {
      for (let index = 0; index < text.length; index++) {
        let point = text.charCodeAt(index);
        if (point >= 0xd800 && point <= 0xdbff) {
          const low = text.charCodeAt(index + 1);
          if (low >= 0xdc00 && low <= 0xdfff) {
            point = 0x10000 + ((point - 0xd800) << 10) + low - 0xdc00;
            index++;
          }
          else point = 0xfffd;
        }
        else if (point >= 0xdc00 && point <= 0xdfff) point = 0xfffd;
        if (point <= 0x7f) bytes.push(point);
        else if (point <= 0x7ff) bytes.push(0xc0 | (point >> 6), 0x80 | (point & 63));
        else if (point <= 0xffff) bytes.push(0xe0 | (point >> 12), 0x80 | ((point >> 6) & 63), 0x80 | (point & 63));
        else bytes.push(0xf0 | (point >> 18), 0x80 | ((point >> 12) & 63), 0x80 | ((point >> 6) & 63), 0x80 | (point & 63));
      }
    }
    return wrap(new Bytes(bytes));
  }
  function base64String(buffer, start, end, url) {
    const alphabet = url ? 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_' : 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    const parts = [];
    for (let index = start; index < end; index += 3) {
      const a = buffer[index], second = index + 1 < end, third = index + 2 < end;
      const b = second ? buffer[index + 1] : 0, c = third ? buffer[index + 2] : 0;
      parts.push(alphabet[a >>> 2] + alphabet[((a & 3) << 4) | (b >>> 4)]
        + (second ? alphabet[((b & 15) << 2) | (c >>> 6)] : url ? '' : '=')
        + (third ? alphabet[c & 63] : url ? '' : '='));
    }
    return parts.join('');
  }
  function allocationSize(size) {
    if (typeof size !== 'number') fail('ERR_INVALID_ARG_TYPE', 'Buffer size must be a number', TypeError);
    if (!Number.isFinite(size) || size < 0 || size > maxLength) fail('ERR_OUT_OF_RANGE', 'Invalid Buffer size', RangeError);
    return Math.floor(size);
  }
  function rangeIndex(value) {
    if (typeof value !== 'number') fail('ERR_INVALID_ARG_TYPE', 'Buffer index must be a number', TypeError);
    if (!Number.isSafeInteger(value) || value < 0 || value > 0xffffffff) fail('ERR_OUT_OF_RANGE', 'Invalid Buffer index', RangeError);
    return value;
  }
  function byteView(value) {
    return ArrayBuffer.isView(value) && value instanceof Bytes;
  }
  Buffer.from = function(value, option, length) {
    if (typeof value === 'string') return encode(value, encoding(option, true));
    if (isRawBuffer(value)) return wrap(new Bytes(value, option, length));
    if (ArrayBuffer.isView(value) || Array.isArray(value)) return wrap(new Bytes(value));
    if (value && value.type === 'Buffer' && Array.isArray(value.data)) return wrap(new Bytes(value.data));
    fail('ERR_INVALID_ARG_TYPE', 'Buffer.from requires a string, byte source or ArrayBuffer', TypeError);
  };
  Buffer.alloc = function(size, value, name) {
    const buffer = wrap(new Bytes(allocationSize(size)));
    if (value !== undefined) buffer.fill(value, 0, buffer.length, name);
    return buffer;
  };
  // These methods promise writable bytes, not observable prior heap contents.
  // Home's managed TypedArray allocator supplies fresh zeroed, unpooled storage
  // for both variants; do not expose native uninitialized memory or pretend a
  // slab pool exists. Keep allocation independent of mutable public alloc().
  function unsafeAllocation(size, alignment) {
    const length = allocationSize(size);
    if (alignment !== undefined) unsupported('Home Buffer aligned native allocations are not implemented');
    return wrap(new Bytes(length));
  }
  Buffer.allocUnsafe = function(size, alignment) {
    return unsafeAllocation(size, alignment);
  };
  Buffer.allocUnsafeSlow = function(size, alignment) {
    return unsafeAllocation(size, alignment);
  };
  Buffer.isBuffer = function(value) {
    return value instanceof Buffer;
  };
  Buffer.byteLength = function(value, name) {
    if (ArrayBuffer.isView(value) || isRawBuffer(value)) return value.byteLength;
    if (typeof value !== 'string') fail('ERR_INVALID_ARG_TYPE', 'Buffer.byteLength requires a string or byte source', TypeError);
    // Node measures hex text length independently of where hex decoding stops.
    if (typeof name === 'string' && name.toLowerCase() === 'hex') return Math.floor(value.length / 2);
    let selected;
    try {
      selected = encoding(name, true);
    }
    catch (error) {
      if (error.code !== 'ERR_UNKNOWN_ENCODING') throw error;
      selected = 'utf8';
    }
    if (selected === 'base64' || selected === 'base64url') {
      // byteLength is an estimate for valid input, not the permissive decoder's
      // output length. Whitespace/invalid digits still contribute to the size.
      let size = value.length;
      if (size && value.charCodeAt(size - 1) === 61) --size;
      if (size && value.charCodeAt(size - 1) === 61) --size;
      return Math.floor(size * 3 / 4);
    }
    return encode(value, selected).length;
  };
  Buffer.concat = function(list, length) {
    if (!Array.isArray(list) || list.some(function(item) {
      return !byteView(item);
    })) fail('ERR_INVALID_ARG_TYPE', 'Buffer.concat requires Uint8Array entries', TypeError);
    const size = length === undefined ? list.reduce(function(sum, item) {
      return sum + item.length;
    }, 0) : rangeIndex(length);
    const output = Buffer.alloc(size);
    let offset = 0;
    for (const item of list) {
      const count = Math.min(item.length, size - offset);
      if (count <= 0) break;
      setBytes.call(output, subarray.call(item, 0, count), offset);
      offset += count;
    }
    return output;
  };
  Buffer.prototype.subarray = function(start, end) {
    return wrap(subarray.call(this, start, end));
  };
  Buffer.prototype.slice = function(start, end) {
    return this.subarray(start, end);
  };
  Buffer.prototype.toString = function(name, start, end) {
    start = start === undefined ? 0 : Math.max(0, Math.min(this.length, Math.trunc(Number(start)) || 0));
    end = end === undefined ? this.length : Math.max(0, Math.min(this.length, Math.trunc(Number(end)) || 0));
    if (end <= start) return '';
    const selected = encoding(name, false);
    if (selected === 'base64' || selected === 'base64url') return base64String(this, start, end, selected === 'base64url');
    let hex = '';
    for (let index = start; index < end; index++) hex += digits[this[index] >> 4] + digits[this[index] & 15];
    return selected === 'hex' ? hex : decodeUtf8Hex(hex);
  };
  Buffer.prototype.toLocaleString = Buffer.prototype.toString;
  Buffer.prototype.write = function(string, offset, length, name) {
    if (typeof string !== 'string') fail('ERR_INVALID_ARG_TYPE', 'Buffer.write requires a string', TypeError);
    if (!byteView(this)) fail('ERR_INVALID_ARG_TYPE', 'Buffer.write requires byte storage', TypeError);
    const size = viewLength.call(this);
    if (offset === undefined) { offset = 0; length = size; name = 'utf8'; }
    else if (typeof offset === 'string') {
      if (length !== undefined) fail('ERR_INVALID_ARG_TYPE', 'Buffer.write encoding must be the last argument', TypeError);
      name = offset; offset = 0; length = size;
    }
    else {
      offset = rangeIndex(offset);
      if (offset > size) fail('ERR_OUT_OF_RANGE', 'Buffer write offset is outside the buffer', RangeError);
      if (typeof length === 'string') { name = length; length = size - offset; }
      else if (length === undefined) length = size - offset;
      else {
        length = rangeIndex(length);
        if (length > size) fail('ERR_OUT_OF_RANGE', 'Buffer write length is outside the buffer', RangeError);
        length = Math.min(length, size - offset);
      }
    }
    const selected = encoding(name || 'utf8', false), bytes = encode(string, selected);
    let count = Math.min(length, bytes.length);
    // Node never writes a partial UTF-8 scalar when the destination is short.
    if (selected === 'utf8' && count < bytes.length) while (count > 0 && (bytes[count] & 0xc0) === 0x80) --count;
    setBytes.call(this, subarray.call(bytes, 0, count), offset);
    return count;
  };
  // Fixed-width reads use the visible byte window, including subarrays. Keep
  // offset validation before the short-buffer check, as Node does for invalid
  // types/fractions, without coercing strings or boxed numbers into offsets.
  function readInteger(buffer, offset, width, littleEndian, signed) {
    if (typeof offset !== 'number') fail('ERR_INVALID_ARG_TYPE', 'Buffer offset must be a number', TypeError);
    if (Math.floor(offset) !== offset) fail('ERR_OUT_OF_RANGE', 'Buffer offset must be an integer', RangeError);
    if (buffer.length < width) fail('ERR_BUFFER_OUT_OF_BOUNDS', 'Attempt to access memory outside buffer bounds', RangeError);
    if (offset < 0 || offset > buffer.length - width) fail('ERR_OUT_OF_RANGE', 'Buffer offset is outside the buffer', RangeError);
    let value = 0;
    for (let index = 0; index < width; index++) {
      const position = littleEndian ? width - index - 1 : index;
      value = value * 256 + buffer[offset + position];
    }
    const limit = 2 ** (width * 8);
    return signed && value >= limit / 2 ? value - limit : value;
  }
  Object.assign(Buffer.prototype, {
    readUInt8(offset = 0) { return readInteger(this, offset, 1, false, false); },
    readInt8(offset = 0) { return readInteger(this, offset, 1, false, true); },
    readUInt16LE(offset = 0) { return readInteger(this, offset, 2, true, false); },
    readUInt16BE(offset = 0) { return readInteger(this, offset, 2, false, false); },
    readInt16LE(offset = 0) { return readInteger(this, offset, 2, true, true); },
    readInt16BE(offset = 0) { return readInteger(this, offset, 2, false, true); },
    readUInt32LE(offset = 0) { return readInteger(this, offset, 4, true, false); },
    readUInt32BE(offset = 0) { return readInteger(this, offset, 4, false, false); },
    readInt32LE(offset = 0) { return readInteger(this, offset, 4, true, true); },
    readInt32BE(offset = 0) { return readInteger(this, offset, 4, false, true); },
  });
  for (const name of ['readUInt8', 'readUInt16LE', 'readUInt16BE', 'readUInt32LE', 'readUInt32BE']) {
    Buffer.prototype[name.replace('UInt', 'Uint')] = Buffer.prototype[name];
  }
  function writeInteger(buffer, value, offset, width, littleEndian, signed) {
    // Node coerces the value once before checking offsets. Its one-byte
    // writers check offset type before value range; wider writers reverse
    // those two checks. Keep all checks before the first byte mutation.
    value = +value;
    if (width === 1 && typeof offset !== 'number') fail('ERR_INVALID_ARG_TYPE', 'Buffer offset must be a number', TypeError);
    const limit = 2 ** (width * 8);
    const minimum = signed ? -limit / 2 : 0;
    const maximum = signed ? limit / 2 - 1 : limit - 1;
    if (value < minimum || value > maximum) fail('ERR_OUT_OF_RANGE', 'Value is outside the integer range', RangeError);
    if (typeof offset !== 'number') fail('ERR_INVALID_ARG_TYPE', 'Buffer offset must be a number', TypeError);
    if (Math.floor(offset) !== offset) fail('ERR_OUT_OF_RANGE', 'Buffer offset must be an integer', RangeError);
    // Inspect native view kind and extent, not public length/byteLength or
    // prototype tags. A forged Uint16Array prototype is not byte storage.
    if (viewTag.call(buffer) !== 'Uint8Array') unsupported('Home Buffer integer writes require genuine Uint8Array storage');
    const length = viewLength.call(buffer);
    if (offset < 0 || offset > length - width) {
      // Node consults public length only while reporting a genuine bounds
      // failure. Never let a shadowed length authorize an out-of-view write.
      if (buffer.length - width < 0) fail('ERR_BUFFER_OUT_OF_BOUNDS', 'Attempt to access memory outside buffer bounds', RangeError);
      fail('ERR_OUT_OF_RANGE', 'Buffer offset is outside the buffer', RangeError);
    }
    let word = value >>> 0;
    for (let index = 0; index < width; index++) {
      buffer[offset + (littleEndian ? index : width - index - 1)] = word & 255;
      word >>>= 8;
    }
    return offset + width;
  }
  Object.assign(Buffer.prototype, {
    writeUInt8(value, offset = 0) { return writeInteger(this, value, offset, 1, false, false); },
    writeInt8(value, offset = 0) { return writeInteger(this, value, offset, 1, false, true); },
    writeUInt16LE(value, offset = 0) { return writeInteger(this, value, offset, 2, true, false); },
    writeUInt16BE(value, offset = 0) { return writeInteger(this, value, offset, 2, false, false); },
    writeInt16LE(value, offset = 0) { return writeInteger(this, value, offset, 2, true, true); },
    writeInt16BE(value, offset = 0) { return writeInteger(this, value, offset, 2, false, true); },
    writeUInt32LE(value, offset = 0) { return writeInteger(this, value, offset, 4, true, false); },
    writeUInt32BE(value, offset = 0) { return writeInteger(this, value, offset, 4, false, false); },
    writeInt32LE(value, offset = 0) { return writeInteger(this, value, offset, 4, true, true); },
    writeInt32BE(value, offset = 0) { return writeInteger(this, value, offset, 4, false, true); },
  });
  for (const name of ['writeUInt8', 'writeUInt16LE', 'writeUInt16BE', 'writeUInt32LE', 'writeUInt32BE']) {
    Buffer.prototype[name.replace('UInt', 'Uint')] = Buffer.prototype[name];
  }
  function search(buffer, value, offset, name, reverse) {
    if (typeof offset === 'string') {
      name = offset;
      offset = undefined;
    }
    let needle;
    if (typeof value === 'number') needle = new Bytes([value & 255]);
    else if (typeof value === 'string') needle = Buffer.from(value, name);
    else if (byteView(value)) {
      if (name !== undefined) encoding(name, false);
      needle = value;
    }
    else fail('ERR_INVALID_ARG_TYPE', 'Buffer search requires a string, byte value or Uint8Array', TypeError);
    let position = offset === undefined ? (reverse ? buffer.length : 0) : +offset;
    if (Number.isNaN(position)) position = reverse ? buffer.length : 0;
    position = Math.trunc(position);
    if (position < 0) position += buffer.length;
    if (needle.length === 0) return Math.max(0, Math.min(buffer.length, position));
    if (reverse) position = Math.min(position, buffer.length - needle.length);
    else position = Math.max(0, position);
    for (; reverse ? position >= 0 : position <= buffer.length - needle.length; position += reverse ? -1 : 1) {
      let matches = true;
      for (let index = 0; index < needle.length; index++) {
        if (buffer[position + index] !== needle[index]) {
          matches = false;
          break;
        }
      }
      if (matches) return position;
    }
    return -1;
  }
  Buffer.prototype.indexOf = function(value, offset, name) {
    return search(this, value, offset, name, false);
  };
  Buffer.prototype.lastIndexOf = function(value, offset, name) {
    return search(this, value, offset, name, true);
  };
  Buffer.prototype.includes = function(value, offset, name) {
    return search(this, value, offset, name, false) !== -1;
  };
  Buffer.prototype.toJSON = function() {
    return { type: 'Buffer', data: Array.from(this) };
  };
  function copyWindow(value, label) {
    try {
      return { buffer: bufferApply(viewBuffer, value, []), offset: bufferApply(viewOffset, value, []), length: bufferApply(viewLength, value, []) };
    } catch { /* DataView has separate native accessors, not a prototype tag. */ }
    try {
      return { buffer: bufferApply(dataBuffer, value, []), offset: bufferApply(dataOffset, value, []), length: bufferApply(dataLength, value, []) };
    } catch { /* Refuse ordinary objects and proxies before index coercion. */ }
    fail('ERR_INVALID_ARG_TYPE', `Buffer copy ${label} must be a genuine ArrayBuffer view`, TypeError);
  }
  function copyIndex(value) {
    // Node's Buffer copy uses floor, with non-finite explicit values mapping
    // to zero (including an explicit sourceEnd, unlike omitted sourceEnd).
    value = +value;
    return Number.isFinite(value) ? Math.floor(value) : 0;
  }
  Buffer.prototype.copy = function(target, targetStart, sourceStart, sourceEnd) {
    copyWindow(this, 'source');
    copyWindow(target, 'target');
    targetStart = targetStart === undefined ? 0 : copyIndex(targetStart);
    if (targetStart < 0) fail('ERR_OUT_OF_RANGE', 'Buffer copy targetStart is negative', RangeError);
    sourceStart = sourceStart === undefined ? 0 : copyIndex(sourceStart);
    if (sourceStart < 0 || sourceStart > copyWindow(this, 'source').length) fail('ERR_OUT_OF_RANGE', 'Buffer copy sourceStart is outside the view', RangeError);
    sourceEnd = sourceEnd === undefined ? copyWindow(this, 'source').length : copyIndex(sourceEnd);
    if (sourceEnd < 0) fail('ERR_OUT_OF_RANGE', 'Buffer copy sourceEnd is negative', RangeError);
    // Coercion can mutate or resize backing storage; sample the native extents
    // after those hooks. Never use mutable public byteLength/buffer fields.
    const source = copyWindow(this, 'source'), destination = copyWindow(target, 'target');
    const count = Math.min(sourceEnd - sourceStart, source.length - sourceStart, destination.length - targetStart);
    if (count <= 0) return 0;
    // These intrinsic byte views bypass species/constructor/subarray hooks.
    // The engine's TypedArray set provides real overlapping-buffer semantics.
    const input = new Bytes(source.buffer, source.offset + sourceStart, count);
    const output = new Bytes(destination.buffer, destination.offset, destination.length);
    bufferApply(setBytes, output, [input, targetStart]);
    return count;
  };
  Buffer.prototype.equals = function(other) {
    if (!byteView(other)) fail('ERR_INVALID_ARG_TYPE', 'Buffer.equals requires Uint8Array', TypeError);
    if (this.length !== other.length) return false;
    for (let index = 0; index < this.length; index++) if (this[index] !== other[index]) return false;
    return true;
  };
  Buffer.prototype.fill = function(value, start, end, name) {
    if (typeof start === 'string') {
      name = start;
      start = 0;
      end = this.length;
    }
    else if (typeof end === 'string') {
      name = end;
      end = this.length;
    }
    start = start === undefined ? 0 : rangeIndex(start);
    end = end === undefined ? this.length : rangeIndex(end);
    if (end > this.length) fail('ERR_OUT_OF_RANGE', 'Buffer fill range is outside the buffer', RangeError);
    if (end <= start) return this;
    if (value === undefined || value === null || typeof value === 'number' || typeof value === 'boolean') {
      fillBytes.call(this, Number(value) || 0, start, end);
      return this;
    }
    const pattern = typeof value === 'string' ? Buffer.from(value, name) : byteView(value) ? Buffer.from(value) : null;
    if (pattern === null) fail('ERR_INVALID_ARG_TYPE', 'Unsupported Buffer fill value', TypeError);
    if (pattern.length === 0) {
      if (typeof value !== 'string') fail('ERR_INVALID_ARG_VALUE', 'Empty Buffer fill pattern', TypeError);
      fillBytes.call(this, 0, start, end);
    }
    else for (let index = start; index < end; index++) this[index] = pattern[(index - start) % pattern.length];
    return this;
  };
  const api = { Buffer, kMaxLength: maxLength };
  Object.defineProperty(api, 'constants', { value: constants, enumerable: true });
  return api;
};
