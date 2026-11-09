import fs, { readFileSync } from 'node:fs';
import alias from 'fs';
import { readFile } from 'node:fs/promises';
function check(value, message) { if (!value) throw new Error(message); }
const root = process.argv[2];
const path = root + '/actual-bytes';
const hex = 'efbbbf4100f09f9fa2ff7461696c';
const text = '\ufeffA\0🟢\ufffdtail';
fs.writeFileSync(path, Buffer.from(hex, 'hex'));
check(fs === alias && readFileSync === alias.readFileSync, 'filesystem aliases');
for (const options of [undefined, null, {}, { encoding: null }, { encoding: undefined, flag: 'r' }]) {
  const result = readFileSync(path, options);
  check(Buffer.isBuffer(result) && result instanceof Uint8Array, 'actual managed Buffer result');
  check(result.toString('hex') === hex && result.toString('utf8') === text, 'exact native bytes, NUL, BOM and invalid UTF8');
  result[0] = 0;
  check(readFileSync(path).toString('hex') === hex, 'independent native read storage');
  const promised = await readFile(path, options);
  check(Buffer.isBuffer(promised) && promised.toString('hex') === hex, 'promised native Buffer read');
}
for (const options of ['utf8', 'utf-8', { encoding: 'UTF8', flag: 'r' }]) {
  check(readFileSync(path, options) === text && await readFile(path, options) === text, 'existing explicit UTF8 read');
}
fs.writeFileSync(path, 'changed');
check(readFileSync(path).toString() === 'changed' && (await readFile(path)).toString() === 'changed', 'native mutation observed');
let syncError, promisedError;
try { readFileSync(root + '/missing'); } catch (error) { syncError = error; }
try { await readFile(root + '/missing'); } catch (error) { promisedError = error; }
check(syncError && promisedError && syncError.code === 'ENOENT' && promisedError.code === 'ENOENT', 'actual missing-file failures');
console.log('OK native sync and promised Buffer reads, exact bytes, UTF8 and OS errors');
