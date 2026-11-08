// Managed Uint8Array storage and deliberately bounded Buffer operations.
globalThis.__home_tool_buffer_factory = function(decodeUtf8Hex) {
  'use strict';
  const Bytes = Uint8Array;
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
    if (['ascii', 'latin1', 'binary', 'base64', 'base64url', 'ucs2', 'ucs-2', 'utf16le', 'utf-16le'].includes(name)) unsupported(`Home Buffer encoding ${name} is not implemented`);
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
    if (name === 'hex') {
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
  function allocationSize(size) {
    if (typeof size !== 'number') fail('ERR_INVALID_ARG_TYPE', 'Buffer size must be a number', TypeError);
    if (!Number.isFinite(size) || size < 0 || size > Number.MAX_SAFE_INTEGER) fail('ERR_OUT_OF_RANGE', 'Invalid Buffer size', RangeError);
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
    let hex = '';
    for (let index = start; index < end; index++) hex += digits[this[index] >> 4] + digits[this[index] & 15];
    return selected === 'hex' ? hex : decodeUtf8Hex(hex);
  };
  Buffer.prototype.toLocaleString = Buffer.prototype.toString;
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
  return { Buffer };
};
