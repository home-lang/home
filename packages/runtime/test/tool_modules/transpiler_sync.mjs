import { Transpiler } from 'bun';

const transpiler = new Transpiler({ loader: 'ts' });
const tests = [];
function test(name, body) { tests.push([name, body]); }
function equal(actual, expected) {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) throw new Error(`Expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
}
function evaluate(source, expression) {
  const output = transpiler.transformSync(source);
  return Function(output + '\nreturn (' + expression + ');')();
}
test('global and module constructor identity', () => equal(Transpiler, Bun.Transpiler));
test('typed parameters and locals execute', () => equal(evaluate('function sum(a: number, b: number): number { const value: number = a + b; return value; }', 'sum(20, 22)'), 42));
test('generic function executes', () => equal(evaluate('function identity<T>(value: T): T { return value; }', 'identity("actual")'), 'actual'));
test('interface erasure executes', () => equal(evaluate('interface Entry { value: number }; const entry: Entry = { value: 17 };', 'entry.value'), 17));
test('type alias and assertion erasure execute', () => equal(evaluate('type Entry = { value: number }; const entry = { value: 18 } as Entry;', 'entry.value'), 18));
test('enum retains runtime values', () => equal(evaluate('enum Choice { First = 4, Next };', '[Choice.First, Choice.Next]'), [4, 5]));
test('typed destructuring executes', () => equal(evaluate('const { label = "fallback" }: { label?: string } = {};', 'label'), 'fallback'));
test('typed class accessor executes', () => equal(evaluate('class Entry { value: number = 19; get answer(): number { return this.value; } }', 'new Entry().answer'), 19));
test('unresolved ESM dependencies are preserved', () => {
  const out = transpiler.transformSync('import { missing } from "home-does-not-exist"; export const result: number = missing;');
  equal(out.includes('home-does-not-exist') && /import\s*\{/.test(out) && /export\s+const/.test(out), true);
  equal(out.includes('__home_'), false);
});
test('type-only imports are erased without lookup', () => equal(evaluate('import type { Missing } from "home-does-not-exist"; const value: number = 20;', 'value'), 20));
test('explicit require remains source', () => equal(transpiler.transformSync('const value: unknown = require("home-does-not-exist");').includes('require("home-does-not-exist")'), true));
test('dynamic import remains source', () => equal(/import\s*\(/.test(transpiler.transformSync('export const load = () => import("home-does-not-exist");')), true));
test('top-level await remains source', () => equal(/await\s/.test(transpiler.transformSync('export const value: number = await Promise.resolve(21);')), true));
test('Unicode and embedded NUL string survive', () => equal(evaluate('const value: string = "Ω😀\\0end";', 'value'), 'Ω😀\0end'));
test('transformation executes no source body', () => {
  delete globalThis.transpilerExecutionCanary;
  transpiler.transformSync('globalThis.transpilerExecutionCanary = 1; throw new Error("must not run");');
  equal(globalThis.transpilerExecutionCanary, undefined);
});
test('directives preserve strict execution', () => equal(evaluate('"use strict"; function receiver(): unknown { return this; }', 'receiver()') === undefined, true));
test('empty source has real string result', () => equal(typeof transpiler.transformSync(''), 'string'));
test('syntax failure rejects and instance recovers', () => {
  let failure;
  try { transpiler.transformSync('const value: number = ;'); }
  catch (error) { failure = error; }
  equal(failure instanceof Error, true);
  equal(evaluate('const value: number = 22;', 'value'), 22);
});
test('explicit ts override executes', () => equal(Function(transpiler.transformSync('const value: number = 23;', 'ts') + 'return value;')(), 23));
test('STX render wrapper compiles and executes', () => {
  const out = transpiler.transformSync('export function __render(__helpers) { const { title = "menu" } = this._props(); let out = ""; out += `<div>${title}</div>`; return out; }');
  const body = out.slice(out.indexOf('{') + 1, out.lastIndexOf('}')).trim();
  const render = Function('__helpers', body);
  equal(render.call({ _props: () => ({ title: 'Actual menu' }) }, {}), '<div>Actual menu</div>');
});
const failures = [];
for (const [name, body] of tests) {
  try { await body(); }
  catch (error) { failures.push({ name, message: String(error.message) }); }
}
console.log('TRANSPILE SYNC RESULTS ' + JSON.stringify({ checks: tests.length, passed: tests.length - failures.length, failures }));
if (tests.length !== 20 || failures.length) throw new Error('Transpile execution denominator or result mismatch');
if (process.argv.includes('--home-refusals')) {
  let refused = 0;
  function reject(body, type, code) {
    let failure;
    try { body(); }
    catch (error) { failure = error; }
    if (!(failure instanceof type) || (code && failure.code !== code)) throw new Error('Unsupported transform request did not reject truthfully');
    refused++;
  }
  for (const option of ['define', 'target', 'tsconfig', 'macro', 'exports', 'trimUnusedImports', 'minifyWhitespace'])
    reject(() => new Transpiler({ loader: 'ts', [option]: undefined }), Error, 'ERR_HOME_UNSUPPORTED');
  for (const loader of ['js', 'jsx', 'tsx']) reject(() => new Transpiler({ loader }), Error, 'ERR_HOME_UNSUPPORTED');
  reject(() => new Transpiler({}), Error, 'ERR_HOME_UNSUPPORTED');
  reject(() => new Transpiler(null), TypeError);
  reject(() => transpiler.transformSync('const x = 1', 'tsx'), Error, 'ERR_HOME_UNSUPPORTED');
  reject(() => transpiler.transformSync('', 'ts', {}), Error, 'ERR_HOME_UNSUPPORTED');
  reject(() => transpiler.transformSync(new Uint8Array([49])), TypeError);
  reject(() => transpiler.transformSync.call({}, ''), TypeError);
  equal([typeof transpiler.transform, typeof transpiler.scan, typeof transpiler.scanImports], ['undefined', 'undefined', 'undefined']);
  equal(typeof globalThis.__home_tool_transform_ts, 'undefined');
  console.log('TRANSPILE EXPLICIT REFUSALS ' + refused);
  if (refused !== 16) throw new Error('Refusal denominator mismatch');
}
console.log('TRANSPILE 20 EXECUTED CHECKS OK');
