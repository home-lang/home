(function() {
  'use strict';
  const sample = globalThis.__home_tool_monotonic_millis;
  delete globalThis.__home_tool_monotonic_millis;
  const finite = Number.isFinite;
  function read() {
    const value = sample();
    if (typeof value !== 'number' || !finite(value)) throw new Error('Home monotonic clock failed');
    return value;
  }
  const timeOrigin = Date.now();
  const start = read();
  const token = {};
  let performance;
  function receiver(value) {
    if (value !== performance) {
      const error = new TypeError('Value of this must be a Performance instance');
      error.code = 'ERR_INVALID_THIS';
      throw error;
    }
  }
  class Performance {
    constructor(secret) {
      if (secret !== token) throw new TypeError('Illegal constructor');
    }
    now() {
      receiver(this);
      return read() - start;
    }
    get timeOrigin() {
      receiver(this);
      return timeOrigin;
    }
    toJSON() {
      receiver(this);
      // Only actual supported measurements are serialized. Node timing and
      // event-loop telemetry are absent, rather than populated with zeros.
      return { timeOrigin };
    }
  }
  Object.defineProperty(Performance.prototype, Symbol.toStringTag, { value: 'Performance', configurable: true });
  performance = new Performance(token);
  globalThis.performance = performance;
  globalThis.Performance = Performance;
})();
