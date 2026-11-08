import { file } from 'bun';
import { Buffer } from 'node:buffer';
import fs from 'node:fs';
function check(value, message) { if (!value) throw new Error(message); }
const root = import.meta.dir + '/bun_file/';
check(file === Bun.file && require('bun').file === file, 'module identity');
const source = file(root + 'data.json');
check(await source.exists(), 'existing real file');
check(source.size === 31 && source.lastModified === Math.trunc((await fs.promises.stat(root + 'data.json')).mtimeMs), 'actual metadata');
const record = await source.json(); check(record.name === 'café' && record.number === 7, 'real JSON and BOM');
source.text = async function() { return 'not filesystem data'; };
check((await source.json()).number === 7, 'json must read its own actual file');
const textFile = file(root + 'unicode and spaces%#.txt', {});
const text = await textFile.text(); check(text === 'text é\u0000end�', 'UTF-8, BOM, NUL and replacement');
check(Buffer.from(await textFile.arrayBuffer()).toString('hex') === 'efbbbf7465787420c3a900656e64ff', 'raw byte transport');
try { await textFile.json(); throw new Error('accepted invalid JSON'); } catch (error) { check(error instanceof SyntaxError, 'JSON failure'); }
const binary = file(root + 'bytes.bin'); const bytes = await binary.bytes(); const buffer = await binary.arrayBuffer();
check(bytes instanceof Uint8Array && !Buffer.isBuffer(bytes) && bytes.length === 256, 'byte storage');
check(buffer instanceof ArrayBuffer && buffer.byteLength === 256, 'array buffer storage');
const all = new Uint8Array(buffer); for (let index = 0; index < 256; index++) check(bytes[index] === index && all[index] === index, 'actual binary data');
bytes[0] = 255; all[1] = 255;
check((await binary.bytes())[0] === 0 && (await binary.bytes())[1] === 1, 'independent reads');
const empty = file(root + 'empty.txt'); check(await empty.exists() && empty.size === 0 && await empty.text() === '' && (await empty.bytes()).length === 0, 'real empty file');
const missing = file(root + 'missing.json'); check(!await missing.exists() && missing.size === 0, 'actual missing file');
for (const method of ['text', 'json', 'arrayBuffer', 'bytes']) {
  const promise = missing[method](); check(promise instanceof Promise, 'read rejection must be a Promise');
  try { await promise; throw new Error('fabricated missing-file data'); }
  catch (error) { check(error.code === 'ENOENT' && error.path === root + 'missing.json' && error.syscall === 'open', 'missing-file error'); }
}
const directory = file(root); check(!await directory.exists(), 'directory is not a file');
try { await directory.text(); throw new Error('fabricated directory data'); } catch (error) { check(error.code === 'EISDIR' && error.syscall === 'read', 'directory error'); }
try { await file(root + 'data.json').text.call({}); throw new Error('forged file receiver'); } catch (error) { check(error instanceof TypeError, 'file brand'); }
console.log('OK real Bun file reads, bytes, metadata and failures');
