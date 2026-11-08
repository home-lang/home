import hooks, { performance as clock, Performance } from 'node:perf_hooks';
import alias from 'perf_hooks';
function check(value, message) { if (!value) throw new Error(message); }
check(hooks === alias && clock === globalThis.performance, 'actual module identity');
check(Performance === globalThis.Performance && clock instanceof Performance, 'actual constructor identity');
check(Object.prototype.toString.call(clock) === '[object Performance]', 'clock tag');
try { new Performance(); throw new Error('constructed'); } catch (error) { check(error instanceof TypeError, 'constructor refusal'); }
const origin = clock.timeOrigin;
check(Number.isFinite(origin) && Math.abs(Date.now() - origin) < 60000, 'real wall origin');
const first = clock.now();
check(Number.isFinite(first) && first >= 0, 'real relative sample');
const nativeStart = process.hrtime.bigint();
let previous = first;
let reads = 0;
while (Number(process.hrtime.bigint() - nativeStart) < 10000000) {
  const current = clock.now();
  check(current >= previous, 'monotonic samples');
  previous = current;
  reads++;
}
const elapsedNative = Number(process.hrtime.bigint() - nativeStart) / 1e6;
const elapsed = clock.now() - first;
check(reads > 0 && elapsed >= 1 && Math.abs(elapsedNative - elapsed) < 100, 'actual elapsed interval');
const realDateNow = Date.now;
const realHrtime = process.hrtime;
const beforeMutation = clock.now();
try {
  Date.now = () => -123456;
  process.hrtime = () => [0, 0];
  check(clock.now() >= beforeMutation && clock.timeOrigin === origin, 'independent native clock');
}
finally {
  Date.now = realDateNow;
  process.hrtime = realHrtime;
}
check(clock.toJSON().timeOrigin === origin && JSON.parse(JSON.stringify(clock)).timeOrigin === origin, 'origin serialization');
console.log('OK actual native monotonic Performance clock');
