globalThis.__home_tool_async_hooks_factory = function(getContext, swapContext) {
  'use strict';
  const states = new WeakMap();
  const nodes = new WeakSet();
  function stateFor(owner) {
    const state = states.get(owner);
    if (!state) throw new TypeError('Invalid AsyncLocalStorage receiver');
    return state;
  }
  function callable(callback) {
    if (typeof callback !== 'function') {
      const error = new TypeError('AsyncLocalStorage callback must be a function');
      error.code = 'ERR_INVALID_ARG_TYPE';
      throw error;
    }
  }
  function immutableNode(owner, store, parent) {
    const captured = Object.freeze({ owner, store, parent });
    nodes.add(captured);
    return captured;
  }
  function node(owner, store) {
    const original = getContext();
    let current = original;
    const kept = [];
    let replaced = false;
    while (current && typeof current === 'object' && nodes.has(current)) {
      if (current.owner === owner) replaced = true;
      else kept.push(current);
      current = current.parent;
    }
    // Captured jobs keep their old immutable snapshots. The current context
    // must not retain every store replaced by repeated enterWith calls.
    if (replaced) {
      for (let index = kept.length - 1; index >= 0; index--)
        current = immutableNode(kept[index].owner, kept[index].store, current);
    }
    else current = original;
    return immutableNode(owner, store, current);
  }
  class AsyncLocalStorage {
    constructor(options = undefined) {
      if (options !== undefined) {
        const error = new Error('Home AsyncLocalStorage constructor options are not implemented');
        error.code = 'ERR_HOME_UNSUPPORTED';
        throw error;
      }
      states.set(this, {});
    }
    getStore() {
      stateFor(this);
      let current = getContext();
      while (current && typeof current === 'object' && nodes.has(current)) {
        if (current.owner === this) return current.store;
        current = current.parent;
      }
      return undefined;
    }
    run(store, callback, ...args) {
      stateFor(this);
      callable(callback);
      const previous = swapContext(node(this, store));
      try {
        return Reflect.apply(callback, null, args);
      }
      finally {
        swapContext(previous);
      }
    }
    enterWith(store) {
      stateFor(this);
      swapContext(node(this, store));
    }
    exit(callback, ...args) {
      stateFor(this);
      callable(callback);
      const previous = swapContext(node(this, undefined));
      try {
        return Reflect.apply(callback, null, args);
      }
      finally {
        swapContext(previous);
      }
    }
    disable() {
      stateFor(this);
      const error = new Error('Home AsyncLocalStorage disable and async resource lifecycle hooks are not implemented');
      error.code = 'ERR_HOME_UNSUPPORTED';
      throw error;
    }
  }
  return { AsyncLocalStorage };
};
