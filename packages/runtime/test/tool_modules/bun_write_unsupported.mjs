import { write, file } from 'bun';
import fs from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
function check(value, message) { if (!value) throw new Error(message); }
const root = join(tmpdir(), 'home-bun-write-profile-' + process.pid + '-' + Date.now());
await fs.promises.mkdir(root);
const target = join(root, 'unwritten');
async function rejected(operation, code) {
  const promise = operation();
  check(promise instanceof Promise, 'unsupported write must return a rejection');
  try { await promise; throw new Error('unsupported write succeeded'); }
  catch (error) { check(error.code === code, 'explicit unsupported write: ' + error); }
  check(!fs.existsSync(target), 'unsupported write must not create a file');
}
try {
  await rejected(() => write(target, new ArrayBuffer(4)), 'ERR_HOME_UNSUPPORTED');
  await rejected(() => write(target, { toString() { return 'coerced'; } }), 'ERR_HOME_UNSUPPORTED');
  await rejected(() => write(file(target), 'x'), 'ERR_HOME_UNSUPPORTED');
  await rejected(() => write(99, 'x'), 'ERR_HOME_UNSUPPORTED');
  await rejected(() => write(target, 'x', { mode: 0o600 }), 'ERR_HOME_UNSUPPORTED');
  await rejected(() => write(target, 'x', { signal: {} }), 'ERR_HOME_UNSUPPORTED');
  console.log('OK unsupported Bun writes remain explicit failures');
}
finally {
  await fs.promises.rm(root, { recursive: true, force: true });
}
