import fs, { closeSync, fsyncSync, openSync, writeFileSync } from 'node:fs';
import alias from 'fs';
import { writeFile } from 'node:fs/promises';

function check(value, message) { if (!value) throw new Error(message); }
function fails(call, code, syscall, path) {
  let failure;
  try { call(); } catch (error) { failure = error; }
  check(failure && failure.code === code && failure.syscall === syscall, 'actual ' + syscall + ' error: ' + code);
  if (path !== undefined) check(failure.path === path, 'actual error path');
}
const root = process.argv[2];
const borrowed = Number(process.argv[3]);
const broken = Number(process.argv[4]);
check(fs === alias && openSync === fs.openSync && closeSync === fs.closeSync && fsyncSync === fs.fsyncSync && writeFileSync === fs.writeFileSync, 'descriptor API aliases');
let fd = openSync(root + '/sequence', 'w+', 0o640);
check(Number.isInteger(fd) && fd >= 0, 'actual numeric file descriptor');
check(writeFileSync(fd, 'A\0🟢') === undefined, 'string descriptor write');
const view = new Uint8Array([99, 0, 128, 255, 88]);
check(writeFileSync(fd, view.subarray(1, 4)) === undefined, 'exact typed-array subrange');
writeFileSync(fd, 'Z', { flag: 'a' });
check(fsyncSync(fd) === undefined, 'native file fsync');
check(closeSync(fd) === undefined, 'native file close');
fails(() => fsyncSync(fd), 'EBADF', 'fsync');
fails(() => writeFileSync(fd, 'must fail'), 'EBADF', 'write');
fails(() => closeSync(fd), 'EBADF', 'close');
check(writeFileSync(fd, '') === undefined && writeFileSync(fd, new Uint8Array(0)) === undefined, 'Node empty-write behavior does not issue a syscall');
fd = openSync(root + '/append', 'a', 0o600);
writeFileSync(fd, 'first:');
writeFileSync(fd, 'second', { flag: 'w' });
fsyncSync(fd);
closeSync(fd);
fd = openSync(root + '/append', 'a+');
writeFileSync(fd, ':third');
closeSync(fd);
fd = openSync(root + '/seed');
fails(() => writeFileSync(fd, 'must not overwrite'), 'EBADF', 'write');
closeSync(fd);
fd = openSync(root + '/exclusive', 'wx');
writeFileSync(fd, 'once');
closeSync(fd);
fails(() => openSync(root + '/exclusive', 'wx'), 'EEXIST', 'open', root + '/exclusive');
fails(() => openSync(root + '/missing', 'r'), 'ENOENT', 'open', root + '/missing');
writeFileSync(root + '/path-append', 'first:');
writeFileSync(root + '/path-append', 'second', { flag: 'a' });
fails(() => writeFileSync(root + '/exclusive', 'must not overwrite', { flag: 'wx' }), 'EEXIST', 'open', root + '/exclusive');
writeFileSync(root + '/data-view', new DataView(view.buffer, 1, 3), { mode: 0o600 });
await writeFile(root + '/async-exclusive', 'actual', { flag: 'wx' });
let rejected;
try { await writeFile(root + '/async-exclusive', 'must not overwrite', { flag: 'wx' }); } catch (error) { rejected = error; }
check(rejected && rejected.code === 'EEXIST', 'real promised exclusive create');
writeFileSync(borrowed, 'child');
fsyncSync(borrowed);
closeSync(borrowed);
fails(() => writeFileSync(broken, 'broken'), 'EPIPE', 'write');
fails(() => fsyncSync(broken), process.argv[5], 'fsync');
closeSync(broken);
console.log('OK actual descriptor writes, append, fsync, close and OS failures');
