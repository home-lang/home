import { types } from 'node:util';
import utilAlias from 'util';
import direct, { isPromise, isProxy } from 'node:util/types';
import directAlias from 'util/types';

function check(value, message) { if (!value) throw new Error(message); }
check(types === direct && direct === directAlias && utilAlias.types === direct, 'native types aliases');
check(isPromise === direct.isPromise && isProxy === direct.isProxy, 'named brand exports');
let touched = 0;
const poisoned = Object.create(Promise.prototype);
Object.defineProperty(poisoned, 'then', { get() { touched += 1; throw new Error('then getter touched'); } });
Object.defineProperty(poisoned, Symbol.toStringTag, { get() { touched += 1; throw new Error('tag getter touched'); } });
const thenable = { get then() { touched += 1; throw new Error('thenable touched'); } };
const handler = new Proxy({}, { get() { touched += 1; throw new Error('proxy handler consulted'); } });
const live = new Proxy({}, handler);
const callable = new Proxy(function() {}, handler);
const revoked = Proxy.revocable({}, handler);
revoked.revoke();
const promise = Promise.resolve(42);
const promisedProxy = new Proxy(promise, handler);
class Subclass extends Promise {}
const subclass = new Subclass(resolve => resolve('subclass'));
const asyncResult = (async () => 42)();
for (const value of [undefined, null, true, 42, 1n, 'text', Symbol('x'), {}, [], function() {}, Promise.prototype, poisoned, thenable, live, callable, revoked.proxy, promisedProxy]) {
  check(isPromise(value) === false, 'only actual Promise slots match');
}
for (const value of [promise, subclass, asyncResult]) check(isPromise(value) === true, 'native Promise/subclass/async return');
for (const value of [live, callable, revoked.proxy, promisedProxy]) check(isProxy(value) === true, 'live/callable/revoked/proxied Promise brand');
for (const value of [undefined, null, true, 42, 1n, 'text', Symbol('x'), {}, [], function() {}, promise, subclass, poisoned, thenable]) check(isProxy(value) === false, 'non-Proxy slots');
check(isPromise() === false && isProxy() === false && touched === 0, 'no arguments, traps or user getters');
let observed = 0;
const reason = {};
let rejected;
process.on('unhandledRejection', (value, target) => {
  if (value === reason && target === rejected) observed += 1;
});
rejected = Promise.reject(reason);
check(isPromise(rejected) && !isProxy(rejected), 'rejected native Promise brand');
setTimeout(() => {
  check(observed === 1 && touched === 0, 'brand inspection neither handles rejection nor invokes user code');
  rejected.catch(() => {});
  console.log('OK native Promise/Proxy brands, revoked proxies, zero traps and unchanged rejection state');
}, 0);
