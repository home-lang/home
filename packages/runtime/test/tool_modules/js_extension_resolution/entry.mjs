import { createRequire } from 'node:module';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { marker as staticJs } from './js-ts/dep.js';
import { marker as staticJsx } from './jsx-tsx/dep.jsx';
import { marker as staticMjs } from './mjs-mts/dep.mjs';
import { marker as staticCjs } from './cjs-cts/dep.cjs';

const require = createRequire(import.meta.url);
const root = path.dirname(require.resolve('./expected.json'));
const cases = JSON.parse(readFileSync(require.resolve('./cases.json'), 'utf8'));
const expected = JSON.parse(readFileSync(require.resolve('./expected.json'), 'utf8'));
let checks = 0;
const failures = [];
function equal(name, actual, expected) {
  checks++;
  if (JSON.stringify(actual) !== JSON.stringify(expected)) failures.push({ name, actual, expected });
}
for (const item of cases) {
  const reference = expected.find(row => row.case === item.case);
  if (!reference) throw new Error('Missing executed Bun oracle row');
  let result;
  try { result = { path: path.relative(root, require.resolve(item.request)) }; }
  catch (error) { result = { error: error.code || error.name }; }
  equal(item.case + ' filename', result, reference.path ? { path: reference.path } : { error: reference.error });
  if (reference.path) equal(item.case + ' actual body', require(item.request).marker, reference.path);
}
equal('static js binding', staticJs, 'js-ts/dep.ts');
equal('static jsx binding', staticJsx, 'jsx-tsx/dep.tsx');
equal('static mjs binding', staticMjs, 'mjs-mts/dep.mts');
equal('static cjs binding', staticCjs, 'cjs-cts/dep.cts');
const alias = await import('./js-ts/dep.js');
const direct = await import('./js-ts/dep.ts');
equal('dynamic module identity', alias === direct, true);
equal('require module identity', require('./js-ts/dep.js') === require('./js-ts/dep.ts'), true);
equal('canonical filename identity', require.resolve('./js-ts/dep.js') === require.resolve('./js-ts/dep.ts'), true);
console.log('JS EXTENSION RESULTS ' + JSON.stringify({ cases: cases.length, checks, passed: checks - failures.length, failures }));
if (cases.length !== 25 || checks !== 54 || failures.length) throw new Error('Extension substitution result or denominator mismatch');
console.log('JS EXTENSION 54 EXECUTED CHECKS OK');
