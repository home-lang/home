const { SafeArrayIterator } = require("internal/primordials");

const ObjectFreeze = Object.freeze;

class NotImplementedError extends Error {
  code: string;
  constructor(feature: string, issue?: number, extra?: string) {
    super(
      feature +
        " is not yet implemented in Bun." +
        (issue ? " Track the status & thumbs up the issue: https://github.com/oven-sh/bun/issues/" + issue : "") +
        (extra ? ". " + extra : ""),
    );
    this.name = "NotImplementedError";
    this.code = "ERR_NOT_IMPLEMENTED";

    // in the definition so that it isn't bundled unless used
    hideFromStack(NotImplementedError);
  }
  get ["constructor"]() {
    return Error;
  }
}

function throwNotImplemented(feature: string, issue?: number, extra?: string): never {
  // in the definition so that it isn't bundled unless used
  hideFromStack(throwNotImplemented);

  throw new NotImplementedError(feature, issue, extra);
}

function hideFromStack(...fns: Function[]) {
  for (const fn of fns) {
    Object.defineProperty(fn, "name", {
      value: "::bunternal::",
    });
  }
}

let warned: Set<string>;
function warnNotImplementedOnce(feature: string, issue?: number) {
  if (!warned) {
    warned = new Set();
  }

  if (warned.has(feature)) {
    return;
  }
  warned.add(feature);
  console.warn(new NotImplementedError(feature, issue));
}

let util: typeof import("node:util");
class ExceptionWithHostPort extends Error {
  errno: number;
  syscall: string;
  port?: number;
  address: string;

  constructor(err: number, syscall: string, address: string, port?: number) {
    // TODO(joyeecheung): We have to use the type-checked
    // getSystemErrorName(err) to guard against invalid arguments from users.
    // This can be replaced with [ code ] = errmap.get(err) when this method
    // is no longer exposed to user land.
    util ??= require("node:util");
    const code = util.getSystemErrorName(err);
    let details = "";
    if (port && port > 0) {
      details = ` ${address}:${port}`;
    } else if (address) {
      details = ` ${address}`;
    }

    super(`${syscall} ${code}${details}`);

    this.errno = err;
    this.code = code;
    this.syscall = syscall;
    this.address = address;
    if (port) {
      this.port = port;
    }
  }
  get ["constructor"]() {
    return Error;
  }
}

class NodeAggregateError extends AggregateError {
  constructor(errors, message) {
    super(new SafeArrayIterator(errors), message);
    this.code = errors[0]?.code;
  }
  get ["constructor"]() {
    return AggregateError;
  }
}

class ConnResetException extends Error {
  constructor(msg) {
    super(msg);
    this.code = "ECONNRESET";
  }
  get ["constructor"]() {
    return Error;
  }
}

class ErrnoException extends Error {
  errno: number;
  syscall: string;

  constructor(err, syscall, original) {
    util ??= require("node:util");
    const code = util.getSystemErrorName(err);
    const message = original ? `${syscall} ${code} ${original}` : `${syscall} ${code}`;

    super(message);

    this.errno = err;
    this.code = code;
    this.syscall = syscall;
  }
  get ["constructor"]() {
    return Error;
  }
}

function once(callback, { preserveReturnValue = false } = kEmptyObject) {
  let called = false;
  let returnValue;
  return function (...args) {
    if (called) return returnValue;
    called = true;
    const result = callback.$apply(this, args);
    returnValue = preserveReturnValue ? result : undefined;
    return result;
  };
}

const kEmptyObject = ObjectFreeze(Object.create(null));

function getLazy<T>(initializer: () => T) {
  let value: T;
  let initialized = false;
  return function () {
    if (initialized) return value;
    value = initializer();
    initialized = true;
    return value;
  };
}

// ─── Node-style performance-entry observation ────────────────────────────────
// For entry types the native (WebCore) PerformanceObserver does not implement
// ('net', 'dns', ...). Mirrors lib/internal/perf/observe.js: producers check
// hasObserver() before doing any work, startPerf() stashes a context on the
// producing object, and stopPerf() builds a plain entry and dispatches it to
// the registered observers on a fresh tick.
// https://github.com/nodejs/node/blob/v25.2.1/lib/internal/perf/observe.js

