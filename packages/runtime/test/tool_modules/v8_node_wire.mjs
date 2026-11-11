import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { deserialize } from 'node:v8';
import { valueCases } from './v8_values.mjs';
const frozen = JSON.parse(readFileSync(join(dirname(fileURLToPath(import.meta.url)), 'v8_node_wires.json'), 'utf8'));
const cases = valueCases(), failures = [];
if (frozen.node !== 'v26.10.0' || frozen.wireVersion !== 15 || frozen.cases.length !== cases.length) throw new Error('Node wire fixture identity/denominator mismatch');
for (let i = 0; i < cases.length; ++i) {
  const [name, , valid] = cases[i], wire = frozen.cases[i];
  try { if (wire.name !== name || !valid(deserialize(Buffer.from(wire.hex, 'hex')))) throw new Error('structural predicate failed'); }
  catch (e) { failures.push({ name, error: String(e) }); }
}
console.log('V8 NODE WIRE RESULTS ' + JSON.stringify({ groups: cases.length, passed: cases.length - failures.length, failures }));
if (failures.length) throw new Error('Real Node-produced binary fixture failed');
console.log('V8 NODE WIRE 23 GROUPS OK');
