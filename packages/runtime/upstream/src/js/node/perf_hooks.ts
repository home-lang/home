// Hardcoded module "node:perf_hooks"
const { throwNotImplemented, kNodeEntryTypes, NodeEntryObserver, makeNodeEntryList, PerformanceObserverEntryList } = require('internal/shared');
const { validateInteger, validateObject, validateFunction } = require('internal/validators');

const cppCreateHistogram = $newCppFunction("JSNodePerformanceHooksHistogram.cpp", "jsFunction_createHistogram", 3) as (
  min: number | bigint,
  max: number | bigint,
  figures: number,
) => import("node:perf_hooks").RecordableHistogram;

var {
  Performance,
  PerformanceEntry,
  PerformanceMark,
  PerformanceMeasure,
  PerformanceObserver: NodePerformanceObserver,
} = globalThis;

const constants = {
  NODE_PERFORMANCE_ENTRY_TYPE_DNS: 4,
  NODE_PERFORMANCE_ENTRY_TYPE_GC: 0,
  NODE_PERFORMANCE_ENTRY_TYPE_HTTP: 1,
  NODE_PERFORMANCE_ENTRY_TYPE_HTTP2: 2,
  NODE_PERFORMANCE_ENTRY_TYPE_NET: 3,
  NODE_PERFORMANCE_GC_FLAGS_ALL_AVAILABLE_GARBAGE: 16,
  NODE_PERFORMANCE_GC_FLAGS_ALL_EXTERNAL_MEMORY: 32,
  NODE_PERFORMANCE_GC_FLAGS_CONSTRUCT_RETAINED: 2,
  NODE_PERFORMANCE_GC_FLAGS_FORCED: 4,
  NODE_PERFORMANCE_GC_FLAGS_NO: 0,
  NODE_PERFORMANCE_GC_FLAGS_SCHEDULE_IDLE: 64,
  NODE_PERFORMANCE_GC_FLAGS_SYNCHRONOUS_PHANTOM_PROCESSING: 8,
  NODE_PERFORMANCE_GC_INCREMENTAL: 8,
  NODE_PERFORMANCE_GC_MAJOR: 4,
  NODE_PERFORMANCE_GC_MINOR: 1,
  NODE_PERFORMANCE_GC_WEAKCB: 16,
  NODE_PERFORMANCE_MILESTONE_BOOTSTRAP_COMPLETE: 7,
  NODE_PERFORMANCE_MILESTONE_ENVIRONMENT: 2,
  NODE_PERFORMANCE_MILESTONE_LOOP_EXIT: 6,
  NODE_PERFORMANCE_MILESTONE_LOOP_START: 5,
  NODE_PERFORMANCE_MILESTONE_NODE_START: 3,
  NODE_PERFORMANCE_MILESTONE_TIME_ORIGIN_TIMESTAMP: 0,
  NODE_PERFORMANCE_MILESTONE_TIME_ORIGIN: 1,
  NODE_PERFORMANCE_MILESTONE_V8_START: 4,
};

// PerformanceEntry is not a valid constructor, so we have to fake it.
class PerformanceNodeTiming extends PerformanceEntry {
  get bootstrapComplete() { return readLoopUtilization(true).bootstrapComplete; }
  get environment() { return readLoopUtilization(true).environment; }
  get idleTime() { return readLoopUtilization().idle; }
  get loopExit() { return readLoopUtilization(true).loopExit; }
  get loopStart() { return readLoopUtilization(true).loopStart; }
  get nodeStart() { return 0; }
  get v8Start() { return readLoopUtilization(true).v8Start; }

  get name() {
    return "node";
  }

  get entryType() {
    return "node";
  }

  get startTime() {
    return 0;
  }

  get duration() {
    return performance.now();
  }

  toJSON() {
    return {
      name: this.name,
      entryType: this.entryType,
      startTime: this.startTime,
      duration: this.duration,
      bootstrapComplete: this.bootstrapComplete,
      environment: this.environment,
      idleTime: this.idleTime,
      loopExit: this.loopExit,
      loopStart: this.loopStart,
      nodeStart: this.nodeStart,
      v8Start: this.v8Start,
    };
  }
}

const readLoopUtilization = $cpp("JS2Native.cpp", "Home::createPerformanceBinding");
function createPerformanceNodeTiming() {
  return Object.create(PerformanceNodeTiming.prototype);
}

