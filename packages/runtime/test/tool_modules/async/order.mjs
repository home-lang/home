const __home_static_import_0 = 'source';
function collision() { const __home_static_import_1 = 'nested'; return __home_static_import_1; }
import trace from './trace.cjs';
trace.push('entry body');
import { value, namespace } from './reexport.mjs';
import * as same from './value.mjs';
import thenable from './thenable.cjs';
import * as thenNamespace from './then-export.mjs';
import { createRequire } from 'node:module';
const localRequire = createRequire(import.meta.url);
if (value !== 42 || namespace.value !== 42 || same.value !== 42 || thenable.marker !== 7 || thenNamespace.marker !== 7) throw new Error('async imports');
let rejected = false;
try { localRequire('./value.mjs'); } catch (error) { rejected = error.code === 'ERR_REQUIRE_ASYNC_MODULE'; }
if (!rejected) throw new Error('explicit require accepted async graph');
const nested = localRequire('./nested.cjs');
if (await nested.run() !== 42) throw new Error('nested async function');
let sum = 0;
for await (const number of [Promise.resolve(1), 2]) sum += number;
if (sum !== 3) throw new Error('for await');
if (trace.join(',') !== 'dependency start,dependency await,dependency end,entry body') throw new Error('evaluation order: ' + trace.join(','));
if (__home_static_import_0 !== 'source' || collision() !== 'nested') throw new Error('static import binding collision');
await Promise.resolve();
console.log('OK home-tool async module evaluation');
