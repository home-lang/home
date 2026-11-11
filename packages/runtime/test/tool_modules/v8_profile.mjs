import * as api from 'node:v8';
const failures = [], passed = [];
function guard(name, value) {
  try { api.serialize(value); failures.push(name + ': accepted'); }
  catch (e) { if (e.code !== 'ERR_HOME_UNSUPPORTED') failures.push(name + ': ' + String(e)); else passed.push(name); }
}
guard('regexp', /a/g);
guard('error', new Error('real error'));
guard('large-bigint', 1n << 4096n);
guard('array-length', new Array(100001));
guard('wire-limit', new Uint8Array(16 * 1024 * 1024 + 1));
let nested = null;
for (let i = 0; i < 258; ++i) nested = { child: nested };
guard('depth-limit', nested);
const resizable = new ArrayBuffer(1, { maxByteLength: 2 });
guard('resizable-array-buffer', resizable);
try { api.deserialize(Buffer.from('ff105f', 'hex')); failures.push('future-wire-version: accepted'); }
catch (e) { if (e.code !== 'ERR_HOME_UNSUPPORTED') failures.push('future-wire-version: ' + String(e)); else passed.push('future-wire-version'); }
if (api.getHeapStatistics !== undefined || api.startupSnapshot !== undefined || api.Serializer !== undefined) failures.push('unimplemented V8 surfaces were fabricated');
else passed.push('unsupported-api-surfaces-absent');
console.log('HOME V8 PROFILE RESULTS ' + JSON.stringify({ groups: passed.length + failures.length, passed: passed.length, failures }));
if (failures.length) throw new Error('Serialization profile guard failed');
console.log('HOME V8 PROFILE 9 GUARDS OK');
