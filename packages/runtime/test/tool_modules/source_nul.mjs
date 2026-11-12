import { createRequire } from 'node:module';
import { mkdtempSync, readFileSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { runInThisContext } from 'node:vm';

const require = createRequire(import.meta.url);
const nul = String.fromCharCode(0);
const root = mkdtempSync(path.join(tmpdir(), 'home-source-nul-'));
const common = path.join(root, 'common.cjs');
const typed = path.join(root, 'typed.ts');
const esm = path.join(root, 'esm.mjs');
const tagged = path.join(root, 'tagged.mjs');
const json = path.join(root, 'value.json');
const invalid = path.join(root, 'invalid.cjs');
writeFileSync(common, 'exports.before = 1; exports.value = "prefix' + nul + 'suffix Ω😀"; exports.after = 17;');
writeFileSync(typed, 'export function token(i: number): string { return `' + nul + 'BPCODE${i}' + nul + '`; } export const after: number = 23;');
writeFileSync(esm, 'export const value = `prefix' + nul + '${7}' + nul + 'suffix`; export const after = 29;');
writeFileSync(tagged, 'function tag(parts) { return { cooked: parts[0], raw: parts.raw[0] }; } export const value = tag`prefix' + nul + 'suffix`;');
writeFileSync(json, JSON.stringify({ value: 'prefix' + nul + 'suffix Ω😀' }));
writeFileSync(invalid, 'globalThis.invalidNulFilePrefix = true;' + nul + 'globalThis.invalidNulFileSuffix = true;');
const tests = [];
function test(name, body) { tests.push([name, body]); }
function equal(actual, expected) {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) throw new Error(`Expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
}
test('intrinsic eval source', () => equal((0, eval)('`prefix' + nul + 'suffix`'), 'prefix' + nul + 'suffix'));
test('native VM source', () => equal(runInThisContext('`prefix' + nul + 'suffix`'), 'prefix' + nul + 'suffix'));
test('CommonJS literal suffix', () => equal(require(common).value, 'prefix' + nul + 'suffix Ω😀'));
test('CommonJS source after NUL', () => equal(require(common).after, 17));
test('TypeScript template value', () => equal(require(typed).token(3), nul + 'BPCODE3' + nul));
test('TypeScript source after NUL', () => equal(require(typed).after, 23));
test('real module cache identity', () => equal(require(typed) === require(typed), true));
test('ESM template and substitution', async () => equal((await import(esm)).value, 'prefix' + nul + '7' + nul + 'suffix'));
test('ESM source after NUL', async () => equal((await import(esm)).after, 29));
test('tagged template cooked', async () => equal((await import(tagged)).value.cooked, 'prefix' + nul + 'suffix'));
test('tagged template raw', async () => equal((await import(tagged)).value.raw, 'prefix' + nul + 'suffix'));
test('escaped JSON control', () => equal(require(json).value, 'prefix' + nul + 'suffix Ω😀'));
test('physical source contains NUL', () => equal(readFileSync(common, 'utf8').includes(nul), true));
test('invalid module source rejects', () => {
  let failure;
  try { require(invalid); }
  catch (error) { failure = error; }
  equal(failure instanceof Error, true);
});
test('invalid module source executes no prefix', () => equal([typeof globalThis.invalidNulFilePrefix, typeof globalThis.invalidNulFileSuffix], ['undefined', 'undefined']));
test('supplementary character suffix survives', () => equal(require(common).value.endsWith('Ω😀'), true));
const failures = [];
try {
  for (const [name, body] of tests) {
    try { await body(); }
    catch (error) { failures.push({ name, message: String(error.message) }); }
  }
  console.log('SOURCE NUL RESULTS ' + JSON.stringify({ checks: tests.length, passed: tests.length - failures.length, failures }));
  if (tests.length !== 16 || failures.length) throw new Error('Source NUL value or denominator mismatch');
  if (process.argv.includes('--transpile')) {
    const transpiler = new Bun.Transpiler({ loader: 'ts' });
    const profile = [];
    function check(name, body) { profile.push([name, body]); }
    function emitted(source, expression) { return Function(transpiler.transformSync(source).replace(/\bexport /g, '') + '\nreturn (' + expression + ');')(); }
    check('transformed token value', () => equal(emitted(readFileSync(typed, 'utf8'), 'token(4)'), nul + 'BPCODE4' + nul));
    check('transformed suffix statement', () => equal(emitted(readFileSync(typed, 'utf8'), 'after'), 23));
    check('transformed tagged raw', () => equal(emitted(readFileSync(tagged, 'utf8'), 'value.raw'), 'prefix' + nul + 'suffix'));
    check('transformation does not run source', () => {
      transpiler.transformSync('globalThis.nulTransformBody = true; const value: string = `a' + nul + 'b`;');
      equal(typeof globalThis.nulTransformBody, 'undefined');
    });
    check('invalid transformed source rejects', () => {
      let failure;
      try { transpiler.transformSync(readFileSync(invalid, 'utf8')); }
      catch (error) { failure = error; }
      equal(failure instanceof Error, true);
    });
    const errors = [];
    for (const [name, body] of profile) {
      try { body(); }
      catch (error) { errors.push({ name, message: String(error.message) }); }
    }
    console.log('SOURCE NUL TRANSPILE RESULTS ' + JSON.stringify({ checks: profile.length, passed: profile.length - errors.length, failures: errors }));
    if (profile.length !== 5 || errors.length) throw new Error('Source NUL transform profile mismatch');
  }
  console.log('SOURCE NUL 16 EXECUTED CHECKS OK');
}
finally {
  rmSync(root, { recursive: true, force: true });
}
