// Internal module for monitorEventLoopDelay implementation
const { validateObject, validateInteger } = require("internal/validators");

// Private C++ bindings for event loop delay monitoring
const cppMonitorEventLoopDelay = $newCppFunction(
  "JSNodePerformanceHooksHistogramPrototype.cpp",
  "jsFunction_monitorEventLoopDelay",
  1,
) as (resolution: number) => import("node:perf_hooks").RecordableHistogram;

const cppEnableEventLoopDelay = $newCppFunction(
  "JSNodePerformanceHooksHistogramPrototype.cpp",
  "jsFunction_enableEventLoopDelay",
  2,
) as (histogram: import("node:perf_hooks").RecordableHistogram, resolution: number) => void;

const cppDisableEventLoopDelay = $newCppFunction(
  "JSNodePerformanceHooksHistogramPrototype.cpp",
  "jsFunction_disableEventLoopDelay",
  1,
) as (histogram: import("node:perf_hooks").RecordableHistogram) => void;

// Each public histogram owns its own enable/disable state and resolution.
function monitorEventLoopDelay(options?: { resolution?: number }) {
  if (options !== undefined) validateObject(options, "options");
  const resolutionOption = options?.resolution;
  if (resolutionOption !== undefined) validateInteger(resolutionOption, "options.resolution", 1);
  const resolution = resolutionOption === undefined ? 10 : resolutionOption;
  const histogram = cppMonitorEventLoopDelay(resolution);
  let enabled = false;
  function enable() {
    if (enabled) return false;
    cppEnableEventLoopDelay(histogram, resolution);
    enabled = true;
    return true;
  }
  function disable() {
    if (!enabled) return false;
    cppDisableEventLoopDelay(histogram);
    enabled = false;
    return true;
  }
  $putByValDirect(histogram, "enable", enable);
  $putByValDirect(histogram, "disable", disable);
  $putByValDirect(histogram, Symbol.dispose, disable);
  return histogram;
}

export default monitorEventLoopDelay;
