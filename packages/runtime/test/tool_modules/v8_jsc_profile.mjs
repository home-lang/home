import { serialize, deserialize } from 'node:v8';
const failures = [], passed = [];
function group(name, fn) { try { if (!fn()) throw new Error('predicate failed'); passed.push(name); } catch (e) { failures.push({ name, error: String(e) }); } }
group('real-primitives', () => [undefined, null, false, true, 42, -0, NaN, Infinity, 12n, '☃\ud800'].every(v => Object.is(v, deserialize(serialize(v)))));
group('real-date', () => deserialize(serialize(new Date(77))).getTime() === 77);
group('real-binary', () => {
  const output = deserialize(serialize(new Uint16Array([7, 11])));
  return output instanceof Uint16Array && output.length === 2 && output[1] === 11;
});
group('real-primitive-map', () => deserialize(serialize(new Map([[7, 11]]))).get(7) === 11);
group('real-primitive-set', () => deserialize(serialize(new Set([7, 11]))).has(11));
group('real-buffer', () => Buffer.isBuffer(deserialize(serialize(Buffer.from([7, 11])))));
group('ordinary-containers-refused', () => {
  for (const value of [{ real: 7 }, [7]]) { let refused = false; try { serialize(value); } catch (e) { refused = e.code === 'ERR_HOME_UNSUPPORTED'; } if (!refused) return false; }
  return true;
});
group('proxy-refused-without-traps', () => {
  let traps = 0;
  const proxy = new Proxy([], { ownKeys() { traps++; return []; }, get() { traps++; return undefined; }, getPrototypeOf() { traps++; return Array.prototype; } });
  try { serialize(proxy); return false; } catch (e) { return e.code === 'ERR_HOME_UNSUPPORTED' && traps === 0; }
});
console.log('HOME JSC V8 PROFILE RESULTS ' + JSON.stringify({ groups: passed.length + failures.length, passed: passed.length, failures }));
if (failures.length) throw new Error('Basic JSC serialization profile failed');
console.log('HOME JSC V8 PROFILE 8 GROUPS OK');
