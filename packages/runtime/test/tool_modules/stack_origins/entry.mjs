import { esmOrigin } from './esm-leaf.mjs';
import commonjs from './cjs-leaf.cjs';
import { typedOrigin } from './typed-leaf.ts';
import { asyncOrigin } from './async-leaf.mjs';
let operations = 0;
const failures = [];
for (const [name, run] of [
  ['esm-leaf.mjs', esmOrigin],
  ['cjs-leaf.cjs', commonjs.cjsOrigin],
  ['typed-leaf.ts', typedOrigin],
  ['async-leaf.mjs', asyncOrigin],
]) {
  let caught;
  try { await run(); } catch (error) { caught = error; }
  if (!(caught instanceof Error) || !String(caught.stack).includes(name)) failures.push(name);
  operations++;
}
if (operations !== 4 || failures.length) throw new Error('Module stack origin failures: ' + failures.join(',') + '; operations=' + operations);
console.log('MODULE STACK ORIGINS 4 OK');
