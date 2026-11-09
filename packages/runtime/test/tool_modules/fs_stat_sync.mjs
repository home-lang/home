import fs, { statSync, lstatSync } from 'node:fs';
import alias from 'fs';
import { stat } from 'node:fs/promises';
function check(value, message) { if (!value) throw new Error(message); }
const root = process.argv[2];
const cases = JSON.parse(process.argv[3]);
check(fs === alias && statSync === fs.statSync && lstatSync === alias.lstatSync, 'metadata module aliases');
for (const [path, follow, expected] of cases) {
  const call = follow ? statSync : lstatSync;
  for (const throwIfNoEntry of [true, false]) {
    let result, error;
    try { result = call(path, { throwIfNoEntry, bigint: false }); } catch (caught) { error = caught; }
    if (expected.code) {
      if (!throwIfNoEntry && (expected.code === 'ENOENT' || (follow && expected.code === 'ENOTDIR'))) check(!error && result === undefined, 'only actual missing entries are suppressed');
      else check(error && error.code === expected.code && error.syscall === (follow ? 'stat' : 'lstat') && error.path === path, 'actual metadata errno, syscall and path: ' + path);
      continue;
    }
    check(!error && result && !(result instanceof Promise), 'synchronous native metadata: ' + path);
    for (const [method, kind] of [['isFile', 'file'], ['isDirectory', 'directory'], ['isSymbolicLink', 'sym_link'], ['isBlockDevice', 'block_device'], ['isCharacterDevice', 'character_device'], ['isFIFO', 'named_pipe'], ['isSocket', 'unix_domain_socket']]) {
      check(result[method]() === (expected.kind === kind), 'actual native kind: ' + method + ' ' + path);
    }
    for (const key of ['size', 'ino', 'nlink']) check(result[key] === expected[key], 'actual native ' + key + ': ' + path);
    for (const key of ['mtime', 'ctime']) {
      check(Number.isFinite(result[key + 'Ms']), 'native numeric timestamp');
      if (path !== '/dev/null') check(Math.abs(result[key + 'Ms'] - expected[key + 'Ms']) < 1, 'owned native metadata timestamp');
      // /dev/null is shared with other processes, whose writes change its
      // timestamps after the Python snapshot. Its returned Date must still
      // describe the metadata from this exact native stat call.
      check(result[key] instanceof Date && Math.abs(result[key].getTime() - result[key + 'Ms']) < 1, 'native Date timestamp');
    }
    if (follow) {
      const promised = await stat(path);
      check(promised.size === result.size && promised.ino === result.ino && promised.isFile() === result.isFile(), 'existing promised stat shares native metadata');
    }
  }
}
fs.writeFileSync(root + '/plain', 'updated native bytes');
check(statSync(root + '/plain').size === 20 && statSync(root + '/file-link').size === 20, 'native mutation observed through symlink');
console.log('OK native sync stat and lstat, seven predicates, metadata, symlinks, mutations and actual errno');
