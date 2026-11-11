// Function mocks execute the supplied code and retain its actual calls/results.
// This is not a test scheduler, assertion library, or module mocking facility.
globalThis.__home_tool_function_mocks_factory = function() {
  'use strict';
  const apply = Reflect.apply, define = Object.defineProperty;
  const descriptor = Object.getOwnPropertyDescriptor, prototype = Object.getPrototypeOf;
  const promise = Promise, resolve = Promise.resolve, reject = Promise.reject;
  const spies = new WeakMap();
  let order = 0;
  function unsupported(message) { const e = new Error(message); e.code = 'ERR_HOME_UNSUPPORTED'; throw e; }
  function callable(fn) { if (typeof fn !== 'function') throw new TypeError('Mock implementation must be a function'); return fn; }
  function create(implementation, restore) {
    let current = implementation, once = [], cursor = 0, state;
    function clear() {
      const history = { calls: [], contexts: [], instances: [], results: [], invocationCallOrder: [] };
      define(history, 'lastCall', { configurable: true, get() { return history.calls[history.calls.length - 1]; } });
      state = history;
    }
    clear();
    function fn(...args) {
      if (new.target) unsupported('Home function mocks do not support construction');
      // Capture the entry state: mockClear/reset during a call must not publish
      // that call's completion into a different, freshly cleared history.
      const entry = state, index = entry.calls.length;
      const result = { type: 'incomplete', value: undefined };
      entry.calls[index] = args; entry.contexts[index] = this;
      entry.invocationCallOrder[index] = ++order; entry.results[index] = result;
      const impl = cursor < once.length ? once[cursor++] : current;
      try {
        const value = impl === undefined ? undefined : apply(impl, this, args);
        result.type = 'return'; result.value = value;
        return value;
      } catch (error) { result.type = 'throw'; result.value = error; throw error; }
    }
    define(fn, 'name', { configurable: true, value: implementation && implementation.name || 'mockConstructor' });
    define(fn, 'length', { configurable: true, value: implementation ? implementation.length : 0 });
    define(fn, 'mock', { get() { return state; } });
    function method(name, body) { define(fn, name, { configurable: true, writable: true, value: body }); }
    method('getMockName', () => fn.name);
    method('getMockImplementation', () => current);
    method('mockClear', () => { clear(); return fn; });
    method('mockReset', () => { clear(); current = undefined; once = []; cursor = 0; return fn; });
    method('mockRestore', () => { clear(); current = undefined; once = []; cursor = 0; if (restore) restore(); return fn; });
    method('mockName', name => { if (typeof name !== 'string') throw new TypeError('Mock name must be a string'); define(fn, 'name', { configurable: true, value: name }); return fn; });
    method('mockImplementation', impl => { current = callable(impl); return fn; });
    method('mockImplementationOnce', impl => { once[once.length] = callable(impl); return fn; });
    method('mockReturnValue', value => { current = () => value; return fn; });
    method('mockReturnValueOnce', value => { once[once.length] = () => value; return fn; });
    method('mockReturnThis', () => { current = function() { return this; }; return fn; });
    method('mockResolvedValue', value => { current = () => apply(resolve, promise, [value]); return fn; });
    method('mockResolvedValueOnce', value => { once[once.length] = () => apply(resolve, promise, [value]); return fn; });
    method('mockRejectedValue', value => { current = () => apply(reject, promise, [value]); return fn; });
    method('mockRejectedValueOnce', value => { once[once.length] = () => apply(reject, promise, [value]); return fn; });
    return fn;
  }
  function mock(implementation) {
    if (implementation !== undefined) callable(implementation);
    return create(implementation);
  }
  function spyOn(target, key, accessType) {
    if (target === null || (typeof target !== 'object' && typeof target !== 'function')) throw new TypeError('Spy target must be an object');
    if (typeof key !== 'string' && typeof key !== 'symbol') throw new TypeError('Spy key must be a string or symbol');
    if (accessType !== undefined) unsupported('Home function spies support data methods, not accessors');
    let found = descriptor(target, key), owner = target;
    const own = found;
    while (!found && (owner = prototype(owner)) !== null) found = descriptor(owner, key);
    if (!found) throw new TypeError('Spy property does not exist');
    if (!('value' in found)) unsupported('Home function spies do not evaluate or replace accessors');
    callable(found.value);
    let entries = spies.get(target);
    if (entries && entries.has(key)) {
      const active = entries.get(key);
      if (found.value === active) return active;
      unsupported('An active Home spy was replaced externally');
    }
    // Preserve the complete own descriptor, or remove the shadow when the
    // method was inherited. No getter is invoked to discover the method.
    let restored = false;
    const fn = create(found.value, () => {
      if (restored) return;
      if (own) define(target, key, own);
      else if (!delete target[key]) throw new TypeError('Cannot restore inherited spy');
      restored = true; entries.delete(key);
    });
    define(target, key, own ? { ...own, value: fn } : { configurable: true, writable: true, enumerable: found.enumerable, value: fn });
    if (!entries) { entries = new Map(); spies.set(target, entries); }
    entries.set(key, fn);
    return fn;
  }
  return { mock, spyOn };
};
