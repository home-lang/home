import { createRequire } from 'node:module';
import { mkdtempSync, readFileSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';

const require = createRequire(import.meta.url);
const root = mkdtempSync(path.join(tmpdir(), 'home-runtime-jsdoc-'));
const comments = [
  '/**\n * @returns {number} first\n * @returns {number} second\n */',
  '/** @type {Array<} */',
  '/**\n * @param {number} missing.child\n */',
  '/**\n * @template {T} T\n * @template T\n */',
];
const broken = ['const = ;', "const value = 'unterminated", '/* unterminated', 'export const = 1;'];
const failures = [];
let checks = 0;
function equal(actual, expected) {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) throw new Error(`Expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
}
async function check(name, body, errors = failures) {
  checks++;
  try { await body(); }
  catch (error) { errors.push({ name, message: String(error.message) }); }
}
async function load(filename) { return filename.endsWith('.cjs') || filename.endsWith('.cts') ? require(filename) : import(filename); }
function moduleSource(comment, extension, index) {
  const typed = extension === '.cts' || extension === '.mts';
  const common = extension === '.cjs' || extension === '.cts';
  const body = comment + '\nfunction answer' + (typed ? '(value: number): number' : '(value)') + ' { return value + 40; }\n';
  return body + (common ? `module.exports = { answer, identity: ${index} };` : `export { answer }; export const identity = ${index};`);
}
try {
  for (const extension of ['.cjs', '.mjs']) {
    for (let i = 0; i < comments.length; i++) {
      const filename = path.join(root, `comment-${i}${extension}`);
      writeFileSync(filename, moduleSource(comments[i], extension, i));
      await check(extension + ' comment ' + i, async () => {
        const value = await load(filename);
        equal(value.answer(2), 42);
        equal(value.identity, i);
      });
    }
    for (let i = 0; i < broken.length; i++) {
      const filename = path.join(root, `broken-${i}${extension}`);
      const key = 'jsdocBroken' + i + (extension === '.cjs' ? 'Cjs' : 'Mjs');
      writeFileSync(filename, comments[0] + '\nglobalThis.' + key + '=true;\n' + broken[i]);
      await check(extension + ' real invalid source ' + i, async () => {
        let caught;
        try { await load(filename); } catch (error) { caught = error; }
        equal(caught instanceof Error, true);
        equal(typeof globalThis[key], 'undefined');
      });
    }
    await check(extension + ' real cache identity', async () => {
      const filename = path.join(root, 'comment-0' + extension);
      equal(await load(filename) === await load(filename), true);
    });
  }
  await check('physical comment remains unchanged', () => equal(readFileSync(path.join(root, 'comment-0.cjs'), 'utf8').startsWith(comments[0]), true));
  console.log('RUNTIME JSDOC RESULTS ' + JSON.stringify({ checks, passed: checks - failures.length, failures }));
  const commonFailed = failures.length;
  if (checks !== 19) throw new Error('Runtime JSDoc common denominator mismatch');
  if (process.argv.includes('--transpile')) {
    checks = 0;
    const profile = [];
    for (const extension of ['.cts', '.mts']) {
      for (let i = 0; i < comments.length; i++) {
        const filename = path.join(root, `typed-${i}${extension}`);
        writeFileSync(filename, moduleSource(comments[i], extension, i));
        await check(extension + ' typed comment ' + i, async () => equal((await load(filename)).answer(2), 42), profile);
      }
    }
    const transpiler = new Bun.Transpiler({ loader: 'ts' });
    for (let i = 0; i < comments.length; i++) {
      await check('transform comment ' + i, () => {
        const output = transpiler.transformSync(comments[i] + '\nconst answer: number = 42;');
        equal(Function(output + '\nreturn answer;')(), 42);
      }, profile);
    }
    for (let i = 0; i < broken.length; i++) {
      await check('transform real invalid syntax ' + i, () => {
        let caught;
        try { transpiler.transformSync(comments[0] + '\n' + broken[i]); } catch (error) { caught = error; }
        equal(caught instanceof Error, true);
      }, profile);
    }
    await check('transformation does not execute the body', () => {
      transpiler.transformSync(comments[0] + '\nglobalThis.jsdocTransformExecuted = true;');
      equal(typeof globalThis.jsdocTransformExecuted, 'undefined');
    }, profile);
    console.log('RUNTIME JSDOC TRANSPILE RESULTS ' + JSON.stringify({ checks, passed: checks - profile.length, failures: profile }));
    if (checks !== 17 || profile.length) throw new Error('Runtime JSDoc transform profile mismatch');
  }
  if (commonFailed) throw new Error('Runtime JSDoc common checks failed');
  console.log('RUNTIME JSDOC 19 EXECUTED CHECKS OK');
}
finally { rmSync(root, { recursive: true, force: true }); }
