import { rename, mkdir, writeFile, readFile, stat, rm } from 'node:fs/promises';
import { rename as bareRename } from 'fs/promises';
import fs from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
function check(value, message) { if (!value) throw new Error(message); }
const root = join(tmpdir(), 'home-rename-' + process.pid + '-' + Date.now());
await mkdir(root);
try {
  check(rename === fs.promises.rename && rename === bareRename, 'rename aliases');
  const source = join(root, 'source.txt'), destination = join(root, 'destination.txt');
  await writeFile(source, 'é\0actual');
  await writeFile(destination, 'old destination contents');
  const inode = (await stat(source)).ino;
  const promise = rename(source, destination);
  check(promise instanceof Promise && await promise === undefined, 'rename acknowledgement');
  check(!fs.existsSync(source) && (await stat(destination)).ino === inode, 'real move preserves inode');
  check(await readFile(destination, 'utf8') === 'é\0actual', 'destination replacement and contents');
  const staging = join(root, 'staging'), output = join(root, 'output');
  await mkdir(staging);
  await writeFile(join(staging, 'page.html'), '<h1>real output</h1>');
  const directoryInode = (await stat(staging)).ino;
  await rename(staging, output);
  check(!fs.existsSync(staging) && (await stat(output)).ino === directoryInode, 'directory move');
  check(await readFile(join(output, 'page.html'), 'utf8') === '<h1>real output</h1>', 'moved subtree');
  for (const [from, to] of [[source, join(root, 'new.txt')], [destination, join(root, 'missing', 'file.txt')]]) {
    const failed = rename(from, to);
    check(failed instanceof Promise, 'rename OS failure must reject');
    try { await failed; throw new Error('fabricated rename success'); }
    catch (error) { check(error.code === 'ENOENT' && error.syscall === 'rename' && error.path === from && error.dest === to, 'actual rename error fields'); }
  }
  check(await readFile(destination, 'utf8') === 'é\0actual', 'failed move preserves source');
  console.log('OK native promised file and directory renames');
}
finally {
  await rm(root, { recursive: true, force: true });
}
