import os from 'node:os';
import bare from 'os';
import { availableParallelism } from 'node:os';
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
let checks = 0;
function assert(value, message) { checks++; if (!value) throw new Error(message); }
function nativeCount(value) { return typeof value === 'number' && Number.isSafeInteger(value) && value > 0; }
assert(typeof availableParallelism === 'function', 'named native CPU query exists');
assert(nativeCount(availableParallelism()), 'positive integer native estimate');
assert(os.availableParallelism === availableParallelism && bare.availableParallelism === availableParallelism, 'bare and node module aliases');
assert(require('os').availableParallelism === availableParallelism && require('node:os').availableParallelism === availableParallelism, 'CommonJS module aliases');
assert(nativeCount(availableParallelism.call(null)), 'detached call does not need an OS receiver');
assert(nativeCount(availableParallelism.call(42)), 'receiver is ignored');
for (const argument of [undefined, null, 42, Symbol('ignored'), 1n, { valueOf() { throw new Error('must not coerce argument'); } }]) {
  assert(nativeCount(availableParallelism(argument)), 'no-argument query ignores extra values');
}
console.log('NODE AVAILABLE PARALLELISM ' + checks + ' CHECKS OK; native estimate ' + availableParallelism());