const observerCounts = new Map();
const kObservers = new Set();

/** Entry types routed through this JS-side registry instead of the native observer. */
const kNodeEntryTypes = new Set(["net", "dns", "http", "resource"]);

function hasObserver(type) {
  return (observerCounts.get(type) ?? 0) > 0;
}

function startPerf(target, key, context) {
  context.startTime = performance.now();
  target[key] = context;
}

function stopPerf(target, key, context) {
  const ctx = target[key];
  if (!ctx) {
    return;
  }
  target[key] = undefined;
  const startTime = ctx.startTime;
  const entry = {
    name: ctx.name,
    entryType: ctx.type,
    startTime,
    duration: performance.now() - startTime,
    // Node.js merges the detail recorded at startPerf() with the detail
    // passed to stopPerf() (e.g. http entries carry both req and res).
    detail:
      ctx.detail !== undefined || context?.detail !== undefined ? { ...ctx.detail, ...context?.detail } : undefined,
  };
  for (const observer of kObservers) {
    observer.bufferEntry(entry);
  }
}

/**
 * One registered observer of node-only entry types. The PerformanceObserver
 * wrapper in node:perf_hooks owns one of these when it observes such a type.
 */
class NodeEntryObserver {
  callback;
  owner;
  types = new Set();
  buffer = [];
  scheduled = false;
  generation = 0;

  constructor(callback, owner) {
    this.callback = callback;
    this.owner = owner;
  }

  observe(types) {
    for (const type of this.types) {
      observerCounts.set(type, (observerCounts.get(type) ?? 1) - 1);
    }
    this.types = new Set(types);
    for (const type of this.types) {
      observerCounts.set(type, (observerCounts.get(type) ?? 0) + 1);
    }
    kObservers.add(this);
  }

  disconnect() {
    for (const type of this.types) {
      observerCounts.set(type, (observerCounts.get(type) ?? 1) - 1);
    }
    this.types.clear();
    this.buffer = [];
    this.scheduled = false;
    this.generation++;
    kObservers.delete(this);
  }

  takeRecords() {
    const entries = this.buffer;
    this.buffer = [];
    return entries;
  }

  bufferEntry(entry) {
    if (!this.types.has(entry.entryType)) {
      return;
    }
    this.buffer.push(entry);
    if (!this.scheduled) {
      this.scheduled = true;
      const generation = this.generation;
      setImmediate(() => {
        if (generation !== this.generation) return;
        this.scheduled = false;
        const entries = this.buffer;
        if (entries.length === 0) {
          return;
        }
        this.buffer = [];
        this.callback.$call(undefined, makeNodeEntryList(entries), this.owner);
      });
    }
  }
}

const kEntryListToken = Symbol("PerformanceObserverEntryList");
const entryListBuffers = new WeakMap();

function entryListBuffer(receiver) {
  const buffer = entryListBuffers.get(receiver);
  if (buffer === undefined) {
    throw $ERR_INVALID_THIS("PerformanceObserverEntryList");
  }
  return buffer;
}

class PerformanceObserverEntryList {
  constructor(token = undefined, entries = []) {
    if (token !== kEntryListToken) throw $ERR_ILLEGAL_CONSTRUCTOR();
    entryListBuffers.set(this, entries.slice().sort((a, b) => a.startTime - b.startTime));
  }

  getEntries() {
    return entryListBuffer(this).slice();
  }

  getEntriesByType(type) {
    const buffer = entryListBuffer(this);
    if (arguments.length === 0) throw $ERR_MISSING_ARGS("type");
    type = `${type}`;
    return buffer.filter(entry => entry.entryType === type);
  }

