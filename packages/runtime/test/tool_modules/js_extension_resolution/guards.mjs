import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const cases = [
  ['resolve exact export target', () => require.resolve('strict-exports'), 'MODULE_NOT_FOUND'],
  ['load exact export target', () => require('strict-exports'), 'MODULE_NOT_FOUND'],
  ['blocked export subpath', () => require('blocked/hidden.js'), 'ERR_PACKAGE_PATH_NOT_EXPORTED'],
  ['exact imports target', () => require('#missing'), 'MODULE_NOT_FOUND'],
];
let checks = 0;
const failures = [];
for (const [name, body, expected] of cases) {
  let code;
  try { body(); }
  catch (error) { code = error.code; }
  checks++;
  if (code !== expected) failures.push({ name, code, expected });
}
checks++;
if (globalThis.jsSuffixForbiddenBody !== undefined) failures.push({ name: 'forbidden module executed' });
console.log('JS EXTENSION PACKAGE RESULTS ' + JSON.stringify({ checks, passed: checks - failures.length, failures }));
if (checks !== 5 || failures.length) throw new Error('Package boundaries changed or forbidden body ran');
console.log('JS EXTENSION PACKAGE GUARDS 5 CHECKS OK');
