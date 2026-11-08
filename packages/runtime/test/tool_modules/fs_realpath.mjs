import fs from 'node:fs';
import { realpath } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
function check(value, message) { if (!value) throw new Error(message); }
const cases = JSON.parse(process.argv[2]);
const root = process.argv[3];
for (const [path, legacy, native] of cases) {
  for (const call of [() => fs.realpathSync(path), () => fs.realpathSync(path, 'utf8'), () => fs.realpathSync(path, { encoding: 'utf-8' })]) {
    let result, error;
    try { result = call(); } catch (caught) { error = caught; }
    check(legacy.code ? error && error.code === legacy.code : !error && result === legacy.path, `canonical path or OS errno for ${JSON.stringify(path)}: ${error?.code || result}, expected ${legacy.code || legacy.path}`);
  }
  for (const call of [() => fs.realpathSync.native(path), () => realpath(path)]) {
    let result, error;
    try { result = await call(); } catch (caught) { error = caught; }
    check(native.code ? error && error.code === native.code : !error && result === native.path, `native canonical path or OS errno for ${JSON.stringify(path)}: ${error?.code || result}, expected ${native.code || native.path}`);
  }
}
check(fs.realpathSync('mutable') === fs.realpathSync('plain.txt'), 'initial physical target');
execFileSync('/bin/ln', ['-sfn', 'space 🐿.txt', root + '/mutable'], { stdio: 'inherit' });
check(fs.realpathSync('mutable') === fs.realpathSync('space 🐿.txt'), 'symlink mutation must be observed');
check(await realpath('mutable') === fs.realpathSync('space 🐿.txt'), 'promised physical mutation');
console.log('OK actual canonical paths, symlink traversal/mutation, native alias, errno and promise rejections');
