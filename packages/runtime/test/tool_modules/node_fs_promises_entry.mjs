import promises, { mkdir, readFile, rm, stat } from 'node:fs/promises';
import * as bare from 'fs/promises';
import { promises as fsPromises } from 'node:fs';
import { createRequire } from 'node:module';
import { execFileSync } from 'node:child_process';
const requireHere = createRequire(import.meta.url);
if (promises !== fsPromises || promises !== requireHere('fs/promises') || promises !== requireHere('node:fs/promises') || bare.mkdir !== mkdir) throw new Error('filesystem promise identity');
const base = process.cwd() + '/.zig-cache/home-tool-fs-' + process.pid;
let created = false;
async function rejects(operation, code) {
  let caught = false;
  try { await operation(); } catch (error) { caught = code === undefined || error.code === code; }
  if (!caught) throw new Error('expected filesystem rejection ' + code);
}
try {
  if (await mkdir(base) !== undefined) throw new Error('nonrecursive mkdir result');
  created = true;
  if (await mkdir(base, { recursive: true }) !== undefined) throw new Error('existing recursive mkdir result');
  if (await mkdir(base + '/a/b', { recursive: true }) !== base + '/a') throw new Error('first created ancestor');
  await rejects(() => mkdir(base), 'EEXIST');
  await rejects(() => mkdir(base + '/missing/child'), 'ENOENT');
  await rejects(() => rm(base), 'ERR_FS_EISDIR');
  await rejects(() => stat(base + '/missing'), 'ENOENT');
  await rejects(() => readFile(base + '/missing', 'utf8'), 'ENOENT');
  await rm(base + '/missing', { force: true });
  const directory = await stat(base);
  if (!directory.isDirectory() || directory.isFile() || directory.isSymbolicLink() || !Number.isFinite(directory.mtimeMs) || directory.mtime.getTime() !== Math.trunc(directory.mtimeMs)) throw new Error('directory metadata');
  const fixture = import.meta.dirname + '/node_fs_utf8.bin';
  const expected = requireHere('./node_fs_utf8.expected.json');
  if (await readFile(fixture, { encoding: 'utf8', flag: 'r' }) !== expected.text) throw new Error('promise UTF-8 read');
  const file = await stat(fixture);
  if (!file.isFile() || file.isDirectory() || file.size <= 0 || file.ino <= 0 || file.nlink <= 0) throw new Error('real file metadata');
  execFileSync('/bin/ln', ['-s', fixture, base + '/file-link'], { stdio: 'inherit' });
  if (!(await stat(base + '/file-link')).isFile()) throw new Error('stat did not follow symlink');
  await rm(base + '/file-link');
  execFileSync('/bin/ln', ['-s', import.meta.dirname, base + '/directory-link'], { stdio: 'inherit' });
  await rm(base + '/directory-link', { recursive: true });
  if ((await readFile(fixture, 'utf8')) !== expected.text) throw new Error('recursive rm followed symlink');
  await rm(base + '/a', { recursive: true });
  await rejects(() => stat(base + '/a'), 'ENOENT');
  await rejects(() => rm(base + '/missing'), 'ENOENT');
  console.log('OK home-tool native filesystem promises');
} finally {
  if (created) await rm(base, { recursive: true, force: true });
}
