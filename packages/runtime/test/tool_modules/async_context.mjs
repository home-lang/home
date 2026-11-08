import hooks, { AsyncLocalStorage } from 'node:async_hooks';
import alias from 'async_hooks';
import process from 'node:process';
function check(value, message) { if (!value) throw new Error(message); }
check(hooks === alias && hooks.AsyncLocalStorage === AsyncLocalStorage, 'module identity');
const a = new AsyncLocalStorage(); const b = new AsyncLocalStorage();
check(a.getStore() === undefined && b.getStore() === undefined, 'initial scope');
const marker = { id: 7 }; const reason = new Error('identity');
check(a.run(marker, (x, y) => { check(a.getStore() === marker, 'store identity'); return x + y; }, 8, 9) === 17, 'arguments/result');
check(a.getStore() === undefined, 'sync restore');
a.run('outer', () => {
  try { a.run('inner', () => { check(a.getStore() === 'inner', 'nested'); throw reason; }); } catch (error) { check(error === reason, 'throw identity'); }
  check(a.getStore() === 'outer', 'abrupt restore');
  b.run('other', () => {
    check(a.exit(() => { check(a.getStore() === undefined && b.getStore() === 'other', 'exit isolation'); return 19; }) === 19, 'exit return');
    check(a.getStore() === 'outer' && b.getStore() === 'other', 'exit restore');
  });
  a.enterWith('entered'); check(a.getStore() === 'entered', 'enterWith');
});
check(a.getStore() === undefined && b.getStore() === undefined, 'independent restore');
let release; const barrier = new Promise(resolve => { release = resolve; });
const first = a.run('first', async () => { await barrier; check(a.getStore() === 'first', 'first await'); await Promise.resolve(); return a.getStore(); });
const second = a.run('second', async () => { release(); await Promise.resolve(); check(a.getStore() === 'second', 'second await'); return a.getStore(); });
check(a.getStore() === undefined, 'async caller restore');
check(JSON.stringify(await Promise.all([first, second])) === '["first","second"]', 'overlapping contexts');
const callbacks = await a.run('callbacks', () => Promise.all([
  new Promise(resolve => queueMicrotask(() => resolve(a.getStore()))),
  new Promise(resolve => process.nextTick(() => resolve(a.getStore()))),
  Promise.resolve().then(() => a.getStore()),
]));
check(JSON.stringify(callbacks) === '["callbacks","callbacks","callbacks"]', 'actual callback capture');
const exited = await a.run('outside-exit', () => b.run('kept', () => a.exit(() => Promise.resolve().then(() => [a.getStore(), b.getStore()]))));
check(exited[0] === undefined && exited[1] === 'kept', 'async exit isolation');
let settle; const thenableSeen = [];
const source = a.run('create', () => new Promise(resolve => { settle = resolve; }));
const tail = a.run('register', () => source.then(() => thenableSeen.push(a.getStore())));
a.run('resolve', () => settle({ then(done) { thenableSeen.push(a.getStore()); done(1); } }));
await tail; check(JSON.stringify(thenableSeen) === '["resolve","register"]', 'thenable and reaction capture');
const custom = Promise.resolve(1); let speciesSeen;
Object.defineProperty(custom, 'constructor', { value: { [Symbol.species]: function(executor) { return a.run('species', () => new Promise(executor)); } } });
await a.run('register-species', () => custom.then(() => { speciesSeen = a.getStore(); }));
check(speciesSeen === 'register-species', 'species capture');
const changes = await a.run('original', () => Promise.all([
  Promise.resolve().then(() => { a.enterWith('changed'); return Promise.resolve().then(() => a.getStore()); }),
  Promise.resolve().then(() => a.getStore()),
]));
check(JSON.stringify(changes) === '["changed","original"]', 'job-local enterWith');
for (const value of [undefined, null, false, 0]) check(a.run(value, () => a.getStore()) === value, 'primitive store');
try { AsyncLocalStorage.prototype.getStore.call({}); throw new Error('forged receiver'); } catch (error) { check(error instanceof TypeError, 'receiver brand'); }
check(a.getStore() === undefined && b.getStore() === undefined, 'final restore');
console.log('OK actual async context across await, callbacks, siblings, exit and species');
