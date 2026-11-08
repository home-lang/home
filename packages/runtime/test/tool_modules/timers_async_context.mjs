import { AsyncLocalStorage } from 'node:async_hooks';
import { setTimeout as delay } from 'node:timers/promises';

function check(value, message) { if (!value) throw new Error(message); }
const scope = new AsyncLocalStorage();
const events = [];
const first = scope.run('first', () => new Promise(resolve => setTimeout(() => {
  check(scope.getStore() === 'first', 'first callback snapshot');
  events.push('first');
  Promise.resolve().then(() => { check(scope.getStore() === 'first', 'callback job snapshot'); events.push('job'); });
  scope.enterWith('nested');
  setTimeout(() => { check(scope.getStore() === 'nested', 'nested registration snapshot'); events.push('nested'); resolve(); }, 5);
}, 5)));
const second = scope.run('second', async () => {
  check(await delay(30, 'value') === 'value', 'promise delay');
  check(scope.getStore() === 'second', 'promise continuation snapshot');
  events.push('second');
});
check(scope.getStore() === undefined, 'registration must restore caller');
await Promise.all([first, second]);
check(scope.getStore() === undefined, 'timer dispatch must restore caller');
check(JSON.stringify(events) === '["first","job","nested","second"]', 'isolated timer contexts');
const reason = {};
process.once('uncaughtExceptionMonitor', (error, origin) => {
  check(error === reason && origin === 'uncaughtException' && scope.getStore() === 'throwing', 'uncaught monitor context and identity');
  events.push('monitor');
});
process.once('uncaughtException', (error, origin) => {
  check(error === reason && origin === 'uncaughtException' && scope.getStore() === 'throwing', 'uncaught handler context and identity');
  events.push('handled');
});
scope.run('throwing', () => setTimeout(() => { throw reason; }, 1));
await delay(15);
check(events.slice(-2).join(',') === 'monitor,handled' && scope.getStore() === undefined, 'handled throw restores context');
console.log('OK actual timer context across callbacks, nested tasks, jobs, awaits and exceptions');
