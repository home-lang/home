import processDefault, { chdir, cwd } from 'node:process';
import { createRequire } from 'node:module';
import { readFileSync, writeFileSync, realpathSync } from 'node:fs';
import { resolve } from 'node:path';
import { execFileSync } from 'node:child_process';
const root = process.argv[2];
const original = cwd();
const requireHere = createRequire(import.meta.url);
const labels = [];
function check(label, value) { if (!value) throw new Error(label); labels.push(label); }
function failure(path, code) {
  const before = cwd(); let error;
  try { chdir(path); } catch (caught) { error = caught; }
  check(code + ' native error', error && error.code === code && error.errno < 0 && error.syscall === 'chdir' && error.path === before && error.dest === path && cwd() === before);
}
try {
  check('aliases use the same function', chdir === processDefault.chdir && chdir === globalThis.process.chdir && requireHere('process').chdir === chdir);
  check('standard mutable descriptor', chdir.length === 1 && Object.getOwnPropertyDescriptor(process, 'chdir').enumerable);
  check('absolute change returns undefined', chdir(root) === undefined && cwd() === realpathSync(root));
  const pwd = process.env.PWD;
  chdir('nested-☃');
  check('relative Unicode directory', cwd() === realpathSync(root + '/nested-☃'));
  check('native relative file read', readFileSync('read.txt', 'utf8') === 'kernel-relative');
  writeFileSync('written.txt', 'real relative write');
  check('path resolution uses new directory', resolve('written.txt') === cwd() + '/written.txt');
  execFileSync('/bin/sh', ['-c', 'pwd -P > child-cwd.txt'], { stdio: 'inherit' });
  check('child inherits real kernel cwd', readFileSync('child-cwd.txt', 'utf8').trim() === cwd());
  check('environment PWD stays independent', process.env.PWD === pwd);
  chdir(root + '/link/..');
  check('kernel symlink parent traversal', cwd() === realpathSync(root + '/other'));
  chdir.call(null, root);
  check('detached receiver is accepted', cwd() === realpathSync(root));
  check('module referrer stays anchored after chdir', requireHere('./process_chdir_anchor.cjs').marker === 'anchored source');
  failure('missing-directory', 'ENOENT');
  failure(root + '/not-directory', 'ENOTDIR');
  failure(root + '/not-directory/child', 'ENOTDIR');
  failure(root + '/denied', 'EACCES');
  failure(root + '/loop', 'ELOOP');
  let invalid = 0;
  for (const path of [undefined, null, 3, {}, new String(root), new Date(0), new Uint8Array(1)]) {
    try { chdir(path); } catch (error) { if (error instanceof TypeError && error.code === 'ERR_INVALID_ARG_TYPE') invalid++; }
  }
  check('all seven invalid types refused', invalid === 7 && cwd() === realpathSync(root));
  check('native callback stays private', typeof globalThis.__home_tool_fs_operation === 'undefined');
  chdir(original);
  check('original directory restored', cwd() === original);
} finally { chdir(original); }
if (labels.length !== 19) throw new Error('wrong chdir denominator: ' + labels.length);
console.log('NODE PROCESS CHDIR RESULTS ' + JSON.stringify({ checks: labels.length, passed: labels.length, labels }));
console.log('NODE PROCESS CHDIR 19 CHECKS OK');
