import fs, { readFileSync } from 'node:fs';
import promises, { mkdir, readFile, rm, stat, writeFile } from 'node:fs/promises';
import * as bare from 'fs/promises';
if (fs.promises !== promises || bare.writeFile !== writeFile) throw new Error('writeFile alias identity');
const base = process.cwd() + '/.zig-cache/write-file-' + process.pid;
const file = base + '/actual';
const readHex = typeof Home === 'object' ? Home.readFileHex : path => readFileSync(path).toString('hex');
async function rejected(path, value, code, options) {
  const promise = writeFile(path, value, options);
  if (!(promise instanceof Promise)) throw new Error('writeFile must return a real promise');
  let failed = false;
  try { await promise; } catch (error) { failed = code === undefined || error.code === code; }
  if (!failed) throw new Error('expected write rejection: ' + code);
}
await mkdir(base, { recursive: true });
try {
  if (await writeFile(file, 'long existing content') !== undefined) throw new Error('writeFile result');
  await writeFile(file, 'é\0🟢\ud800suffix', { encoding: 'UTF-8', flag: 'w', mode: 0o666 });
  if (readHex(file) !== 'c3a900f09f9fa2efbfbd737566666978') throw new Error('real UTF-8 bytes including surrogate suffix');
  await writeFile(file, 'short', 'utf8');
  if (await readFile(file, 'utf8') !== 'short') throw new Error('truncate actual file');
  await writeFile(file, '');
  if ((await stat(file)).size !== 0) throw new Error('empty file truncate');
  const padded = new Uint8Array([170, 1, 0, 255, 3, 187]);
  await writeFile(file, padded.subarray(1, 5));
  if (readHex(file) !== '0100ff03') throw new Error('subarray bytes');
  await writeFile(file, new DataView(padded.buffer, 2, 3));
  if (readHex(file) !== '00ff03') throw new Error('DataView bytes');
  for (const Type of [Int8Array, Uint8Array, Uint8ClampedArray, Int16Array, Uint16Array, Int32Array, Uint32Array, Float32Array, Float64Array, BigInt64Array, BigUint64Array]) {
    const buffer = new ArrayBuffer(32);
    const bytes = new Uint8Array(buffer);
    for (let i = 0; i < bytes.length; i++) bytes[i] = i;
    const size = Type.BYTES_PER_ELEMENT;
    await writeFile(file, new Type(buffer, size, 1));
    let expected = '';
    for (let i = size; i < size * 2; i++) expected += i.toString(16).padStart(2, '0');
    if (readHex(file) !== expected) throw new Error('typed view bytes ' + Type.name);
  }
  await rejected(base + '/absent/child', 'x', 'ENOENT');
  await rejected(base, 'x', 'EISDIR');
  await rejected(file + '/child', 'x', 'ENOTDIR');
  for (const invalid of [null, undefined, 42, {}, new ArrayBuffer(2)]) await rejected(file, invalid, 'ERR_INVALID_ARG_TYPE');
  const original = new Error('option getter identity');
  let caught;
  try { await writeFile(file, 'x', { get encoding() { throw original; } }); } catch (error) { caught = error; }
  if (caught !== original) throw new Error('original option error lost');
  console.log('OK actual file writes, UTF-8, 11 typed ranges, DataView, truncation and rejections');
} finally {
  await rm(base, { recursive: true, force: true });
}
