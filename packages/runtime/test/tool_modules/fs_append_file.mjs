import fs from 'node:fs';
import { appendFile, readFile } from 'node:fs/promises';
function check(value, message) { if (!value) throw new Error(message); }
const root = process.argv[2];
const path = name => root + '/' + name;
check(fs.appendFileSync(path('text'), 'A\0🐿') === undefined, 'sync actual write result');
check(await appendFile(path('text'), 'B', 'utf8') === undefined, 'promised actual write result');
check(await readFile(path('text'), 'utf8') === 'A\0🐿B', 'UTF-8 and embedded NUL preserved');
fs.appendFileSync(path('existing'), 'sync');
await appendFile(path('existing'), 'promise', { mode: 0o777 });
fs.appendFileSync(path('override'), 'replacement', { flag: 'w' });
fs.appendFileSync(path('readonly-flag'), 'XY', { flag: 'r+' });
const bytes = new Uint8Array([99, 0, 128, 255, 88]);
fs.appendFileSync(path('bytes'), bytes.subarray(1, 4));
await appendFile(path('bytes'), new DataView(bytes.buffer, 2, 2));
fs.appendFileSync(path('bytes'), Buffer.from(bytes).subarray(3, 4));
let fd = fs.openSync(path('descriptor'), 'r+');
try {
  fs.appendFileSync(fd, 'A');
  fs.appendFileSync(fd, 'B');
} finally { fs.closeSync(fd); }
fd = fs.openSync(path('descriptor-append'), 'a');
try { fs.appendFileSync(fd, 'tail'); } finally { fs.closeSync(fd); }
for (const [target, code] of [[path('missing-parent/file'), 'ENOENT'], [root, 'EISDIR']]) {
  let error; try { fs.appendFileSync(target, 'must fail'); } catch (caught) { error = caught; }
  check(error && error.code === code, 'sync actual OS error ' + code);
  error = undefined;
  try { await appendFile(target, 'must fail'); } catch (caught) { error = caught; }
  check(error && error.code === code, 'promised actual OS error ' + code);
}
let error; try { fs.appendFileSync(999999, 'bad fd'); } catch (caught) { error = caught; }
check(error && error.code === 'EBADF', 'real invalid descriptor error');
console.log('OK actual append bytes, UTF-8, binary views, descriptor offsets, flags and OS errors');
