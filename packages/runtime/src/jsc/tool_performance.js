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
  const entryState = new WeakMap();
  let marks = [];
  let performance;
  function invalid(code, message) {
    const error = new TypeError(message);
    error.code = code;
    throw error;
  }
  function unsupported(message) {
    const error = new Error(message);
    error.code = 'ERR_HOME_UNSUPPORTED';
    throw error;
  }
  function text(value) {
    if (typeof value === 'symbol') throw new TypeError('Cannot convert a Symbol value to a string');
    return String(value);
  }
  function entry(value) {
    const data = entryState.get(value);
    if (!data) invalid('ERR_INVALID_THIS', 'Value of this must be a PerformanceEntry');
    return data;
  }
  class PerformanceEntry {
    constructor(secret, data) {
      if (secret !== token) invalid('ERR_ILLEGAL_CONSTRUCTOR', 'Illegal constructor');
      entryState.set(this, data);
    }
    get name() { return entry(this).name; }
    get entryType() { return entry(this).entryType; }
    get startTime() { return entry(this).startTime; }
    get duration() { return entry(this).duration; }
    toJSON() {
      const data = entry(this);
      return { name: data.name, entryType: data.entryType, startTime: data.startTime, duration: data.duration, detail: data.detail };
    }
  }
  class PerformanceMark extends PerformanceEntry {
    constructor(name, options) {
      if (arguments.length === 0) invalid('ERR_MISSING_ARGS', 'The name argument must be specified');
      name = text(name);
      if (['nodeStart', 'v8Start', 'environment', 'loopStart', 'loopExit', 'bootstrapComplete'].includes(name)) invalid('ERR_INVALID_ARG_VALUE', 'Reserved native timing name');
      if (options != null && typeof options !== 'object') invalid('ERR_INVALID_ARG_TYPE', 'Mark options must be an object');
      let timestamp = options == null ? undefined : options.startTime;
      if (timestamp == null) timestamp = read() - start;
      if (typeof timestamp !== 'number') invalid('ERR_INVALID_ARG_TYPE', 'Mark startTime must be a number');
      if (timestamp < 0) invalid('ERR_PERFORMANCE_INVALID_TIMESTAMP', 'Negative mark timestamp');
      if (!finite(timestamp)) unsupported('Home marks currently require finite timestamps');
      const suppliedDetail = options == null ? undefined : options.detail;
      const detail = suppliedDetail === undefined ? null : suppliedDetail;
      // Primitive details clone by value. Do not retain caller objects in
      // place of the structured clone required by User Timing.
      if ((typeof detail === 'object' && detail !== null) || typeof detail === 'function' || typeof detail === 'symbol') unsupported('Home mark details currently support cloneable primitive values only');
      super(token, { name: name, entryType: 'mark', startTime: timestamp, duration: 0, detail: detail });
    }
    get detail() { return entry(this).detail; }
  }
  for (const name of ['name', 'entryType', 'startTime', 'duration']) {
    const descriptor = Object.getOwnPropertyDescriptor(PerformanceEntry.prototype, name);
    descriptor.enumerable = true;
    Object.defineProperty(PerformanceEntry.prototype, name, descriptor);
  }
  const detailDescriptor = Object.getOwnPropertyDescriptor(PerformanceMark.prototype, 'detail');
  detailDescriptor.enumerable = true;
  Object.defineProperty(PerformanceMark.prototype, 'detail', detailDescriptor);
  Object.defineProperty(PerformanceEntry.prototype, Symbol.toStringTag, { value: 'PerformanceEntry', configurable: true });
  Object.defineProperty(PerformanceMark.prototype, Symbol.toStringTag, { value: 'PerformanceMark', configurable: true });
  function entries(name, type) {
    return marks.filter(mark => (name === undefined || entry(mark).name === name) && (type === undefined || entry(mark).entryType === type)).sort((left, right) => entry(left).startTime - entry(right).startTime);
  }
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
    mark(name, options) {
      receiver(this);
      if (arguments.length === 0) invalid('ERR_MISSING_ARGS', 'The name argument must be specified');
      const mark = new PerformanceMark(name, options);
      marks.push(mark);
      return mark;
    }
    getEntries() {
      receiver(this);
      return entries();
    }
    getEntriesByName(name, type) {
      receiver(this);
      if (arguments.length === 0) invalid('ERR_MISSING_ARGS', 'The name argument must be specified');
      return entries(text(name), type === undefined ? undefined : text(type));
    }
    getEntriesByType(type) {
      receiver(this);
      if (arguments.length === 0) invalid('ERR_MISSING_ARGS', 'The type argument must be specified');
      return entries(undefined, text(type));
    }
    clearMarks(name) {
      receiver(this);
      if (name === undefined) marks = [];
      else {
        name = text(name);
        marks = marks.filter(mark => entry(mark).name !== name);
      }
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
  globalThis.PerformanceEntry = PerformanceEntry;
  globalThis.PerformanceMark = PerformanceMark;
})();
