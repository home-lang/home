import path, { basename } from 'node:path/posix';
import alias from 'path/posix';
function check(value, message) { if (!value) throw new Error(message); }
check(path === alias && path.posix === path && path.basename === basename, 'module identity');
const cases = [
  ['', undefined, ''], ['/', undefined, ''], ['///', undefined, ''],
  ['foo/', undefined, 'foo'], ['/a/file.ts///', undefined, 'file.ts'],
  ['.', undefined, '.'], ['..', undefined, '..'], ['/a/..', undefined, '..'],
  ['a\\b.ts', '.ts', 'a\\b'], ['航/🧪.ts/', '.ts', '🧪'],
  ['foo', 'foo', ''], ['foo/', 'foo', 'foo'], ['/a/foo', 'foo', 'foo'],
  ['foo/bar', 'foo/bar', ''], ['/a/foo///', 'bar/foo', 'foo///'],
  ['///', '/', '///'], ['/', 'x', '/'], ['/', 'longer', ''],
  ['.ts', '.ts', ''], ['/x/.ts', '.ts', '.ts'], ['a.ts', '.js', 'a.ts'],
  ['a\0b', 'b', 'a\0'],
];
for (const [value, suffix, expected] of cases) {
  check(basename(value, suffix) === expected, 'actual basename ' + JSON.stringify([value, suffix]));
}
for (const value of [undefined, null, 1, {}, [], true]) {
  try { basename(value); throw new Error('invalid path accepted'); }
  catch (error) { check(error instanceof TypeError && error.code === 'ERR_INVALID_ARG_TYPE', 'path type'); }
  try { basename('/actual/path', value); if (value !== undefined) throw new Error('invalid suffix accepted'); }
  catch (error) { check(error instanceof TypeError && error.code === 'ERR_INVALID_ARG_TYPE', 'suffix type'); }
}
console.log('OK actual POSIX basename and suffix boundaries');
