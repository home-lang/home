// Values and independent structural predicates shared by reference and host
// fixtures. No serialization implementation or hardcoded success is used here.
export function valueCases() {
  const result = [];
  const primitive = [undefined, null, true, false, 0, -0, 42, -2147483648, 2147483647, 2147483648, NaN, Infinity, -Infinity, 1.25, 0n, -12n, 1n << 4000n, '', 'sql\0\xff', '☃\ud800\udfff'];
  result.push(['primitive-types', primitive, x => x.length === primitive.length && x.every((v, i) => Object.is(v, primitive[i]))]);
  for (const n of [0, 77, NaN]) result.push(['date-' + n, new Date(n), x => x instanceof Date && Object.is(x.getTime(), n)]);
  const raw = new Uint8Array([0, 37, 255]).buffer;
  result.push(['array-buffer', raw, x => x instanceof ArrayBuffer && x !== raw && new Uint8Array(x).join(',') === '0,37,255']);
  const constructors = [Int8Array, Uint8Array, Uint8ClampedArray, Int16Array, Uint16Array, Int32Array, Uint32Array, Float32Array, Float64Array, BigInt64Array, BigUint64Array];
  for (const C of constructors) {
    const big = C === BigInt64Array || C === BigUint64Array;
    const backing = new C(6); backing.fill(big ? 99n : 99); backing[2] = big ? 7n : 7; backing[3] = big ? 11n : 11;
    const view = backing.subarray(2, 4);
    result.push([C.name, view, x => x instanceof C && x.length === 2 && x[0] === view[0] && x[1] === view[1] && x.buffer !== backing.buffer]);
  }
  const backing = new Uint8Array([91, 92, 7, 11, 93]);
  result.push(['data-view-offset', new DataView(backing.buffer, 2, 2), x => x instanceof DataView && x.byteLength === 2 && x.getUint8(0) === 7 && x.getUint8(1) === 11]);
  const array = [undefined, , 7]; array.extra = 'extra'; array.self = array;
  result.push(['sparse-array-cycle', array, x => x.length === 3 && 0 in x && !(1 in x) && x[2] === 7 && x.extra === 'extra' && x.self === x]);
  const object = { n: 7 }; object.self = object;
  const shared = { a: object, b: object };
  result.push(['shared-object-cycle', shared, x => x.a === x.b && x.a.self === x.a && x.a.n === 7]);
  const map = new Map(); map.set(map, new Set([map]));
  result.push(['map-set-cycle', map, x => x instanceof Map && x.size === 1 && x.get(x) instanceof Set && x.get(x).has(x)]);
  const set = new Set(); set.add(set);
  result.push(['set-cycle', set, x => x instanceof Set && x.size === 1 && x.has(x)]);
  const pollution = {}; Object.defineProperty(pollution, '__proto__', { value: { safe: 9 }, enumerable: true });
  result.push(['own-proto-data', pollution, x => Object.hasOwn(x, '__proto__') && x.__proto__.safe === 9 && Object.getPrototypeOf(x) === Object.prototype && !Object.prototype.safe]);
  const ignored = { n: 3 }; ignored[Symbol('ignored')] = 99;
  Object.defineProperty(ignored, 'hidden', { value: 8 });
  result.push(['enumerability', ignored, x => x.n === 3 && Object.keys(x).length === 1 && Object.getOwnPropertySymbols(x).length === 0]);
  return result;
}

export function runValueContract(api) {
  const passed = [], failures = [];
  function group(name, fn) { try { if (!fn()) throw new Error('structural predicate failed'); passed.push(name); } catch (e) { failures.push({ name, error: String(e) }); } }
  for (const [name, value, valid] of valueCases()) group(name, () => valid(api.deserialize(api.serialize(value))));
  group('buffer-brand-and-view', () => {
    const backing = Buffer.from([91, 7, 11, 93]);
    const output = api.deserialize(api.serialize(backing.subarray(1, 3)));
    return Buffer.isBuffer(output) && output.length === 2 && output[0] === 7 && output[1] === 11;
  });
  group('detached-output-bytes', () => {
    const input = new Uint8Array([7, 11]), wire = api.serialize(input); input.fill(99);
    const output = api.deserialize(wire); return output[0] === 7 && output[1] === 11;
  });
  group('getters-delete-and-order', () => {
    const order = [], input = {};
    Object.defineProperty(input, 'first', { enumerable: true, get() { order.push('first'); delete input.later; input.newKey = 9; return 7; } });
    input.later = 8;
    const output = api.deserialize(api.serialize(input));
    return order.join(',') === 'first' && output.first === 7 && !Object.hasOwn(output, 'later') && !Object.hasOwn(output, 'newKey');
  });
  group('map-entry-snapshot', () => {
    const map = new Map(), first = {};
    Object.defineProperty(first, 'x', { enumerable: true, get() { map.clear(); return 7; } });
    map.set('first', first); map.set('later', 11);
    const output = api.deserialize(api.serialize(map)); return output.size === 2 && output.get('later') === 11 && output.get('first').x === 7;
  });
  group('input-view-offset', () => {
    const wire = api.serialize(7); const framed = new Uint8Array(wire.length + 4); framed.set(wire, 2);
    return api.deserialize(new DataView(framed.buffer, 2, wire.length)) === 7;
  });
  group('proxy-no-traps', () => {
    let traps = 0; const proxy = new Proxy({}, { ownKeys() { traps++; return []; }, get() { traps++; return undefined; }, getPrototypeOf() { traps++; return Object.prototype; } });
    try { api.serialize(proxy); return false; } catch { return traps === 0; }
  });
  group('unsupported-clone-values', () => {
    for (const value of [() => {}, Symbol('value'), Promise.resolve(7), new WeakMap(), new WeakSet()]) { let threw = false; try { api.serialize(value); } catch { threw = true; } if (!threw) return false; }
    return true;
  });
  group('public-helper-mutation', () => {
    const saved = [Buffer.from, Buffer.isBuffer, Map.prototype.set, Set.prototype.add, DataView.prototype.setFloat64, DataView.prototype.getFloat64];
    const value = { map: new Map([['n', 7]]), set: new Set([11]), date: new Date(77), bytes: Buffer.from([7, 11]), double: -0 };
    let output;
    try {
      const poison = () => { throw new Error('public helper must not implement the codec'); };
      Buffer.from = Buffer.isBuffer = Map.prototype.set = Set.prototype.add = DataView.prototype.setFloat64 = DataView.prototype.getFloat64 = poison;
      output = api.deserialize(api.serialize(value));
    }
    finally { [Buffer.from, Buffer.isBuffer, Map.prototype.set, Set.prototype.add, DataView.prototype.setFloat64, DataView.prototype.getFloat64] = saved; }
    return output.map.get('n') === 7 && output.set.has(11) && output.date.getTime() === 77 && Buffer.isBuffer(output.bytes) && output.bytes[1] === 11 && Object.is(output.double, -0);
  });
  return { groups: passed.length + failures.length, passed: passed.length, failures };
}
