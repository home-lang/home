// Timers backed by the host's kernel event queue, not Promise jobs.
globalThis.__home_tool_timers_factory = function(schedule, control, getContext, swapContext) {
  'use strict';
  const states = new WeakMap();
  let warnedNegative = false;
  let warnedNaN = false;
  function invalid(message) {
    const error = new TypeError(message);
    error.code = 'ERR_INVALID_ARG_TYPE';
    throw error;
  }
  function unsupported(message) {
    const error = new Error(message);
    error.code = 'ERR_HOME_UNSUPPORTED';
    throw error;
  }
  function duration(value) {
    if (value === undefined) value = 1;
    const number = +value;
    if (number > 2147483647) {
      process.emitWarning(`${number} does not fit into a 32-bit signed integer.\nTimeout duration was set to 1.`, { type: 'TimeoutOverflowWarning' });
    }
    else if (number < 0 && !warnedNegative) {
      warnedNegative = true;
      process.emitWarning(`${number} is a negative number.\nTimeout duration was set to 1.`, { type: 'TimeoutNegativeWarning' });
    }
    else if (Number.isNaN(number) && !warnedNaN) {
      warnedNaN = true;
      process.emitWarning(`${number} is not a number.\nTimeout duration was set to 1.`, { type: 'TimeoutNaNWarning' });
    }
    return Number.isFinite(number) && number >= 1 && number <= 2147483647 ? Math.trunc(number) : 1;
  }
  function stateFor(handle) {
    const state = states.get(handle);
    if (!state) throw new TypeError('Invalid Timeout receiver');
    return state;
  }
  class Timeout {
    ref() {
      const state = stateFor(this);
      control(true, state.id, true);
      state.refed = true;
      return this;
    }
    unref() {
      const state = stateFor(this);
      control(true, state.id, false);
      state.refed = false;
      return this;
    }
    hasRef() {
      return stateFor(this).refed;
    }
    [Symbol.toPrimitive]() {
      return stateFor(this).id;
    }
  }
  function register(callback, after, args, repeat) {
    if (typeof callback !== 'function') invalid('Timer callback must be a function');
    const milliseconds = duration(after);
    const handle = new Timeout();
    const hasContext = typeof getContext === 'function' && typeof swapContext === 'function';
    const context = hasContext ? getContext() : undefined;
    // The engine hooks require active JS execution. This protected closure
    // retains the actual engine snapshot, not a parallel JS context store.
    const id = schedule(function(uncaught) {
      const previous = hasContext ? swapContext(context) : undefined;
      try {
        try {
          Reflect.apply(callback, handle, args);
        }
        catch (error) {
          uncaught(error);
        }
      }
      finally {
        if (hasContext) swapContext(previous);
      }
    }, milliseconds, true, repeat);
    if (!(id > 0)) throw new Error('Native timer registration failed');
    states.set(handle, { id, refed: true });
    return handle;
  }
  function setTimeout(callback, after, ...args) {
    return register(callback, after, args, false);
  }
  function setInterval(callback, after, ...args) {
    return register(callback, after, args, true);
  }
  function clearTimeout(handle) {
    const state = handle !== null && typeof handle === 'object' ? states.get(handle) : undefined;
    const id = state ? state.id : typeof handle === 'number' || typeof handle === 'string' ? +handle : NaN;
    if (Number.isSafeInteger(id) && id > 0) control(false, id);
  }
  function clearInterval(handle) {
    clearTimeout(handle);
  }
  const callbackTimeout = setTimeout;
  const promiseTimeout = function setTimeout(after, value, options = undefined) {
    return new Promise(function(resolve) {
      if (after !== undefined && typeof after !== 'number') invalid('Timer delay must be a number');
      if (options === undefined) options = {};
      if (options === null || typeof options !== 'object' || Array.isArray(options)) invalid('Timer options must be an object');
      const ref = options.ref;
      const signal = options.signal;
      if (ref !== undefined && typeof ref !== 'boolean') invalid('Timer ref must be a boolean');
      if (signal !== undefined) unsupported('Home timer AbortSignal integration is not implemented');
      for (const key of Object.keys(options)) {
        if (key !== 'ref' && key !== 'signal') unsupported(`Unsupported timer option: ${key}`);
      }
      const handle = callbackTimeout(resolve, after, value);
      if (ref === false) handle.unref();
    });
  };
  return { setTimeout, clearTimeout, setInterval, clearInterval, promises: { setTimeout: promiseTimeout } };
};
