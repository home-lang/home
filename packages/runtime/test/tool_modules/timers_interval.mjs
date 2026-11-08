import timers, { setInterval as every, clearInterval as cancel } from 'node:timers';
import { setTimeout as delay } from 'node:timers/promises';
function check(value, message) { if (!value) throw new Error(message); }
check(every === globalThis.setInterval && cancel === globalThis.clearInterval && timers.setInterval === every, 'interval aliases');
const times = [];
const value = {};
const start = performance.now();
await new Promise(resolve => {
  const handle = every(function(argument) {
    check(this === handle && argument === value, 'interval receiver/argument');
    times.push(performance.now() - start);
    if (times.length === 3) { cancel(handle); resolve(); }
  }, 15, value);
});
check(times.length === 3 && times[0] >= 10 && times[1] - times[0] >= 10 && times[2] - times[1] >= 10, 'actual recurring deadlines');
await delay(35);
check(times.length === 3, 'self-cancellation');
const numeric = every(() => { throw new Error('numeric interval fired'); }, 5);
cancel(+numeric);
const interval = every(() => { throw new Error('timeout cross-cancel failed'); }, 5);
clearTimeout(interval);
const timeout = setTimeout(() => { throw new Error('interval cross-cancel failed'); }, 5);
cancel(timeout);
const unref = every(() => {}, 10);
check(unref.unref() === unref && !unref.hasRef() && unref.ref() === unref && unref.hasRef(), 'interval references');
cancel(unref);
await delay(15);
console.log('OK actual recurring timer deadlines, self-cancellation, aliases and references');