  getEntriesByName(name, type = undefined) {
    const buffer = entryListBuffer(this);
    if (arguments.length === 0) throw $ERR_MISSING_ARGS("name");
    name = `${name}`;
    return buffer.filter(entry => entry.name === name && (type == null || entry.entryType === type));
  }
}
for (const method of ["getEntries", "getEntriesByType", "getEntriesByName"]) {
  Object.defineProperty(PerformanceObserverEntryList.prototype, method, { enumerable: true });
}
Object.defineProperty(PerformanceObserverEntryList.prototype, Symbol.toStringTag, {
  value: "PerformanceObserverEntryList", configurable: true,
});

function makeNodeEntryList(entries) {
  return new PerformanceObserverEntryList(kEntryListToken, entries);
}

const resourceStates = new WeakMap();
let resourceBuffer = [];
let resourceSecondaryBuffer = [];
let resourceBufferSize = 250;
let resourceBufferFullPending = false;

function resourceState(receiver) {
  const state = resourceStates.get(receiver);
  if (!state) throw $ERR_INVALID_THIS("PerformanceResourceTiming");
  return state;
}

class PerformanceResourceTiming extends globalThis.PerformanceEntry {
  constructor() { throw $ERR_ILLEGAL_CONSTRUCTOR(); }
  get name() { return resourceState(this).url; }
  get entryType() { resourceState(this); return "resource"; }
  get startTime() { return resourceState(this).timing.startTime; }
  get duration() { const timing = resourceState(this).timing; return timing.endTime - timing.startTime; }
  get initiatorType() { return resourceState(this).initiator; }
  get workerStart() { return resourceState(this).timing.finalServiceWorkerStartTime; }
  get redirectStart() { return resourceState(this).timing.redirectStartTime; }
  get redirectEnd() { return resourceState(this).timing.redirectEndTime; }
  get fetchStart() { return resourceState(this).timing.postRedirectStartTime; }
  get domainLookupStart() { return resourceState(this).timing.finalConnectionTimingInfo?.domainLookupStartTime; }
  get domainLookupEnd() { return resourceState(this).timing.finalConnectionTimingInfo?.domainLookupEndTime; }
  get connectStart() { return resourceState(this).timing.finalConnectionTimingInfo?.connectionStartTime; }
  get connectEnd() { return resourceState(this).timing.finalConnectionTimingInfo?.connectionEndTime; }
  get secureConnectionStart() { return resourceState(this).timing.finalConnectionTimingInfo?.secureConnectionStartTime; }
  get nextHopProtocol() { return resourceState(this).timing.finalConnectionTimingInfo?.ALPNNegotiatedProtocol; }
  get requestStart() { return resourceState(this).timing.finalNetworkRequestStartTime; }
  get finalResponseHeadersStart() { return resourceState(this).timing.finalNetworkResponseStartTime; }
  get firstInterimResponseStart() { return resourceState(this).timing.firstInterimNetworkResponseStartTime ?? 0; }
  get responseStart() { const timing = resourceState(this).timing; return timing.firstInterimNetworkResponseStartTime || timing.finalNetworkResponseStartTime; }
  get responseEnd() { return resourceState(this).timing.endTime; }
  get encodedBodySize() { return resourceState(this).timing.encodedBodySize; }
  get decodedBodySize() { return resourceState(this).timing.decodedBodySize; }
  get transferSize() { const state = resourceState(this); return state.cache === "local" ? 0 : state.cache === "validated" ? 300 : state.timing.encodedBodySize + 300; }
  get deliveryType() { return resourceState(this).delivery; }
  get responseStatus() { return resourceState(this).status; }
  get renderBlockingStatus() { return resourceState(this).timing.renderBlocking === true ? "blocking" : "non-blocking"; }
  get contentType() { return resourceState(this).body?.contentType ?? ""; }
  get contentEncoding() { return resourceState(this).body?.contentEncoding ?? ""; }
  toJSON() {
    resourceState(this);
    const result = {};
    for (const name of resourceTimingProperties) result[name] = this[name];
    return result;
  }
}
const resourceTimingProperties = ["name", "entryType", "startTime", "duration", "initiatorType", "nextHopProtocol", "workerStart", "redirectStart", "redirectEnd", "fetchStart", "domainLookupStart", "domainLookupEnd", "connectStart", "connectEnd", "secureConnectionStart", "requestStart", "finalResponseHeadersStart", "firstInterimResponseStart", "responseStart", "responseEnd", "transferSize", "encodedBodySize", "decodedBodySize", "deliveryType", "responseStatus", "renderBlockingStatus", "contentType", "contentEncoding"];
for (const name of [...resourceTimingProperties, "toJSON"]) {
  Object.defineProperty(PerformanceResourceTiming.prototype, name, { enumerable: true });
}
Object.defineProperty(PerformanceResourceTiming.prototype, Symbol.toStringTag, { value: "PerformanceResourceTiming", configurable: true });

