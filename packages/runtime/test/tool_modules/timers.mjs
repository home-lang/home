import timers from 'node:timers';
import alias from 'timers';
import promises, { setTimeout as delay } from 'node:timers/promises';
import promiseAlias from 'timers/promises';

function check(value, message) { if (!value) throw new Error(message); }
check(timers === alias && timers.setTimeout === globalThis.setTimeout && timers.clearTimeout === globalThis.clearTimeout, 'callback aliases');
check(promises === promiseAlias && timers.promises === promises && delay === promises.setTimeout, 'promise aliases');
check((await import('node:timers/promises')).setTimeout === delay, 'dynamic import');
const events = [];
const start = performance.now();
const value = { actual: true };
const settled = new Promise(resolve => {
  const canceled = setTimeout(() => { throw new Error('canceled handle fired'); }, 5);
  clearTimeout(canceled);
  const numeric = setTimeout(() => { throw new Error('canceled numeric id fired'); }, 5);
  clearTimeout(+numeric);
  // Register the later deadline first: a blocking registration or FIFO host
  // queue cannot produce the required order.
  setTimeout(() => { events.push('late'); resolve(); }, 160);
  let early;
  early = setTimeout(function(a, b) {
    check(this === early && a === value && b === 7, 'callback receiver and arguments');
    check(performance.now() - start >= 20, 'early timer fired before its deadline');
    events.push('early');
    Promise.resolve().then(() => events.push('early job'));
    setTimeout(() => events.push('nested'), 5);
  }, 30, value, 7);
  Promise.resolve().then(() => events.push('registration job'));
  events.push('registered');
});
await settled;
check(JSON.stringify(events) === '["registered","registration job","early","early job","nested","late"]', 'registration, deadlines and job checkpoints: ' + JSON.stringify(events));
check(performance.now() - start >= 150, 'late timer resolved too early');
const promiseStart = performance.now();
check(await delay(25, value) === value, 'promise value identity');
check(performance.now() - promiseStart >= 20, 'promise delay was fabricated');
for (const invalid of [null, '2', 1n, {}, []]) {
  const rejected = delay(invalid);
  check(rejected instanceof Promise, 'validation must reject a Promise');
  let reason;
  try { await rejected; } catch (error) { reason = error; }
  check(reason instanceof TypeError && reason.code === 'ERR_INVALID_ARG_TYPE', 'strict promise delay validation');
}
for (const callback of [undefined, null, 'code', 2]) {
  let reason;
  try { setTimeout(callback); } catch (error) { reason = error; }
  check(reason instanceof TypeError && reason.code === 'ERR_INVALID_ARG_TYPE', 'callback validation');
}
const ref = setTimeout(() => { throw new Error('cleared reference timer fired'); }, 1);
check(ref.hasRef() === true && ref.unref() === ref && ref.hasRef() === false && ref.ref() === ref && ref.hasRef() === true, 'reference state');
clearTimeout(ref);
check(await new Promise(resolve => setTimeout(resolve, '2', value)) === value, 'callback delay coercion');
console.log('OK actual timer deadlines, cancellation, callback jobs, values and aliases');
