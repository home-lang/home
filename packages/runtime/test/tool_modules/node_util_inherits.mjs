import util, { inherits } from 'node:util';
import { createRequire } from 'node:module';
import { EventEmitter } from 'node:events';
const failures = [], labels = [];
function assert(value, label) { if (!value) throw new Error(label); }
function throws(fn) { let error; try { fn(); } catch (caught) { error = caught; } assert(error, 'expected failure'); return error; }
function check(label, fn) { try { fn(); labels.push(label); } catch (error) { failures.push({ label, message: String(error), code: error.code }); } }
check('named, default and CJS exports share the actual helper', () => {
  const requireHere = createRequire(import.meta.url);
  assert(requireHere('util') === util && requireHere('node:util') === util && util.inherits === inherits && inherits.length === 2, 'module identity');
});
check('real constructor calls and inherited methods', () => {
  function Parent(value) { this.value = value; }
  Parent.prototype.read = function() { return this.value; };
  function Child(value) { Parent.call(this, value); }
  assert(inherits(Child, Parent) === undefined, 'return value');
  const value = new Child(42);
  assert(value instanceof Child && value instanceof Parent && value.read() === 42 && value.constructor === Child, 'real instance chain');
});
check('super property has Node descriptor flags', () => {
  function Parent() {} function Child() {}
  inherits(Child, Parent);
  const d = Object.getOwnPropertyDescriptor(Child, 'super_');
  assert(d.value === Parent && d.writable && d.configurable && !d.enumerable && !Object.keys(Child).includes('super_'), 'descriptor');
  Child.super_ = 42; assert(Child.super_ === 42 && delete Child.super_, 'mutable and deletable');
});
check('constructor statics and prototype identity are retained', () => {
  function Parent() {} Parent.staticValue = 1;
  function Child() {} const proto = Child.prototype, ctorProto = Object.getPrototypeOf(Child), symbol = Symbol('own');
  proto.own = 42; proto[symbol] = 'symbol';
  inherits(Child, Parent);
  assert(Child.prototype === proto && proto.own === 42 && proto[symbol] === 'symbol' && Object.getPrototypeOf(Child) === ctorProto && Child.staticValue === undefined, 'identity and statics');
});
check('plain objects with prototype fields are accepted', () => {
  const parent = { prototype: { value: 42 } }, child = { prototype: {} };
  inherits(child, parent);
  assert(child.super_ === parent && child.prototype.value === 42 && Object.getPrototypeOf(child.prototype) === parent.prototype, 'object constructor profile');
});
check('null parent prototype is an actual null chain', () => {
  const parent = { prototype: null }; function Child() {}
  inherits(Child, parent);
  assert(Object.getPrototypeOf(Child.prototype) === null && Child.super_ === parent, 'null prototype');
});
check('missing constructors fail before reading parent accessors', () => {
  let reads = 0; const parent = { get prototype() { reads++; return {}; } };
  for (const value of [undefined, null]) assert(throws(() => inherits(value, parent)).code === 'ERR_INVALID_ARG_TYPE', 'invalid ctor');
  assert(reads === 0, 'validation ordering');
});
check('missing parent does not mutate the child', () => {
  function Child() {} const proto = Object.getPrototypeOf(Child.prototype);
  for (const value of [undefined, null]) assert(throws(() => inherits(Child, value)).code === 'ERR_INVALID_ARG_TYPE', 'invalid parent');
  assert(!Object.hasOwn(Child, 'super_') && Object.getPrototypeOf(Child.prototype) === proto, 'no premature mutation');
});
check('missing parent prototype fails before defining super', () => {
  function Child() {}
  for (const value of [{}, () => {}]) assert(throws(() => inherits(Child, value)).code === 'ERR_INVALID_ARG_TYPE', 'undefined prototype');
  assert(!Object.hasOwn(Child, 'super_'), 'no mutation');
});
check('missing child prototype throws after publishing super', () => {
  const Child = () => {}; function Parent() {}
  assert(throws(() => inherits(Child, Parent)) instanceof TypeError && Child.super_ === Parent, 'partial mutation');
});
check('invalid parent prototype throws after publishing super', () => {
  function Child() {} const parent = { prototype: 42 }, before = Object.getPrototypeOf(Child.prototype);
  assert(throws(() => inherits(Child, parent)) instanceof TypeError && Child.super_ === parent && Object.getPrototypeOf(Child.prototype) === before, 'native prototype validation');
});
check('nonextensible constructor fails before prototype mutation', () => {
  function Child() {} function Parent() {} const before = Object.getPrototypeOf(Child.prototype); Object.preventExtensions(Child);
  assert(throws(() => inherits(Child, Parent)) instanceof TypeError && !Object.hasOwn(Child, 'super_') && Object.getPrototypeOf(Child.prototype) === before, 'definition refusal');
});
check('nonextensible prototype retains the prior super write', () => {
  function Child() {} function Parent() {} const before = Object.getPrototypeOf(Child.prototype); Object.preventExtensions(Child.prototype);
  assert(throws(() => inherits(Child, Parent)) instanceof TypeError && Child.super_ === Parent && Object.getPrototypeOf(Child.prototype) === before, 'native mutation refusal');
});
check('nonconfigurable super descriptor is not overwritten', () => {
  function Child() {} function Parent() {} Object.defineProperty(Child, 'super_', { value: 42 }); const before = Object.getPrototypeOf(Child.prototype);
  assert(throws(() => inherits(Child, Parent)) instanceof TypeError && Child.super_ === 42 && Object.getPrototypeOf(Child.prototype) === before, 'descriptor refusal');
});
check('parent accessor ordering surrounds the super write', () => {
  function Child() {} const proto = {}, events = [], parent = { get prototype() { events.push(Object.hasOwn(Child, 'super_')); return proto; } };
  inherits(Child, parent);
  assert(JSON.stringify(events) === '[false,true]' && Object.getPrototypeOf(Child.prototype) === proto, 'access ordering');
});
check('undefined parent getter is read again during validation', () => {
  let count = 0; const parent = { get prototype() { count++; return undefined; } }; function Child() {}
  assert(throws(() => inherits(Child, parent)).code === 'ERR_INVALID_ARG_TYPE' && count === 2 && !Object.hasOwn(Child, 'super_'), 'error getter count');
});
check('captured intrinsics survive public Object replacement', () => {
  const define = Object.defineProperty, set = Object.setPrototypeOf;
  function Parent() {} function Child() {}
  try {
    Object.defineProperty = Object.setPrototypeOf = function() { throw new Error('mutated global intrinsic'); };
    inherits(Child, Parent);
  } finally { Object.defineProperty = define; Object.setPrototypeOf = set; }
  assert(Child.super_ === Parent && Object.getPrototypeOf(Child.prototype) === Parent.prototype, 'captured primordials');
});
check('legacy EventEmitter subclass retains real listener state', () => {
  function Legacy() { EventEmitter.call(this); }
  inherits(Legacy, EventEmitter);
  const value = new Legacy(); let count = 0;
  value.on('actual', function(n) { assert(this === value, 'event receiver'); count += n; });
  assert(value.emit('actual', 42) && count === 42 && value instanceof EventEmitter && value.listenerCount('actual') === 1, 'real listener dispatch');
});
if (labels.length + failures.length !== 18) throw new Error('wrong inherits denominator');
console.log('NODE UTIL INHERITS RESULTS ' + JSON.stringify({ checks: 18, passed: labels.length, failures }));
if (failures.length) throw new Error('util.inherits contract failed');
console.log('NODE UTIL INHERITS 18 CHECKS OK');
