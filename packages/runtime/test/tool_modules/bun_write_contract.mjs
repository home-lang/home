import { write } from 'bun';
import fs from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Buffer } from 'node:buffer';
function check(value, message) { if (!value) throw new Error(message); }
const root = join(tmpdir(), 'home-bun-write-' + process.pid + '-' + Date.now() + '-' + Math.random().toString(16).slice(2));
await fs.promises.mkdir(root);
try {
  check(write === Bun.write && require('bun').write === write, 'write module identity');
  const target = join(root, 'nested', 'unicode.txt');
  const promise = write(target, 'é😀\0');
  check(promise instanceof Promise, 'write acknowledgement must be a Promise');
  check(await promise === 7, 'actual UTF-8 byte count');
  check(fs.readFileSync(target).toString('hex') === 'c3a9f09f988000', 'real UTF-8 and NUL contents');
  const data = new Uint8Array([99, 0, 128, 255, 88]);
  check(await write(target, data.subarray(1, 4)) === 3, 'view byte count');
  check(fs.readFileSync(target).toString('hex') === '0080ff', 'view offset and overwrite truncation');
  check(await write(target, new DataView(data.buffer, 2, 2)) === 2, 'DataView byte count');
  check(fs.readFileSync(target).toString('hex') === '80ff', 'DataView byte offset');
  check(await write(target, '') === 0 && (await fs.promises.stat(target)).size === 0, 'empty write truncates');
  check(await write(target, '\uFEFF') === 3, 'BOM byte count');
  check(fs.readFileSync(target).toString('hex') === 'efbbbf', 'BOM is written unchanged');
  const byteLength = Buffer.byteLength;
  const publicWrite = fs.writeFileSync;
  try {
    Buffer.byteLength = function() { throw new Error('public byte counter called'); };
    fs.writeFileSync = function() { throw new Error('public writer called'); };
    check(await write(target, 'é😀\0') === 7, 'native acknowledgement independent of public helpers');
  }
  finally {
    Buffer.byteLength = byteLength;
    fs.writeFileSync = publicWrite;
  }
  check(fs.readFileSync(target).toString('hex') === 'c3a9f09f988000', 'private writer performed actual I/O');
  const missing = join(root, 'missing', 'file.txt');
  const denied = write(missing, 'x', { createPath: false });
  check(denied instanceof Promise, 'open failure must reject a Promise');
  try { await denied; throw new Error('fabricated missing-parent success'); }
  catch (error) { check(error.code === 'ENOENT', 'real missing-parent failure'); }
  check(!fs.existsSync(join(root, 'missing')), 'createPath false leaves parent missing');
  const directory = write(root, 'x');
  check(directory instanceof Promise, 'directory failure must reject a Promise');
  try { await directory; throw new Error('fabricated directory-write success'); }
  catch (error) { check(error.code === 'EISDIR', 'real directory failure'); }
  console.log('OK real Bun pathname writes, byte counts, truncation and failures');
}
finally {
  await fs.promises.rm(root, { recursive: true, force: true });
}