function eventLoopUtilization(utilization1, utilization2) {
  const current = readLoopUtilization();
  if (current.idle === 0 && current.active === 0) return { idle: 0, active: 0, utilization: 0 };
  const idle = utilization2 ? utilization1.idle - utilization2.idle : current.idle - (utilization1 ? utilization1.idle : 0);
  const active = utilization2 ? utilization1.active - utilization2.active : current.active - (utilization1 ? utilization1.active : 0);
  return { idle, active, utilization: active / (idle + active) };
}

// PerformanceEntry is not a valid constructor, so we have to fake it.
class PerformanceResourceTiming {
  constructor() {
    throwNotImplemented("PerformanceResourceTiming");
  }
}
$toClass(PerformanceResourceTiming, "PerformanceResourceTiming", PerformanceEntry);

const kNodeObserver = Symbol("kNodeObserver");
const kObserverCallback = Symbol("kObserverCallback");
const kObserverMode = Symbol("kObserverMode");
const kObserverEntries = Symbol("kObserverEntries");
const kObserverScheduled = Symbol("kObserverScheduled");
const kObserverGeneration = Symbol("kObserverGeneration");

class PerformanceObserverForNodeTypes extends NodePerformanceObserver {
  constructor(callback) {
    validateFunction(callback, "callback");
    let owner;
    super(list => owner.#enqueueEntries(list.getEntries()));
    owner = this;
    this[kObserverCallback] = callback;
    this[kObserverEntries] = [];
    this[kObserverScheduled] = false;
    this[kObserverGeneration] = 0;
  }

  static get supportedEntryTypes() {
    return [...new Set([...(NodePerformanceObserver.supportedEntryTypes ?? []), ...kNodeEntryTypes])].sort();
  }

  #enqueueEntries(entries) {
    this[kObserverEntries].push(...entries);
    if (this[kObserverScheduled]) return;
    this[kObserverScheduled] = true;
    const generation = this[kObserverGeneration];
    setImmediate(() => {
      if (generation !== this[kObserverGeneration]) return;
      this[kObserverScheduled] = false;
      const records = this.takeRecords();
      if (records.length) this[kObserverCallback].$call(this, makeNodeEntryList(records), this);
    });
  }

