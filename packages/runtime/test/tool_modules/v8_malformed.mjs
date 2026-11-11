import { deserialize } from 'node:v8';
const invalid = [
  '', 'ff', 'ff0f', 'ff0f49', 'ff0f4e000000', 'ff0f5e00',
  'ff0f22ffffffff1f', 'ff0f6301ff', 'ff0f6f220178',
  'ff0f6100400100', 'ff0f41015f240000', 'ff0f5c0102ff',
  
];
const failures = [];
for (const hex of invalid) {
  let threw = false;
  try { deserialize(Buffer.from(hex, 'hex')); } catch { threw = true; }
  if (!threw) failures.push(hex);
}
for (const value of [null, undefined, 7, 'bytes', {}]) {
  let threw = false;
  try { deserialize(value); } catch { threw = true; }
  if (!threw) failures.push(typeof value);
}
console.log('V8 MALFORMED RESULTS ' + JSON.stringify({ groups: 17, passed: 17 - failures.length, failures }));
if (failures.length) throw new Error('Malformed clone data was accepted');
console.log('V8 MALFORMED 17 GROUPS OK');
