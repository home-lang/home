import { createRequire } from 'node:module';
import loadFromCommonJS from './from-cjs.cjs';
import { load as loadRelative } from './subdir/referrer.mjs';
const req = createRequire(import.meta.url);
const trace = [];
const first = import({ [Symbol.toPrimitive](hint) { trace.push(hint); return './awaited.mjs'; } });
trace.push('after');
if (trace.join(',') !== 'string,after') throw new Error('specifier coercion ordering changed');
if (globalThis.dynamicExecutions) throw new Error('dynamic import ran module body synchronously');
const [a, b] = await Promise.all([first, import('./awaited.mjs')]);
if (a !== b || a.value !== 7 || !a.default.ready || globalThis.dynamicExecutions !== 1) throw new Error('async module result or cache identity changed');
if (Object.getPrototypeOf(a) !== null || Object.isExtensible(a) || Object.prototype.toString.call(a) !== '[object Module]') throw new Error('namespace shape changed');
const fileURL = import.meta.url.replace(/entry\.mjs$/, 'awaited.mjs');
if (await import(fileURL) !== a || await import(fileURL.replace('file:', 'FILE:')) !== a || await import('#awaited') !== a) throw new Error('file URL/private import lost canonical module identity');
if (await loadFromCommonJS() !== a || (await loadRelative()).value !== 42) throw new Error('dynamic import lost its lexical referrer');
if ((await import('@home/dynamic')).default !== 'import' || req('@home/dynamic') !== 'require') throw new Error('dynamic import used require conditions');
const primitive = await import('./primitive.cjs');
const object = await import('./object.cjs');
if (primitive.default !== 17 || object.default !== req('./object.cjs') || object.value !== 23) throw new Error('CommonJS dynamic namespace lost actual values');
if (primitive !== await import('./primitive.cjs')) throw new Error('CommonJS namespace is not cached');
const empty = await import('./empty.mjs');
if (Object.keys(empty).length !== 0 || globalThis.emptyDynamicExecutions !== 1) throw new Error('empty .mjs gained a default export');
const moduleBuiltin = await import('node:module');
if (moduleBuiltin !== await import('module') || moduleBuiltin.createRequire !== createRequire || moduleBuiltin.default !== req('node:module')) throw new Error('builtin namespace identity differs');
let missing;
try { missing = import('./not-created.mjs'); } catch { throw new Error('missing dynamic module threw synchronously'); }
let missingRejected = false;
try { await missing; } catch { missingRejected = true; }
if (!missingRejected) throw new Error('missing dynamic module resolved');
const ordered = [];
const orderedImport = import({ toString() { ordered.push('string'); return './awaited.mjs'; } }, (ordered.push('options'), undefined));
ordered.push('after');
if (ordered.join(',') !== 'options,string,after' || await orderedImport !== a) throw new Error('import argument evaluation order changed');
const escapedURL = import.meta.url.replace(/entry\.mjs$/, 'spaced%20%23%20%25.mjs');
if ((await import(escapedURL)).default !== 39) throw new Error('file URL escaping changed');
const marker = {};
let conversion;
try { conversion = import({ toString() { throw marker; } }); } catch { throw new Error('specifier conversion threw synchronously'); }
try { await conversion; throw new Error('conversion resolved'); } catch (error) { if (error !== marker) throw new Error('conversion error identity changed'); }
let symbolRejected = false;
try { await import(Symbol('invalid')); } catch (error) { symbolRejected = error instanceof TypeError; }
if (!symbolRejected) throw new Error('Symbol specifier was converted');
globalThis.dynamicFailure = marker;
for (let index = 0; index < 2; index++) {
  let rejected = false;
  try { await import('./rejected.mjs'); } catch (error) { rejected = true; if (error !== marker) throw new Error('module failure identity changed'); }
  if (!rejected) throw new Error('failed module resolved');
}
if (globalThis.dynamicFailureExecutions !== 1) throw new Error('failed ESM module was re-executed');
let undefinedRejected = false;
try { await import('./undefined.mjs'); } catch (error) { undefinedRejected = error === undefined; }
if (!undefinedRejected) throw new Error('throw undefined was lost');
let requireRefused = false;
try { req('./awaited.mjs'); } catch (error) { requireRefused = error.code === 'ERR_REQUIRE_ASYNC_MODULE'; }
if (!requireRefused) throw new Error('explicit require accepted an async graph');
const __home_dynamic_import_0 = 1;
function hygienic(Promise, require, __home_dynamic_import_1) { return import((trace.push('comma'), './awaited.mjs')); }
if (await hygienic(null, null, null) !== a || __home_dynamic_import_0 !== 1 || trace[trace.length - 1] !== 'comma') throw new Error('host dynamic accessor collided with source bindings');
if (await import('./namespace-then.mjs') !== 73) throw new Error('actual then export assimilation changed');
console.log('OK actual dynamic import graphs namespaces referrers and failures');