  observe(options) {
    validateObject(options, "options");
    const { entryTypes, type, buffered } = options;
    if (entryTypes !== undefined && type !== undefined) {
      throw $ERR_INVALID_ARG_VALUE("options.entryTypes", entryTypes, "can not be set with options.type together");
    }
    if (entryTypes !== undefined && !Array.isArray(entryTypes)) {
      throw $ERR_INVALID_ARG_TYPE("options.entryTypes", "string[]", entryTypes);
    }
    if (entryTypes === undefined && type === undefined) throw $ERR_MISSING_ARGS("options.entryTypes", "options.type");
    const mode = entryTypes === undefined ? "single" : "multiple";
    if (this[kObserverMode] !== undefined && this[kObserverMode] !== mode) {
      throw new DOMException("PerformanceObserver can not change observation mode", "InvalidModificationError");
    }
    const requested = (mode === "single" ? [type] : entryTypes).filter(entry => PerformanceObserverForNodeTypes.supportedEntryTypes.includes(entry));
    if (mode === "multiple" && requested.length === 0) return this.disconnect();
    const nodeTypes = requested.filter(entry => kNodeEntryTypes.has(entry));
    const webTypes = requested.filter(entry => !kNodeEntryTypes.has(entry));
    // Native validation happens before changing the Node registry or mode.
    if (webTypes.length) {
      super.observe(mode === "single" ? { type, buffered } : { entryTypes: webTypes });
    } else if (mode === "multiple") {
      super.disconnect();
    }
    this[kObserverMode] = mode;
    if (requested.length === 0) return;
    let registration = this[kNodeObserver];
    if (nodeTypes.length && !registration) {
      registration = this[kNodeObserver] = new NodeEntryObserver(list => this.#enqueueEntries(list.getEntries()), this);
    }
    if (registration) registration.observe(mode === "single" ? [...registration.types, ...nodeTypes] : nodeTypes);
  }

  takeRecords() {
    const records = this[kObserverEntries];
    this[kObserverEntries] = [];
    records.push(...super.takeRecords(), ...(this[kNodeObserver]?.takeRecords() ?? []));
    return records.sort((a, b) => a.startTime - b.startTime);
  }

  disconnect() {
    this[kNodeObserver]?.disconnect();
    this[kNodeObserver] = undefined;
    this[kObserverEntries] = [];
    this[kObserverScheduled] = false;
    this[kObserverGeneration]++;
    this[kObserverMode] = undefined;
    return super.disconnect();
  }
}
// Not $toClass: that resets the prototype object and would drop the
// observe/disconnect overrides above. Only the public name needs fixing.
Object.defineProperty(PerformanceObserverForNodeTypes, "name", {
  value: "PerformanceObserver",
  configurable: true,
});

export default {
  performance: {
    mark(_) {
      return performance.mark(...arguments);
    },
    measure(_) {
      return performance.measure(...arguments);
    },
    clearMarks(_) {
      return performance.clearMarks(...arguments);
    },
    clearMeasures(_) {
      return performance.clearMeasures(...arguments);
    },
    getEntries(_) {
      return performance.getEntries(...arguments);
    },
    getEntriesByName(_) {
      return performance.getEntriesByName(...arguments);
    },
    getEntriesByType(_) {
      return performance.getEntriesByType(...arguments);
    },
    setResourceTimingBufferSize(_) {
      return performance.setResourceTimingBufferSize(...arguments);
    },
    timeOrigin: performance.timeOrigin,
    toJSON(_) {
      return performance.toJSON(...arguments);
    },
    onresourcetimingbufferfull: performance.onresourcetimingbufferfull,
    nodeTiming: createPerformanceNodeTiming(),
    now: () => performance.now(),
    eventLoopUtilization: eventLoopUtilization,
    clearResourceTimings: function () { return performance.clearResourceTimings(...arguments); },
  },
  // performance: {
  //   clearMarks: [Function: clearMarks],
  //   clearMeasures: [Function: clearMeasures],
  //   clearResourceTimings: [Function: clearResourceTimings],
  //   getEntries: [Function: getEntries],
  //   getEntriesByName: [Function: getEntriesByName],
  //   getEntriesByType: [Function: getEntriesByType],
  //   mark: [Function: mark],
  //   measure: [Function: measure],
  //   now: performance.now,
  //   setResourceTimingBufferSize: [Function: setResourceTimingBufferSize],
  //   timeOrigin: performance.timeOrigin,
  //   toJSON: [Function: toJSON],
  //   onresourcetimingbufferfull: [Getter/Setter]
  // },
  constants,
  Performance,
  PerformanceEntry,
  PerformanceMark,
  PerformanceMeasure,
  PerformanceObserver: PerformanceObserverForNodeTypes,
  PerformanceObserverEntryList,
  PerformanceNodeTiming,
  monitorEventLoopDelay: function monitorEventLoopDelay(options?: { resolution?: number }) {
    const impl = require("internal/perf_hooks/monitorEventLoopDelay");
    return impl(options);
  },
  createHistogram: function createHistogram(options?: {
    lowest?: number | bigint;
    highest?: number | bigint;
    figures?: number;
  }): import("node:perf_hooks").RecordableHistogram {
    const opts = options === undefined ? {} : options;
    validateObject(opts, "options");

    const { lowest = 1, highest = Number.MAX_SAFE_INTEGER, figures = 3 } = opts;

    for (const [name, value] of [["options.lowest", lowest], ["options.highest", highest]] as const) {
      if (typeof value === "bigint") {
        if (value < 1n || value > 9223372036854775807n) {
          throw $ERR_OUT_OF_RANGE(name, ">= 1n && <= 9223372036854775807n", value);
        }
      } else {
        validateInteger(value, name, 1, Number.MAX_SAFE_INTEGER);
      }
    }

    const minimumHighest = 2n * BigInt(lowest);
    if (BigInt(highest) < minimumHighest) {
      throw $ERR_OUT_OF_RANGE("options.highest", `>= 2 * options.lowest (${minimumHighest}n)`, highest);
    }
    validateInteger(figures, "options.figures", 1, 5);

    return cppCreateHistogram(lowest, highest, figures);
  },
  PerformanceResourceTiming,
};
