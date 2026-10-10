// Hardcoded module "node:perf_hooks"
const { throwNotImplemented, kNodeEntryTypes, NodeEntryObserver } = require('internal/shared');
const { validateInteger, validateObject } = require('internal/validators');

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
  PerformanceObserverEntryList,
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
class PerformanceNodeTiming {
  bootstrapComplete: number = 0;
  environment: number = 0;
  idleTime: number = 0;
  loopExit: number = 0;
  loopStart: number = 0;
  nodeStart: number = 0;
  v8Start: number = 0;

  // we have to fake the properties since it's not real
  get name() {
    return "node";
  }

  get entryType() {
    return "node";
  }

  get startTime() {
    return this.nodeStart;
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
$toClass(PerformanceNodeTiming, "PerformanceNodeTiming", PerformanceEntry);

function createPerformanceNodeTiming() {
  const object = Object.create(PerformanceNodeTiming.prototype);

  object.bootstrapComplete = object.environment = object.nodeStart = object.v8Start = performance.timeOrigin;
  object.loopStart = object.idleTime = 1;
  object.loopExit = -1;
  return object;
}

const readLoopUtilization = $cpp("JS2Native.cpp", "Home::createPerformanceBinding");
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

/**
 * The native (WebCore) observer only understands mark/measure/resource.
 * Node-only entry types ('net', 'dns', ...) are routed to the JS-side
 * registry in internal/shared; everything else is delegated to the native
 * observer unchanged. (`NodePerformanceObserver` is the existing alias for
 * the native class destructured from globalThis above.)
 */
class PerformanceObserverForNodeTypes extends NodePerformanceObserver {
  constructor(callback) {
    super(callback);
    this[kObserverCallback] = callback;
  }

  /** The native list plus the Node-only types routed through the JS registry. */
  static get supportedEntryTypes() {
    return [...new Set([...(NodePerformanceObserver.supportedEntryTypes ?? []), ...kNodeEntryTypes])].sort();
  }

  observe(options) {
    let requested;
    let isTypeMode = false;
    if (options != null && typeof options === "object") {
      const entryTypes = options.entryTypes;
      let type;
      if (entryTypes !== undefined && Array.isArray(entryTypes)) {
        requested = entryTypes;
      } else if ((type = options.type) !== undefined) {
        requested = [type];
        isTypeMode = true;
      }
    }
    if (requested) {
      const nodeTypes = requested.filter(type => kNodeEntryTypes.has(type));
      let registration = this[kNodeObserver];
      if (nodeTypes.length > 0 && !registration) {
        registration = this[kNodeObserver] = new NodeEntryObserver(this[kObserverCallback], this);
      }
      if (registration) {
        if (isTypeMode) {
          // observe({type}) appends to the observed set per the spec.
          registration.observe([...registration.types, ...nodeTypes]);
        } else {
          // observe({entryTypes}) replaces the observed set, including
          // dropping a previously-observed node type when the new set has
          // none.
          registration.observe(nodeTypes);
        }
      }
      if (nodeTypes.length > 0) {
        const webTypes = requested.filter(type => !kNodeEntryTypes.has(type));
        if (webTypes.length === 0) {
          // observe({entryTypes}) replaces the whole observed set: a
          // previously-subscribed web type must stop firing when the new set
          // is node-only. The native impl rejects an empty entryTypes array,
          // so drop the subscription instead of re-observing with [].
          if (!isTypeMode) {
            try {
              super.disconnect();
            } catch {}
          }
          return;
        }
        // A non-empty webTypes set alongside a node type is only possible in
        // entryTypes mode (observe({type}) requests exactly one type), so the
        // forwarded subscription is always an entryTypes one.
        return super.observe({ ...options, entryTypes: webTypes });
      }
    }
    return super.observe(options);
  }

  disconnect() {
    this[kNodeObserver]?.disconnect();
    this[kNodeObserver] = undefined;
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