function bufferResourceTiming(entry) {
  if (resourceBuffer.length < resourceBufferSize && !resourceBufferFullPending) {
    resourceBuffer.push(entry);
    return;
  }
  resourceSecondaryBuffer.push(entry);
  if (resourceBufferFullPending) return;
  resourceBufferFullPending = true;
  setImmediate(() => {
    while (resourceSecondaryBuffer.length) {
      const before = resourceSecondaryBuffer.length;
      performance.dispatchEvent(new Event("resourcetimingbufferfull"));
      const preserve = Math.max(Math.min(resourceBufferSize - resourceBuffer.length, resourceSecondaryBuffer.length), 0);
      resourceBuffer.push(...resourceSecondaryBuffer.splice(0, preserve));
      if (resourceSecondaryBuffer.length >= before) resourceSecondaryBuffer = [];
    }
    resourceBufferFullPending = false;
  });
}

// The global argument is part of the public Node signature.
// eslint-disable-next-line pickier/no-unused-vars
function markResourceTiming(timing, url, initiator, global, cache, body, status, delivery = "") {
  if (cache !== "" && cache !== "local") throw $ERR_INTERNAL_ASSERTION("cache must be an empty string or 'local'");
  const entry = Object.create(PerformanceResourceTiming.prototype);
  resourceStates.set(entry, { timing, url, initiator, cache, body, status, delivery });
  for (const observer of kObservers) observer.bufferEntry(entry);
  bufferResourceTiming(entry);
  return entry;
}
function getResourceTimings(name, type) {
  if (type !== undefined && type !== "resource") return [];
  return resourceBuffer.filter(entry => name === undefined || entry.name === name).sort((a, b) => a.startTime - b.startTime);
}
function clearResourceTimings(name) {
  if (name !== undefined && typeof name !== "string") throw $ERR_INVALID_ARG_TYPE("name", "string", name);
  resourceBuffer = name === undefined ? [] : resourceBuffer.filter(entry => entry.name !== name);
}
function mergeResourceTimings(entries, name, type) {
  return [...entries, ...getResourceTimings(name, type)].sort((a, b) => a.startTime - b.startTime);
}
function setResourceTimingBufferSize(size) { resourceBufferSize = size; }

//

export default {
  NotImplementedError,
  throwNotImplemented,
  hideFromStack,
  warnNotImplementedOnce,
  ExceptionWithHostPort,
  NodeAggregateError,
  ConnResetException,
  ErrnoException,
  once,
  getLazy,

  hasObserver,
  startPerf,
  stopPerf,
  kNodeEntryTypes,
  NodeEntryObserver,
  makeNodeEntryList,
  PerformanceObserverEntryList,
  PerformanceResourceTiming,
  markResourceTiming,
  getResourceTimings,
  mergeResourceTimings,
  clearResourceTimings,
  setResourceTimingBufferSize,

  kHandle: Symbol("kHandle"),
  kAutoDestroyed: Symbol("kAutoDestroyed"),
  kResistStopPropagation: Symbol("kResistStopPropagation"),
  kWeakHandler: Symbol("kWeak"),
  kGetNativeReadableProto: Symbol("kGetNativeReadableProto"),
  kEmptyObject,
};
