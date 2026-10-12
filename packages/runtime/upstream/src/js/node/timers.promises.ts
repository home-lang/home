// Hardcoded module "node:timers/promises"
// https://github.com/niksy/isomorphic-timers-promises/blob/master/index.js

const { validateBoolean, validateAbortSignal, validateObject, validateNumber } = require("internal/validators");

const { addAbortListener } = require("internal/abort_listener");
const setImmediateGlobal = globalThis.setImmediate;
const setTimeoutGlobal = globalThis.setTimeout;
const setIntervalGlobal = globalThis.setInterval;

function setTimeout(after, value, options = {}) {
  const arguments_ = [].concat(value ?? []);
  try {
    // If after is a number, but an invalid one (too big, Infinity, NaN), we only want to emit a
    // warning, not throw an error. So we can't call validateNumber as that will throw if the number
    // is outside of a given range.
    if (after !== undefined && typeof after != "number") {
      validateNumber(after, "delay");
    }
  } catch (error) {
    return Promise.$reject(error);
  }
  try {
    validateObject(options, "options");
  } catch (error) {
    return Promise.$reject(error);
  }
  const { signal, ref: reference = true } = options;
  try {
    validateAbortSignal(signal, "options.signal");
  } catch (error) {
    return Promise.$reject(error);
  }
  try {
    validateBoolean(reference, "options.ref");
  } catch (error) {
    return Promise.$reject(error);
  }
  if (signal?.aborted) {
    return Promise.$reject($makeAbortError(undefined, { cause: signal.reason }));
  }
  let onCancel, abortSubscription;
  const returnValue = new Promise((resolve, reject) => {
    const timeout = setTimeoutGlobal(() => resolve(value), after, ...arguments_);
    if (!reference) {
      timeout?.unref?.();
    }
    if (signal) {
      onCancel = () => {
        clearTimeout(timeout);
        reject($makeAbortError(undefined, { cause: signal.reason }));
      };
      abortSubscription = addAbortListener(signal, onCancel);
    }
  });
  return typeof onCancel !== "undefined"
    ? returnValue.finally(() => abortSubscription[Symbol.dispose]())
    : returnValue;
}

function setImmediate(value, options = {}) {
  try {
    validateObject(options, "options");
  } catch (error) {
    return Promise.$reject(error);
  }
  const { signal, ref: reference = true } = options;
  try {
    validateAbortSignal(signal, "options.signal");
  } catch (error) {
    return Promise.$reject(error);
  }
  try {
    validateBoolean(reference, "options.ref");
  } catch (error) {
    return Promise.$reject(error);
  }
  if (signal?.aborted) {
    return Promise.$reject($makeAbortError(undefined, { cause: signal.reason }));
  }
  let onCancel, abortSubscription;
  const returnValue = new Promise((resolve, reject) => {
    const immediate = setImmediateGlobal(() => resolve(value));
    if (!reference) {
      immediate?.unref?.();
    }
    if (signal) {
      onCancel = () => {
        clearImmediate(immediate);
        reject($makeAbortError(undefined, { cause: signal.reason }));
      };
      abortSubscription = addAbortListener(signal, onCancel);
    }
  });
  return typeof onCancel !== "undefined"
    ? returnValue.finally(() => abortSubscription[Symbol.dispose]())
    : returnValue;
}

async function* setInterval(after, value, options = {}) {
  if (after !== undefined && typeof after !== "number") validateNumber(after, "delay");
  validateObject(options, "options");
  const { signal, ref: reference = true } = options;
  validateAbortSignal(signal, "options.signal");
  validateBoolean(reference, "options.ref");
  if (signal?.aborted) throw $makeAbortError(undefined, { cause: signal.reason });
  let notYielded = 0;
  let wake;
  let interval, abortSubscription;
  try {
    interval = setIntervalGlobal(() => {
      notYielded++;
      if (wake) {
        wake();
        wake = undefined;
      }
    }, after);
    if (!reference) interval?.unref?.();
    if (signal) {
      abortSubscription = addAbortListener(signal, () => {
        clearInterval(interval);
        if (wake) {
          wake(Promise.$reject($makeAbortError(undefined, { cause: signal.reason })));
          wake = undefined;
        }
      });
    }
    while (!signal?.aborted) {
      if (notYielded === 0) {
        await new Promise(resolve => {
          wake = resolve;
        });
      }
      for (; notYielded > 0; notYielded--) yield value;
    }
    throw $makeAbortError(undefined, { cause: signal?.reason });
  }
  finally {
    clearInterval(interval);
    abortSubscription?.[Symbol.dispose]();
    wake = undefined;
  }
}

export default {
  setTimeout,
  setImmediate,
  setInterval,
  scheduler: {
    wait: (delay, options) => setTimeout(delay, undefined, options),
    yield: setImmediate,
  },
};
