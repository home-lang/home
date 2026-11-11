// A bounded, actual binary value codec. V8 wire version 15 and Node's default
// view delegate are interoperable; no V8 heap, snapshot or isolate is simulated.
globalThis.__home_tool_v8_factory = function(Buffer, isProxy, isPromise) {
  'use strict';
  const apply = Reflect.apply;
  const get = Object.getOwnPropertyDescriptor;
  const prototype = Object.getPrototypeOf;
  const define = Object.defineProperty;
  const keys = Object.keys;
  const own = Object.hasOwn;
  const NativeMap = Map, NativeSet = Set, NativeDate = Date, NativeArray = Array;
  const mapHas = Map.prototype.has, mapGet = Map.prototype.get, mapSet = Map.prototype.set;
  const setAdd = Set.prototype.add;
  const arrayFrom = Array.from, isArray = Array.isArray;
  const bufferFrom = Buffer.from, isBuffer = Buffer.isBuffer;
  const Bytes = Uint8Array;
  const View = DataView;
  const writeDouble = View.prototype.setFloat64, readDouble = View.prototype.getFloat64;
  const typed = prototype(Bytes.prototype);
  const tagOf = get(typed, Symbol.toStringTag).get;
  const bufferOf = get(typed, 'buffer').get;
  const offsetOf = get(typed, 'byteOffset').get;
  const lengthOf = get(typed, 'byteLength').get;
  const rawLength = get(ArrayBuffer.prototype, 'byteLength').get;
  const resizable = get(ArrayBuffer.prototype, 'resizable');
  const dataLength = get(View.prototype, 'byteLength').get;
  const dataBuffer = get(View.prototype, 'buffer').get;
  const dataOffset = get(View.prototype, 'byteOffset').get;
  const mapSize = get(Map.prototype, 'size').get;
  const setSize = get(Set.prototype, 'size').get;
  const mapEntries = Map.prototype.entries;
  const setValues = Set.prototype.values;
  const dateTime = Date.prototype.getTime;
  const limit = 16 * 1024 * 1024;
  const entryLimit = 100000;
  const depthLimit = 256;
  const viewNames = ['Int8Array', 'Uint8Array', 'Uint8ClampedArray', 'Int16Array', 'Uint16Array', 'Int32Array', 'Uint32Array', 'Float32Array', 'Float64Array', 'DataView', 'Buffer', 'BigInt64Array', 'BigUint64Array'];
  const viewTypes = [Int8Array, Uint8Array, Uint8ClampedArray, Int16Array, Uint16Array, Int32Array, Uint32Array, Float32Array, Float64Array, DataView, Buffer, BigInt64Array, BigUint64Array];
  function unsupported(message) {
    const error = new Error(`Home v8 serialization: ${message}`);
    error.code = 'ERR_HOME_UNSUPPORTED';
    throw error;
  }
  function malformed() { throw new Error('Unable to deserialize cloned data'); }
  function bound(size) {
    if (!Number.isSafeInteger(size) || size < 0 || size > limit) unsupported('wire size exceeds the 16 MiB profile');
    return size;
  }
  function intrinsic(fn, value) {
    try { return { value: apply(fn, value, []) }; }
    catch { return null; }
  }
  function viewBytes(value) {
    if (!ArrayBuffer.isView(value)) return null;
    const data = intrinsic(dataLength, value);
    const buffer = apply(data ? dataBuffer : bufferOf, value, []);
    const offset = apply(data ? dataOffset : offsetOf, value, []);
    const length = data ? data.value : apply(lengthOf, value, []);
    return { bytes: new Bytes(buffer, offset, length), name: data ? 'DataView' : apply(tagOf, value, []) };
  }
  function serialize(value) {
    let bytes = new Bytes(128), used = 0, entries = 0;
    const refs = new NativeMap();
    function reserve(count) {
      const size = bound(used + count);
      if (size <= bytes.length) return;
      const next = new Bytes(Math.min(limit, Math.max(size, bytes.length * 2)));
      next.set(bytes); bytes = next;
    }
    function byte(n) { reserve(1); bytes[used++] = n; }
    function uint(n) {
      do { const rest = Math.floor(n / 128); byte(n % 128 + (rest ? 128 : 0)); n = rest; } while (n);
    }
    function double(n) { reserve(8); apply(writeDouble, new View(bytes.buffer), [used, n, true]); used += 8; }
    function raw(data) { reserve(data.length); bytes.set(data, used); used += data.length; }
    function string(s) {
      let wide = false;
      for (let i = 0; i < s.length; ++i) if (s.charCodeAt(i) > 255) { wide = true; break; }
      bound(s.length * (wide ? 2 : 1));
      // V8 requires the raw UTF-16 payload to start at an even offset.
      const size = s.length * (wide ? 2 : 1);
      let width = 1, n = size;
      while (n >= 128) { ++width; n = Math.floor(n / 128); }
      if (wide && (used + 1 + width) % 2) byte(0);
      byte(wide ? 99 : 34); uint(size); reserve(size);
      for (let i = 0; i < s.length; ++i) { const c = s.charCodeAt(i); bytes[used++] = c & 255; if (wide) bytes[used++] = c >>> 8; }
    }
    function bigint(n) {
      const negative = n < 0n; if (negative) n = -n;
      const parts = [];
      while (n) { if (parts.length >= 512) unsupported('bigint exceeds 4096 bits'); parts.push(Number(n & 255n)); n >>= 8n; }
      while (parts.length % 8) parts.push(0);
      uint(parts.length * 2 + (negative ? 1 : 0)); raw(new Bytes(parts));
    }
    function count() { if (++entries > entryLimit) unsupported('container entry count exceeds 100000'); }
    function properties(object, depth) {
      let written = 0;
      for (const key of keys(object)) {
        // Snapshot the keys, but a prior getter may delete a later own key.
        if (!own(object, key)) continue;
        count(); const v = object[key]; string(key); write(v, depth + 1); ++written;
      }
      return written;
    }
    function write(v, depth) {
      if (depth > depthLimit) unsupported('nesting exceeds 256');
      if (v === undefined) { byte(95); return; }
      if (v === null) { byte(48); return; }
      if (typeof v === 'boolean') { byte(v ? 84 : 70); return; }
      if (typeof v === 'string') { string(v); return; }
      if (typeof v === 'bigint') { byte(90); bigint(v); return; }
      if (typeof v === 'number') {
        if (Number.isInteger(v) && v >= -2147483648 && v <= 2147483647 && !Object.is(v, -0)) { byte(73); uint(v < 0 ? -v * 2 - 1 : v * 2); }
        else { byte(78); double(v); }
        return;
      }
      if (typeof v !== 'object') unsupported('functions and symbols cannot be cloned');
      if (typeof isProxy === 'function' && isProxy(v)) unsupported('proxies cannot be cloned');
      if (typeof isPromise === 'function' && isPromise(v)) unsupported('promises cannot be cloned');
      if (apply(mapHas, refs, [v])) { byte(94); uint(apply(mapGet, refs, [v])); return; }
      if (apply(mapSize, refs, []) >= entryLimit) unsupported('object count exceeds 100000');
      apply(mapSet, refs, [v, apply(mapSize, refs, [])]);
      const view = viewBytes(v);
      if (view) {
        const type = isBuffer(v) ? 10 : viewNames.indexOf(view.name);
        if (type < 0) unsupported('unsupported binary view');
        byte(92); uint(type); uint(bound(view.bytes.length)); raw(view.bytes); return;
      }
      const buffer = intrinsic(rawLength, v);
      if (buffer) {
        if (resizable && apply(resizable.get, v, [])) unsupported('resizable ArrayBuffers are not implemented');
        byte(66); uint(bound(buffer.value)); raw(new Bytes(v)); return;
      }
      const date = intrinsic(dateTime, v);
      if (date) { byte(68); double(date.value); return; }
      const map = intrinsic(mapSize, v);
      if (map) {
        if (map.value > entryLimit - entries) unsupported('container entry count exceeds 100000');
        // V8 snapshots entries before serializing getters in their values.
        const snapshot = arrayFrom(apply(mapEntries, v, []));
        byte(59); for (const pair of snapshot) { count(); write(pair[0], depth + 1); write(pair[1], depth + 1); }
        byte(58); uint(snapshot.length * 2); return;
      }
      const set = intrinsic(setSize, v);
      if (set) {
        if (set.value > entryLimit - entries) unsupported('container entry count exceeds 100000');
        const snapshot = arrayFrom(apply(setValues, v, []));
        byte(39); for (const item of snapshot) { count(); write(item, depth + 1); }
        byte(44); uint(snapshot.length); return;
      }
      // Basic system JSC has no trap-free proxy inspection. Refuse ordinary
      // containers there rather than running proxy traps or claiming a clone.
      if (typeof isProxy !== 'function') unsupported('ordinary containers require native proxy brand inspection');
      if (intrinsic(WeakMap.prototype.has, v) || intrinsic(WeakSet.prototype.has, v)) unsupported('weak collections cannot be cloned');
      const proto = prototype(v);
      if (!isArray(v) && proto !== Object.prototype && proto !== null) unsupported('only plain objects and supported native value brands are implemented');
      if (isArray(v)) {
        const length = v.length;
        if (length > entryLimit) unsupported('array length exceeds 100000');
        byte(97); uint(length); const written = properties(v, depth); byte(64); uint(written); uint(length);
      }
      else { byte(111); const written = properties(v, depth); byte(123); uint(written); }
    }
    byte(255); uint(15); write(value, 0);
    return apply(bufferFrom, Buffer, [bytes.subarray(0, used)]);
  }
  function deserialize(input) {
    const view = viewBytes(input);
    if (!view) { const error = new TypeError('deserialize requires a Buffer, TypedArray or DataView'); error.code = 'ERR_INVALID_ARG_TYPE'; throw error; }
    const bytes = view.bytes; bound(bytes.length);
    let at = 0, entries = 0;
    const refs = [];
    function need(size) { if (!Number.isSafeInteger(size) || size < 0 || size > bytes.length - at) malformed(); }
    function byte() { need(1); return bytes[at++]; }
    function uint() {
      let n = 0, factor = 1;
      for (let i = 0; i < 5; ++i) { const b = byte(); if (i === 4 && b > 15) malformed(); n += (b & 127) * factor; if (!(b & 128)) return n; factor *= 128; }
      malformed();
    }
    function double() { need(8); const n = apply(readDouble, new View(bytes.buffer, bytes.byteOffset + at, 8), [0, true]); at += 8; return n; }
    function raw(size) { need(size); const data = bytes.slice(at, at + size); at += size; return data; }
    function tag() { let n = byte(); while (n === 0) n = byte(); return n; }
    function peek() { const saved = at, n = tag(); at = saved; return n; }
    function count() { if (++entries > entryLimit) unsupported('container entry count exceeds 100000'); }
    function ref(value) { if (refs.length >= entryLimit) unsupported('object count exceeds 100000'); refs.push(value); return value; }
    function string(size, wide) {
      need(size); if (wide && size % 2) malformed();
      const pieces = [];
      for (let end = at + size; at < end;) {
        const chunk = [];
        while (chunk.length < 4096 && at < end) { let c = bytes[at++]; if (wide) c |= bytes[at++] << 8; chunk.push(c); }
        pieces.push(String.fromCharCode(...chunk));
      }
      return pieces.join('');
    }
    function bigint() {
      const flags = uint(), size = flags >>> 1; need(size);
      if (size > 512) unsupported('bigint exceeds 4096 bits');
      let n = 0n;
      for (let i = size - 1; i >= 0; --i) n = (n << 8n) | BigInt(bytes[at + i]);
      at += size; return flags & 1 ? -n : n;
    }
    function property(object, depth) {
      count(); const key = read(depth + 1);
      if (typeof key !== 'string' && typeof key !== 'number') malformed();
      if (isArray(object) && key === 'length') malformed();
      const index = Number(key);
      if (isArray(object) && Number.isInteger(index) && index >= 0 && index < 0xffffffff && String(index) === String(key) && index >= object.length) malformed();
      const value = read(depth + 1);
      define(object, key, { value, writable: true, enumerable: true, configurable: true });
    }
    function read(depth) {
      if (depth > depthLimit) unsupported('nesting exceeds 256');
      const t = tag();
      if (t === 95) return undefined;
      if (t === 48) return null;
      if (t === 84 || t === 70) return t === 84;
      if (t === 73) { const n = uint(); return n % 2 ? -(n + 1) / 2 : n / 2; }
      if (t === 85) return uint();
      if (t === 78) return double();
      if (t === 90) return bigint();
      if (t === 34 || t === 99) return string(uint(), t === 99);
      if (t === 94) { const id = uint(); if (id >= refs.length) malformed(); return refs[id]; }
      if (t === 68) return ref(new NativeDate(double()));
      if (t === 66) return ref(raw(uint()).buffer);
      if (t === 92) {
        const type = uint(), size = uint(), ctor = viewTypes[type];
        if (!ctor) unsupported('unsupported host view tag');
        const width = ctor.BYTES_PER_ELEMENT || 1; if (size % width) malformed();
        const data = raw(size);
        return ref(type === 10 ? apply(bufferFrom, Buffer, [data]) : type === 9 ? new View(data.buffer) : new ctor(data.buffer));
      }
      if (t === 111 || t === 97 || t === 65) {
        const length = t === 111 ? 0 : uint();
        if (length > entryLimit) unsupported('array length exceeds 100000');
        const object = ref(t === 111 ? {} : new NativeArray(length));
        if (t === 65) for (let i = 0; i < length; ++i) { count(); if (peek() === 45) { tag(); continue; } object[i] = read(depth + 1); }
        let properties = 0; const end = t === 111 ? 123 : t === 97 ? 64 : 36;
        while (peek() !== end) { property(object, depth); ++properties; }
        tag(); if (uint() !== properties) malformed();
        if (t !== 111 && (uint() !== length || object.length !== length)) malformed();
        return object;
      }
      if (t === 59 || t === 39) {
        const map = t === 59, object = ref(map ? new NativeMap() : new NativeSet()); let size = 0;
        while (peek() !== (map ? 58 : 44)) { count(); const key = read(depth + 1); if (map) apply(mapSet, object, [key, read(depth + 1)]); else apply(setAdd, object, [key]); size += map ? 2 : 1; }
        tag(); if (uint() !== size) malformed(); return object;
      }
      unsupported(`wire tag ${t} is not implemented`);
    }
    if (byte() !== 255) malformed();
    if (uint() !== 15) unsupported('only V8 wire version 15 is implemented');
    return read(0);
  }
  return { serialize, deserialize };
};
